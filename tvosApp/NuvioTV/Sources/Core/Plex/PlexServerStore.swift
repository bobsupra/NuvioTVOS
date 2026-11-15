import Foundation
import Security

/// One Plex Media Server added to the active profile. Servers come from the
/// signed-in account (plex.tv resources), never from a typed URL, so the base
/// URL here is just the last address that answered and is re-resolved on every
/// connect. Tokens live in `PlexCredentialStore`.
struct PlexServerConfig: Codable, Identifiable, Equatable {
    /// The server's machine identifier.
    let id: String
    var displayName: String
    /// Last reachable base URL, used when plex.tv can't be reached.
    var baseURLString: String
    var isOwned: Bool
    var selectedLibraryIDs: [String]
    var lastSyncDate: Date?
    var lastSyncTitleCount: Int?
    var syncAutomatically: Bool
    /// When watch state was last read from the server (Unix seconds).
    var watchStateReadAt: Int64?
    /// Each synced library's change marker at its last sync.
    var libraryChangeMarkers: [String: String]?

    init(
        id: String,
        displayName: String,
        baseURLString: String = "",
        isOwned: Bool = true,
        selectedLibraryIDs: [String] = [],
        lastSyncDate: Date? = nil,
        lastSyncTitleCount: Int? = nil,
        syncAutomatically: Bool = true
    ) {
        self.id = id
        self.displayName = displayName
        self.baseURLString = baseURLString
        self.isOwned = isOwned
        self.selectedLibraryIDs = selectedLibraryIDs
        self.lastSyncDate = lastSyncDate
        self.lastSyncTitleCount = lastSyncTitleCount
        self.syncAutomatically = syncAutomatically
    }

    var baseURL: URL? {
        baseURLString.isEmpty ? nil : URL(string: baseURLString)
    }
}

/// The Plex account and its servers for the active profile, stored the same way
/// as `JellyfinServerStore`: a profile-scoped JSON blob plus a notification.
@MainActor
final class PlexServerStore: ObservableObject {
    static let shared = PlexServerStore()

    static let changedNotification = Notification.Name("nuvio.tv.plex.servers.changed")

    @Published private(set) var servers: [PlexServerConfig] = []
    @Published private(set) var accountName: String?

    private init() {
        reload()
    }

    var isSignedIn: Bool {
        !PlexCredentialStore.accountToken().isEmpty
    }

    func reload() {
        servers = Self.loadServers()
        accountName = ProfileSettings.current.string(forKey: SettingsKey.plexAccountName)
    }

    func server(id: String) -> PlexServerConfig? {
        servers.first { $0.id == id }
    }

    /// A fresh sign-in: `token` is the account owner's, and also the one in use
    /// until a Plex Home user is chosen.
    func signedIn(name: String, token: String) {
        PlexCredentialStore.saveOwnerToken(token)
        setAccount(name: name, token: token)
    }

    /// The token and name in use: the owner's, or a Plex Home user's.
    func setAccount(name: String, token: String) {
        PlexCredentialStore.saveAccountToken(token)
        ProfileSettings.current.set(name, forKey: SettingsKey.plexAccountName)
        accountName = name
        NotificationCenter.default.post(name: Self.changedNotification, object: nil)
    }

    /// Adds servers the account can reach and refreshes names and tokens of
    /// ones already added, keeping each server's library choices.
    func merge(_ resources: [PlexResource]) {
        var updated = servers
        for resource in resources {
            if let token = resource.accessToken, !token.isEmpty {
                PlexCredentialStore.save(token, forServerID: resource.clientIdentifier)
            }
            if let index = updated.firstIndex(where: { $0.id == resource.clientIdentifier }) {
                updated[index].displayName = resource.name
                updated[index].isOwned = resource.isOwned
            } else {
                updated.append(PlexServerConfig(
                    id: resource.clientIdentifier,
                    displayName: resource.name,
                    isOwned: resource.isOwned
                ))
            }
        }
        persist(updated)
    }

    func upsert(_ server: PlexServerConfig) {
        var updated = servers
        if let index = updated.firstIndex(where: { $0.id == server.id }) {
            updated[index] = server
        } else {
            updated.append(server)
        }
        persist(updated)
    }

    func remove(_ serverID: String) {
        persist(servers.filter { $0.id != serverID })
        PlexCredentialStore.remove(forServerID: serverID)
        PlexLibraryIndex.shared.removeAll(forServerID: serverID)
    }

    /// Forgets the account, every server, and every synced title.
    func signOut() {
        for server in servers {
            PlexCredentialStore.remove(forServerID: server.id)
            PlexLibraryIndex.shared.removeAll(forServerID: server.id)
        }
        PlexCredentialStore.removeAccountToken()
        PlexCredentialStore.removeOwnerToken()
        ProfileSettings.current.removeObject(forKey: SettingsKey.plexAccountName)
        accountName = nil
        persist([])
    }

    private func persist(_ servers: [PlexServerConfig]) {
        self.servers = servers
        if let data = try? JSONEncoder().encode(servers) {
            ProfileSettings.current.set(data, forKey: SettingsKey.plexServers)
        }
        NotificationCenter.default.post(name: Self.changedNotification, object: nil)
    }

    private static func loadServers() -> [PlexServerConfig] {
        guard let data = ProfileSettings.current.data(forKey: SettingsKey.plexServers),
              let servers = try? JSONDecoder().decode([PlexServerConfig].self, from: data) else { return [] }
        return servers
    }
}

/// Device-local Plex tokens per profile, kept in Keychain like Jellyfin's and
/// never included in profile copies, sync payloads, or bug reports.
enum PlexCredentialStore {
    private static let service = "com.nuvio.tv.plex"
    private static let accountKey = "account"

    static func accountToken(profileScope: String = ProfileSettings.activeProfileScope) -> String {
        read(account: "\(accountKey).\(profileScope)") ?? ""
    }

    static func saveAccountToken(_ token: String, profileScope: String = ProfileSettings.activeProfileScope) {
        write(token, account: "\(accountKey).\(profileScope)")
    }

    static func removeAccountToken(profileScope: String = ProfileSettings.activeProfileScope) {
        delete(account: "\(accountKey).\(profileScope)")
    }

    /// The token from sign-in itself, needed to switch between Plex Home
    /// users. Falls back to the account token for sign-ins made before Plex
    /// Home support.
    static func ownerToken(profileScope: String = ProfileSettings.activeProfileScope) -> String {
        if let token = read(account: "owner.\(profileScope)"), !token.isEmpty { return token }
        return accountToken(profileScope: profileScope)
    }

    static func saveOwnerToken(_ token: String, profileScope: String = ProfileSettings.activeProfileScope) {
        write(token, account: "owner.\(profileScope)")
    }

    static func removeOwnerToken(profileScope: String = ProfileSettings.activeProfileScope) {
        delete(account: "owner.\(profileScope)")
    }

    /// The server's own token, falling back to the account token (the same
    /// value for servers the account owns).
    static func token(forServerID serverID: String, profileScope: String = ProfileSettings.activeProfileScope) -> String {
        if let token = read(account: "server.\(serverID).\(profileScope)"), !token.isEmpty {
            return token
        }
        return accountToken(profileScope: profileScope)
    }

    static func save(_ token: String, forServerID serverID: String, profileScope: String = ProfileSettings.activeProfileScope) {
        write(token, account: "server.\(serverID).\(profileScope)")
    }

    static func remove(forServerID serverID: String, profileScope: String = ProfileSettings.activeProfileScope) {
        delete(account: "server.\(serverID).\(profileScope)")
    }

    private static func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private static func read(account: String) -> String? {
        var request = query(account)
        request[kSecReturnData as String] = kCFBooleanTrue
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func write(_ value: String, account: String) {
        guard !value.isEmpty else {
            delete(account: account)
            return
        }
        let data = Data(value.utf8)
        var add = query(account)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecValueData as String] = data
        if SecItemAdd(add as CFDictionary, nil) == errSecDuplicateItem {
            SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
    }

    private static func delete(account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}
