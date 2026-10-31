import Foundation

/// The profile's Usenet settings in the Nuvio account, when the profile opts in
/// (Settings → Usenet → Save to Nuvio Account): servers with their passwords,
/// the performance profile, the speed limit and "Always Use My Servers". A
/// reinstall or another Apple TV signed in to the account gets them back.
///
/// Kept in its own feature of the profile's "tv" settings blob. The choice is
/// part of the copy, so turning it off on one Apple TV clears the servers and
/// passwords from the account for all of them. A device where it was never
/// chosen leaves the account's copy as it is: a fresh install doesn't wipe it
/// before its first pull brings it back.
enum UsenetSettingsSync {
    static let featureKey = "tvos_usenet_settings"

    private enum Key {
        static let enabled = "enabled"
        static let servers = "servers"
        static let profile = "profile"
        static let preferOwnServers = "preferOwnServers"
        static let speedLimitMbps = "speedLimitMbps"
    }

    private enum ServerKey {
        static let id = "id"
        static let name = "name"
        static let host = "host"
        static let port = "port"
        static let useSSL = "useSSL"
        static let username = "username"
        static let password = "password"
        static let connections = "connections"
        static let isEnabled = "isEnabled"
    }

    /// The feature to write. Never chosen: the account's copy unchanged (nil
    /// when there is none). Off: only the choice. On: everything.
    static func export(
        store: UserDefaults,
        existing: [String: Any]?,
        password: (String) -> String
    ) -> [String: Any]? {
        switch UsenetSettings.syncChoice(store: store) {
        case nil:
            return existing
        case false?:
            return [Key.enabled: false]
        case true?:
            let servers: [[String: Any]] = UsenetSettings.servers(store: store).map { server in
                [
                    ServerKey.id: server.id,
                    ServerKey.name: server.name,
                    ServerKey.host: server.host,
                    ServerKey.port: server.port,
                    ServerKey.useSSL: server.useSSL,
                    ServerKey.username: server.username,
                    ServerKey.password: password(server.id),
                    ServerKey.connections: server.connections,
                    ServerKey.isEnabled: server.isEnabled,
                ]
            }
            return [
                Key.enabled: true,
                Key.servers: servers,
                Key.profile: UsenetSettings.profile(store: store).rawValue,
                Key.preferOwnServers: UsenetSettings.prefersOwnServers(store: store),
                Key.speedLimitMbps: UsenetSettings.speedLimitMbps(store: store),
            ]
        }
    }

    /// Applies the account's copy. On: its servers replace the local ones, with
    /// their passwords, and the choice turns on here too. Off: the choice turns
    /// off and the local servers stay.
    static func importPayload(
        _ remote: [String: Any]?,
        store: UserDefaults,
        savePassword: (_ password: String, _ serverID: String) -> Void,
        removePassword: (_ serverID: String) -> Void
    ) {
        guard let remote, let enabled = remote[Key.enabled] as? Bool else { return }
        guard enabled else {
            UsenetSettings.setSyncChoice(false, store: store)
            return
        }
        guard let rawServers = remote[Key.servers] as? [[String: Any]] else { return }
        let servers = rawServers.compactMap(server(from:))
        for local in UsenetSettings.servers(store: store) where !servers.contains(where: { $0.server.id == local.id }) {
            removePassword(local.id)
        }
        for (server, password) in servers {
            if password.isEmpty {
                removePassword(server.id)
            } else {
                savePassword(password, server.id)
            }
        }
        store.set(try? JSONEncoder().encode(servers.map { $0.server }), forKey: UsenetSettings.serversKey)
        if let profile = (remote[Key.profile] as? String).flatMap(UsenetMemoryProfile.init(rawValue:)) {
            UsenetSettings.setProfile(profile, store: store)
        }
        if let prefersOwn = remote[Key.preferOwnServers] as? Bool {
            UsenetSettings.setPrefersOwnServers(prefersOwn, store: store)
        }
        if let speedLimit = remote[Key.speedLimitMbps] as? Int {
            UsenetSettings.setSpeedLimitMbps(speedLimit, store: store)
        }
        UsenetSettings.setSyncChoice(true, store: store)
        // Settings listens on the main thread; the pull runs off it.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .usenetServersChanged, object: nil)
        }
    }

    private static func server(from raw: [String: Any]) -> (server: UsenetSavedServer, password: String)? {
        guard let id = raw[ServerKey.id] as? String, !id.isEmpty,
              let host = raw[ServerKey.host] as? String, !host.isEmpty,
              let port = raw[ServerKey.port] as? Int else { return nil }
        let server = UsenetSavedServer(
            id: id,
            name: raw[ServerKey.name] as? String ?? "",
            host: host,
            port: port,
            useSSL: raw[ServerKey.useSSL] as? Bool ?? true,
            username: raw[ServerKey.username] as? String ?? "",
            connections: raw[ServerKey.connections] as? Int ?? 10,
            isEnabled: raw[ServerKey.isEnabled] as? Bool ?? true
        )
        return (server, raw[ServerKey.password] as? String ?? "")
    }
}
