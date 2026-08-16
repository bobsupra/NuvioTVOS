import Foundation

/// Configured Jellyfin servers for the active profile. Mirrors
/// `SMBServerStore`'s UserDefaults-JSON-blob pattern: small, profile-scoped,
/// notification-driven so Settings and Home can react without a shared timer.
@MainActor
final class JellyfinServerStore: ObservableObject {
    static let shared = JellyfinServerStore()

    static let changedNotification = Notification.Name("nuvio.tv.jellyfin.servers.changed")

    @Published private(set) var servers: [JellyfinServerConfig] = []

    private init() {
        servers = Self.load()
    }

    /// Re-reads from the active profile's store. Call after a profile switch.
    func reload() {
        servers = Self.load()
    }

    func server(id: String) -> JellyfinServerConfig? {
        servers.first { $0.id == id }
    }

    func upsert(_ server: JellyfinServerConfig) {
        var updated = servers
        if let index = updated.firstIndex(where: { $0.id == server.id }) {
            updated[index] = server
        } else {
            updated.append(server)
        }
        persist(updated)
    }

    func remove(_ serverID: String) {
        var updated = servers
        updated.removeAll { $0.id == serverID }
        persist(updated)
        JellyfinCredentialStore.remove(forServerID: serverID)
        JellyfinLibraryIndex.shared.removeAll(forServerID: serverID)
    }

    private func persist(_ servers: [JellyfinServerConfig]) {
        self.servers = servers
        guard let data = try? JSONEncoder().encode(servers) else { return }
        ProfileSettings.current.set(data, forKey: SettingsKey.jellyfinServers)
        NotificationCenter.default.post(name: Self.changedNotification, object: nil)
    }

    private static func load() -> [JellyfinServerConfig] {
        guard let data = ProfileSettings.current.data(forKey: SettingsKey.jellyfinServers),
              let servers = try? JSONDecoder().decode([JellyfinServerConfig].self, from: data) else { return [] }
        return servers
    }
}
