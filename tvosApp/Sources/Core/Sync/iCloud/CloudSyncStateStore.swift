import CloudKit
import Foundation

/// File-backed storage for everything `CKSyncEngine` needs to survive a
/// relaunch: its own state serialization, and the CloudKit system fields of
/// records this device has seen.
///
/// Deliberately files, not `UserDefaults`. The settings suite is already
/// watched by two change observers that push on every write, and the codebase
/// has scars from oversized preference plists aborting the process
/// (`SimklSyncCache.purgeLegacyPreferenceBlobs`). Sync bookkeeping has no
/// business in there.
enum CloudSyncStateStore {
    private static let directoryName = "CloudSync"
    private static let stateFile = "sync-engine-state.json"
    private static let systemFieldsFile = "record-system-fields.json"

    // MARK: - Engine state

    static func loadState() -> CKSyncEngine.State.Serialization? {
        guard let url = fileURL(stateFile),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }

    static func saveState(_ serialization: CKSyncEngine.State.Serialization) {
        guard let url = fileURL(stateFile),
              let data = try? JSONEncoder().encode(serialization) else { return }
        try? data.write(to: url, options: [.atomic])
    }

    // MARK: - Record system fields

    /// CloudKit rejects a save whose `recordChangeTag` is stale. Replaying the
    /// system fields of the last version this device saw means the common case
    /// — nobody else changed the record — saves without a conflict round trip.
    static func systemFields(forRecordName name: String) -> CKRecord? {
        guard let data = loadSystemFields()[name] else { return nil }
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        unarchiver.requiresSecureCoding = true
        let record = CKRecord(coder: unarchiver)
        unarchiver.finishDecoding()
        return record
    }

    static func storeSystemFields(of record: CKRecord) {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()

        var cache = loadSystemFields()
        cache[record.recordID.recordName] = archiver.encodedData
        writeSystemFields(cache)
    }

    static func forgetSystemFields(forRecordName name: String) {
        var cache = loadSystemFields()
        guard cache.removeValue(forKey: name) != nil else { return }
        writeSystemFields(cache)
    }

    /// Drops all local sync bookkeeping. Used when the iCloud account changes —
    /// state from the previous account describes records this one cannot see.
    static func reset() {
        for file in [stateFile, systemFieldsFile] {
            guard let url = fileURL(file) else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Whether bookkeeping actually persists, and how much of it there is.
    ///
    /// A failure here is invisible at runtime but fatal to sync: with no cached
    /// system fields every save carries no change tag, the server rejects it as
    /// `serverRecordChanged`, and the retry rebuilds the same tagless record
    /// forever.
    static func healthDiagnostic() -> String {
        guard let directoryURL else { return "no writable directory" }
        let cached = loadSystemFields().count
        let hasState = fileURL(stateFile).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        // Enough of the path to tell Application Support from Caches from tmp,
        // which is the part that actually differs per platform and per install.
        let location = directoryURL.pathComponents.suffix(3).joined(separator: "/")
        return "\(cached) record(s) cached, state \(hasState ? "saved" : "missing"), at \(location)"
    }

    private static func loadSystemFields() -> [String: Data] {
        guard let url = fileURL(systemFieldsFile),
              let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode([String: Data].self, from: data) else {
            return [:]
        }
        return cache
    }

    private static func writeSystemFields(_ cache: [String: Data]) {
        guard let url = fileURL(systemFieldsFile),
              let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: url, options: [.atomic])
    }

    // MARK: - Storage location

    /// Resolved once, probing each candidate with a real write rather than
    /// trusting it — the same approach as
    /// `ProfileViewModel.makeDefaultProfileManager`.
    ///
    /// Order matters on tvOS. Application Support and Documents are *not*
    /// writable there; `Library/Caches` is. Losing this data to a Caches purge
    /// is survivable — a missing state file makes the engine re-fetch, and
    /// missing system fields cost one `serverRecordChanged` round before
    /// converging — whereas having nowhere to write at all is not: every save
    /// then goes up with no change tag and is rejected forever.
    private static let directoryURL: URL? = {
        let fileManager = FileManager.default
        var candidates: [URL] = []

        // Durable when the platform allows it (and on non-tvOS targets).
        for directory in [FileManager.SearchPathDirectory.applicationSupportDirectory, .cachesDirectory] {
            if let base = fileManager.urls(for: directory, in: .userDomainMask).first {
                candidates.append(base.appendingPathComponent("Nuvio", isDirectory: true))
            }
        }

        let homeLibrary = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
        candidates.append(
            homeLibrary
                .appendingPathComponent("Caches", isDirectory: true)
                .appendingPathComponent("Nuvio", isDirectory: true)
        )
        // Last resort: survives the session, which is still enough to stop the
        // tagless-save loop even if it does not survive a relaunch.
        candidates.append(
            URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("Nuvio", isDirectory: true)
        )

        for candidate in candidates {
            let directory = candidate.appendingPathComponent(directoryName, isDirectory: true)
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                let probe = directory.appendingPathComponent(".probe-\(UUID().uuidString)")
                try Data().write(to: probe, options: .atomic)
                try? fileManager.removeItem(at: probe)
                return directory
            } catch {
                continue
            }
        }
        print("iCloud sync state has no writable directory; every save will be rejected as serverRecordChanged.")
        return nil
    }()

    private static func fileURL(_ name: String) -> URL? {
        directoryURL?.appendingPathComponent(name)
    }
}
