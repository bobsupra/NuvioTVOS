import Foundation

/// One resolved SMB file within a title. `season`/`episode` are set only when
/// the parent title is a series.
struct SMBIndexedFile: Codable, Equatable {
    let serverID: String
    let share: String
    /// Share-relative path, e.g. `"Movies/Foo (2020)/Foo.mkv"`.
    let path: String
    let filename: String
    let size: Int64
    var season: Int?
    var episode: Int?

    /// `smb://host[:port]/share/path` — what `AetherPlaybackController` opens
    /// and what backs the synthetic "Local (SMB)" stream's `NuvioStream.url`.
    /// `host` is not stored on the file (only on `SMBServerConfig`); callers
    /// build the full URL once they have both.
    func streamPath(hostAndPort: String) -> String {
        "smb://\(hostAndPort)/\(share)/\(path)"
    }
}

/// A local title the scanner matched to a real Cinemeta id. Metadata itself
/// is never stored here — it's re-fetched through the same `getMetadata` path
/// remote catalog rows use, which is the entire point of resolving to a real
/// id instead of caching the filename's guess.
struct SMBIndexedTitle: Codable, Equatable {
    let contentId: String
    let type: String
    let year: Int?
    var files: [SMBIndexedFile]
}

/// Persisted record of every server's scan results: `contentId → files`. This
/// is the durable index — small (ids and paths, not artwork or descriptions)
/// and must survive app eviction, unlike the Caches-backed continue-watching
/// snapshot (`Models/CatalogModels.swift`, whose own comment notes Caches is
/// evictable and Application Support only worked in the Simulator on tvOS).
/// Stored as JSON in the active profile's `UserDefaults`, alongside the
/// server list.
@MainActor
final class SMBLibraryIndex: ObservableObject {
    static let shared = SMBLibraryIndex()

    static let changedNotification = Notification.Name("nuvio.tv.smb.library.changed")

    @Published private(set) var titlesByServerID: [String: [SMBIndexedTitle]] = [:]

    private init() {
        titlesByServerID = Self.load()
    }

    func reload() {
        titlesByServerID = Self.load()
    }

    /// All indexed titles across every server, ordered by
    /// `SMBServerStore.servers` when possible. Falls back to appending any
    /// server id `SMBServerStore` doesn't currently know about (rather than
    /// silently dropping its titles) — the two stores are kept in sync in
    /// normal operation (`SMBServerStore.remove` clears the matching index
    /// entry), but a title must never simply vanish if they ever diverge.
    func titles() -> [SMBIndexedTitle] {
        let orderedServerIDs = SMBServerStore.shared.servers.map(\.id)
        let ordered = orderedServerIDs.flatMap { titlesByServerID[$0] ?? [] }
        let knownIDs = Set(orderedServerIDs)
        let unordered = titlesByServerID
            .filter { !knownIDs.contains($0.key) }
            .values
            .flatMap { $0 }
        return ordered + unordered
    }

    func files(forContentId contentId: String, season: Int?, episode: Int?) -> [SMBIndexedFile] {
        titles()
            .first { $0.contentId == contentId }?
            .files
            .filter { $0.season == season && $0.episode == episode }
            ?? []
    }

    func replace(titles: [SMBIndexedTitle], forServerID serverID: String) {
        titlesByServerID[serverID] = titles
        persist()
    }

    func removeAll(forServerID serverID: String) {
        titlesByServerID.removeValue(forKey: serverID)
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(titlesByServerID) else { return }
        ProfileSettings.current.set(data, forKey: SettingsKey.smbLibraryIndex)
        NotificationCenter.default.post(name: Self.changedNotification, object: nil)
    }

    private static func load() -> [String: [SMBIndexedTitle]] {
        guard let data = ProfileSettings.current.data(forKey: SettingsKey.smbLibraryIndex),
              let decoded = try? JSONDecoder().decode([String: [SMBIndexedTitle]].self, from: data) else {
            return [:]
        }
        return decoded
    }
}
