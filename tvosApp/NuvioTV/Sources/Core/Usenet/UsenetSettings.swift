import Foundation
import Security

/// A Usenet provider saved in Settings. The password lives in Keychain
/// (`UsenetCredentialStore`), never in UserDefaults, sync or exports.
struct UsenetSavedServer: Codable, Identifiable, Equatable, Hashable {
    var id: String = UUID().uuidString
    var name: String
    var host: String
    var port: Int
    var useSSL: Bool
    var username: String
    var connections: Int
    var isEnabled: Bool = true

    var displayName: String { name.isEmpty ? host : name }

    func config(password: String) -> UsenetServerConfig {
        UsenetServerConfig(
            host: host,
            port: port,
            useSSL: useSSL,
            username: username.isEmpty ? nil : username,
            password: password.isEmpty ? nil : password,
            maxConnections: connections
        )
    }
}

enum UsenetSettings {
    static let serversKey = "nuvio.tv.settings.integrations.usenetServers"
    static let profileKey = "nuvio.tv.settings.integrations.usenetProfile"
    static let preferOwnServersKey = "nuvio.tv.settings.integrations.usenetPreferOwnServers"
    static let speedLimitKey = "nuvio.tv.settings.integrations.usenetSpeedLimit"

    /// Speed cap choices in Mbit/s; 0 means no cap.
    static let speedLimitOptions = [0, 200, 100, 50, 25]

    static func speedLimitMbps(store: UserDefaults = ProfileSettings.current) -> Int {
        let value = store.integer(forKey: speedLimitKey)
        return speedLimitOptions.contains(value) ? value : 0
    }

    static func setSpeedLimitMbps(_ value: Int, store: UserDefaults = ProfileSettings.current) {
        store.set(speedLimitOptions.contains(value) ? value : 0, forKey: speedLimitKey)
    }

    static func servers(store: UserDefaults = ProfileSettings.current) -> [UsenetSavedServer] {
        guard let data = store.data(forKey: serversKey),
              let servers = try? JSONDecoder().decode([UsenetSavedServer].self, from: data) else { return [] }
        return servers
    }

    static func setServers(_ servers: [UsenetSavedServer], store: UserDefaults = ProfileSettings.current) {
        store.set(try? JSONEncoder().encode(servers), forKey: serversKey)
        NotificationCenter.default.post(name: .usenetServersChanged, object: nil)
    }

    static func upsert(_ server: UsenetSavedServer, password: String?, store: UserDefaults = ProfileSettings.current) {
        var all = servers(store: store)
        if let index = all.firstIndex(where: { $0.id == server.id }) {
            all[index] = server
        } else {
            all.append(server)
        }
        if let password { UsenetCredentialStore.save(password, forServerID: server.id) }
        setServers(all, store: store)
    }

    static func remove(_ id: String, store: UserDefaults = ProfileSettings.current) {
        setServers(servers(store: store).filter { $0.id != id }, store: store)
        UsenetCredentialStore.remove(forServerID: id)
    }

    /// The enabled servers from Settings, in their saved order.
    static func configuredServers(store: UserDefaults = ProfileSettings.current) -> [UsenetServerConfig] {
        servers(store: store).filter(\.isEnabled).map {
            $0.config(password: UsenetCredentialStore.password(forServerID: $0.id))
        }
    }

    static func profile(store: UserDefaults = ProfileSettings.current) -> UsenetMemoryProfile {
        store.string(forKey: profileKey).flatMap(UsenetMemoryProfile.init(rawValue:)) ?? .balanced
    }

    static func setProfile(_ profile: UsenetMemoryProfile, store: UserDefaults = ProfileSettings.current) {
        store.set(profile.rawValue, forKey: profileKey)
    }

    /// When on, your own servers are used even if the add-on sends its own.
    static func prefersOwnServers(store: UserDefaults = ProfileSettings.current) -> Bool {
        store.bool(forKey: preferOwnServersKey)
    }

    static func setPrefersOwnServers(_ value: Bool, store: UserDefaults = ProfileSettings.current) {
        store.set(value, forKey: preferOwnServersKey)
    }

    /// Servers for a stream: the add-on's (unless you prefer your own), then
    /// yours as the fallback for articles the first ones are missing.
    static func servers(for spec: UsenetStreamSpec, store: UserDefaults = ProfileSettings.current) -> [UsenetServerConfig] {
        let own = configuredServers(store: store)
        if prefersOwnServers(store: store), !own.isEmpty { return own }
        var result = spec.servers
        for server in own where !result.contains(where: { $0.host == server.host && $0.username == server.username }) {
            result.append(server)
        }
        return result
    }
}

extension Notification.Name {
    static let usenetServersChanged = Notification.Name("nuvio.usenet.serversChanged")
}

/// Device-local Usenet passwords, one per server per profile (same pattern as
/// `SMBCredentialStore`).
enum UsenetCredentialStore {
    private static let service = "com.nuvio.tv.usenet"

    static func password(forServerID id: String, profileScope: String = ProfileSettings.activeProfileScope) -> String {
        var query = keychainQuery(id, profileScope)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    @discardableResult
    static func save(_ password: String, forServerID id: String, profileScope: String = ProfileSettings.activeProfileScope) -> Bool {
        guard !password.isEmpty else { return remove(forServerID: id, profileScope: profileScope) }
        let data = Data(password.utf8)
        var add = keychainQuery(id, profileScope)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecValueData as String] = data
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            return SecItemUpdate(keychainQuery(id, profileScope) as CFDictionary,
                                 [kSecValueData as String: data] as CFDictionary) == errSecSuccess
        }
        return status == errSecSuccess
    }

    @discardableResult
    static func remove(forServerID id: String, profileScope: String = ProfileSettings.activeProfileScope) -> Bool {
        let status = SecItemDelete(keychainQuery(id, profileScope) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func keychainQuery(_ id: String, _ profileScope: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "\(id).\(profileScope)",
        ]
    }
}
