import Foundation

/// Configured SMB servers for the active profile. Mirrors
/// `TVHomeCatalogOrder`'s UserDefaults-JSON-blob pattern
/// (`NuvioTVApp.swift`): small, profile-scoped, notification-driven so
/// Settings and playback code can react without a shared timer.
@MainActor
final class SMBServerStore: ObservableObject {
    static let shared = SMBServerStore()

    static let changedNotification = Notification.Name("nuvio.tv.smb.servers.changed")

    @Published private(set) var servers: [SMBServerConfig] = []

    private init() {
        servers = Self.load()
    }

    /// Re-reads from the active profile's store. Call after a profile switch,
    /// same as `TraktSettingsViewModel.reload()` and friends.
    func reload() {
        servers = Self.load()
    }

    func server(id: String) -> SMBServerConfig? {
        servers.first { $0.id == id }
    }

    func upsert(_ server: SMBServerConfig) {
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
        SMBCredentialStore.remove(forServerID: serverID)
        SMBLibraryIndex.shared.removeAll(forServerID: serverID)
    }

    private func persist(_ servers: [SMBServerConfig]) {
        self.servers = servers
        guard let data = try? JSONEncoder().encode(servers) else { return }
        ProfileSettings.current.set(data, forKey: SettingsKey.smbServers)
        NotificationCenter.default.post(name: Self.changedNotification, object: nil)
    }

    private static func load() -> [SMBServerConfig] {
        guard let data = ProfileSettings.current.data(forKey: SettingsKey.smbServers),
              let servers = try? JSONDecoder().decode([SMBServerConfig].self, from: data) else { return [] }
        return servers
    }
}
