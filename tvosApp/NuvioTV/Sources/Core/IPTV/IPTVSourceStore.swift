import Foundation
import Security

struct IPTVSource: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable { case m3u, xtream, stalker }
    let id: UUID
    var name: String
    var playlistURL: String
    var kind: Kind
    var username: String?
    var password: String?
    var mac: String?
    var xtreamOutput: IPTVXtreamOutput

    init(id: UUID, name: String, playlistURL: String, kind: Kind = .m3u, username: String? = nil, password: String? = nil, mac: String? = nil, xtreamOutput: IPTVXtreamOutput = .mpegTS) {
        self.id = id; self.name = name; self.playlistURL = playlistURL
        self.kind = kind; self.username = username; self.password = password; self.mac = mac; self.xtreamOutput = xtreamOutput
    }

    private enum CodingKeys: String, CodingKey { case id, name, playlistURL, kind, username, password, mac, xtreamOutput }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        playlistURL = try c.decode(String.self, forKey: .playlistURL)
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .m3u
        username = try c.decodeIfPresent(String.self, forKey: .username)
        password = try c.decodeIfPresent(String.self, forKey: .password)
        mac = try c.decodeIfPresent(String.self, forKey: .mac)
        xtreamOutput = try c.decodeIfPresent(IPTVXtreamOutput.self, forKey: .xtreamOutput) ?? .mpegTS
    }
}

protocol IPTVSourceStorage {
    func read(profileID: String) throws -> Data?
    func write(_ data: Data, profileID: String) throws
    func remove(profileID: String) throws
}

enum IPTVSourceStoreError: Error, Equatable {
    case invalidProfile
    case invalidSource
    case duplicateID
    case keychain(OSStatus)
}

/// Per-profile source definitions. Playlist URLs can contain credentials, so
/// the entire payload is kept in Keychain rather than preferences or logs.
struct IPTVSourceStore {
    let storage: any IPTVSourceStorage

    init(storage: any IPTVSourceStorage = IPTVKeychainStorage()) {
        self.storage = storage
    }

    func load(profileID: String) throws -> [IPTVSource] {
        guard !profileID.isEmpty else { throw IPTVSourceStoreError.invalidProfile }
        guard let data = try storage.read(profileID: profileID) else { return [] }
        return try JSONDecoder().decode([IPTVSource].self, from: data)
    }

    func save(_ sources: [IPTVSource], profileID: String) throws {
        guard !profileID.isEmpty else { throw IPTVSourceStoreError.invalidProfile }
        var ids = Set<UUID>()
        for source in sources {
            guard ids.insert(source.id).inserted else { throw IPTVSourceStoreError.duplicateID }
            guard !source.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let url = URL(string: source.playlistURL),
                  let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
                  let host = url.host, !host.isEmpty else { throw IPTVSourceStoreError.invalidSource }
            if source.kind == .xtream {
                guard let username = source.username, !username.isEmpty,
                      let password = source.password, !password.isEmpty,
                      IPTVXtreamClient.apiURL(credentials: IPTVXtreamCredentials(server: url, username: username, password: password), action: nil) != nil else {
                    throw IPTVSourceStoreError.invalidSource
                }
            }
            if source.kind == .stalker {
                guard let mac = source.mac, IPTVStalkerProtocol.normalizedMAC(mac) != nil,
                      IPTVStalkerProtocol.requestURL(portal: url, type: "stb", action: "handshake") != nil else {
                    throw IPTVSourceStoreError.invalidSource
                }
            }
        }
        if sources.isEmpty {
            try storage.remove(profileID: profileID)
        } else {
            try storage.write(JSONEncoder().encode(sources), profileID: profileID)
        }
    }
}

struct IPTVKeychainStorage: IPTVSourceStorage {
    private static let service = "com.nuvio.tv.iptv.sources"

    func read(profileID: String) throws -> Data? {
        var query = baseQuery(profileID: profileID)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw IPTVSourceStoreError.keychain(status) }
        guard let data = result as? Data else { throw IPTVSourceStoreError.keychain(errSecDecode) }
        return data
    }

    func write(_ data: Data, profileID: String) throws {
        let query = baseQuery(profileID: profileID)
        var item = query
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecValueData as String] = data
        var status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
        guard status == errSecSuccess else { throw IPTVSourceStoreError.keychain(status) }
    }

    func remove(profileID: String) throws {
        let status = SecItemDelete(baseQuery(profileID: profileID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw IPTVSourceStoreError.keychain(status) }
    }

    /// Called during a full sign-out to remove sources for retired profiles too.
    static func removeAll() throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw IPTVSourceStoreError.keychain(status) }
    }

    private func baseQuery(profileID: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: profileID]
    }
}
