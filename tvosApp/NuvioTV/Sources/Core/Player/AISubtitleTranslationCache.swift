import CryptoKit
import Foundation

/// A small, device-local cache for completed subtitle translations. Entries
/// are profile-scoped, never synced, and contain only a hash of the source
/// cue plus the translated text—never the Gemini API key or original cue.
actor AISubtitleTranslationCache {
    static let shared = AISubtitleTranslationCache()

    struct PendingTranslation: Sendable {
        let translatedText: String
        let source: String
    }

    private struct Entry: Codable {
        let translatedText: String
        let createdAt: Date
        var lastAccessedAt: Date
    }

    private struct Store: Codable {
        var entries: [String: Entry] = [:]
    }

    private static let schemaVersion = "v1"
    private static let entryLimit = 10_000
    private static let maximumAge: TimeInterval = 60 * 60 * 24 * 90

    private let directory: URL
    private var stores: [String: Store] = [:]

    init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory()
    }

    func translation(
        for source: String,
        targetLanguage: String,
        model: String,
        stripHearingImpaired: Bool,
        profileScope: String
    ) -> String? {
        let key = Self.key(
            source: source,
            targetLanguage: targetLanguage,
            model: model,
            stripHearingImpaired: stripHearingImpaired
        )
        var store = loadStore(for: profileScope)
        guard var entry = store.entries[key] else { return nil }
        guard Date().timeIntervalSince(entry.createdAt) <= Self.maximumAge else {
            store.entries.removeValue(forKey: key)
            stores[profileScope] = store
            persist(store, for: profileScope)
            return nil
        }
        entry.lastAccessedAt = Date()
        store.entries[key] = entry
        stores[profileScope] = store
        return entry.translatedText
    }

    func store(
        _ translatedText: String,
        for source: String,
        targetLanguage: String,
        model: String,
        stripHearingImpaired: Bool,
        profileScope: String
    ) {
        store(
            [PendingTranslation(translatedText: translatedText, source: source)],
            targetLanguage: targetLanguage,
            model: model,
            stripHearingImpaired: stripHearingImpaired,
            profileScope: profileScope
        )
    }

    /// Stores a completed provider batch with one trim, encode, and atomic
    /// disk write instead of rewriting the whole profile cache per cue.
    func store(
        _ translations: [PendingTranslation],
        targetLanguage: String,
        model: String,
        stripHearingImpaired: Bool,
        profileScope: String
    ) {
        let translations = translations.filter { !$0.translatedText.isEmpty }
        guard !translations.isEmpty else { return }
        var store = loadStore(for: profileScope)
        let now = Date()
        for translation in translations {
            let key = Self.key(
                source: translation.source,
                targetLanguage: targetLanguage,
                model: model,
                stripHearingImpaired: stripHearingImpaired
            )
            store.entries[key] = Entry(
                translatedText: translation.translatedText,
                createdAt: now,
                lastAccessedAt: now
            )
        }
        trim(&store)
        stores[profileScope] = store
        persist(store, for: profileScope)
    }

    func removeAll(profileScope: String) {
        stores.removeValue(forKey: profileScope)
        try? FileManager.default.removeItem(at: fileURL(for: profileScope))
    }

    private func loadStore(for profileScope: String) -> Store {
        if let store = stores[profileScope] { return store }
        let url = fileURL(for: profileScope)
        guard let data = try? Data(contentsOf: url),
              let store = try? JSONDecoder().decode(Store.self, from: data) else {
            let empty = Store()
            stores[profileScope] = empty
            return empty
        }
        stores[profileScope] = store
        return store
    }

    private func persist(_ store: Store, for profileScope: String) {
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let url = fileURL(for: profileScope)
            let data = try JSONEncoder().encode(store)
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path
            )
        } catch {
            // Cache failures must never interrupt subtitle playback.
        }
    }

    private func trim(_ store: inout Store) {
        let cutoff = Date().addingTimeInterval(-Self.maximumAge)
        store.entries = store.entries.filter { $0.value.createdAt >= cutoff }
        guard store.entries.count > Self.entryLimit else { return }
        let keysToRemove = store.entries
            .sorted { $0.value.lastAccessedAt < $1.value.lastAccessedAt }
            .prefix(store.entries.count - Self.entryLimit)
            .map(\.key)
        keysToRemove.forEach { store.entries.removeValue(forKey: $0) }
    }

    private func fileURL(for profileScope: String) -> URL {
        directory.appendingPathComponent("\(Self.digest(profileScope)).json")
    }

    private static func key(
        source: String,
        targetLanguage: String,
        model: String,
        stripHearingImpaired: Bool
    ) -> String {
        digest(
            "\(schemaVersion)|\(model.lowercased())|\(targetLanguage.lowercased())|\(stripHearingImpaired)|\(source)"
        )
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("NuvioTV", isDirectory: true)
            .appendingPathComponent("AISubtitleTranslations", isDirectory: true)
    }
}
