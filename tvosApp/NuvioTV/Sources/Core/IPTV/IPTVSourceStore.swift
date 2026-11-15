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

    /// Where sources are kept unless a store is given another storage (tests swap it).
    static var defaultStorage: any IPTVSourceStorage = IPTVKeychainStorage()

    /// Moved on whenever a profile's sources are removed with the profile, so an
    /// earlier pending save for that profile can't bring them back.
    static let profileGenerations = AccountLoginGenerations()

    init(storage: any IPTVSourceStorage = IPTVSourceStore.defaultStorage) {
        self.storage = storage
    }

    /// Profiles whose sources are still waiting to be deleted (see `removeProfile`).
    /// Kept in preferences for subsequent launches; tests swap it. Preferences
    /// are written asynchronously and do not guarantee crash durability.
    static var pendingRemovals = IPTVPendingSourceRemovals(defaults: .standard)

    func load(profileID: String) throws -> [IPTVSource] {
        guard !profileID.isEmpty else { throw IPTVSourceStoreError.invalidProfile }
        // Keep the check and read together with removals and saves. Otherwise a
        // failed deletion could mark the profile between the check and read.
        return try Self.profileGenerations.exclusive {
            if Self.pendingRemovals.contains(profileID) {
                Self.removeMarked(profileID, storage: storage)
                return []
            }
            guard let data = try storage.read(profileID: profileID) else { return [] }
            return try JSONDecoder().decode([IPTVSource].self, from: data)
        }
    }

    /// The generation to capture before work that saves later (see `save(_:profileID:ifGeneration:)`).
    static func generation(for profileID: String) -> UInt64 {
        profileGenerations.current(for: profileID)
    }

    /// Saves only if the profile's sources weren't removed since `generation`
    /// was captured. Returns false, saving nothing, when they were.
    @discardableResult
    func save(_ sources: [IPTVSource], profileID: String, ifGeneration generation: UInt64) throws -> Bool {
        let payload = try validated(sources, profileID: profileID)
        var failure: Error?
        let saved = Self.profileGenerations.commit(generation, for: profileID) {
            do { try store(payload, profileID: profileID) } catch { failure = error }
        }
        if let failure { throw failure }
        return saved
    }

    /// A profile was deleted, here or on another device. Profile ids can be
    /// reused, so its sources (with their credentials), favourites and last
    /// channel must not pass to a new profile; a pending save for it is stopped.
    /// Other profiles' sources are untouched.
    ///
    /// If Keychain refuses the deletion, the profile stays marked: its sources
    /// aren't read again, and the deletion is retried
    /// on the next load and at launch. A later successful save for the id
    /// replaces the whole Keychain item, which also clears the mark.
    static func removeProfile(_ profileID: String, defaults: UserDefaults? = nil) {
        guard !profileID.isEmpty else { return }
        let storage = defaultStorage
        profileGenerations.invalidate(profileID) {
            // Mark before deleting. Preferences are persisted asynchronously;
            // this does not guarantee durability across an immediate crash.
            pendingRemovals.insert(profileID)
            removeMarked(profileID, storage: storage)
        }
        let settings = defaults ?? ProfileSettings.store(for: profileID)
        IPTVFavoritesStore(defaults: settings).save([])
        IPTVRecentChannelStore.remove(from: settings)
    }

    /// Retries every deletion that failed earlier; called at launch.
    static func retryPendingRemovals(storage: (any IPTVSourceStorage)? = nil) {
        let storage = storage ?? defaultStorage
        for profileID in pendingRemovals.all {
            retryRemoval(profileID, storage: storage)
        }
    }

    /// Mark every retired slot before attempting the full wipe. A failed wipe
    /// leaves those slots unreadable and eligible for the normal retry path.
    static func removeAllSources(profileIDs: [String], removeAll: () throws -> Void = IPTVKeychainStorage.removeAll) {
        let ids = Set(profileIDs.filter { !$0.isEmpty })
        profileGenerations.invalidate(ids) {
            for id in ids { pendingRemovals.insert(id) }
            do {
                try removeAll()
                pendingRemovals.removeAll()
            } catch {
                print("Failed to clear IPTV sources from Keychain; retrying later")
            }
        }
    }

    private static func retryRemoval(_ profileID: String, storage: any IPTVSourceStorage) {
        profileGenerations.exclusive {
            // Another call may have finished it, or a new profile saved meanwhile.
            guard pendingRemovals.contains(profileID) else { return }
            removeMarked(profileID, storage: storage)
        }
    }

    /// Called with the generations lock held.
    private static func removeMarked(_ profileID: String, storage: any IPTVSourceStorage) {
        do {
            try storage.remove(profileID: profileID)
            pendingRemovals.remove(profileID)
        } catch {
            print("IPTV sources of a deleted profile couldn't be removed yet; retrying later")
        }
    }

    func save(_ sources: [IPTVSource], profileID: String) throws {
        let payload = try validated(sources, profileID: profileID)
        let failure: Error? = Self.profileGenerations.exclusive {
            do { try store(payload, profileID: profileID); return nil } catch { return error }
        }
        if let failure { throw failure }
    }

    /// Writes (or, for no sources, deletes) the profile's sources. Run with the
    /// generations lock held, so a retried deletion can't run in between. A
    /// success replaces whatever was kept for the id, so a deletion still
    /// pending for it is done too.
    private func store(_ payload: Data?, profileID: String) throws {
        if let payload {
            try storage.write(payload, profileID: profileID)
        } else {
            try storage.remove(profileID: profileID)
        }
        Self.pendingRemovals.remove(profileID)
    }

    /// The encoded sources, or nil when there are none; throws for invalid input.
    private func validated(_ sources: [IPTVSource], profileID: String) throws -> Data? {
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
        return sources.isEmpty ? nil : try JSONEncoder().encode(sources)
    }
}

/// The profile ids whose IPTV sources must be deleted but couldn't be yet.
final class IPTVPendingSourceRemovals: @unchecked Sendable {
    static let key = "nuvio.iptv.pending_source_removals"
    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults) { self.defaults = defaults }

    var all: [String] { lock.withLock { ids.sorted() } }
    func contains(_ profileID: String) -> Bool { lock.withLock { ids.contains(profileID) } }
    func insert(_ profileID: String) { update { $0.insert(profileID) } }
    func remove(_ profileID: String) { update { $0.remove(profileID) } }
    func removeAll() { update { $0.removeAll() } }

    private var ids: Set<String> { Set(defaults.stringArray(forKey: Self.key) ?? []) }

    private func update(_ change: (inout Set<String>) -> Void) {
        lock.withLock {
            var current = ids
            let before = current
            change(&current)
            guard current != before else { return }
            if current.isEmpty {
                defaults.removeObject(forKey: Self.key)
            } else {
                defaults.set(current.sorted(), forKey: Self.key)
            }
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
