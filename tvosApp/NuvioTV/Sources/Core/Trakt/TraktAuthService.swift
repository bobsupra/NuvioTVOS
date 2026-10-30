import Foundation
import SwiftUI

enum TraktConfig {
    static let apiBaseURL = "https://api.trakt.tv"
    /// OAuth endpoints moved to the dedicated auth host; the data API stays on
    /// `apiBaseURL`. (Trakt docs, 2026: "Use auth.trakt.tv for all OAuth requests.")
    static let authBaseURL = "https://auth.trakt.tv"
    static let legacyRedirectURI = "urn:ietf:wg:oauth:2.0:oob"
    static let defaultRedirectURI = "http://localhost:5173/callback"

    static func redirectURI(in store: UserDefaults) -> String {
        let stored = store.string(forKey: SettingsKey.traktRedirectURI)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stored.isEmpty ? inferredRedirectURI(in: store) : stored
    }

    /// Pins the profile's legacy or new-app default before credentials are first
    /// saved, so later client ID changes cannot silently change refresh requests.
    @discardableResult
    static func initializeRedirectURI(in store: UserDefaults) -> String {
        let stored = store.string(forKey: SettingsKey.traktRedirectURI)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !stored.isEmpty {
            if store.string(forKey: SettingsKey.traktRedirectURI) != stored {
                store.set(stored, forKey: SettingsKey.traktRedirectURI)
            }
            return stored
        }

        let inferred = inferredRedirectURI(in: store)
        store.set(inferred, forKey: SettingsKey.traktRedirectURI)
        return inferred
    }

    /// Blank input keeps the profile's pinned URI. Custom values are stored
    /// exactly as entered after trimming surrounding whitespace.
    @discardableResult
    static func setRedirectURI(_ value: String, in store: UserDefaults) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let selected = trimmed.isEmpty ? redirectURI(in: store) : trimmed
        store.set(selected, forKey: SettingsKey.traktRedirectURI)
        return selected
    }

    private static func inferredRedirectURI(in store: UserDefaults) -> String {
        clientID(in: store).isEmpty ? defaultRedirectURI : legacyRedirectURI
    }

    static var clientID: String {
        clientID(in: ProfileSettings.current)
    }

    static var clientSecret: String {
        clientSecret(in: ProfileSettings.current)
    }

    static var isConfigured: Bool {
        isConfigured(in: ProfileSettings.current)
    }

    static func clientID(in store: UserDefaults) -> String {
        store.string(forKey: SettingsKey.traktClientID)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func clientSecret(in store: UserDefaults) -> String {
        store.string(forKey: SettingsKey.traktClientSecret)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func isConfigured(in store: UserDefaults) -> Bool {
        // Trakt deprecated the client secret (1-Oct-2026, trakt/trakt-api#974): a
        // PKCE-only app is configured with just a Client ID. The secret stays
        // optional for the legacy server-to-server apps that still have one.
        !clientID(in: store).isEmpty
    }

    static var userAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return "NuvioTV/\(version)"
    }
}

enum TraktConnectionMode {
    case disconnected
    case awaitingApproval
    case connected
}

enum TraktWatchProgressSource: String, CaseIterable, Codable, Hashable, Sendable {
    case trakt = "TRAKT"
    case simkl = "SIMKL"
    case mdblist = "MDBLIST"
    case wetrakr = "WETRAKR"
    case nuvioSync = "NUVIO_SYNC"

    var label: String {
        switch self {
        case .trakt: return "Trakt"
        case .simkl: return "Simkl"
        case .mdblist: return "MDBList"
        case .wetrakr: return "WeTrakr"
        case .nuvioSync: return "Nuvio Sync"
        }
    }
}

enum TraktLibrarySourceMode: String, CaseIterable, Hashable, Sendable {
    case trakt = "TRAKT"
    case simkl = "SIMKL"
    case mdblist = "MDBLIST"
    case wetrakr = "WETRAKR"
    case local = "LOCAL"

    var label: String {
        switch self {
        case .trakt: return "Trakt"
        case .simkl: return "Simkl"
        case .mdblist: return "MDBList"
        case .wetrakr: return "WeTrakr"
        case .local: return "Nuvio Library"
        }
    }
}

enum TraktMoreLikeThisSource: String, CaseIterable {
    case trakt = "TRAKT"
    case tmdb = "TMDB"
    case simkl = "SIMKL"

    var label: String {
        switch self {
        case .trakt: return "Trakt"
        case .tmdb: return "TMDB"
        case .simkl: return "Simkl"
        }
    }
}

struct TraktCachedStats: Codable, Equatable {
    var moviesWatched: Int?
    var showsWatched: Int?
    var episodesWatched: Int?
    var totalWatchedHours: Int?
}

struct TraktAuthState: Equatable {
    var accessToken: String?
    var refreshToken: String?
    var tokenType: String?
    var createdAt: Int?
    var expiresIn: Int?
    var username: String?
    var userSlug: String?
    var deviceCode: String?
    var userCode: String?
    var verificationURL: String?
    var expiresAt: Double?
    var pollInterval: Int?
    var credentialClientID: String?

    var isAuthenticated: Bool {
        isAuthenticated(in: ProfileSettings.current)
    }

    func isAuthenticated(in store: UserDefaults) -> Bool {
        TraktConfig.isConfigured(in: store) &&
        !(accessToken ?? "").isEmpty &&
        !(refreshToken ?? "").isEmpty &&
        credentialClientID == TraktConfig.clientID(in: store)
    }

    var hasActiveDeviceFlow: Bool {
        hasActiveDeviceFlow(in: ProfileSettings.current)
    }

    func hasActiveDeviceFlow(in store: UserDefaults) -> Bool {
        TraktConfig.isConfigured(in: store) &&
        !(deviceCode ?? "").isEmpty &&
        credentialClientID == TraktConfig.clientID(in: store)
    }

    var tokenExpiresAtMillis: Double? {
        guard let createdAt, let expiresIn else { return nil }
        return Double(createdAt + expiresIn) * 1000.0
    }
}

enum TraktDefaults {
    static let continueWatchingDaysCapAll = 0
    static let continueWatchingDaysCap = 60
    static let showMetaComments = true
    /// Nuvio Sync, not Trakt. The old default named a provider the user had not
    /// necessarily connected, and because every Trakt/Simkl write is gated on the
    /// selected source matching, a Simkl-only account silently scrobbled nowhere.
    /// Connecting a tracker now selects it (see `selectWatchProgressSourceOnConnect`).
    static let watchProgressSource = TraktWatchProgressSource.nuvioSync
    static let librarySourceMode = TraktLibrarySourceMode.local
    static let moreLikeThisSource = TraktMoreLikeThisSource.trakt
}

enum TraktAuthStore {
    static let changedNotification = Notification.Name("nuvio.tv.trakt.auth.changed")

    private enum Key {
        static let accessToken = "nuvio.tv.trakt.auth.accessToken"
        static let refreshToken = "nuvio.tv.trakt.auth.refreshToken"
        static let tokenType = "nuvio.tv.trakt.auth.tokenType"
        static let createdAt = "nuvio.tv.trakt.auth.createdAt"
        static let expiresIn = "nuvio.tv.trakt.auth.expiresIn"
        static let username = "nuvio.tv.trakt.auth.username"
        static let userSlug = "nuvio.tv.trakt.auth.userSlug"
        static let accountBindingID = "nuvio.tv.trakt.auth.accountBindingID"
        static let deviceFlowRequestID = "nuvio.tv.trakt.auth.deviceFlowRequestID"
        static let deviceCode = "nuvio.tv.trakt.auth.deviceCode"
        static let userCode = "nuvio.tv.trakt.auth.userCode"
        static let verificationURL = "nuvio.tv.trakt.auth.verificationURL"
        static let expiresAt = "nuvio.tv.trakt.auth.expiresAt"
        static let pollInterval = "nuvio.tv.trakt.auth.pollInterval"
        static let credentialClientID = "nuvio.tv.trakt.auth.credentialClientID"
        static let cachedStats = "nuvio.tv.trakt.auth.cachedStats"
    }

    static var state: TraktAuthState {
        state(in: ProfileSettings.current)
    }

    /// Authentication is valid only for the profile that explicitly linked
    /// the account. The primary profile may use a legacy token created before
    /// the profile link marker existed; secondary profiles must reconnect after
    /// upgrading instead of inheriting that token.
    static var isAuthenticated: Bool {
        isAuthenticated(in: ProfileSettings.current)
    }

    static func isAuthenticated(in defaults: UserDefaults) -> Bool {
        guard state(in: defaults).isAuthenticated(in: defaults) else { return false }
        if (defaults.object(forKey: SettingsKey.traktConnected) as? Bool) == true {
            return true
        }
        return ProfileSettings.isPrimaryProfileStore(defaults)
    }

    static func state(in defaults: UserDefaults) -> TraktAuthState {
        return TraktAuthState(
            accessToken: defaults.string(forKey: Key.accessToken),
            refreshToken: defaults.string(forKey: Key.refreshToken),
            tokenType: defaults.string(forKey: Key.tokenType),
            createdAt: intIfPresent(Key.createdAt, defaults: defaults),
            expiresIn: intIfPresent(Key.expiresIn, defaults: defaults).map(normalizeTokenLifetime),
            username: defaults.string(forKey: Key.username),
            userSlug: defaults.string(forKey: Key.userSlug),
            deviceCode: defaults.string(forKey: Key.deviceCode),
            userCode: defaults.string(forKey: Key.userCode),
            verificationURL: defaults.string(forKey: Key.verificationURL),
            expiresAt: doubleIfPresent(Key.expiresAt, defaults: defaults),
            pollInterval: intIfPresent(Key.pollInterval, defaults: defaults),
            credentialClientID: defaults.string(forKey: Key.credentialClientID)
        )
    }

    static func beginDeviceFlowRequest(store: UserDefaults) -> String {
        let requestID = UUID().uuidString
        store.set(requestID, forKey: Key.deviceFlowRequestID)
        return requestID
    }

    static func isCurrentDeviceFlowRequest(_ requestID: String, store: UserDefaults) -> Bool {
        store.string(forKey: Key.deviceFlowRequestID) == requestID
    }

    static func saveDeviceFlow(
        _ response: TraktDeviceCodeResponse,
        clientID: String,
        store defaults: UserDefaults = ProfileSettings.current
    ) {
        defaults.removeObject(forKey: Key.deviceFlowRequestID)
        if defaults.string(forKey: Key.credentialClientID) != clientID {
            [
                Key.accessToken, Key.refreshToken, Key.tokenType, Key.createdAt,
                Key.expiresIn, Key.username, Key.userSlug, Key.cachedStats
            ].forEach { defaults.removeObject(forKey: $0) }
            defaults.removeObject(forKey: Key.accountBindingID)
            defaults.removeObject(forKey: SettingsKey.traktConnected)
        }
        defaults.set(response.deviceCode, forKey: Key.deviceCode)
        defaults.set(response.userCode, forKey: Key.userCode)
        defaults.set(response.verificationURL, forKey: Key.verificationURL)
        defaults.set(Date().timeIntervalSince1970 * 1000.0 + Double(response.expiresIn * 1000), forKey: Key.expiresAt)
        defaults.set(response.interval, forKey: Key.pollInterval)
        defaults.set(clientID, forKey: Key.credentialClientID)
    }

    static func saveToken(
        _ response: TraktTokenResponse,
        clientID: String,
        store defaults: UserDefaults = ProfileSettings.current,
        isNewLogin: Bool = false
    ) {
        if isNewLogin {
            defaults.removeObject(forKey: Key.deviceFlowRequestID)
            defaults.removeObject(forKey: Key.username)
            defaults.removeObject(forKey: Key.userSlug)
            defaults.set(UUID().uuidString, forKey: Key.accountBindingID)
        } else if defaults.string(forKey: Key.accountBindingID) == nil {
            defaults.set(UUID().uuidString, forKey: Key.accountBindingID)
        }
        defaults.set(response.accessToken, forKey: Key.accessToken)
        defaults.set(response.refreshToken, forKey: Key.refreshToken)
        defaults.set(response.tokenType, forKey: Key.tokenType)
        defaults.set(response.createdAt, forKey: Key.createdAt)
        defaults.set(normalizeTokenLifetime(response.expiresIn), forKey: Key.expiresIn)
        defaults.set(clientID, forKey: Key.credentialClientID)
        defaults.set(true, forKey: SettingsKey.traktConnected)
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }

    static func saveUser(
        username: String?,
        slug: String?,
        store defaults: UserDefaults = ProfileSettings.current
    ) {
        setOptional(username, forKey: Key.username, defaults: defaults)
        setOptional(slug, forKey: Key.userSlug, defaults: defaults)
    }

    static func accountBindingID(in defaults: UserDefaults) -> String? {
        defaults.string(forKey: Key.accountBindingID)
    }

    static func updatePollInterval(
        _ seconds: Int,
        store: UserDefaults = ProfileSettings.current
    ) {
        store.set(seconds, forKey: Key.pollInterval)
    }

    static var cachedStats: TraktCachedStats? {
        cachedStats(in: ProfileSettings.current)
    }

    static func cachedStats(in store: UserDefaults) -> TraktCachedStats? {
        guard let data = store.data(forKey: Key.cachedStats) else { return nil }
        return try? JSONDecoder().decode(TraktCachedStats.self, from: data)
    }

    static func saveCachedStats(
        _ stats: TraktCachedStats,
        store: UserDefaults = ProfileSettings.current
    ) {
        guard let data = try? JSONEncoder().encode(stats) else { return }
        store.set(data, forKey: Key.cachedStats)
    }

    static func clearDeviceFlow(store defaults: UserDefaults = ProfileSettings.current) {
        [Key.deviceFlowRequestID, Key.deviceCode, Key.userCode, Key.verificationURL, Key.expiresAt, Key.pollInterval].forEach {
            defaults.removeObject(forKey: $0)
        }
    }

    static func clearAuth(store defaults: UserDefaults = ProfileSettings.current) {
        [
            Key.accessToken, Key.refreshToken, Key.tokenType, Key.createdAt, Key.expiresIn,
            Key.username, Key.userSlug, Key.accountBindingID, Key.deviceFlowRequestID, Key.deviceCode, Key.userCode, Key.verificationURL,
            Key.expiresAt, Key.pollInterval, Key.credentialClientID, Key.cachedStats
        ].forEach { defaults.removeObject(forKey: $0) }
        defaults.removeObject(forKey: SettingsKey.traktConnected)
        RemoteLibraryStore.clear(source: .trakt, profileId: ProfileSettings.activeProfileID)
        NotificationCenter.default.post(name: changedNotification, object: nil)
        RemoteTrackingState.normalizeWatchProgressSource(in: defaults)
        RemoteTrackingState.normalizeLibrarySource(in: defaults)
        RemoteTrackingState.normalizeMoreLikeThisSource(in: defaults)
    }

    private static func intIfPresent(_ key: String, defaults: UserDefaults) -> Int? {
        defaults.object(forKey: key) == nil ? nil : defaults.integer(forKey: key)
    }

    private static func doubleIfPresent(_ key: String, defaults: UserDefaults) -> Double? {
        defaults.object(forKey: key) == nil ? nil : defaults.double(forKey: key)
    }

    private static func setOptional(_ value: String?, forKey key: String, defaults: UserDefaults) {
        if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private static func normalizeTokenLifetime(_ expiresIn: Int) -> Int {
        expiresIn <= 0 ? 7_776_000 : expiresIn
    }
}

enum TraktSettingsStore {
    static let continueWatchingChangedNotification = Notification.Name(
        "nuvio.tv.trakt.continueWatchingSettings.changed"
    )
    static let continueWatchingSourceInvalidatedNotification = Notification.Name(
        "nuvio.tv.trakt.continueWatchingSource.invalidated"
    )
    static let libraryChangedNotification = Notification.Name(
        "nuvio.tv.trakt.librarySettings.changed"
    )

    static var continueWatchingDaysCap: Int {
        get {
            let defaults = ProfileSettings.current
            guard defaults.object(forKey: SettingsKey.traktContinueWatchingDaysCap) != nil else {
                return TraktDefaults.continueWatchingDaysCap
            }
            let value = defaults.integer(forKey: SettingsKey.traktContinueWatchingDaysCap)
            return normalizeContinueWatchingDaysCap(value)
        }
        set {
            let normalized = normalizeContinueWatchingDaysCap(newValue)
            guard normalized != continueWatchingDaysCap else { return }
            ProfileSettings.current.set(normalized, forKey: SettingsKey.traktContinueWatchingDaysCap)
            NotificationCenter.default.post(name: continueWatchingChangedNotification, object: nil)
        }
    }

    static func notifyContinueWatchingSourceInvalidated(
        for source: TraktWatchProgressSource,
        in store: UserDefaults = ProfileSettings.current
    ) {
        guard ProfileSettings.isActiveStore(store), watchProgressSource(in: store) == source else { return }
        NotificationCenter.default.post(name: continueWatchingSourceInvalidatedNotification, object: nil)
    }

    static var showMetaComments: Bool {
        get { bool(SettingsKey.traktShowMetaComments, fallback: TraktDefaults.showMetaComments) }
        set { ProfileSettings.current.set(newValue, forKey: SettingsKey.traktShowMetaComments) }
    }

    static var watchProgressSource: TraktWatchProgressSource {
        get {
            watchProgressSource(in: ProfileSettings.current)
        }
        set {
            guard newValue != watchProgressSource else { return }
            ProfileSettings.current.set(newValue.rawValue, forKey: SettingsKey.traktWatchProgressSource)
            NotificationCenter.default.post(name: continueWatchingChangedNotification, object: nil)
        }
    }

    static func watchProgressSource(in defaults: UserDefaults) -> TraktWatchProgressSource {
        let raw = defaults.string(forKey: SettingsKey.traktWatchProgressSource)
        return TraktWatchProgressSource(rawValue: raw ?? "") ?? TraktDefaults.watchProgressSource
    }

    /// True once the user has picked a source from the Settings row themselves.
    static func watchProgressSourceChosenByUser(in defaults: UserDefaults = ProfileSettings.current) -> Bool {
        defaults.bool(forKey: SettingsKey.watchProgressSourceChosenByUser)
    }

    /// Records an explicit choice, so connecting a tracker later never silently
    /// overrides what the user asked for.
    static func markWatchProgressSourceChosenByUser(in defaults: UserDefaults = ProfileSettings.current) {
        defaults.set(true, forKey: SettingsKey.watchProgressSourceChosenByUser)
    }

    /// One-time upgrade step for installs that never stored a source.
    ///
    /// The default used to be `.trakt`, so a Trakt user who never opened the
    /// picker relied on it. Flipping the default to `.nuvioSync` would silently
    /// stop their scrobbling, so resolve the absent value once from whichever
    /// tracker this profile actually has credentials for and write it down.
    static func migrateWatchProgressSourceIfNeeded(
        in defaults: UserDefaults,
        tokenStorage: SimklTokenStorage = SimklKeychainTokenStorage(),
        profileScope: String? = nil
    ) {
        guard defaults.string(forKey: SettingsKey.traktWatchProgressSource) == nil else { return }
        let resolved: TraktWatchProgressSource
        if TraktAuthStore.isAuthenticated(in: defaults) {
            resolved = .trakt
        } else if SimklRuntimeSession.authenticatedState(
            store: defaults,
            tokenStorage: tokenStorage,
            profileScope: profileScope
        ) != nil {
            resolved = .simkl
        } else {
            resolved = .nuvioSync
        }
        defaults.set(resolved.rawValue, forKey: SettingsKey.traktWatchProgressSource)
    }

    /// Points watch progress at a tracker the user has just connected.
    ///
    /// Connecting Trakt or Simkl is the clearest possible statement that the user
    /// wants their playback to land there, and every write path is gated on this
    /// value. Without this, "Connected" was shown while nothing was ever sent.
    /// An explicit choice already on record always wins.
    static func selectWatchProgressSourceOnConnect(
        _ source: TraktWatchProgressSource,
        in defaults: UserDefaults = ProfileSettings.current
    ) {
        guard source != .nuvioSync else { return }
        guard !watchProgressSourceChosenByUser(in: defaults) else { return }
        guard watchProgressSource(in: defaults) != source else { return }
        defaults.set(source.rawValue, forKey: SettingsKey.traktWatchProgressSource)
        NotificationCenter.default.post(name: continueWatchingChangedNotification, object: nil)
    }

    static var librarySourceMode: TraktLibrarySourceMode {
        get {
            librarySourceMode(in: ProfileSettings.current)
        }
        set {
            let previous = librarySourceMode
            guard newValue != previous else { return }
            ProfileSettings.current.set(newValue.rawValue, forKey: SettingsKey.traktLibrarySourceMode)
            RemoteLibraryStore.clear(source: previous, profileId: ProfileSettings.activeProfileID)
            NotificationCenter.default.post(name: libraryChangedNotification, object: nil)
        }
    }

    static func librarySourceMode(in defaults: UserDefaults) -> TraktLibrarySourceMode {
        let raw = defaults.string(forKey: SettingsKey.traktLibrarySourceMode)
        return TraktLibrarySourceMode(rawValue: raw ?? "") ?? TraktDefaults.librarySourceMode
    }

    static var moreLikeThisSource: TraktMoreLikeThisSource {
        get {
            moreLikeThisSource(in: ProfileSettings.current)
        }
        set { ProfileSettings.current.set(newValue.rawValue, forKey: SettingsKey.traktMoreLikeThisSource) }
    }

    static func moreLikeThisSource(in defaults: UserDefaults) -> TraktMoreLikeThisSource {
        let raw = defaults.string(forKey: SettingsKey.traktMoreLikeThisSource)
        return TraktMoreLikeThisSource(rawValue: raw ?? "") ?? TraktDefaults.moreLikeThisSource
    }

    private static func bool(_ key: String, fallback: Bool) -> Bool {
        let defaults = ProfileSettings.current
        return defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
    }

    private static func normalizeContinueWatchingDaysCap(_ days: Int) -> Int {
        if days == TraktDefaults.continueWatchingDaysCapAll { return days }
        return min(max(days, 7), 365)
    }
}

enum RemoteTrackingState {
    static var isProgressSourceAuthenticated: Bool {
        isProgressSourceAuthenticated(in: ProfileSettings.current)
    }

    static func isProgressSourceAuthenticated(in store: UserDefaults) -> Bool {
        let source = TraktSettingsStore.watchProgressSource(in: store)
        return source != .nuvioSync && isProgressSourceAuthenticated(source, in: store)
    }

    static func isProgressSourceAuthenticated(
        _ source: TraktWatchProgressSource,
        in store: UserDefaults,
        simklTokenStorage: SimklTokenStorage? = nil,
        mdbListTokenStorage: MdbListTokenStorage? = nil,
        profileScope: String? = nil
    ) -> Bool {
        switch source {
        case .nuvioSync:
            return false
        case .trakt:
            return ProfileSettings.isActiveStore(store)
                && TraktAuthStore.isAuthenticated(in: store)
        case .simkl:
            guard ProfileSettings.isActiveStore(store) else { return false }
            if let simklTokenStorage {
                return SimklRuntimeSession.authenticatedState(
                    store: store,
                    tokenStorage: simklTokenStorage,
                    profileScope: profileScope
                ) != nil
            }
            return SimklRuntimeSession.authenticatedState(store: store, profileScope: profileScope) != nil
        case .mdblist:
            guard ProfileSettings.isActiveStore(store) else { return false }
            let scope = profileScope ?? MdbListRuntimeSession.profileScope()
            let tokens = mdbListTokenStorage ?? MdbListKeychainTokenStorage()
            return MdbListAuthStore.state(in: store, profileScope: scope, tokenStorage: tokens).hasOAuthTokens
                || MdbListRuntimeSession.hasAPIKey(in: store)
        case .wetrakr:
            return ProfileSettings.isActiveStore(store)
                && WeTrakrRuntimeSession.authenticatedState(store: store, profileScope: profileScope) != nil
        }
    }

    static func isScrobbleEnabled(
        for source: TraktWatchProgressSource,
        in store: UserDefaults = ProfileSettings.current,
        simklTokenStorage: SimklTokenStorage? = nil,
        mdbListTokenStorage: MdbListTokenStorage? = nil,
        profileScope: String? = nil
    ) -> Bool {
        guard source != .nuvioSync,
              isProgressSourceAuthenticated(
                source,
                in: store,
                simklTokenStorage: simklTokenStorage,
                mdbListTokenStorage: mdbListTokenStorage,
                profileScope: profileScope
              ) else {
            return false
        }
        let key: String
        switch source {
        case .trakt: key = SettingsKey.traktScrobbleEnabled
        case .simkl: key = SettingsKey.simklScrobbleEnabled
        case .mdblist: key = SettingsKey.mdbListScrobbleEnabled
        case .wetrakr: key = SettingsKey.wetrakrScrobbleEnabled
        case .nuvioSync: return false
        }
        return store.bool(forKey: key)
    }

    static func isNuvioSyncScrobbleEnabled(
        in store: UserDefaults = ProfileSettings.current
    ) -> Bool {
        store.bool(forKey: SettingsKey.nuvioSyncScrobbleEnabled)
    }

    static func shouldSaveNuvioSyncPlayback(
        usesRemoteProgress: Bool,
        in store: UserDefaults = ProfileSettings.current
    ) -> Bool {
        !usesRemoteProgress || isNuvioSyncScrobbleEnabled(in: store)
    }

    static func setScrobbleEnabled(
        _ enabled: Bool,
        for source: TraktWatchProgressSource,
        in store: UserDefaults = ProfileSettings.current
    ) {
        let key: String
        switch source {
        case .trakt: key = SettingsKey.traktScrobbleEnabled
        case .simkl: key = SettingsKey.simklScrobbleEnabled
        case .mdblist: key = SettingsKey.mdbListScrobbleEnabled
        case .wetrakr: key = SettingsKey.wetrakrScrobbleEnabled
        case .nuvioSync: return
        }
        store.set(enabled, forKey: key)
        NotificationCenter.default.post(
            name: TraktSettingsStore.continueWatchingChangedNotification,
            object: nil
        )
        NotificationCenter.default.post(
            name: WatchedStore.changedNotification,
            object: nil
        )
    }

    static func activeScrobbleSources(
        in store: UserDefaults = ProfileSettings.current
    ) -> [TraktWatchProgressSource] {
        TraktWatchProgressSource.allCases.filter { source in
            isScrobbleEnabled(for: source, in: store)
        }
    }

    static func availableProgressSources(
        in store: UserDefaults = ProfileSettings.current
    ) -> [TraktWatchProgressSource] {
        TraktWatchProgressSource.allCases.filter { source in
            source == .nuvioSync || isProgressSourceAuthenticated(source, in: store)
        }
    }

    static func normalizeWatchProgressSource(
        in store: UserDefaults = ProfileSettings.current
    ) {
        let source = TraktSettingsStore.watchProgressSource(in: store)
        guard source != .nuvioSync,
              !isProgressSourceAuthenticated(source, in: store) else { return }
        store.set(TraktWatchProgressSource.nuvioSync.rawValue, forKey: SettingsKey.traktWatchProgressSource)
        NotificationCenter.default.post(
            name: TraktSettingsStore.continueWatchingChangedNotification,
            object: nil
        )
    }

    static func isLibrarySourceAuthenticated(
        _ source: TraktLibrarySourceMode,
        in store: UserDefaults = ProfileSettings.current,
        mdbListTokenStorage: MdbListTokenStorage? = nil,
        profileScope: String? = nil
    ) -> Bool {
        switch source {
        case .local:
            return true
        case .trakt:
            return ProfileSettings.isActiveStore(store)
                && TraktAuthStore.isAuthenticated(in: store)
        case .simkl:
            return ProfileSettings.isActiveStore(store)
                && SimklRuntimeSession.authenticatedState(store: store) != nil
        case .mdblist:
            guard ProfileSettings.isActiveStore(store) else { return false }
            let scope = profileScope ?? MdbListRuntimeSession.profileScope()
            let tokens = mdbListTokenStorage ?? MdbListKeychainTokenStorage()
            return MdbListAuthStore.state(in: store, profileScope: scope, tokenStorage: tokens).hasOAuthTokens
                || MdbListRuntimeSession.hasAPIKey(in: store)
        case .wetrakr:
            return ProfileSettings.isActiveStore(store)
                && WeTrakrRuntimeSession.authenticatedState(store: store) != nil
        }
    }

    static func availableLibrarySources(
        in store: UserDefaults = ProfileSettings.current
    ) -> [TraktLibrarySourceMode] {
        TraktLibrarySourceMode.allCases.filter {
            isLibrarySourceAuthenticated($0, in: store)
        }
    }

    static func normalizeLibrarySource(
        in store: UserDefaults = ProfileSettings.current
    ) {
        let source = TraktSettingsStore.librarySourceMode(in: store)
        guard !isLibrarySourceAuthenticated(source, in: store) else { return }
        store.set(TraktLibrarySourceMode.local.rawValue, forKey: SettingsKey.traktLibrarySourceMode)
        NotificationCenter.default.post(
            name: TraktSettingsStore.libraryChangedNotification,
            object: nil
        )
    }

    static func isMoreLikeThisSourceAvailable(
        _ source: TraktMoreLikeThisSource,
        in store: UserDefaults = ProfileSettings.current
    ) -> Bool {
        switch source {
        case .trakt:
            return ProfileSettings.isActiveStore(store)
                && TraktAuthStore.isAuthenticated(in: store)
        case .simkl:
            return ProfileSettings.isActiveStore(store)
                && SimklRuntimeSession.authenticatedState(store: store) != nil
        case .tmdb:
            let apiKey = store.string(forKey: SettingsKey.tmdbApiKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let enabled = (store.object(forKey: SettingsKey.tmdbEnabled) as? Bool) ?? false
            let useMoreLikeThis = (store.object(forKey: SettingsKey.tmdbUseMoreLikeThis) as? Bool) ?? true
            return enabled && !apiKey.isEmpty && useMoreLikeThis
        }
    }

    static func availableMoreLikeThisSources(
        in store: UserDefaults = ProfileSettings.current
    ) -> [TraktMoreLikeThisSource] {
        TraktMoreLikeThisSource.allCases.filter {
            isMoreLikeThisSourceAvailable($0, in: store)
        }
    }

    static func normalizeMoreLikeThisSource(
        in store: UserDefaults = ProfileSettings.current
    ) {
        let source = TraktSettingsStore.moreLikeThisSource(in: store)
        guard !isMoreLikeThisSourceAvailable(source, in: store) else { return }
        let fallback = availableMoreLikeThisSources(in: store).first ?? .tmdb
        store.set(fallback.rawValue, forKey: SettingsKey.traktMoreLikeThisSource)
    }

    static func routesWatchedHistory(
        to target: TraktWatchProgressSource,
        selectedSource: TraktWatchProgressSource,
        in store: UserDefaults = ProfileSettings.current
    ) -> Bool {
        target != .nuvioSync && (target == selectedSource || isScrobbleEnabled(for: target, in: store))
    }

    static func shouldSyncWatchedHistory(
        to target: TraktWatchProgressSource,
        in store: UserDefaults = ProfileSettings.current
    ) -> Bool {
        let selectedSource = TraktSettingsStore.watchProgressSource(in: store)
        guard routesWatchedHistory(to: target, selectedSource: selectedSource, in: store) else {
            return false
        }
        return isProgressSourceAuthenticated(target, in: store)
    }

    /// Trakt watched history is an account-level mirror, not the resume source.
    /// A user may keep Continue Watching in Nuvio Sync while still expecting
    /// local watched actions to reach their connected Trakt account.
    static func shouldMirrorWatchedHistoryToTrakt(
        in store: UserDefaults = ProfileSettings.current
    ) -> Bool {
        ProfileSettings.isActiveStore(store)
            && TraktAuthStore.isAuthenticated(in: store)
    }
}

private struct TraktDeviceCodeRequest: Encodable {
    let clientID: String
    enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
    }
}

private struct TraktDeviceTokenRequest: Encodable {
    let code: String
    let clientID: String
    // Optional/deprecated: a PKCE-only app sends nil, which the synthesized
    // Encodable omits (`encodeIfPresent`), so Trakt treats it as a public client.
    let clientSecret: String?
    enum CodingKeys: String, CodingKey {
        case code
        case clientID = "client_id"
        case clientSecret = "client_secret"
    }
}

private struct TraktRefreshTokenRequest: Encodable {
    let refreshToken: String
    let clientID: String
    let clientSecret: String?
    let redirectURI: String
    let grantType = "refresh_token"
    enum CodingKeys: String, CodingKey {
        case refreshToken = "refresh_token"
        case clientID = "client_id"
        case clientSecret = "client_secret"
        case redirectURI = "redirect_uri"
        case grantType = "grant_type"
    }
}

private struct TraktRevokeRequest: Encodable {
    let token: String
    let clientID: String
    let clientSecret: String?
    enum CodingKeys: String, CodingKey {
        case token
        case clientID = "client_id"
        case clientSecret = "client_secret"
    }
}

struct TraktDeviceCodeResponse: Decodable {
    let deviceCode: String
    let userCode: String
    let verificationURL: String
    let expiresIn: Int
    let interval: Int
    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationURL = "verification_url"
        case expiresIn = "expires_in"
        case interval
    }
}

struct TraktTokenResponse: Decodable {
    let accessToken: String
    let tokenType: String
    let expiresIn: Int
    let refreshToken: String
    let createdAt: Int
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case createdAt = "created_at"
    }
}

private struct TraktUserSettingsResponse: Decodable {
    struct User: Decodable {
        struct IDs: Decodable { let slug: String? }
        let username: String?
        let ids: IDs?
    }
    let user: User?
}

private struct TraktUserStatsResponse: Decodable {
    struct Category: Decodable {
        let watched: Int?
        let minutes: Int?
    }
    let movies: Category?
    let shows: Category?
    let episodes: Category?
}

enum TraktPollResult {
    case pending
    case alreadyUsed
    case expired
    case denied
    case slowDown(Int)
    case approved(String?)
    case failed(String)
}

final class TraktAuthService {
    private let session: URLSession
    private let store: UserDefaults
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private let refreshLeewaySeconds = 60

    init(session: URLSession = .shared, store: UserDefaults = ProfileSettings.current) {
        self.session = session
        self.store = store
    }

    func hasRequiredCredentials() -> Bool {
        TraktConfig.isConfigured(in: store)
    }

    func currentState() -> TraktAuthState {
        TraktAuthStore.state(in: store)
    }

    @MainActor
    func startDeviceAuth() async throws -> TraktDeviceCodeResponse {
        try Task.checkCancellation()
        guard ProfileSettings.isActiveStore(store) else { throw CancellationError() }
        guard hasRequiredCredentials() else {
            throw TraktServiceError.message("Enter your Trakt Client ID first.")
        }
        TraktConfig.initializeRedirectURI(in: store)

        let state = currentState()
        if let deviceCode = state.deviceCode,
           let expiresAt = state.expiresAt,
           state.credentialClientID == clientID,
           Date().timeIntervalSince1970 * 1000.0 < expiresAt {
            let response = TraktDeviceCodeResponse(
                deviceCode: deviceCode,
                userCode: state.userCode ?? "",
                verificationURL: state.verificationURL ?? "https://trakt.tv/activate",
                expiresIn: max(Int((expiresAt - Date().timeIntervalSince1970 * 1000.0) / 1000.0), 0),
                interval: state.pollInterval ?? 5
            )
            return response
        }

        let capturedProfileID = ProfileSettings.activeProfileID
        let capturedClientID = clientID
        let requestID = TraktAuthStore.beginDeviceFlowRequest(store: store)
        let response: TraktDeviceCodeResponse = try await post(
            path: "oauth/device/code",
            body: TraktDeviceCodeRequest(clientID: capturedClientID),
            authorized: false
        )
        guard !Task.isCancelled,
              ProfileSettings.isActiveStore(store),
              ProfileSettings.activeProfileID == capturedProfileID,
              clientID == capturedClientID,
              TraktAuthStore.isCurrentDeviceFlowRequest(requestID, store: store) else {
            throw CancellationError()
        }
        // Validation and persistence stay on MainActor with no suspension.
        TraktAuthStore.saveDeviceFlow(response, clientID: capturedClientID, store: store)
        return response
    }

    func pollDeviceToken() async -> TraktPollResult {
        guard !Task.isCancelled, ProfileSettings.isActiveStore(store), hasRequiredCredentials() else {
            return .failed("Enter your Trakt Client ID first.")
        }
        let state = currentState()
        guard state.hasActiveDeviceFlow(in: store),
              let deviceCode = state.deviceCode,
              !deviceCode.isEmpty else {
            return .failed("No active Trakt device code.")
        }
        let capturedProfileID = ProfileSettings.activeProfileID
        let capturedClientID = clientID
        let capturedDeviceCode = deviceCode

        do {
            let response: HTTPResult<TraktTokenResponse> = try await postResult(
                path: "oauth/device/token",
                body: TraktDeviceTokenRequest(
                    code: deviceCode,
                    clientID: capturedClientID,
                    clientSecret: clientSecretOrNil
                ),
                authorized: false
            )
            // Cancel is handled on the main actor. Keep the ownership check and
            // every response mutation together so it cannot interleave here.
            let result: TraktPollResult = await MainActor.run {
                guard !Task.isCancelled, ProfileSettings.isActiveStore(store),
                      ProfileSettings.activeProfileID == capturedProfileID,
                      currentState().deviceCode == capturedDeviceCode,
                      clientID == capturedClientID else {
                    return .failed("The active profile or Trakt account changed during login.")
                }
                if let token = response.value, (200..<300).contains(response.statusCode) {
                    TraktAuthStore.saveToken(
                        token,
                        clientID: capturedClientID,
                        store: store,
                        isNewLogin: true
                    )
                    TraktAuthStore.clearDeviceFlow(store: store)
                    // Preserve the selected-source policy on a valid login.
                    TraktSettingsStore.selectWatchProgressSourceOnConnect(.trakt, in: store)
                    return .approved(nil)
                }
                switch response.statusCode {
                case 400: return .pending
                case 409:
                    TraktAuthStore.clearDeviceFlow(store: store)
                    return .alreadyUsed
                case 410:
                    TraktAuthStore.clearDeviceFlow(store: store)
                    return .expired
                case 418:
                    TraktAuthStore.clearDeviceFlow(store: store)
                    return .denied
                case 429:
                    let next = min((currentState().pollInterval ?? 5) + 5, 60)
                    TraktAuthStore.updatePollInterval(next, store: store)
                    return .slowDown(next)
                default:
                    return .failed("Trakt token polling failed (\(response.statusCode)).")
                }
            }
            if case .approved = result {
                let username = await fetchUserSettings()
                return .approved(username)
            }
            return result
        } catch {
            return .failed("Network error. Retrying is safe.")
        }
    }

    /// Response ownership checks and auth mutations stay on MainActor so they
    /// cannot interleave with a profile's Trakt Redirect URI settings commit.
    /// The network await suspends the actor; validation and save/clear resume
    /// together after the response arrives.
    @MainActor
    func refreshTokenIfNeeded(force: Bool = false) async -> Bool {
        guard ProfileSettings.isActiveStore(store), hasRequiredCredentials() else { return false }
        let state = currentState()
        guard TraktAuthStore.isAuthenticated(in: store), let refreshToken = state.refreshToken else { return false }
        if !force && !isTokenExpiredOrExpiring(state) { return true }
        let capturedProfileID = ProfileSettings.activeProfileID
        let capturedClientID = clientID
        let capturedBindingID = TraktAuthStore.accountBindingID(in: store)
        let capturedRedirectURI = TraktConfig.redirectURI(in: store)

        do {
            let response: HTTPResult<TraktTokenResponse> = try await postResult(
                path: "oauth/token",
                body: TraktRefreshTokenRequest(
                    refreshToken: refreshToken,
                    clientID: capturedClientID,
                    clientSecret: clientSecretOrNil,
                    redirectURI: capturedRedirectURI
                ),
                authorized: false
            )
            let latestState = currentState()
            let isCapturedSession = ProfileSettings.isActiveStore(store)
                && ProfileSettings.activeProfileID == capturedProfileID
                && clientID == capturedClientID
                && latestState.refreshToken == refreshToken
                && capturedBindingID == TraktAuthStore.accountBindingID(in: store)
            guard let token = response.value, (200..<300).contains(response.statusCode) else {
                if isCapturedSession
                    && TraktConfig.redirectURI(in: store) == capturedRedirectURI
                    && (response.statusCode == 401 || response.statusCode == 403) {
                    TraktAuthStore.clearAuth(store: store)
                }
                return false
            }
            guard isCapturedSession else {
                // A relink or a concurrent refresh won while this request was
                // in flight. Never overwrite that newer account/session.
                return TraktAuthStore.isAuthenticated(in: store)
                    && !isTokenExpiredOrExpiring(latestState)
            }
            TraktAuthStore.saveToken(token, clientID: capturedClientID, store: store)
            return true
        } catch {
            return false
        }
    }

    func revokeAndLogout() async {
        let state = currentState()
        if hasRequiredCredentials(), TraktAuthStore.isAuthenticated(in: store), let accessToken = state.accessToken {
            try? await postEmpty(
                path: "oauth/revoke",
                body: TraktRevokeRequest(
                    token: accessToken,
                    clientID: clientID,
                    clientSecret: clientSecretOrNil
                ),
                authorized: false
            )
        }
        TraktAuthStore.clearAuth(store: store)
    }

    func fetchUserSettings() async -> String? {
        guard ProfileSettings.isActiveStore(store) else { return nil }
        let capturedProfileID = ProfileSettings.activeProfileID
        let capturedBindingID = TraktAuthStore.accountBindingID(in: store)
        let capturedAccessToken = currentState().accessToken
        let capturedRefreshToken = currentState().refreshToken
        guard let response: TraktUserSettingsResponse = try? await authorizedGet(path: "users/settings") else {
            return nil
        }
        let latestState = currentState()
        guard ProfileSettings.isActiveStore(store),
              ProfileSettings.activeProfileID == capturedProfileID,
              TraktAuthStore.isAuthenticated(in: store),
              (capturedBindingID != nil
                ? TraktAuthStore.accountBindingID(in: store) == capturedBindingID
                : latestState.accessToken == capturedAccessToken && latestState.refreshToken == capturedRefreshToken) else {
            return nil
        }
        let username = response.user?.username
        let slug = response.user?.ids?.slug
        TraktAuthStore.saveUser(username: username, slug: slug, store: store)
        return username
    }

    func fetchUserStats() async -> TraktCachedStats? {
        let slug = currentState().userSlug ?? "me"
        guard let response: TraktUserStatsResponse = try? await authorizedGet(path: "users/\(slug)/stats") else {
            return nil
        }
        let totalMinutes = (response.movies?.minutes ?? 0) + (response.episodes?.minutes ?? 0)
        return TraktCachedStats(
            moviesWatched: response.movies?.watched,
            showsWatched: response.shows?.watched,
            episodesWatched: response.episodes?.watched,
            totalWatchedHours: totalMinutes > 0 ? totalMinutes / 60 : nil
        )
    }

    fileprivate func authorizedGet<T: Decodable>(path: String) async throws -> T {
        let result: HTTPResult<T> = try await authorizedGetResult(path: path)
        return try result.valueOrThrow()
    }

    /// Authenticated GET variant used by paginated endpoints that need the
    /// response headers as well as the decoded value.
    fileprivate func authorizedGetResult<T: Decodable>(path: String) async throws -> HTTPResult<T> {
        guard await refreshTokenIfNeeded(), let token = currentState().accessToken else {
            throw TraktServiceError.message("Not authenticated with Trakt.")
        }
        var request = baseRequest(path: path)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return try await perform(request)
    }

    /// Authenticated writes such as scrobbles may legitimately return an empty
    /// body. Check the status directly instead of requiring a decoded payload.
    fileprivate func authorizedPostEmpty<Body: Encodable>(path: String, body: Body) async throws {
        guard await refreshTokenIfNeeded() else {
            throw TraktServiceError.message("Not authenticated with Trakt.")
        }
        let result: HTTPResult<EmptyResponse> = try await postResult(
            path: path,
            body: body,
            authorized: true
        )
        guard (200..<300).contains(result.statusCode) else {
            throw TraktServiceError.message(
                result.errorMessage ?? "Trakt request failed (\(result.statusCode))."
            )
        }
    }

    /// Deletes an exact Trakt playback progress row. A missing row is already
    /// cleaned up, while every other non-success status remains retryable.
    fileprivate func authorizedDeletePlayback(path: String) async -> Bool {
        guard await refreshTokenIfNeeded(), let token = currentState().accessToken else {
            return false
        }
        var request = baseRequest(path: path)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200..<300).contains(http.statusCode) || http.statusCode == 404
        } catch {
            return false
        }
    }

    fileprivate func authorizedPost<T: Decodable, Body: Encodable>(path: String, body: Body) async throws -> T {
        guard await refreshTokenIfNeeded() else {
            throw TraktServiceError.message("Not authenticated with Trakt.")
        }
        let result: HTTPResult<T> = try await postResult(
            path: path,
            body: body,
            authorized: true
        )
        return try result.valueOrThrow()
    }

    private func post<T: Decodable, Body: Encodable>(path: String, body: Body, authorized: Bool) async throws -> T {
        try await postResult(path: path, body: body, authorized: authorized).valueOrThrow()
    }

    private func postEmpty<Body: Encodable>(path: String, body: Body, authorized: Bool) async throws {
        _ = try await postResult(path: path, body: body, authorized: authorized) as HTTPResult<EmptyResponse>
    }

    private func postResult<T: Decodable, Body: Encodable>(path: String, body: Body, authorized: Bool) async throws -> HTTPResult<T> {
        var request = baseRequest(path: path)
        request.httpMethod = "POST"
        request.httpBody = try encoder.encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if authorized, let token = currentState().accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return try await perform(request)
    }

    private func perform<T: Decodable>(_ request: URLRequest) async throws -> HTTPResult<T> {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TraktServiceError.message("Invalid Trakt response.")
        }
        let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, field in
            guard let name = field.key as? String else { return }
            result[name.lowercased()] = String(describing: field.value)
        }
        let rawError = Self.errorMessage(from: data)
        // Prefer decoding only on success so Trakt error payloads never surface as
        // cryptic Decodable cast failures for TraktDeviceCodeResponse / tokens.
        var value: T?
        if (200..<300).contains(http.statusCode), !data.isEmpty {
            do {
                value = try decoder.decode(T.self, from: data)
            } catch {
                return HTTPResult(
                    statusCode: http.statusCode,
                    value: nil,
                    errorMessage: rawError
                        ?? "Trakt response could not be read (\(error.localizedDescription)).",
                    headers: headers
                )
            }
        }
        return HTTPResult(
            statusCode: http.statusCode,
            value: value,
            errorMessage: Self.friendlyTraktError(rawError, status: http.statusCode),
            headers: headers
        )
    }

    private func baseRequest(path: String) -> URLRequest {
        // OAuth (`oauth/...`) goes to auth.trakt.tv; every data endpoint stays on
        // the API host. No non-OAuth path begins with `oauth/`.
        let host = path.hasPrefix("oauth/") ? TraktConfig.authBaseURL : TraktConfig.apiBaseURL
        let normalizedBase = host.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let url = URL(string: "\(normalizedBase)/\(path)")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(TraktConfig.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(clientID, forHTTPHeaderField: "trakt-api-key")
        request.setValue("2", forHTTPHeaderField: "trakt-api-version")
        return request
    }

    private var clientID: String { TraktConfig.clientID(in: store) }
    private var clientSecret: String { TraktConfig.clientSecret(in: store) }
    /// The legacy secret, or nil for a PKCE-only app so it is omitted from the
    /// request body entirely (Trakt reads its absence as a public client).
    private var clientSecretOrNil: String? {
        let secret = clientSecret
        return secret.isEmpty ? nil : secret
    }

    private func isTokenExpiredOrExpiring(_ state: TraktAuthState) -> Bool {
        guard let createdAt = state.createdAt, let expiresIn = state.expiresIn else { return true }
        let now = Int(Date().timeIntervalSince1970)
        return now >= createdAt + expiresIn - refreshLeewaySeconds
    }

    private static func errorMessage(from data: Data) -> String? {
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        for key in ["error_description", "msg", "message", "error", "error_code"] {
            if let string = object[key] as? String, !string.isEmpty {
                return string
            }
        }
        return nil
    }

    private static func friendlyTraktError(_ raw: String?, status: Int) -> String? {
        if status == 401 || status == 403 {
            return raw ?? "Trakt rejected the Client ID or Client Secret. Check both values and try again."
        }
        if status == 429 {
            return raw ?? "Trakt is rate limiting login attempts. Wait a few minutes and try again."
        }
        if status >= 500 {
            return raw ?? "Trakt is temporarily unavailable (\(status))."
        }
        return raw
    }
}

// MARK: - Continue Watching

/// Loads the remote progress selected by Settings → Trakt → Watch Progress.
/// Remote entries stay in Home's view state instead of being written into the
/// Nuvio Sync store, so switching sources never mixes or destroys either list.
enum TraktScrobbleAction: String {
    case start
    case pause
    case stop
}

@MainActor
struct TraktProgressService {
    static let continueWatchingSnapshotChangedNotification = Notification.Name(
        "nuvio.tv.trakt.continueWatchingSnapshot.changed"
    )

    private static let completionPercent = 90.0
    nonisolated private static let maxItems = 20
    static let maxHomeContinueWatchingSeeds = 36
    /// Long enough to outlive an app relaunch plus Simkl's 20-second per-user
    /// scrobble lock. Kept to an hour so a checkpoint the server never confirms
    /// (for example the title was marked watched on another device) cannot linger
    /// as a ghost card for a whole session.
    private static let localCheckpointLifetime: TimeInterval = 60 * 60
    private static let checkpointStorageKey = "nuvio.tv.remoteProgress.localCheckpoints.v1"

    private struct LocalPlaybackCheckpoint: Codable {
        let profileId: String?
        let source: TraktWatchProgressSource
        let item: ContinueWatchingItem
    }

    private struct ContinueWatchingSnapshot {
        let profileId: String?
        let source: TraktWatchProgressSource
        let items: [ContinueWatchingItem]
    }

    /// Optimistic positions bridge the interval between leaving playback and the
    /// provider returning the newly-scrobbled timestamp from `sync/playback`.
    /// They are deliberately separate from ContinueWatchingStore so choosing
    /// Trakt never contaminates Nuvio Sync's independent progress ledger.
    ///
    /// Persisted: these used to be memory-only, so quitting the app during the
    /// window when the provider had not yet published the scrobble left the title
    /// missing from Continue Watching with nothing to mask the gap.
    private static var cachedCheckpoints: [LocalPlaybackCheckpoint]?
    private static var localPlaybackCheckpoints: [LocalPlaybackCheckpoint] {
        get {
            if let cachedCheckpoints { return cachedCheckpoints }
            let loaded = loadCheckpoints()
            cachedCheckpoints = loaded
            return loaded
        }
        set {
            cachedCheckpoints = newValue
            saveCheckpoints(newValue)
        }
    }

    private static let checkpointDirectoryName = "traktCheckpoints"

    private static func loadCheckpoints() -> [LocalPlaybackCheckpoint] {
        let data: Data? = {
            if let fileData = LargePayloadStore.read(key: checkpointStorageKey, directory: checkpointDirectoryName) {
                return fileData
            }
            guard let legacy = UserDefaults.standard.data(forKey: checkpointStorageKey) else { return nil }
            if LargePayloadStore.write(legacy, key: checkpointStorageKey, directory: checkpointDirectoryName) {
                UserDefaults.standard.removeObject(forKey: checkpointStorageKey)
            }
            return legacy
        }()
        guard let data,
              let decoded = try? checkpointDecoder().decode(
                  [LocalPlaybackCheckpoint].self,
                  from: data
              ) else {
            return []
        }
        return decoded
    }

    private static func saveCheckpoints(_ checkpoints: [LocalPlaybackCheckpoint]) {
        guard !checkpoints.isEmpty else {
            LargePayloadStore.remove(key: checkpointStorageKey, directory: checkpointDirectoryName)
            UserDefaults.standard.removeObject(forKey: checkpointStorageKey)
            return
        }
        guard let data = try? checkpointEncoder().encode(checkpoints) else { return }
        if LargePayloadStore.write(data, key: checkpointStorageKey, directory: checkpointDirectoryName) {
            UserDefaults.standard.removeObject(forKey: checkpointStorageKey)
        }
    }

    private static func checkpointEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN"
        )
        return encoder
    }

    private static func checkpointDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN"
        )
        return decoder
    }
    /// Last list handed to Home for each profile. Details and an already-rendered
    /// Home card use this synchronously, avoiding a stale resume position while
    /// a replacement Trakt fetch is still in flight.
    private static var continueWatchingSnapshots: [ContinueWatchingSnapshot] = []

    static func currentContinueWatchingItem(
        for meta: NuvioMeta,
        source sourceOverride: TraktWatchProgressSource? = nil
    ) -> ContinueWatchingItem? {
        pruneExpiredLocalCheckpoints()
        let profileId = ContinueWatchingStore.activeProfileId
        let source = sourceOverride ?? TraktSettingsStore.watchProgressSource
        if let local = localPlaybackCheckpoints.first(where: {
            $0.profileId == profileId
                && $0.source == source
                && WatchedStore.sameContent($0.item.meta, meta)
        })?.item {
            return local
        }
        return continueWatchingSnapshots.first(where: {
            $0.profileId == profileId && $0.source == source
        })?
            .items.first(where: { WatchedStore.sameContent($0.meta, meta) })
    }

    static func recordLocalPlayback(
        meta: NuvioMeta,
        position: Double,
        duration: Double,
        season: Int?,
        episode: Int?,
        source sourceOverride: TraktWatchProgressSource? = nil,
        notify: Bool
    ) {
        guard position.isFinite,
              duration.isFinite,
              position > 0,
              duration > 0 else { return }

        let profileId = ContinueWatchingStore.activeProfileId
        let source = sourceOverride ?? TraktSettingsStore.watchProgressSource
        print("[TraktProgressService] recordLocalPlayback: meta=\(meta.id) S\(season.map(String.init) ?? "nil")E\(episode.map(String.init) ?? "nil"), pos=\(position)/\(duration), source=\(source.rawValue), notify=\(notify)")
        let completionPercent = source == .mdblist ? MdbListProgressService.completionPercent : Self.completionPercent
        // Going back to a title retires the removal the user made earlier, so a
        // provider row they are actively watching again is never hidden.
        ContinueWatchingDismissStore.clear(contentId: meta.id)
        localPlaybackCheckpoints.removeAll {
            $0.profileId == profileId
                && $0.source == source
                && WatchedStore.sameContent($0.item.meta, meta)
        }

        let progressPercent = position / duration * 100
        if progressPercent < completionPercent {
            let video = meta.videos?.first {
                $0.season == season && $0.episode == episode
            }
            localPlaybackCheckpoints.append(
                LocalPlaybackCheckpoint(
                    profileId: profileId,
                    source: source,
                    item: ContinueWatchingItem(
                        // Snapshot drops the episode guide, which can run to
                        // megabytes — tvOS aborts the process on a UserDefaults
                        // value that large. The overrides below already carry
                        // everything the card renders.
                        meta: meta.persistenceSnapshot,
                        streamUrl: "",
                        position: position,
                        duration: duration,
                        lastWatchedAt: Date(),
                        season: season,
                        episode: episode,
                        released: video?.released,
                        episodeTitleOverride: video?.title,
                        episodeOverviewOverride: video?.overview,
                        episodeThumbnailOverride: video?.thumbnail,
                        isUpNext: false
                    )
                )
            )
        } else {
            removeFromContinueWatchingSnapshot(profileId: profileId, source: source) {
                WatchedStore.sameContent($0.meta, meta)
            }
        }

        if notify {
            NotificationCenter.default.post(
                name: TraktSettingsStore.continueWatchingChangedNotification,
                object: nil
            )
        }
    }

    /// The last fetched list for this profile and provider, if one is cached.
    /// Callers use this for stable membership checks without reading playback
    /// positions or starting another provider request.
    static func currentContinueWatchingItems(
        source sourceOverride: TraktWatchProgressSource? = nil
    ) -> [ContinueWatchingItem]? {
        pruneExpiredLocalCheckpoints()
        let profileId = ContinueWatchingStore.activeProfileId
        let source = sourceOverride ?? TraktSettingsStore.watchProgressSource
        let remoteItems = continueWatchingSnapshots.first {
            $0.profileId == profileId && $0.source == source
        }?.items ?? []
        return mergingLocalPlaybackCheckpoints(
            into: remoteItems,
            source: source,
            profileId: profileId,
            limit: maxItems
        )
    }

    /// Retain the measured stream timeline for every provider receiving scrobbles.
    /// Provider playback lists can otherwise reconstruct seconds from a different runtime.
    static func recordLocalPlaybackForScrobbleSources(
        meta: NuvioMeta,
        position: Double,
        duration: Double,
        season: Int?,
        episode: Int?,
        primarySource: TraktWatchProgressSource,
        scrobbleSources: [TraktWatchProgressSource],
        notify: Bool = false
    ) {
        guard position.isFinite, duration.isFinite, position > 0, duration > 0 else { return }
        let sources = TraktWatchProgressSource.allCases.filter {
            $0 != .nuvioSync && ($0 == primarySource || scrobbleSources.contains($0))
        }
        for source in sources {
            recordLocalPlayback(
                meta: meta, position: position, duration: duration,
                season: season, episode: episode, source: source, notify: false
            )
        }
        if notify, !sources.isEmpty {
            NotificationCenter.default.post(
                name: TraktSettingsStore.continueWatchingChangedNotification, object: nil
            )
        }
    }

    /// Drops a title from the optimistic layers that sit in front of the
    /// provider's list, so a card the user removed cannot be re-shown by a
    /// checkpoint or the snapshot of the last fetch while the row refreshes.
    ///
    /// `season`/`episode` narrow the removal to one episode — what a watched
    /// mark clears, since another episode of the same show may still be
    /// legitimately in progress. `recordedNoLaterThan` keeps progress made
    /// *after* the mark (the user carried on watching), mirroring how
    /// ``ContinueWatchingStore/removeWatched(_:)`` settles the same race.
    static func forgetLocalPlayback(
        meta: NuvioMeta,
        season: Int? = nil,
        episode: Int? = nil,
        recordedNoLaterThan cutoff: Date? = nil,
        notify: Bool = false
    ) {
        print("[TraktProgressService] forgetLocalPlayback: meta=\(meta.id) S\(season.map(String.init) ?? "nil")E\(episode.map(String.init) ?? "nil"), notify=\(notify)")
        removeLocalPlayback(
            meta: meta, season: season, episode: episode,
            profileId: ContinueWatchingStore.activeProfileId,
            source: TraktSettingsStore.watchProgressSource,
            recordedNoLaterThan: cutoff, notify: notify
        )
    }

    /// A durable watched mark retires all provider checkpoints for that playback,
    /// including providers that were only background scrobble targets.
    static func forgetLocalPlaybackForCompletion(
        meta: NuvioMeta,
        season: Int? = nil,
        episode: Int? = nil,
        profileId: String?,
        recordedNoLaterThan cutoff: Date? = nil,
        notify: Bool = false
    ) {
        removeLocalPlayback(
            meta: meta, season: season, episode: episode, profileId: profileId,
            source: nil, recordedNoLaterThan: cutoff,
            notify: notify && ContinueWatchingStore.activeProfileId == profileId
                && ProfileSettings.activeProfileID == profileId
        )
    }

    private static func removeLocalPlayback(
        meta: NuvioMeta,
        season: Int?,
        episode: Int?,
        profileId: String?,
        source: TraktWatchProgressSource?,
        recordedNoLaterThan cutoff: Date?,
        notify: Bool
    ) {
        let matchesRemoval: (ContinueWatchingItem) -> Bool = { item in
            guard WatchedStore.sameContent(item.meta, meta) else { return false }
            if let cutoff, item.lastWatchedAt > cutoff { return false }
            guard let season, let episode else { return true }
            // A row that never recorded its episode cannot be attributed to this
            // mark, and Details only draws a bar for a row that names one.
            guard let rowSeason = item.season, let rowEpisode = item.episode else { return false }
            return rowSeason == season && rowEpisode == episode
        }

        let removingCheckpoints = localPlaybackCheckpoints.contains {
            $0.profileId == profileId && (source == nil || $0.source == source) && matchesRemoval($0.item)
        }
        if removingCheckpoints {
            localPlaybackCheckpoints.removeAll {
                $0.profileId == profileId && (source == nil || $0.source == source) && matchesRemoval($0.item)
            }
        }
        var removedFromSnapshot = false
        for target in source.map({ [$0] }) ?? TraktWatchProgressSource.allCases {
            if removeFromContinueWatchingSnapshot(profileId: profileId, source: target, where: matchesRemoval) {
                removedFromSnapshot = true
            }
        }

        // The caller's own store notification has already been posted by now, so
        // a view that reads this layer needs its own signal to look again.
        if notify, removingCheckpoints || removedFromSnapshot {
            NotificationCenter.default.post(
                name: TraktSettingsStore.continueWatchingChangedNotification,
                object: nil
            )
        }
    }

    /// Ownership captured before provider I/O. A source override used for a
    /// transfer may differ from Home's selected source when no snapshot is written.
    struct ContinueWatchingFetchContext {
        let profileId: String?
        let settingsProfileId: String?
        let store: UserDefaults
        let profileScope: String
        let source: TraktWatchProgressSource
        let updateDisplayedSnapshot: Bool
        let replaceSnapshot: Bool

        @MainActor
        init(
            source: TraktWatchProgressSource,
            updateDisplayedSnapshot: Bool,
            replaceSnapshot: Bool = true
        ) {
            profileId = ContinueWatchingStore.activeProfileId
            settingsProfileId = ProfileSettings.activeProfileID
            store = ProfileSettings.current
            profileScope = ProfileSettings.activeProfileScope
            self.source = source
            self.updateDisplayedSnapshot = updateDisplayedSnapshot
            self.replaceSnapshot = replaceSnapshot
        }
    }

    /// Revalidate before merging: reconciliation itself may remove checkpoints.
    /// Keep the guard, merge and snapshot write together with no suspension so a
    /// UI profile/source switch cannot interleave between those operations.
    @MainActor
    static func finalizeContinueWatchingFetch(
        _ items: [ContinueWatchingItem],
        context: ContinueWatchingFetchContext,
        displayPredicate: ((ContinueWatchingItem) -> Bool)? = nil,
        displaySort: (([ContinueWatchingItem]) -> [ContinueWatchingItem])? = nil
    ) -> [ContinueWatchingItem]? {
        guard !Task.isCancelled,
              context.profileId == ContinueWatchingStore.activeProfileId,
              context.settingsProfileId == ProfileSettings.activeProfileID,
              ProfileSettings.isActiveStore(context.store) else { return nil }
        guard context.updateDisplayedSnapshot else {
            guard let displayPredicate else { return items }
            return selectContinueWatchingItemsForDisplay(
                items,
                predicate: displayPredicate,
                sort: displaySort
            )
        }
        guard context.source == TraktSettingsStore.watchProgressSource else { return nil }

        let resolvedItems = mergingLocalPlaybackCheckpoints(
            into: items,
            source: context.source,
            profileId: context.profileId,
            limit: displayPredicate == nil ? maxItems : nil
        )
        let displayedItems: [ContinueWatchingItem]
        if let displayPredicate {
            displayedItems = selectContinueWatchingItemsForDisplay(
                resolvedItems,
                predicate: displayPredicate,
                sort: displaySort
            )
        } else {
            displayedItems = resolvedItems
        }
        let snapshotItems: [ContinueWatchingItem]
        if displayPredicate == nil {
            snapshotItems = resolvedItems
        } else {
            var snapshotMetaIDs = Set<String>()
            snapshotItems = (displayedItems + Array(resolvedItems.prefix(maxItems))).filter {
                snapshotMetaIDs.insert($0.meta.id).inserted
            }
        }
        let previousItems = continueWatchingSnapshots.first {
            $0.profileId == context.profileId && $0.source == context.source
        }?.items ?? []
        let retainedItems = context.replaceSnapshot ? [] : previousItems.filter { previous in
            !snapshotItems.contains { WatchedStore.sameContent($0.meta, previous.meta) }
        }
        replaceContinueWatchingSnapshot(
            snapshotItems + retainedItems,
            source: context.source,
            profileId: context.profileId
        )
        return displayedItems
    }

    /// Resolve a bounded seed pool concurrently. Each result is restored to
    /// candidate order before returning, regardless of completion order.
    static func resolveContinueWatchingMetadata<Seed>(
        from seeds: [Seed],
        candidateLimit: Int,
        resolve: @escaping (Seed) async -> ContinueWatchingItem?
    ) async -> [ContinueWatchingItem]? {
        guard candidateLimit > 0 else { return [] }
        let candidates = Array(seeds.prefix(candidateLimit))
        guard !Task.isCancelled else { return nil }
        let tasks = candidates.enumerated().map { index, seed in
            Task { @MainActor in
                (index, await resolve(seed))
            }
        }
        return await withTaskCancellationHandler {
            var indexedItems: [(Int, ContinueWatchingItem)] = []
            for task in tasks {
                guard !Task.isCancelled else { return nil }
                let (index, item) = await task.value
                if let item {
                    indexedItems.append((index, item))
                }
            }
            guard !Task.isCancelled else { return nil }
            return indexedItems.sorted { $0.0 < $1.0 }.map(\.1)
        } onCancel: {
            tasks.forEach { $0.cancel() }
        }
    }

    /// Apply Home eligibility and title-level deduplication only after all
    /// checkpoints are merged, then order and cap the visible row.
    static func selectContinueWatchingItemsForDisplay(
        _ items: [ContinueWatchingItem],
        predicate: (ContinueWatchingItem) -> Bool,
        sort: (([ContinueWatchingItem]) -> [ContinueWatchingItem])? = nil
    ) -> [ContinueWatchingItem] {
        var seenMetaIDs = Set<String>()
        let eligibleUniqueItems = items.filter {
            predicate($0) && seenMetaIDs.insert($0.meta.id).inserted
        }
        let orderedItems = sort?(eligibleUniqueItems) ?? eligibleUniqueItems
        return Array(orderedItems.prefix(maxItems))
    }

    /// Separate Upcoming is a presentation split performed after selection.
    /// Rank its combined pool by the default recency order so upcoming entries
    /// still compete for the Home 20-item limit before `setContinueWatching` splits it.
    static func sortContinueWatchingForDisplaySelection(
        _ items: [ContinueWatchingItem],
        preference: String
    ) -> [ContinueWatchingItem] {
        let selectionPreference = preference == "Separate Upcoming Row" ? "Default" : preference
        return ContinueWatchingSortPolicy.sorted(items, preference: selectionPreference)
    }

    static func fetchContinueWatching(
        repository: CatalogRepository,
        source sourceOverride: TraktWatchProgressSource? = nil,
        updateDisplayedSnapshot: Bool = true,
        displayPredicate: ((ContinueWatchingItem) -> Bool)? = nil,
        displaySort: (([ContinueWatchingItem]) -> [ContinueWatchingItem])? = nil,
        replaceSnapshot: Bool = true
    ) async -> [ContinueWatchingItem]? {
        let context = await MainActor.run {
            ContinueWatchingFetchContext(
                source: sourceOverride ?? TraktSettingsStore.watchProgressSource,
                updateDisplayedSnapshot: updateDisplayedSnapshot,
                replaceSnapshot: replaceSnapshot
            )
        }
        let source = context.source
        #if DEBUG
        print("[ContinueWatching] Provider fetch started source=\(source.rawValue)")
        #endif
        if source == .simkl {
            guard SimklRuntimeSession.authenticatedState(store: context.store, profileScope: context.profileScope) != nil else { return [] }
            guard let items = await SimklProgressService.fetchContinueWatching(
                repository: repository,
                store: context.store,
                profileScope: context.profileScope
            ) else { return nil }
            return finalizeContinueWatchingFetch(items, context: context)
        }

        if source == .mdblist {
            guard MdbListRuntimeSession.isAuthenticated(in: context.store, profileScope: context.profileScope) else { return [] }
            guard let items = await MdbListProgressService.fetchContinueWatching(
                repository: repository,
                store: context.store,
                profileScope: context.profileScope
            ) else { return nil }
            return finalizeContinueWatchingFetch(items, context: context)
        }

        if source == .wetrakr {
            guard WeTrakrRuntimeSession.authenticatedState(store: context.store) != nil else { return [] }
            guard let items = await WeTrakrProgressService.fetchContinueWatching(
                repository: repository,
                store: context.store
            ) else { return nil }
            return finalizeContinueWatchingFetch(items, context: context)
        }

        guard source == .trakt,
              TraktAuthStore.isAuthenticated(in: context.store) else {
            return []
        }

        let service = TraktAuthService(store: context.store)
        guard await service.refreshTokenIfNeeded() else {
            #if DEBUG
            print("[ContinueWatching] Trakt token refresh failed")
            #endif
            return nil
        }

        async let moviesRequest: [TraktPlaybackDTO]? = fetchList(
            TraktPlaybackDTO.self,
            path: "sync/playback/movies",
            service: service
        )
        async let episodesRequest: [TraktPlaybackDTO]? = fetchList(
            TraktPlaybackDTO.self,
            path: "sync/playback/episodes",
            service: service
        )
        async let watchedShowsRequest: [TraktWatchedShowDTO]? = fetchList(
            TraktWatchedShowDTO.self,
            // Trakt stopped including the season/episode breakdown in the
            // default watched-show response. Up Next needs that progress,
            // while the compact response only tells us that the show exists.
            path: "sync/watched/shows?extended=progress",
            service: service
        )
        async let episodeHistoryRequest: [TraktEpisodeHistoryDTO]? = fetchList(
            TraktEpisodeHistoryDTO.self,
            path: "users/me/history/episodes?page=1&limit=100",
            service: service
        )

        let (movies, episodes, watchedShows, episodeHistory) = await (
            moviesRequest,
            episodesRequest,
            watchedShowsRequest,
            episodeHistoryRequest
        )
        #if DEBUG
        print(
            "[ContinueWatching] Trakt lists movies=\(movies?.count.description ?? "failed") "
                + "episodes=\(episodes?.count.description ?? "failed") "
                + "shows=\(watchedShows?.count.description ?? "failed") "
                + "history=\(episodeHistory?.count.description ?? "failed")"
        )
        #endif
        guard movies != nil || episodes != nil || watchedShows != nil || episodeHistory != nil else {
            return nil
        }

        var seeds =
            movies.orEmpty.compactMap { playbackSeed(from: $0, type: "movie") }
            + episodes.orEmpty.compactMap { playbackSeed(from: $0, type: "series") }
        let playbackIDs = Set(seeds.map(\.contentID))
        let preferFurthestEpisode = UpNextEpisodeSelectionPolicy.prefersFurthestEpisode

        // Merge both watched-show progress and episode history. The former is
        // the complete source for normal accounts; the latter is the fallback
        // for accounts where Trakt omits `seasons`, and can also contain a
        // newer watch than the show snapshot.
        var upNextSeedsByContentID: [String: TraktProgressSeed] = [:]
        for seed in watchedShows.orEmpty.compactMap({
            nextUpSeed(from: $0, preferFurthestEpisode: preferFurthestEpisode)
        }) {
            guard !playbackIDs.contains(seed.contentID) else { continue }
            upNextSeedsByContentID[seed.contentID] = seed
        }
        for history in episodeHistory.orEmpty {
            guard let candidate = nextUpSeed(from: history),
                  !playbackIDs.contains(candidate.contentID) else {
                continue
            }
            if let current = upNextSeedsByContentID[candidate.contentID] {
                guard UpNextEpisodeSelectionPolicy.prefers(
                    candidateSeason: candidate.season ?? 0,
                    candidateEpisode: candidate.episode ?? 0,
                    candidateWatchedAt: candidate.lastUpdated,
                    over: current.season ?? 0,
                    currentEpisode: current.episode ?? 0,
                    currentWatchedAt: current.lastUpdated,
                    preferFurthestEpisode: preferFurthestEpisode
                ) else { continue }
            }
            upNextSeedsByContentID[candidate.contentID] = candidate
        }
        seeds.append(contentsOf: upNextSeedsByContentID.values)

        let cutoff: Date? = {
            let days = TraktSettingsStore.continueWatchingDaysCap
            guard days != TraktDefaults.continueWatchingDaysCapAll else { return nil }
            return Calendar.current.date(byAdding: .day, value: -days, to: Date())
        }()

        let recentSeeds = seeds
            .filter { cutoff == nil || $0.lastUpdated >= cutoff! }
            .sorted {
                ordersBefore(
                    isUpNext: $0.isUpNext,
                    updatedAt: $0.lastUpdated,
                    otherIsUpNext: $1.isUpNext,
                    otherUpdatedAt: $1.lastUpdated
                )
            }

        var usedContentIDs = Set<String>()
        let uniqueSeeds = recentSeeds.filter {
            usedContentIDs.insert($0.contentID).inserted
        }
        let items: [ContinueWatchingItem]
        if displayPredicate != nil {
            guard let resolvedItems = await resolveContinueWatchingMetadata(
                from: uniqueSeeds,
                candidateLimit: maxHomeContinueWatchingSeeds,
                resolve: { seed in
                    let item = await makeItem(from: seed, repository: repository)
                    #if DEBUG
                    if item == nil {
                        print("[ContinueWatching] Trakt metadata omitted \(seed.title)")
                    }
                    #endif
                    return item
                }
            ) else {
                #if DEBUG
                print("[ContinueWatching] Trakt metadata assembly cancelled")
                #endif
                return nil
            }
            items = resolvedItems
        } else {
            let metadataTasks = uniqueSeeds.prefix(maxItems).enumerated().map { index, seed in
                Task { @MainActor in
                    (index, seed.title, await makeItem(from: seed, repository: repository))
                }
            }
            var indexedItems: [(Int, ContinueWatchingItem)] = []
            for task in metadataTasks {
                guard !Task.isCancelled else {
                    #if DEBUG
                    print("[ContinueWatching] Trakt metadata assembly cancelled")
                    #endif
                    return nil
                }
                let (index, title, item) = await task.value
                if let item {
                    indexedItems.append((index, item))
                } else {
                    #if DEBUG
                    print("[ContinueWatching] Trakt metadata omitted \(title)")
                    #endif
                }
            }
            items = indexedItems.sorted { $0.0 < $1.0 }.map(\.1)
        }
        guard let resolvedItems = finalizeContinueWatchingFetch(
            items,
            context: context,
            displayPredicate: displayPredicate,
            displaySort: displaySort
        ) else {
            return nil
        }
        #if DEBUG
        print("[ContinueWatching] Trakt provider returning \(resolvedItems.count) items")
        #endif
        return resolvedItems
    }

    private static func fetchList<Element: Decodable>(
        _ type: Element.Type,
        path: String,
        service: TraktAuthService
    ) async -> [Element]? {
        do {
            return try await service.authorizedGet(path: path)
        } catch {
            #if DEBUG
            print("[ContinueWatching] Trakt GET \(path) failed: \(error.localizedDescription)")
            #endif
            return nil
        }
    }

    nonisolated static func ordersBefore(
        isUpNext: Bool,
        updatedAt: Date,
        otherIsUpNext: Bool,
        otherUpdatedAt: Date
    ) -> Bool {
        if isUpNext != otherIsUpNext {
            return !isUpNext
        }
        return updatedAt > otherUpdatedAt
    }

    static func mergingLocalPlaybackCheckpoints(
        into remoteItems: [ContinueWatchingItem],
        source: TraktWatchProgressSource,
        profileId: String? = ContinueWatchingStore.activeProfileId,
        limit: Int? = maxItems
    ) -> [ContinueWatchingItem] {
        pruneExpiredLocalCheckpoints()
        let checkpoints = localPlaybackCheckpoints.filter {
            $0.profileId == profileId && $0.source == source
        }
        var merged = remoteItems
        var confirmedItems: [ContinueWatchingItem] = []

        for checkpoint in checkpoints {
            let local = checkpoint.item
            if let index = merged.firstIndex(where: { WatchedStore.sameContent($0.meta, local.meta) }) {
                let remote = merged[index]
                let sameEpisode = remote.season == local.season && remote.episode == local.episode
                if sameEpisode {
                    let localProgress = local.duration > 0 ? (local.position / local.duration) : 0
                    let remoteProgress = remote.duration > 0 ? (remote.position / remote.duration) : 0
                    let remoteIsSubstantiallyNewer = remote.lastWatchedAt > local.lastWatchedAt.addingTimeInterval(30)
                    let remoteIsFurther = remoteProgress > (localProgress + 0.01)

                    if remoteIsSubstantiallyNewer && remoteIsFurther {
                        // User genuinely continued playback on another device.
                        // Inherit verified stream duration if remote has an estimated duration.
                        let resolvedDuration = local.duration > 100 ? local.duration : remote.duration
                        let resolvedPosition = resolvedDuration * remoteProgress
                        merged[index] = ContinueWatchingItem(
                            meta: remote.meta,
                            streamUrl: local.streamUrl.isEmpty ? remote.streamUrl : local.streamUrl,
                            position: resolvedPosition,
                            duration: resolvedDuration,
                            lastWatchedAt: remote.lastWatchedAt,
                            season: remote.season,
                            episode: remote.episode,
                            released: remote.released ?? local.released,
                            episodeTitleOverride: remote.episodeTitleOverride ?? local.episodeTitleOverride,
                            episodeOverviewOverride: remote.episodeOverviewOverride ?? local.episodeOverviewOverride,
                            episodeThumbnailOverride: remote.episodeThumbnailOverride ?? local.episodeThumbnailOverride,
                            isUpNext: false
                        )
                        confirmedItems.append(local)
                    } else {
                        // Remote is the server-side confirmation of local playback.
                        // Preserve exact local playback position and duration measured from the player.
                        merged[index] = ContinueWatchingItem(
                            meta: remote.meta,
                            streamUrl: local.streamUrl.isEmpty ? remote.streamUrl : local.streamUrl,
                            position: local.position,
                            duration: local.duration,
                            lastWatchedAt: max(local.lastWatchedAt, remote.lastWatchedAt),
                            season: local.season,
                            episode: local.episode,
                            released: local.released ?? remote.released,
                            episodeTitleOverride: local.episodeTitleOverride ?? remote.episodeTitleOverride,
                            episodeOverviewOverride: local.episodeOverviewOverride ?? remote.episodeOverviewOverride,
                            episodeThumbnailOverride: local.episodeThumbnailOverride ?? remote.episodeThumbnailOverride,
                            isUpNext: false
                        )
                    }
                } else {
                    let remoteIsNewer = remote.lastWatchedAt > local.lastWatchedAt.addingTimeInterval(1)
                    if remoteIsNewer {
                        confirmedItems.append(local)
                    } else {
                        merged[index] = local
                    }
                }
            } else {
                merged.append(local)
            }
        }

        if !confirmedItems.isEmpty {
            localPlaybackCheckpoints.removeAll { checkpoint in
                checkpoint.profileId == profileId
                    && checkpoint.source == source
                    && confirmedItems.contains { confirmed in
                        WatchedStore.sameContent(checkpoint.item.meta, confirmed.meta)
                    }
            }
        }

        let orderedItems = merged.sorted { $0.lastWatchedAt > $1.lastWatchedAt }
        guard let limit else { return orderedItems }
        return Array(orderedItems.prefix(max(0, limit)))
    }

    private static func pruneExpiredLocalCheckpoints() {
        let now = Date()
        localPlaybackCheckpoints.removeAll {
            now.timeIntervalSince($0.item.lastWatchedAt) > localCheckpointLifetime
        }
    }

    private static func replaceContinueWatchingSnapshot(
        _ items: [ContinueWatchingItem],
        source: TraktWatchProgressSource,
        profileId: String?
    ) {
        let previousIdentity = continueWatchingSnapshots.first {
            $0.profileId == profileId && $0.source == source
        }.map { continueWatchingIdentity($0.items) }
        let nextIdentity = continueWatchingIdentity(items)
        continueWatchingSnapshots.removeAll {
            $0.profileId == profileId && $0.source == source
        }
        continueWatchingSnapshots.append(
            ContinueWatchingSnapshot(profileId: profileId, source: source, items: items)
        )
        if previousIdentity != nextIdentity {
            NotificationCenter.default.post(name: continueWatchingSnapshotChangedNotification, object: nil)
        }
    }

    private static func continueWatchingIdentity(_ items: [ContinueWatchingItem]) -> String {
        Set(items.map {
            let imdb = NuvioMeta.canonicalImdbID(from: $0.meta.imdbId ?? "") ?? ""
            let tmdb = $0.meta.tmdbId.map(String.init) ?? ""
            return "\($0.meta.canonicalType):\($0.meta.id):\(imdb):\(tmdb)"
        })
            .sorted()
            .joined(separator: ",")
    }

    /// Returns whether the snapshot actually lost a row.
    @discardableResult
    private static func removeFromContinueWatchingSnapshot(
        profileId: String?,
        source: TraktWatchProgressSource,
        where matchesRemoval: (ContinueWatchingItem) -> Bool
    ) -> Bool {
        guard let index = continueWatchingSnapshots.firstIndex(where: {
            $0.profileId == profileId && $0.source == source
        }) else {
            return false
        }
        let remaining = continueWatchingSnapshots[index].items.filter { !matchesRemoval($0) }
        guard remaining.count != continueWatchingSnapshots[index].items.count else { return false }
        continueWatchingSnapshots[index] = ContinueWatchingSnapshot(
            profileId: profileId,
            source: source,
            items: remaining
        )
        return true
    }

    /// Writes the current player position to the connected scrobble providers.
    /// Broadcasts concurrently to all active scrobble targets unless a specific
    /// sourceOverride is provided.
    static func reportPlayback(
        meta: NuvioMeta,
        position: Double,
        duration: Double,
        season: Int?,
        episode: Int?,
        action: TraktScrobbleAction,
        store: UserDefaults = ProfileSettings.current,
        sourceOverride: TraktWatchProgressSource? = nil,
        expectedAccountID: String? = nil,
        playbackID: String? = nil,
        profileId: String? = nil,
        isPeriodicHeartbeat: Bool = false,
        session: URLSession = .shared
    ) async -> Bool {
        if let source = sourceOverride {
            return await reportPlaybackSingleSource(
                source: source,
                meta: meta,
                position: position,
                duration: duration,
                season: season,
                episode: episode,
                action: action,
                store: store,
                expectedAccountID: expectedAccountID,
                playbackID: playbackID,
                profileId: profileId,
                session: session
            )
        }

        var targets = RemoteTrackingState.activeScrobbleSources(in: store)
        if isPeriodicHeartbeat {
            targets.removeAll { $0 == .simkl }
        }
        guard !targets.isEmpty else { return false }

        return await withTaskGroup(of: Bool.self) { group in
            for target in targets {
                group.addTask {
                    await reportPlaybackSingleSource(
                        source: target,
                        meta: meta,
                        position: position,
                        duration: duration,
                        season: season,
                        episode: episode,
                        action: action,
                        store: store,
                        expectedAccountID: target == .trakt ? expectedAccountID : nil,
                        playbackID: playbackID,
                        profileId: profileId,
                        session: session
                    )
                }
            }
            var anySucceeded = false
            for await success in group {
                if success { anySucceeded = true }
            }
            return anySucceeded
        }
    }

    private static func reportPlaybackSingleSource(
        source: TraktWatchProgressSource,
        meta: NuvioMeta,
        position: Double,
        duration: Double,
        season: Int?,
        episode: Int?,
        action: TraktScrobbleAction,
        store: UserDefaults,
        expectedAccountID: String?,
        playbackID: String?,
        profileId: String?,
        session: URLSession
    ) async -> Bool {
        print("[TraktProgressService] reportPlaybackSingleSource: action=\(action.rawValue), source=\(source.rawValue), meta=\(meta.id), pos=\(position)/\(duration)")
        switch source {
        case .simkl:
            return await SimklProgressService.reportPlayback(
                meta: meta,
                position: position,
                duration: duration,
                season: season,
                episode: episode,
                action: action,
                store: store
            )
        case .mdblist:
            return await MdbListProgressService.reportPlayback(
                meta: meta,
                position: position,
                duration: duration,
                season: season,
                episode: episode,
                action: action,
                store: store
            )
        case .wetrakr:
            let wetrakrAction: TraktScrobbleAction = (action == .stop) ? .pause : action
            return await WeTrakrProgressService.reportPlayback(
                meta: meta,
                position: position,
                duration: duration,
                season: season,
                episode: episode,
                action: wetrakrAction,
                expectedAccountID: expectedAccountID,
                playbackID: playbackID,
                profileId: profileId,
                store: store
            )
        case .trakt:
            let traktAction: TraktScrobbleAction = (action == .stop) ? .pause : action
            return await reportTraktPlaybackItem(
                meta: meta,
                position: position,
                duration: duration,
                season: season,
                episode: episode,
                action: traktAction,
                store: store,
                expectedAccountID: expectedAccountID,
                playbackID: playbackID,
                profileId: profileId,
                session: session
            )
        case .nuvioSync:
            return false
        }
    }

    private static func reportTraktPlaybackItem(
        meta: NuvioMeta,
        position: Double,
        duration: Double,
        season: Int?,
        episode: Int?,
        action: TraktScrobbleAction,
        store: UserDefaults,
        expectedAccountID: String?,
        playbackID: String?,
        profileId: String?,
        session: URLSession
    ) async -> Bool {
        guard ProfileSettings.isActiveStore(store),
              TraktAuthStore.isAuthenticated(in: store),
              position.isFinite,
              duration.isFinite,
              duration > 0,
              let media = scrobbleMedia(for: meta) else {
            return false
        }
        let profileID = profileId ?? WatchedStore.activeProfileId
        guard WatchedStore.activeProfileId == profileID,
              ProfileSettings.activeProfileID == profileID else { return false }
        guard let accountID = expectedAccountID
                ?? TraktHistoryService.completionAccountID(in: store, profileId: profileID),
              expectedAccountID == nil || expectedAccountID == accountID else {
            return false
        }

        let progress = min(max(position / duration * 100, 0.01), 100)
        let request: TraktScrobbleRequest
        if meta.isSeries {
            guard let season, season >= 0, let episode, episode > 0 else { return false }
            request = TraktScrobbleRequest(
                progress: progress,
                movie: nil,
                show: media,
                episode: TraktScrobbleEpisode(season: season, number: episode)
            )
        } else {
            request = TraktScrobbleRequest(
                progress: progress,
                movie: media,
                show: nil,
                episode: nil
            )
        }

        let service = TraktAuthService(session: session, store: store)
        return await TraktHistoryService.withPlaybackHistoryLane(accountID: accountID) {
            guard ProfileSettings.isActiveStore(store),
                  WatchedStore.activeProfileId == profileID,
                  TraktHistoryService.completionAccountID(in: store, profileId: profileID) == accountID else {
                return false
            }
            if action == .pause, let playbackID,
               !TraktHistoryService.ownsPlayback(
                    accountID: accountID,
                    profileId: profileID,
                    playbackID: playbackID
               ) {
                return false
            }
            do {
                try await service.authorizedPostEmpty(
                    path: "scrobble/\(action.rawValue)",
                    body: request
                )
                guard ProfileSettings.isActiveStore(store),
                      WatchedStore.activeProfileId == profileID,
                      TraktHistoryService.completionAccountID(in: store, profileId: profileID) == accountID else {
                    return false
                }
                if action == .start, let playbackID {
                    TraktHistoryService.noteSuccessfulPlaybackStart(
                        accountID: accountID,
                        profileId: profileID,
                        playbackID: playbackID
                    )
                }
                NotificationCenter.default.post(
                    name: TraktSettingsStore.continueWatchingChangedNotification,
                    object: nil
                )
                return true
            } catch {
                return false
            }
        }
    }

    fileprivate static func scrobbleMedia(for meta: NuvioMeta) -> TraktScrobbleMedia? {
        let firstIDComponent = meta.id.split(separator: ":", maxSplits: 1).first.map(String.init) ?? meta.id
        let imdb = meta.imdbId ?? (firstIDComponent.hasPrefix("tt") ? firstIDComponent : nil)
        let tmdb = meta.tmdbId ?? (meta.id.hasPrefix("tmdb:")
            ? Int(meta.id.dropFirst("tmdb:".count))
            : nil)
        guard imdb != nil || tmdb != nil else { return nil }
        return TraktScrobbleMedia(ids: TraktScrobbleIDs(imdb: imdb, tmdb: tmdb))
    }

    /// Routes a locally accepted completion to all active scrobble history owners.
    /// Trakt and WeTrakr use their completion outboxes; Simkl/MDBList receive
    /// stop actions and watched marks, and Nuvio Sync drains any captured mirror.
    static func finishPlaybackForHistory(
        meta: NuvioMeta,
        position: Double,
        duration: Double,
        season: Int?,
        episode: Int?,
        store: UserDefaults = ProfileSettings.current,
        profileId: String?,
        completionID: String,
        source: TraktWatchProgressSource,
        expectedAccountID: String?,
        traktMirrorAccountID: String?
    ) async -> Bool {
        guard ProfileSettings.isActiveStore(store),
              ProfileSettings.activeProfileID == profileId,
              WatchedStore.activeProfileId == profileId,
              !completionID.isEmpty else { return false }

        var results: [Bool] = []

        // Finalize Trakt if active
        if RemoteTrackingState.isScrobbleEnabled(for: .trakt, in: store) || source == .trakt {
            let accountID = (source == .trakt ? expectedAccountID : nil)
                ?? traktMirrorAccountID
                ?? TraktHistoryService.completionAccountID(in: store, profileId: profileId)
            if let accountID {
                let traktResult = await TraktHistoryService.finishTraktPlaybackForHistory(
                    meta: meta,
                    position: position,
                    duration: duration,
                    season: season,
                    episode: episode,
                    store: store,
                    profileId: profileId,
                    completionID: completionID,
                    expectedAccountID: accountID
                )
                results.append(traktResult)
            }
        }

        // Finalize WeTrakr if active
        if RemoteTrackingState.isScrobbleEnabled(for: .wetrakr, in: store) || source == .wetrakr {
            let accountID = (source == .wetrakr ? expectedAccountID : nil)
                ?? WeTrakrProgressService.completionAccountID(in: store, profileId: profileId)
            if let accountID {
                let wetrakrResult = await WeTrakrProgressService.finishPlaybackForHistory(
                    meta: meta,
                    position: position,
                    duration: duration,
                    season: season,
                    episode: episode,
                    store: store,
                    profileId: profileId,
                    completionID: completionID,
                    accountID: accountID
                )
                results.append(wetrakrResult)
            }
        }

        // Finalize Simkl if active
        if RemoteTrackingState.isScrobbleEnabled(for: .simkl, in: store) || source == .simkl {
            let simklResult = await reportPlaybackSingleSource(
                source: .simkl,
                meta: meta,
                position: position,
                duration: duration,
                season: season,
                episode: episode,
                action: .stop,
                store: store,
                expectedAccountID: nil,
                playbackID: completionID,
                profileId: profileId,
                session: .shared
            )
            results.append(simklResult)
        }

        // Finalize MDBList if active
        if RemoteTrackingState.isScrobbleEnabled(for: .mdblist, in: store) || source == .mdblist {
            let mdblistResult = await reportPlaybackSingleSource(
                source: .mdblist,
                meta: meta,
                position: position,
                duration: duration,
                season: season,
                episode: episode,
                action: .stop,
                store: store,
                expectedAccountID: nil,
                playbackID: completionID,
                profileId: profileId,
                session: .shared
            )
            results.append(mdblistResult)
        }

        return results.contains(true) || results.isEmpty
    }

    private static func playbackSeed(from item: TraktPlaybackDTO, type: String) -> TraktProgressSeed? {
        let media = type == "movie" ? item.movie : item.show
        guard let media, let contentID = contentID(from: media.ids) else { return nil }
        guard let progress = normalizedProgress(item.progress),
              progress > 0,
              progress < completionPercent else { return nil }

        return TraktProgressSeed(
            contentID: contentID,
            type: type,
            title: media.title ?? contentID,
            year: media.year,
            progressPercent: progress,
            lastUpdated: traktDate(item.pausedAt) ?? .distantPast,
            season: item.episode?.season,
            episode: item.episode?.number,
            episodeTitle: item.episode?.title,
            isUpNext: false,
            ids: media.ids
        )
    }

    private static func nextUpSeed(
        from item: TraktWatchedShowDTO,
        preferFurthestEpisode: Bool
    ) -> TraktProgressSeed? {
        guard let show = item.show, let contentID = contentID(from: show.ids) else { return nil }
        let watched = item.seasons.orEmpty.flatMap { season -> [TraktWatchedEpisodeSeed] in
            guard let seasonNumber = season.number, seasonNumber > 0 else { return [] }
            return season.episodes.orEmpty.compactMap { episode in
                guard let number = episode.number,
                      number > 0,
                      (episode.plays ?? 1) > 0 else { return nil }
                return TraktWatchedEpisodeSeed(
                    season: seasonNumber,
                    episode: number,
                    watchedAt: traktDate(episode.lastWatchedAt ?? item.lastWatchedAt)
                )
            }
        }
        guard var selected = watched.first else { return nil }
        for candidate in watched.dropFirst() {
            if UpNextEpisodeSelectionPolicy.prefers(
                candidateSeason: candidate.season,
                candidateEpisode: candidate.episode,
                candidateWatchedAt: candidate.watchedAt ?? .distantPast,
                over: selected.season,
                currentEpisode: selected.episode,
                currentWatchedAt: selected.watchedAt ?? .distantPast,
                preferFurthestEpisode: preferFurthestEpisode
            ) {
                selected = candidate
            }
        }

        return TraktProgressSeed(
            contentID: contentID,
            type: "series",
            title: show.title ?? contentID,
            year: show.year,
            progressPercent: 0,
            lastUpdated: selected.watchedAt ?? traktDate(item.lastWatchedAt) ?? .distantPast,
            season: selected.season,
            episode: selected.episode,
            episodeTitle: nil,
            isUpNext: true,
            ids: show.ids
        )
    }

    private static func nextUpSeed(from item: TraktEpisodeHistoryDTO) -> TraktProgressSeed? {
        guard let show = item.show,
              let episode = item.episode,
              let season = episode.season,
              let number = episode.number,
              season > 0,
              number > 0,
              let contentID = contentID(from: show.ids) else { return nil }

        return TraktProgressSeed(
            contentID: contentID,
            type: "series",
            title: show.title ?? contentID,
            year: show.year,
            progressPercent: 0,
            lastUpdated: traktDate(item.watchedAt) ?? .distantPast,
            season: season,
            episode: number,
            episodeTitle: episode.title,
            isUpNext: true,
            ids: show.ids
        )
    }

    private static func makeItem(
        from seed: TraktProgressSeed,
        repository: CatalogRepository
    ) async -> ContinueWatchingItem? {
        // Home caches lightweight catalog cards without episode guides. Next Up
        // must bypass that shallow cache or the newest watched show is omitted.
        let loadedMeta: NuvioMeta?
        if seed.isUpNext {
            loadedMeta = try? await repository.refreshMetadata(
                id: seed.contentID,
                type: seed.type
            )
        } else {
            loadedMeta = try? await repository.getMetadata(
                id: seed.contentID,
                type: seed.type
            )
        }
        var meta = loadedMeta ?? placeholderMeta(for: seed)

        // The seed's own season, kept before the up-next branch below overwrites
        // `season` with the suggested episode's — the pair is what tells a season
        // rollover from a step inside one.
        let seedSeason = seed.season
        var season = seed.season
        var episode = seed.episode
        var episodeTitle = seed.episodeTitle
        var episodeOverview: String?
        var episodeThumbnail: String?
        var released: String?

        if seed.type == "series", let currentSeason = season, let currentEpisode = episode {
            if seed.isUpNext {
                guard let next = nextEpisode(after: (currentSeason, currentEpisode), in: meta),
                      EpisodeReleasePolicy.shouldSurfaceNextEpisode(
                        watchedSeason: currentSeason,
                        candidateSeason: next.season,
                        released: next.released
                      ) else { return nil }
                season = next.season
                episode = next.episode
                episodeTitle = next.title
                episodeOverview = next.overview
                episodeThumbnail = next.thumbnail
                released = next.released
            } else if let matched = meta.videos?.first(where: {
                $0.season == currentSeason && $0.episode == currentEpisode
            }) {
                episodeTitle = episodeTitle ?? matched.title
                episodeOverview = matched.overview
                episodeThumbnail = matched.thumbnail
                released = matched.released
            }
        }

        // Prefer the canonical id and artwork returned by metadata, while a
        // lightweight fallback still lets a Trakt-only result open Details.
        if meta.id.isEmpty {
            meta = placeholderMeta(for: seed)
        }
        let duration = runtimeSeconds(for: meta)
        let position = seed.isUpNext
            ? 1.0
            : max(1.0, duration * seed.progressPercent / 100.0)

        return ContinueWatchingItem(
            meta: meta,
            streamUrl: "",
            position: position,
            duration: duration,
            lastWatchedAt: seed.lastUpdated,
            season: season,
            episode: episode,
            released: released,
            episodeTitleOverride: episodeTitle,
            episodeOverviewOverride: episodeOverview,
            episodeThumbnailOverride: episodeThumbnail,
            isUpNext: seed.isUpNext,
            upNextSeedSeason: seed.isUpNext ? seedSeason : nil
        )
    }

    private static func nextEpisode(
        after current: (season: Int, episode: Int),
        in meta: NuvioMeta
    ) -> NuvioVideo? {
        let episodes = meta.videos.orEmpty
            .filter { $0.season > 0 }
            .sorted { ($0.season, $0.episode) < ($1.season, $1.episode) }
        guard let index = episodes.firstIndex(where: {
            $0.season == current.season && $0.episode == current.episode
        }) else { return nil }
        let nextIndex = episodes.index(after: index)
        return episodes.indices.contains(nextIndex) ? episodes[nextIndex] : nil
    }

    private static func placeholderMeta(for seed: TraktProgressSeed) -> NuvioMeta {
        NuvioMeta(
            id: seed.contentID,
            name: seed.title,
            description: nil,
            posterUrl: nil,
            backgroundUrl: nil,
            logoUrl: nil,
            imdbId: seed.ids?.imdb,
            tmdbId: seed.ids?.tmdb,
            type: seed.type,
            year: seed.year,
            genres: nil,
            rating: nil,
            releaseInfo: seed.year.map(String.init),
            runtime: nil,
            cast: nil,
            director: nil,
            writer: nil,
            certification: nil,
            country: nil,
            released: nil
        )
    }

    private static func contentID(from ids: TraktProgressIDsDTO?) -> String? {
        if let imdb = ids?.imdb?.trimmingCharacters(in: .whitespacesAndNewlines), !imdb.isEmpty {
            return imdb
        }
        if let tmdb = ids?.tmdb { return "tmdb:\(tmdb)" }
        if let trakt = ids?.trakt { return "trakt:\(trakt)" }
        return nil
    }

    private static func normalizedProgress(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return min(max(value <= 1 ? value * 100 : value, 0), 100)
    }

    private static func traktDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func runtimeSeconds(for meta: NuvioMeta) -> Double {
        let fallback = meta.isSeries ? 45.0 * 60.0 : 120.0 * 60.0
        guard let raw = meta.runtime?.lowercased(), !raw.isEmpty else { return fallback }
        let values = raw.split(whereSeparator: { !$0.isNumber }).compactMap { Double($0) }
        guard let first = values.first else { return fallback }
        if raw.contains("h") {
            let minutes = values.count > 1 ? values[1] : 0
            return max((first * 60 + minutes) * 60, 60)
        }
        return max(first * 60, 60)
    }
}

// MARK: - Watched history

/// Pagination policy for Trakt's watched endpoints. Trakt may return fewer
/// than the requested limit while more pages still exist, so an empty page or
/// an explicit page-count header is the only normal termination signal.
enum TraktWatchedHistoryPagination {
    static let pageLimit = 250
    static let maxPages = 1_000

    static func shouldFetchNextPage(
        page: Int,
        itemCount: Int,
        pageCount: Int?
    ) -> Bool {
        guard itemCount > 0, page < maxPages else { return false }
        if let pageCount { return page < pageCount }
        return true
    }

    static func pageCount(from headers: [String: String]) -> Int? {
        headers["x-pagination-page-count"]?
            .split(separator: ",", maxSplits: 1)
            .first
            .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
}

/// Mirrors durable local watched/unwatched mutations to Trakt history. This is
/// intentionally independent of the selected Continue Watching source: a
/// connected Trakt account should receive an explicit watched action even when
/// resume points are kept in Nuvio Sync.
struct TraktHistoryService {
    private struct PlaybackOwner: Equatable {
        let profileId: String?
        let playbackID: String
    }

    private enum PendingHistoryWrite {
        case mutation(WatchedStore.PendingProviderMutation)
        case completion(WatchedPlaybackCompletionUpload)
        case libraryMutation(WatchedLibraryMutationUpload)

        var changedAt: Date {
            switch self {
            case .mutation(let mutation): return mutation.changedAt
            case .completion(let completion): return completion.watchedAt
            case .libraryMutation(let mutation): return mutation.changedAt
            }
        }

        var stableID: String {
            switch self {
            case .mutation(let mutation): return "0:\(mutation.id)"
            case .completion(let completion): return "1:\(completion.id)"
            case .libraryMutation(let mutation): return "2:\(mutation.id)"
            }
        }

        var priorityAtEqualTime: Int {
            switch self {
            case .mutation(let mutation): return mutation.isWatched ? 1 : 0
            case .completion: return 2
            case .libraryMutation(let mutation): return mutation.isWatched ? 1 : 0
            }
        }
    }

    private struct WatchedHistoryFetchResult {
        let items: [WatchedStoreItem]
        let receivedResponse: Bool
        let isComplete: Bool
    }

    struct EpisodeHistoryEntry {
        let historyID: Int64
        let item: WatchedStoreItem
    }

    @MainActor
    private struct InFlightSync {
        let profileId: String?
        let generation: Int
        let task: Task<Bool, Never>
    }

    @MainActor private static var inFlightSync: InFlightSync?
    @MainActor private static var syncGeneration = 0
    @MainActor private static var activePlaybackHistoryLanes = Set<String>()
    @MainActor private static var playbackHistoryLaneWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    @MainActor private static var activePlaybackOwners: [String: PlaybackOwner] = [:]

    /// Stable cached account binding used by completion outbox events. A
    /// missing slug is deliberately treated as unknown so a retry cannot bind
    /// an old play to whichever account is linked later.
    static func completionAccountID(
        in store: UserDefaults = ProfileSettings.current,
        profileId: String?
    ) -> String? {
        guard WatchedStore.activeProfileId == profileId,
              ProfileSettings.activeProfileID == profileId,
              ProfileSettings.isActiveStore(store),
              TraktAuthStore.isAuthenticated(in: store),
              let rawSlug = TraktAuthStore.state(in: store).userSlug else {
            return nil
        }
        let slug = rawSlug.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !slug.isEmpty, slug != "me" else { return nil }
        return slug
    }

    /// Drains Trakt resets and completion events for the active account. Each
    /// event retains its original UTC minute and only leaves the outbox after a
    /// matching history row is confirmed.
    @MainActor
    static func flushPendingPlaybackCompletions(
        store: UserDefaults = ProfileSettings.current,
        profileId: String? = WatchedStore.activeProfileId,
        session: URLSession = .shared
    ) async -> Bool {
        guard let expectedAccountID = completionAccountID(in: store, profileId: profileId) else {
            return false
        }
        return await withPlaybackHistoryLane(accountID: expectedAccountID) {
            await drainPendingPlaybackHistory(
                store: store,
                profileId: profileId,
                expectedAccountID: expectedAccountID,
                session: session
            )
        }
    }

    /// Called by other provider finalizers when a captured Trakt mirror account
    /// has completion rows to flush, without issuing a Trakt scrobble pause.
    @MainActor
    static func flushPendingPlaybackHistory(
        store: UserDefaults,
        profileId: String?,
        expectedAccountID: String,
        session: URLSession = .shared
    ) async -> Bool {
        guard isCurrentTraktAccount(
            store: store,
            profileId: profileId,
            expectedAccountID: expectedAccountID
        ) else { return false }
        return await withPlaybackHistoryLane(accountID: expectedAccountID) {
            await drainPendingPlaybackHistory(
                store: store,
                profileId: profileId,
                expectedAccountID: expectedAccountID,
                session: session
            )
        }
    }

    /// Completes a captured Trakt playback without using /scrobble/stop as a
    /// second history writer. Pause progress is removed only when Trakt returns
    /// its row id and a fresh playback read still matches that exact row.
    @MainActor
    static func finishTraktPlaybackForHistory(
        meta: NuvioMeta,
        position: Double,
        duration: Double,
        season: Int?,
        episode: Int?,
        store: UserDefaults,
        profileId: String?,
        completionID: String,
        expectedAccountID: String,
        session: URLSession = .shared
    ) async -> Bool {
        guard !completionID.isEmpty,
              isCurrentTraktAccount(
                store: store,
                profileId: profileId,
                expectedAccountID: expectedAccountID
              ) else { return false }

        return await withPlaybackHistoryLane(accountID: expectedAccountID) {
            guard isCurrentTraktAccount(
                store: store,
                profileId: profileId,
                expectedAccountID: expectedAccountID
            ) else { return false }

            let ownsLivePlayback = ownsPlayback(
                accountID: expectedAccountID,
                profileId: profileId,
                playbackID: completionID
            )
            if ownsLivePlayback {
                await pauseAndRemoveOwnedPlaybackProgress(
                    meta: meta,
                    position: position,
                    duration: duration,
                    season: season,
                    episode: episode,
                    store: store,
                    profileId: profileId,
                    expectedAccountID: expectedAccountID,
                    session: session,
                    playbackID: completionID
                )
                if ownsPlayback(accountID: expectedAccountID, profileId: profileId, playbackID: completionID) {
                    activePlaybackOwners.removeValue(forKey: playbackOwnerKey(expectedAccountID))
                }
            }
            guard isCurrentTraktAccount(
                store: store,
                profileId: profileId,
                expectedAccountID: expectedAccountID
            ) else { return false }
            return await drainPendingPlaybackHistory(
                store: store,
                profileId: profileId,
                expectedAccountID: expectedAccountID,
                session: session
            )
        }
    }

    @MainActor
    private static func pauseAndRemoveOwnedPlaybackProgress(
        meta: NuvioMeta,
        position: Double,
        duration: Double,
        season: Int?,
        episode: Int?,
        store: UserDefaults,
        profileId: String?,
        expectedAccountID: String,
        session: URLSession,
        playbackID: String
    ) async {
        guard position.isFinite,
              duration.isFinite,
              position > 0,
              duration > 0,
              ownsPlayback(accountID: expectedAccountID, profileId: profileId, playbackID: playbackID),
              let media = TraktProgressService.scrobbleMedia(for: meta) else { return }
        let episodeItem: TraktScrobbleEpisode?
        if meta.isSeries {
            guard let season, season >= 0, let episode, episode > 0 else { return }
            episodeItem = TraktScrobbleEpisode(season: season, number: episode)
        } else {
            episodeItem = nil
        }
        let request = TraktScrobbleRequest(
            progress: min(max(position / duration * 100, 0.01), 100),
            movie: meta.isSeries ? nil : media,
            show: meta.isSeries ? media : nil,
            episode: episodeItem
        )
        let requestedAt = Date()
        let service = TraktAuthService(session: session, store: store)
        let response: TraktScrobbleResponseDTO? = try? await service.authorizedPost(
            path: "scrobble/pause",
            body: request
        )
        guard isCurrentTraktAccount(
            store: store,
            profileId: profileId,
            expectedAccountID: expectedAccountID
        ), let response, let playbackID = response.id else { return }

        let expectedPauseMinute = normalizedUTCMinute(
            response.pausedAt.flatMap(historyDate) ?? requestedAt
        )
        let path = meta.isSeries ? "sync/playback/episodes" : "sync/playback/movies"
        guard let playbacks: [TraktPlaybackDTO] = try? await service.authorizedGet(path: path) else { return }
        guard isCurrentTraktAccount(
            store: store,
            profileId: profileId,
            expectedAccountID: expectedAccountID
        ) else { return }
        let expectedProgress = min(max(position / duration * 100, 0.01), 100)
        let ownedRows = playbacks.filter { item in
            guard item.id == playbackID,
                  let pausedAt = item.pausedAt.flatMap(historyDate),
                  normalizedUTCMinute(pausedAt) == expectedPauseMinute,
                  let progress = item.progress,
                  abs(progress - expectedProgress) <= 1.0 else { return false }
            if meta.isSeries {
                guard item.show != nil,
                      item.episode?.season == season,
                      item.episode?.number == episode,
                      let show = item.show else { return false }
                return completionMatches(show: show, expected: meta)
            }
            guard item.show == nil, let movie = item.movie else { return false }
            return completionMatches(show: movie, expected: meta)
        }
        guard ownedRows.count == 1 else { return }
        _ = await service.authorizedDeletePlayback(path: "sync/playback/\(playbackID)")
        guard isCurrentTraktAccount(
            store: store,
            profileId: profileId,
            expectedAccountID: expectedAccountID
        ) else { return }
    }

    @MainActor
    fileprivate static func withPlaybackHistoryLane(
        accountID: String,
        operation: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        let key = "TRAKT:\(accountID.lowercased())"
        if activePlaybackHistoryLanes.contains(key) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                playbackHistoryLaneWaiters[key, default: []].append(continuation)
            }
        } else {
            activePlaybackHistoryLanes.insert(key)
        }

        defer {
            if var waiters = playbackHistoryLaneWaiters[key], !waiters.isEmpty {
                let next = waiters.removeFirst()
                playbackHistoryLaneWaiters[key] = waiters.isEmpty ? nil : waiters
                next.resume()
            } else {
                playbackHistoryLaneWaiters.removeValue(forKey: key)
                activePlaybackHistoryLanes.remove(key)
            }
        }
        return await operation()
    }

    @MainActor
    static func ownsPlayback(accountID: String, profileId: String?, playbackID: String) -> Bool {
        activePlaybackOwners[playbackOwnerKey(accountID)] == PlaybackOwner(
            profileId: profileId,
            playbackID: playbackID
        )
    }

    @MainActor
    static func noteSuccessfulPlaybackStart(accountID: String, profileId: String?, playbackID: String) {
        activePlaybackOwners[playbackOwnerKey(accountID)] = PlaybackOwner(
            profileId: profileId,
            playbackID: playbackID
        )
    }

    private static func playbackOwnerKey(_ accountID: String) -> String {
        accountID.lowercased()
    }

    private enum ExactHistoryLookup: Equatable {
        case found
        case absent
        case uncertain
    }

    @MainActor
    private static func isCurrentTraktAccount(
        store: UserDefaults,
        profileId: String?,
        expectedAccountID: String
    ) -> Bool {
        guard WatchedStore.activeProfileId == profileId,
              ProfileSettings.activeProfileID == profileId,
              ProfileSettings.isActiveStore(store),
              TraktAuthStore.isAuthenticated(in: store) else { return false }
        return completionAccountID(in: store, profileId: profileId) == expectedAccountID
    }

    @MainActor
    private static func drainPendingPlaybackHistory(
        store: UserDefaults,
        profileId: String?,
        expectedAccountID: String,
        session: URLSession = .shared
    ) async -> Bool {
        guard isCurrentTraktAccount(
            store: store,
            profileId: profileId,
            expectedAccountID: expectedAccountID
        ) else { return false }

        let mutations = WatchedStore.pendingProviderMutations(provider: .trakt, profileId: profileId)
        let completions = WatchedStore.pendingPlaybackCompletions(provider: .trakt, profileId: profileId)
        let libraryMutations = WatchedStore.pendingLibraryMutations(
            provider: .trakt,
            profileId: profileId,
            readyOnly: true
        )
        let writes = mutations
            .filter { $0.accountID == expectedAccountID }
            .map(PendingHistoryWrite.mutation)
            + completions
                .filter { $0.accountID == expectedAccountID }
                .map(PendingHistoryWrite.completion)
            + libraryMutations
                .filter { $0.accountID == expectedAccountID && $0.profileID == profileId }
                .map(PendingHistoryWrite.libraryMutation)
        let orderedWrites = writes.sorted { lhs, rhs in
            if lhs.changedAt != rhs.changedAt { return lhs.changedAt < rhs.changedAt }
            if lhs.priorityAtEqualTime != rhs.priorityAtEqualTime {
                return lhs.priorityAtEqualTime < rhs.priorityAtEqualTime
            }
            return lhs.stableID < rhs.stableID
        }

        let hasDeferredAccountWork = mutations.contains { $0.accountID != expectedAccountID }
            || completions.contains { $0.accountID != expectedAccountID }
            || libraryMutations.contains {
                $0.accountID != expectedAccountID || $0.profileID != profileId
            }
        let service = TraktAuthService(session: session, store: store)
        for write in orderedWrites {
            guard isCurrentTraktAccount(
                store: store,
                profileId: profileId,
                expectedAccountID: expectedAccountID
            ) else { return false }
            switch write {
            case .mutation(let mutation):
                guard await uploadManualMutation(mutation, using: service) else { return false }
                guard isCurrentTraktAccount(
                    store: store,
                    profileId: profileId,
                    expectedAccountID: expectedAccountID
                ) else { return false }
                guard WatchedStore.acknowledgeProviderMutation(
                    id: mutation.id,
                    provider: .trakt,
                    profileId: profileId
                ) else { return false }

            case .completion(let completion):
                guard await uploadPlaybackCompletion(
                    completion,
                    using: service,
                    store: store,
                    profileId: profileId,
                    expectedAccountID: expectedAccountID
                ) else { return false }

            case .libraryMutation(let mutation):
                guard await uploadLibraryMutation(mutation, using: service) else {
                    _ = WatchedStore.deferLibraryMutation(
                        id: mutation.id,
                        provider: .trakt,
                        accountID: expectedAccountID,
                        profileId: profileId
                    )
                    return false
                }
                guard isCurrentTraktAccount(
                    store: store,
                    profileId: profileId,
                    expectedAccountID: expectedAccountID
                ) else { return false }
                guard WatchedStore.acknowledgeLibraryMutation(
                    id: mutation.id,
                    provider: .trakt,
                    accountID: expectedAccountID,
                    profileId: profileId
                ) else { return false }
            }
        }
        return !hasDeferredAccountWork
    }

    private static func uploadManualMutation(
        _ pending: WatchedStore.PendingProviderMutation,
        using service: TraktAuthService
    ) async -> Bool {
        guard let request = mutation(
            for: pending.meta,
            season: pending.season,
            episodes: pending.episode.map { [$0] } ?? [],
            watchedAt: pending.isWatched ? minuteISO8601(pending.changedAt) : nil
        ) else { return false }
        do {
            let result: TraktHistoryWriteResponseDTO = try await service.authorizedPost(
                path: pending.isWatched ? "sync/history" : "sync/history/remove",
                body: request
            )
            guard result.itemErrors.orEmpty.isEmpty else { return false }
            if pending.isWatched {
                guard result.added != nil,
                      (result.notFound?.total ?? 0) == 0 else { return false }
                // A zero added count with no item errors is an idempotent
                // success for an already-watched manual marker.
                return true
            }
            // A reset is satisfied if Trakt deleted the row or confirms there
            // was no matching history item to remove.
            return result.deleted != nil || (result.notFound?.total ?? 0) > 0
        } catch {
            return false
        }
    }

    private static func uploadLibraryMutation(
        _ pending: WatchedLibraryMutationUpload,
        using service: TraktAuthService
    ) async -> Bool {
        let episodes = pending.episodes.isEmpty
            ? pending.episode.map { [$0] } ?? []
            : pending.episodes
        guard let request = mutation(
            for: pending.meta,
            season: pending.season,
            episodes: episodes,
            watchedAt: pending.isWatched ? minuteISO8601(pending.changedAt) : nil
        ) else { return false }
        do {
            let result: TraktHistoryWriteResponseDTO = try await service.authorizedPost(
                path: pending.isWatched ? "sync/history" : "sync/history/remove",
                body: request
            )
            guard result.itemErrors.orEmpty.isEmpty else { return false }
            if pending.isWatched {
                return result.added != nil && (result.notFound?.total ?? 0) == 0
            }
            return result.deleted != nil || (result.notFound?.total ?? 0) > 0
        } catch {
            return false
        }
    }

    @MainActor
    private static func uploadPlaybackCompletion(
        _ completion: WatchedPlaybackCompletionUpload,
        using service: TraktAuthService,
        store: UserDefaults,
        profileId: String?,
        expectedAccountID: String
    ) async -> Bool {
        guard completion.accountID == expectedAccountID,
              isCurrentTraktAccount(store: store, profileId: profileId, expectedAccountID: expectedAccountID) else {
            return false
        }
        let preflight = await exactHistoryLookup(for: completion, using: service)
        guard isCurrentTraktAccount(store: store, profileId: profileId, expectedAccountID: expectedAccountID) else {
            return false
        }
        switch preflight {
        case .found:
            return WatchedStore.acknowledgePlaybackCompletion(
                completionID: completion.completionID,
                provider: .trakt,
                accountID: expectedAccountID,
                profileId: profileId
            )
        case .uncertain:
            return false
        case .absent:
            guard let request = mutation(
                for: completion.meta,
                season: completion.season,
                episodes: completion.episode.map { [$0] } ?? [],
                watchedAt: minuteISO8601(completion.watchedAt)
            ) else { return false }
            // A POST can succeed on Trakt while its response is lost. Always
            // verify the exact minute and identity before acknowledging.
            try? await service.authorizedPostEmpty(path: "sync/history", body: request)
            guard isCurrentTraktAccount(
                store: store,
                profileId: profileId,
                expectedAccountID: expectedAccountID
            ) else { return false }
            guard await exactHistoryLookup(for: completion, using: service) == .found else {
                return false
            }
            guard isCurrentTraktAccount(
                store: store,
                profileId: profileId,
                expectedAccountID: expectedAccountID
            ) else { return false }
            return WatchedStore.acknowledgePlaybackCompletion(
                completionID: completion.completionID,
                provider: .trakt,
                accountID: expectedAccountID,
                profileId: profileId
            )
        }
    }

    private static func exactHistoryLookup(
        for completion: WatchedPlaybackCompletionUpload,
        using service: TraktAuthService
    ) async -> ExactHistoryLookup {
        let minuteStart = normalizedUTCMinute(completion.watchedAt)
        let start = minuteISO8601(minuteStart)
        let end = utcISO8601(minuteStart.addingTimeInterval(59))
        let matches: Set<Int64>?
        let hasUnidentifiedMatch: Bool

        if completion.meta.isSeries {
            guard let season = completion.season, let episode = completion.episode else { return .uncertain }
            guard let rows: [TraktEpisodeHistoryDTO] = await fetchCompletionHistoryPages(
                using: service,
                path: { page in
                    "users/me/history/episodes?start_at=\(start)&end_at=\(end)&page=\(page)&limit=\(TraktWatchedHistoryPagination.pageLimit)"
                }
            ) else { return .uncertain }
            var ids = Set<Int64>()
            var unidentified = false
            for row in rows {
                guard let show = row.show,
                      completionMatches(show: show, expected: completion.meta),
                      row.episode?.season == season,
                      row.episode?.number == episode else { continue }
                guard let watchedAt = historyDate(row.watchedAt) else {
                    unidentified = true
                    continue
                }
                guard normalizedUTCMinute(watchedAt) == minuteStart else { continue }
                if let id = row.id { ids.insert(id) } else { unidentified = true }
            }
            matches = ids
            hasUnidentifiedMatch = unidentified
        } else {
            guard completion.season == nil, completion.episode == nil else { return .uncertain }
            guard let rows: [TraktMovieHistoryDTO] = await fetchCompletionHistoryPages(
                using: service,
                path: { page in
                    "users/me/history/movies?start_at=\(start)&end_at=\(end)&page=\(page)&limit=\(TraktWatchedHistoryPagination.pageLimit)"
                }
            ) else { return .uncertain }
            var ids = Set<Int64>()
            var unidentified = false
            for row in rows {
                guard let movie = row.movie,
                      completionMatches(show: movie, expected: completion.meta) else { continue }
                guard let watchedAt = historyDate(row.watchedAt) else {
                    unidentified = true
                    continue
                }
                guard normalizedUTCMinute(watchedAt) == minuteStart else { continue }
                if let id = row.id { ids.insert(id) } else { unidentified = true }
            }
            matches = ids
            hasUnidentifiedMatch = unidentified
        }

        guard !hasUnidentifiedMatch, let matches else { return .uncertain }
        if matches.isEmpty { return .absent }
        return matches.count == 1 ? .found : .uncertain
    }

    private static func completionMatches(show: TraktProgressMediaDTO, expected: NuvioMeta) -> Bool {
        guard let contentID = historyContentID(from: show.ids) else { return false }
        let remote = historyMeta(from: show, contentID: contentID, type: expected.isSeries ? "series" : "movie")
        return WatchedStore.sameContent(remote, expected)
    }

    private static func fetchCompletionHistoryPages<T: Decodable>(
        using service: TraktAuthService,
        path: (Int) -> String
    ) async -> [T]? {
        var items: [T] = []
        var page = 1
        while page <= TraktWatchedHistoryPagination.maxPages {
            guard let response: HTTPResult<[T]> = try? await service.authorizedGetResult(path: path(page)),
                  (200..<300).contains(response.statusCode),
                  let rows = response.value else { return nil }
            if rows.isEmpty { return items }
            items.append(contentsOf: rows)
            guard TraktWatchedHistoryPagination.shouldFetchNextPage(
                page: page,
                itemCount: rows.count,
                pageCount: TraktWatchedHistoryPagination.pageCount(from: response.headers)
            ) else { return items }
            page += 1
        }
        return nil
    }

    private static func normalizedUTCMinute(_ date: Date) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / 60) * 60)
    }

    static func completionMinuteTimestamp(_ date: Date) -> String {
        utcISO8601(normalizedUTCMinute(date))
    }

    private static func minuteISO8601(_ date: Date) -> String {
        completionMinuteTimestamp(date)
    }

    private static func utcISO8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    /// Returns a complete Trakt watched snapshot without mutating Nuvio's
    /// watched store. Used by one-way provider transfers.
    static func fetchWatchedHistory(
        store: UserDefaults = ProfileSettings.current
    ) async -> [WatchedStoreItem]? {
        guard ProfileSettings.isActiveStore(store),
              TraktAuthStore.isAuthenticated(in: store) else { return nil }

        let service = TraktAuthService(store: store)
        guard await service.refreshTokenIfNeeded() else { return nil }
        let result = await fetchWatchedHistorySnapshot(using: service)
        guard result.receivedResponse, result.isComplete else { return nil }
        return WatchedStore.mergedByIdentity(result.items)
    }

    /// Pulls Trakt's complete watched snapshot into the durable store used by
    /// Details, episode cards, Continue Watching reconciliation, and Nuvio
    /// Sync. This runs whenever Trakt is connected, independently of which
    /// provider is selected for resume progress.
    @MainActor
    static func syncWatchedHistory(
        store: UserDefaults = ProfileSettings.current
    ) async -> Bool {
        guard ProfileSettings.isActiveStore(store),
              TraktAuthStore.isAuthenticated(in: store) else { return false }

        let targetProfileId = WatchedStore.activeProfileId
        if let inFlightSync,
           inFlightSync.profileId == targetProfileId {
            return await inFlightSync.task.value
        }

        syncGeneration &+= 1
        let generation = syncGeneration
        let task = Task { @MainActor in
            await performWatchedHistorySync(
                store: store,
                targetProfileId: targetProfileId
            )
        }
        inFlightSync = InFlightSync(
            profileId: targetProfileId,
            generation: generation,
            task: task
        )
        let result = await task.value
        if inFlightSync?.generation == generation {
            inFlightSync = nil
        }
        return result
    }

    @MainActor
    private static func performWatchedHistorySync(
        store: UserDefaults,
        targetProfileId: String?
    ) async -> Bool {
        guard ProfileSettings.isActiveStore(store),
              TraktAuthStore.isAuthenticated(in: store) else { return false }

        let service = TraktAuthService(store: store)
        guard await service.refreshTokenIfNeeded() else { return false }
        guard let expectedAccountID = completionAccountID(in: store, profileId: targetProfileId) else { return false }

        // Durable resets and playback completions share one account-bound lane.
        // Unbound/old-account mutations stay queued instead of being sent to a
        // newly linked Trakt account.
        _ = await flushPendingPlaybackCompletions(store: store, profileId: targetProfileId)
        guard isCurrentTraktAccount(
            store: store,
            profileId: targetProfileId,
            expectedAccountID: expectedAccountID
        ) else { return false }
        let syncStartedAt = Date()
        let result = await fetchWatchedHistorySnapshot(using: service)
        guard result.receivedResponse,
              isCurrentTraktAccount(
                store: store,
                profileId: targetProfileId,
                expectedAccountID: expectedAccountID
              ) else { return false }
        // Network requests above can outlive the profile that initiated them.
        // Never apply one profile's Trakt account to another profile's store.
        guard WatchedStore.activeProfileId == targetProfileId else { return false }
        guard result.isComplete else {
            // A partial response is still useful for importing new marks, but
            // absence is authoritative only when both Trakt collections loaded.
            return WatchedStore.mergeTraktPartialSnapshot(
                result.items,
                syncStartedAt: syncStartedAt,
                currentAccountID: expectedAccountID,
                profileId: targetProfileId
            )
        }
        return WatchedStore.reconcileTraktSnapshot(
            result.items,
            syncStartedAt: syncStartedAt
        )
    }

    private static func fetchWatchedHistorySnapshot(
        using service: TraktAuthService
    ) async -> WatchedHistoryFetchResult {
        var remoteItems: [WatchedStoreItem] = []
        var receivedResponse = false
        var isComplete = true

        if let movies: [TraktWatchedMovieDTO] = await fetchWatchedPages(
            using: service,
            path: { page in
                "sync/watched/movies?page=\(page)&limit=\(TraktWatchedHistoryPagination.pageLimit)"
            }
        ) {
            receivedResponse = true
            let converted = movies.compactMap(watchedMovie)
            if converted.count != movies.count { isComplete = false }
            remoteItems.append(contentsOf: converted)
        } else {
            isComplete = false
        }

        if let shows: [TraktWatchedShowDTO] = await fetchWatchedPages(
            using: service,
            path: { page in
                "sync/watched/shows?page=\(page)&limit=\(TraktWatchedHistoryPagination.pageLimit)&extended=progress"
            }
        ) {
            receivedResponse = true
            var needsHistoryFallback = false
            for show in shows {
                if show.seasons.orEmpty.isEmpty {
                    needsHistoryFallback = true
                } else if let episodes = watchedEpisodes(show) {
                    remoteItems.append(contentsOf: episodes)
                } else {
                    isComplete = false
                }
            }

            if needsHistoryFallback {
                if let historyItems = await fetchCompleteEpisodeHistory(using: service) {
                    remoteItems.append(contentsOf: historyItems)
                } else {
                    isComplete = false
                }
            }
        } else {
            isComplete = false
        }

        return WatchedHistoryFetchResult(
            items: WatchedStore.mergedByIdentity(remoteItems),
            receivedResponse: receivedResponse,
            isComplete: isComplete
        )
    }

    private static func fetchWatchedPages<T: Decodable>(
        using service: TraktAuthService,
        path: (Int) -> String
    ) async -> [T]? {
        var items: [T] = []
        var page = 1

        while page <= TraktWatchedHistoryPagination.maxPages {
            guard let response: HTTPResult<[T]> = try? await service.authorizedGetResult(
                path: path(page)
            ),
            (200..<300).contains(response.statusCode),
            let pageItems = response.value else {
                return nil
            }

            if pageItems.isEmpty { return items }
            items.append(contentsOf: pageItems)

            guard TraktWatchedHistoryPagination.shouldFetchNextPage(
                page: page,
                itemCount: pageItems.count,
                pageCount: TraktWatchedHistoryPagination.pageCount(from: response.headers)
            ) else {
                return items
            }
            page += 1
        }

        return nil
    }

    static func setWatched(
        _ meta: NuvioMeta,
        season: Int? = nil,
        episode: Int? = nil,
        isWatched: Bool,
        store: UserDefaults = ProfileSettings.current,
        notifyChange: Bool = true
    ) async -> Bool {
        await setWatched(
            meta,
            season: season,
            episodes: episode.map { [$0] } ?? [],
            isWatched: isWatched,
            store: store,
            notifyChange: notifyChange
        )
    }

    /// Season-wide counterpart: every episode listed rides in one `sync/history`
    /// write instead of one request each.
    static func setWatched(
        _ meta: NuvioMeta,
        season: Int?,
        episodes: [Int],
        isWatched: Bool,
        store: UserDefaults = ProfileSettings.current,
        notifyChange: Bool = true
    ) async -> Bool {
        guard ProfileSettings.isActiveStore(store),
              TraktAuthStore.isAuthenticated(in: store),
              let mutation = mutation(
                for: meta,
                season: season,
                episodes: episodes,
                watchedAt: isWatched ? iso8601Now() : nil
              ) else {
            return false
        }

        do {
            try await TraktAuthService(store: store).authorizedPostEmpty(
                path: isWatched ? "sync/history" : "sync/history/remove",
                body: mutation
            )
            if notifyChange {
                NotificationCenter.default.post(
                    name: TraktSettingsStore.continueWatchingChangedNotification,
                    object: nil
                )
                TraktSettingsStore.notifyContinueWatchingSourceInvalidated(for: .trakt, in: store)
            }
            return true
        } catch {
            return false
        }
    }

    /// `episodes` carries every episode being marked in one season, so a whole
    /// season is one request rather than one per episode.
    private static func mutation(
        for meta: NuvioMeta,
        season: Int?,
        episodes: [Int],
        watchedAt: String?
    ) -> TraktHistoryMutation? {
        let firstIDComponent = meta.id.split(separator: ":", maxSplits: 1).first.map(String.init) ?? meta.id
        let ids = TraktHistoryIDs(
            trakt: meta.id.hasPrefix("trakt:") ? Int(meta.id.dropFirst("trakt:".count)) : nil,
            imdb: meta.imdbId ?? (firstIDComponent.hasPrefix("tt") ? firstIDComponent : nil),
            tmdb: meta.tmdbId ?? (meta.id.hasPrefix("tmdb:")
                ? Int(meta.id.dropFirst("tmdb:".count))
                : nil)
        )
        guard ids.trakt != nil || ids.imdb != nil || ids.tmdb != nil else { return nil }

        if meta.isSeries {
            let seasons: [TraktHistorySeason]?
            if let season, !episodes.isEmpty {
                seasons = [
                    TraktHistorySeason(
                        number: season,
                        episodes: episodes.map {
                            TraktHistoryEpisode(number: $0, watchedAt: watchedAt)
                        }
                    )
                ]
            } else {
                seasons = nil
            }
            return TraktHistoryMutation(
                movies: nil,
                shows: [
                    TraktHistoryShow(
                        title: meta.name,
                        year: meta.year,
                        ids: ids,
                        watchedAt: watchedAt,
                        seasons: seasons
                    )
                ]
            )
        }

        return TraktHistoryMutation(
            movies: [
                TraktHistoryMovie(
                    title: meta.name,
                    year: meta.year,
                    ids: ids,
                    watchedAt: watchedAt
                )
            ],
            shows: nil
        )
    }

    private static func iso8601Now() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }

    static func watchedMovie(_ item: TraktWatchedMovieDTO) -> WatchedStoreItem? {
        guard let movie = item.movie,
              let contentID = historyContentID(from: movie.ids) else { return nil }
        return WatchedStoreItem(
            meta: historyMeta(from: movie, contentID: contentID, type: "movie"),
            watchedAt: historyDate(item.lastWatchedAt) ?? .distantPast,
            watchCountsBySource: [TraktWatchProgressSource.trakt.rawValue: max(1, item.plays ?? 1)]
        )
    }

    static func watchedEpisodes(_ item: TraktWatchedShowDTO) -> [WatchedStoreItem]? {
        guard let show = item.show,
              let contentID = historyContentID(from: show.ids),
              let seasons = item.seasons,
              !seasons.isEmpty else { return nil }
        let meta = historyMeta(from: show, contentID: contentID, type: "series")
        var watched: [WatchedStoreItem] = []
        for season in seasons {
            guard let seasonNumber = season.number,
                  seasonNumber >= 0,
                  let episodes = season.episodes else { return nil }
            for episode in episodes {
                guard let episodeNumber = episode.number, episodeNumber > 0 else { return nil }
                guard (episode.plays ?? 1) > 0 else { continue }
                watched.append(
                    WatchedStoreItem(
                        meta: meta,
                        watchedAt: historyDate(episode.lastWatchedAt ?? item.lastWatchedAt) ?? .distantPast,
                        season: seasonNumber,
                        episode: episodeNumber,
                        watchCountsBySource: [
                            TraktWatchProgressSource.trakt.rawValue: max(1, episode.plays ?? 1)
                        ]
                    )
                )
            }
        }
        return watched
    }

    private static func fetchCompleteEpisodeHistory(
        using service: TraktAuthService
    ) async -> [WatchedStoreItem]? {
        let pageSize = 100
        var page = 1
        var entries: [EpisodeHistoryEntry] = []

        while true {
            guard let historyPage: [TraktEpisodeHistoryDTO] = try? await service.authorizedGet(
                path: "users/me/history/episodes?page=\(page)&limit=\(pageSize)"
            ) else { return nil }

            let converted = historyPage.compactMap { item -> EpisodeHistoryEntry? in
                guard let historyID = item.id,
                      let watched = watchedEpisode(item) else { return nil }
                return EpisodeHistoryEntry(historyID: historyID, item: watched)
            }
            // A row we cannot identify makes absence unsafe as a deletion signal.
            guard converted.count == historyPage.count else { return nil }
            entries.append(contentsOf: converted)
            guard historyPage.count == pageSize else {
                return aggregateFallbackEpisodeHistory(entries)
            }
            page += 1
        }
    }

    static func aggregateFallbackEpisodeHistory(_ entries: [EpisodeHistoryEntry]) -> [WatchedStoreItem] {
        struct Group {
            var item: WatchedStoreItem
            var historyIDs: Set<Int64>
        }
        var groups: [String: Group] = [:]
        for entry in entries {
            guard let season = entry.item.season, let episode = entry.item.episode else { continue }
            let identityKeys = WatchedStore.contentIdentityKeys(for: entry.item.meta)
            let canonicalID = identityKeys.first(where: { $0.hasPrefix("imdb:") })
                ?? identityKeys.first(where: { $0.hasPrefix("tmdb:") })
                ?? identityKeys.sorted().first
                ?? entry.item.meta.id.lowercased()
            let key = "\(WatchedStore.normalizedType(entry.item.meta.canonicalType))|\(canonicalID)|\(season)|\(episode)"
            if var group = groups[key] {
                group.historyIDs.insert(entry.historyID)
                if entry.item.watchedAt > group.item.watchedAt {
                    group.item = entry.item
                }
                groups[key] = group
            } else {
                groups[key] = Group(item: entry.item, historyIDs: [entry.historyID])
            }
        }

        return groups.values.map { group in
            WatchedStoreItem(
                meta: group.item.meta,
                watchedAt: group.item.watchedAt,
                season: group.item.season,
                episode: group.item.episode,
                sources: [TraktWatchProgressSource.trakt.rawValue],
                watchCountsBySource: [TraktWatchProgressSource.trakt.rawValue: max(1, group.historyIDs.count)]
            )
        }
    }

    private static func watchedEpisode(_ item: TraktEpisodeHistoryDTO) -> WatchedStoreItem? {
        guard let show = item.show,
              let episode = item.episode,
              let seasonNumber = episode.season,
              let episodeNumber = episode.number,
              let watchedAt = historyDate(item.watchedAt),
              seasonNumber >= 0,
              episodeNumber > 0,
              let contentID = historyContentID(from: show.ids) else { return nil }
        return WatchedStoreItem(
            meta: historyMeta(from: show, contentID: contentID, type: "series"),
            watchedAt: watchedAt,
            season: seasonNumber,
            episode: episodeNumber
        )
    }

    private static func historyMeta(
        from media: TraktProgressMediaDTO,
        contentID: String,
        type: String
    ) -> NuvioMeta {
        NuvioMeta(
            id: contentID,
            name: media.title ?? contentID,
            description: media.overview,
            posterUrl: nil,
            backgroundUrl: nil,
            logoUrl: nil,
            imdbId: media.ids?.imdb,
            tmdbId: media.ids?.tmdb,
            type: type,
            year: media.year,
            genres: media.genres,
            rating: media.rating,
            releaseInfo: media.year.map(String.init),
            runtime: media.runtime.map { "\($0) min" },
            cast: nil,
            director: nil,
            writer: nil,
            certification: nil,
            country: nil,
            released: nil
        ).persistenceSnapshot
    }

    private static func historyContentID(from ids: TraktProgressIDsDTO?) -> String? {
        if let imdb = ids?.imdb?.trimmingCharacters(in: .whitespacesAndNewlines), !imdb.isEmpty {
            return imdb
        }
        if let tmdb = ids?.tmdb { return "tmdb:\(tmdb)" }
        if let trakt = ids?.trakt { return "trakt:\(trakt)" }
        return nil
    }

    private static func historyDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

private struct TraktHistoryMutation: Encodable {
    let movies: [TraktHistoryMovie]?
    let shows: [TraktHistoryShow]?
}

private struct TraktHistoryWriteResponseDTO: Decodable {
    let added: TraktHistoryCountDTO?
    let deleted: TraktHistoryCountDTO?
    let notFound: TraktHistoryNotFoundDTO?
    let itemErrors: [TraktHistoryItemErrorDTO]?

    enum CodingKeys: String, CodingKey {
        case added, deleted
        case notFound = "not_found"
        case itemErrors = "item_errors"
    }
}

private struct TraktHistoryCountDTO: Decodable {
    let movies: Int?
    let shows: Int?
    let seasons: Int?
    let episodes: Int?

    var total: Int { (movies ?? 0) + (shows ?? 0) + (seasons ?? 0) + (episodes ?? 0) }
}

private struct TraktHistoryNotFoundDTO: Decodable {
    let movies: [TraktHistoryNotFoundItemDTO]?
    let shows: [TraktHistoryNotFoundItemDTO]?
    let seasons: [TraktHistoryNotFoundItemDTO]?
    let episodes: [TraktHistoryNotFoundItemDTO]?

    var total: Int { (movies?.count ?? 0) + (shows?.count ?? 0) + (seasons?.count ?? 0) + (episodes?.count ?? 0) }
}

private struct TraktHistoryNotFoundItemDTO: Decodable {
    let ids: TraktProgressIDsDTO?
    let title: String?
    let year: Int?
    let number: Int?
}

private struct TraktHistoryItemErrorDTO: Decodable {
    let code: String?
    let message: String?
}

private struct TraktHistoryMovie: Encodable {
    let title: String
    let year: Int?
    let ids: TraktHistoryIDs
    let watchedAt: String?

    enum CodingKeys: String, CodingKey {
        case title, year, ids
        case watchedAt = "watched_at"
    }
}

private struct TraktHistoryShow: Encodable {
    let title: String
    let year: Int?
    let ids: TraktHistoryIDs
    let watchedAt: String?
    let seasons: [TraktHistorySeason]?

    enum CodingKeys: String, CodingKey {
        case title, year, ids, seasons
        case watchedAt = "watched_at"
    }
}

private struct TraktHistorySeason: Encodable {
    let number: Int
    let episodes: [TraktHistoryEpisode]
}

private struct TraktHistoryEpisode: Encodable {
    let number: Int
    let watchedAt: String?

    enum CodingKeys: String, CodingKey {
        case number
        case watchedAt = "watched_at"
    }
}

private struct TraktHistoryIDs: Encodable {
    let trakt: Int?
    let imdb: String?
    let tmdb: Int?
}

private struct TraktProgressSeed {
    let contentID: String
    let type: String
    let title: String
    let year: Int?
    let progressPercent: Double
    let lastUpdated: Date
    let season: Int?
    let episode: Int?
    let episodeTitle: String?
    let isUpNext: Bool
    let ids: TraktProgressIDsDTO?
}

private struct TraktScrobbleRequest: Encodable {
    let progress: Double
    let movie: TraktScrobbleMedia?
    let show: TraktScrobbleMedia?
    let episode: TraktScrobbleEpisode?
}

private struct TraktScrobbleMedia: Encodable {
    let ids: TraktScrobbleIDs
}

private struct TraktScrobbleIDs: Encodable {
    let imdb: String?
    let tmdb: Int?
}

private struct TraktScrobbleEpisode: Encodable {
    let season: Int
    let number: Int
}

private struct TraktWatchedEpisodeSeed {
    let season: Int
    let episode: Int
    let watchedAt: Date?
}

private struct TraktPlaybackDTO: Decodable {
    let id: Int64?
    let progress: Double?
    let pausedAt: String?
    let movie: TraktProgressMediaDTO?
    let show: TraktProgressMediaDTO?
    let episode: TraktProgressEpisodeDTO?

    enum CodingKeys: String, CodingKey {
        case id, progress, movie, show, episode
        case pausedAt = "paused_at"
    }
}

private struct TraktScrobbleResponseDTO: Decodable {
    let id: Int64?
    let pausedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case pausedAt = "paused_at"
    }
}

struct TraktProgressMediaDTO: Decodable {
    let title: String?
    let year: Int?
    let ids: TraktProgressIDsDTO?
    let overview: String?
    let rating: Double?
    let genres: [String]?
    let runtime: Int?
}

private struct TraktProgressEpisodeDTO: Decodable {
    let title: String?
    let season: Int?
    let number: Int?
}

struct TraktProgressIDsDTO: Decodable {
    let trakt: Int?
    let imdb: String?
    let tmdb: Int?
}

struct TraktWatchedShowDTO: Decodable {
    let lastWatchedAt: String?
    let show: TraktProgressMediaDTO?
    let seasons: [TraktWatchedSeasonDTO]?

    enum CodingKeys: String, CodingKey {
        case show, seasons
        case lastWatchedAt = "last_watched_at"
    }
}

struct TraktWatchedMovieDTO: Decodable {
    let lastWatchedAt: String?
    let plays: Int?
    let movie: TraktProgressMediaDTO?

    enum CodingKeys: String, CodingKey {
        case movie, plays
        case lastWatchedAt = "last_watched_at"
    }
}

private struct TraktEpisodeHistoryDTO: Decodable {
    let id: Int64?
    let watchedAt: String?
    let show: TraktProgressMediaDTO?
    let episode: TraktProgressEpisodeDTO?

    enum CodingKeys: String, CodingKey {
        case id, show, episode
        case watchedAt = "watched_at"
    }
}

private struct TraktMovieHistoryDTO: Decodable {
    let id: Int64?
    let watchedAt: String?
    let movie: TraktProgressMediaDTO?

    enum CodingKeys: String, CodingKey {
        case id, movie
        case watchedAt = "watched_at"
    }
}

struct TraktWatchedSeasonDTO: Decodable {
    let number: Int?
    let episodes: [TraktWatchedEpisodeDTO]?
}

struct TraktWatchedEpisodeDTO: Decodable {
    let number: Int?
    let plays: Int?
    let lastWatchedAt: String?

    enum CodingKeys: String, CodingKey {
        case number, plays
        case lastWatchedAt = "last_watched_at"
    }
}

private extension Optional where Wrapped: RangeReplaceableCollection {
    var orEmpty: Wrapped { self ?? Wrapped() }
}

// MARK: - Library

/// Carries a profile's UserDefaults store across the async boundary. UserDefaults
/// supports concurrent access; ProfileSettings.current itself is captured on MainActor.
private struct TraktLibraryDefaultsStore: @unchecked Sendable {
    let value: UserDefaults
}

/// Loads the Trakt-backed library without writing it into `LibraryStore`.
/// Trakt's library surface mirrors the other Nuvio clients: Watchlist plus
/// items from the user's personal lists.
struct TraktLibraryService {
    private static let maxItems = 200
    static let mutationNotification = Notification.Name("nuvio.tv.trakt.library.mutation")

    /// Mirrors Android TV's default Library action: when the user selected
    /// Trakt as the library source, add/remove the title from Trakt's watchlist
    /// instead of writing only to the hidden local library.
    static func setWatchlist(_ meta: NuvioMeta, isInWatchlist: Bool) async -> Bool {
        guard let body = watchlistMutation(for: meta),
              let context = await MainActor.run(body: { TraktLibraryMutationContext() }) else {
            return false
        }

        do {
            let response: TraktWatchlistMutationResponse = try await TraktAuthService(store: context.store).authorizedPost(
                path: isInWatchlist ? "sync/watchlist" : "sync/watchlist/remove",
                body: body
            )
            guard response.applied(isInWatchlist: isInWatchlist) else { return false }
            await MainActor.run {
                publishMutation(TraktLibraryMutation(
                    meta: meta,
                    isInWatchlist: isInWatchlist,
                    context: context
                ))
            }
            // A successful remote write must not be reported as a failure just
            // because its local notification no longer belongs to this session.
            return true
        } catch {
            return false
        }
    }

    @MainActor
    static func publishMutation(_ mutation: TraktLibraryMutation) {
        guard !Task.isCancelled, mutation.context?.isCurrent == true else { return }
        NotificationCenter.default.post(name: mutationNotification, object: mutation)
        NotificationCenter.default.post(name: TraktSettingsStore.libraryChangedNotification, object: nil)
    }

    static func fetchLibrary(
        repository: CatalogRepository,
        requireSelectedSource: Bool = true,
        onSnapshot: LibraryMetadataHydrator.SnapshotHandler? = nil
    ) async -> [LibraryStoreItem]? {
        let (store, profileID, settingsProfileID, hasLibraryContext, isLibraryContextCurrent) = await MainActor.run {
            let context = TraktLibraryMutationContext()
            let isContextCurrent: @MainActor @Sendable () -> Bool = {
                context?.isCurrent == true
            }
            return (
                TraktLibraryDefaultsStore(value: ProfileSettings.current),
                LibraryStore.activeProfileId,
                ProfileSettings.activeProfileID,
                context != nil,
                isContextCurrent
            )
        }
        guard (!requireSelectedSource || TraktSettingsStore.librarySourceMode(in: store.value) == .trakt),
              TraktAuthStore.isAuthenticated(in: store.value),
              (!requireSelectedSource || hasLibraryContext) else {
            return []
        }

        let isCurrent: @MainActor () -> Bool = {
            guard !Task.isCancelled,
                  LibraryStore.activeProfileId == profileID,
                  ProfileSettings.activeProfileID == settingsProfileID,
                  ProfileSettings.isActiveStore(store.value),
                  TraktAuthStore.isAuthenticated(in: store.value) else { return false }
            if requireSelectedSource {
                return TraktSettingsStore.librarySourceMode(in: store.value) == .trakt
                    && isLibraryContextCurrent()
            }
            return true
        }

        let service = TraktAuthService(store: store.value)
        guard await service.refreshTokenIfNeeded() else { return nil }
        guard await isCurrent() else { return nil }

        var receivedResponse = false
        var seeds: [TraktLibrarySeed] = []

        guard await isCurrent() else { return nil }
        if let movies: [TraktLibraryItemDTO] = try? await service.authorizedGet(
            path: "users/me/watchlist/movies/rank?extended=full&page=1&limit=1000"
        ) {
            receivedResponse = true
            seeds.append(contentsOf: movies.compactMap { seed(from: $0, type: "movie") })
        }

        guard await isCurrent() else { return nil }
        if let shows: [TraktLibraryItemDTO] = try? await service.authorizedGet(
            path: "users/me/watchlist/shows/rank?extended=full&page=1&limit=1000"
        ) {
            receivedResponse = true
            seeds.append(contentsOf: shows.compactMap { seed(from: $0, type: "series") })
        }

        guard await isCurrent() else { return nil }
        if let lists: [TraktPersonalListDTO] = try? await service.authorizedGet(
            path: "users/me/lists"
        ) {
            receivedResponse = true
            for list in lists where list.type?.lowercased() == "personal" {
                guard await isCurrent() else { return nil }
                guard let identifier = listIdentifier(from: list.ids) else { continue }

                if let movies: [TraktLibraryItemDTO] = try? await service.authorizedGet(
                    path: "users/me/lists/\(identifier)/items/movie?extended=full&page=1&limit=1000"
                ) {
                    seeds.append(contentsOf: movies.compactMap { seed(from: $0, type: "movie") })
                }

                guard await isCurrent() else { return nil }
                if let shows: [TraktLibraryItemDTO] = try? await service.authorizedGet(
                    path: "users/me/lists/\(identifier)/items/show?extended=full&page=1&limit=1000"
                ) {
                    seeds.append(contentsOf: shows.compactMap { seed(from: $0, type: "series") })
                }
                guard await isCurrent() else { return nil }
            }
        }

        guard receivedResponse else { return nil }
        guard await isCurrent() else { return nil }

        let sortedSeeds = seeds.enumerated().sorted {
            if $0.element.addedAt == $1.element.addedAt { return $0.offset < $1.offset }
            return $0.element.addedAt > $1.element.addedAt
        }.map(\.element)
        var usedIDs = Set<String>()
        var results: [LibraryStoreItem] = []

        for seed in sortedSeeds {
            guard await isCurrent(), results.count < maxItems else { break }
            let key = "\(seed.type):\(seed.contentID)"
            guard usedIDs.insert(key).inserted else { continue }

            let placeholder = placeholderMeta(for: seed)
            let meta = repository.cachedMetadata(for: seed.contentID)
                .map { LibraryMetadataHydrator.merging($0, into: placeholder) }
                ?? placeholder
            results.append(LibraryStoreItem(meta: meta, addedAt: seed.addedAt))
        }
        return await LibraryMetadataHydrator.hydrate(
            seeds: results,
            repository: repository,
            onSnapshot: onSnapshot,
            isCurrent: isCurrent
        )
    }

    private static func seed(from item: TraktLibraryItemDTO, type: String) -> TraktLibrarySeed? {
        let media = type == "movie" ? item.movie : item.show
        guard let media, let contentID = contentID(from: media.ids) else { return nil }
        return TraktLibrarySeed(
            contentID: contentID,
            type: type,
            title: media.title ?? contentID,
            year: media.year,
            overview: media.overview,
            rating: media.rating,
            genres: media.genres,
            runtime: media.runtime,
            ids: media.ids,
            addedAt: traktDate(item.listedAt) ?? .distantPast
        )
    }

    private static func watchlistMutation(for meta: NuvioMeta) -> TraktWatchlistMutation? {
        let firstIDComponent = meta.id.split(separator: ":", maxSplits: 1).first.map(String.init) ?? meta.id
        let imdb = meta.imdbId ?? (firstIDComponent.hasPrefix("tt") ? firstIDComponent : nil)
        let tmdb = meta.tmdbId ?? (meta.id.hasPrefix("tmdb:")
            ? Int(meta.id.dropFirst("tmdb:".count))
            : nil)
        let trakt = meta.id.hasPrefix("trakt:")
            ? Int(meta.id.dropFirst("trakt:".count))
            : nil
        guard imdb != nil || tmdb != nil || trakt != nil else { return nil }

        let item = TraktWatchlistMedia(
            title: meta.name,
            year: meta.year,
            ids: TraktWatchlistIDs(trakt: trakt, imdb: imdb, tmdb: tmdb)
        )
        return meta.isSeries
            ? TraktWatchlistMutation(movies: nil, shows: [item])
            : TraktWatchlistMutation(movies: [item], shows: nil)
    }

    private static func placeholderMeta(for seed: TraktLibrarySeed) -> NuvioMeta {
        NuvioMeta(
            id: seed.contentID,
            name: seed.title,
            description: seed.overview,
            posterUrl: nil,
            backgroundUrl: nil,
            logoUrl: nil,
            imdbId: seed.ids?.imdb,
            tmdbId: seed.ids?.tmdb,
            type: seed.type,
            year: seed.year,
            genres: seed.genres,
            rating: seed.rating,
            releaseInfo: seed.year.map(String.init),
            runtime: seed.runtime.map { "\($0) min" },
            cast: nil,
            director: nil,
            writer: nil,
            certification: nil,
            country: nil,
            released: nil
        )
    }

    private static func contentID(from ids: TraktProgressIDsDTO?) -> String? {
        if let imdb = ids?.imdb?.trimmingCharacters(in: .whitespacesAndNewlines), !imdb.isEmpty {
            return imdb
        }
        if let tmdb = ids?.tmdb { return "tmdb:\(tmdb)" }
        if let trakt = ids?.trakt { return "trakt:\(trakt)" }
        return nil
    }

    private static func listIdentifier(from ids: TraktPersonalListIDsDTO?) -> String? {
        if let trakt = ids?.trakt { return String(trakt) }
        guard let slug = ids?.slug?.trimmingCharacters(in: .whitespacesAndNewlines), !slug.isEmpty else {
            return nil
        }
        return slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
    }

    private static func traktDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

private struct TraktLibrarySeed {
    let contentID: String
    let type: String
    let title: String
    let year: Int?
    let overview: String?
    let rating: Double?
    let genres: [String]?
    let runtime: Int?
    let ids: TraktProgressIDsDTO?
    let addedAt: Date
}

private struct TraktLibraryItemDTO: Decodable {
    let listedAt: String?
    let movie: TraktProgressMediaDTO?
    let show: TraktProgressMediaDTO?

    enum CodingKeys: String, CodingKey {
        case movie, show
        case listedAt = "listed_at"
    }
}

private struct TraktWatchlistMutation: Encodable {
    let movies: [TraktWatchlistMedia]?
    let shows: [TraktWatchlistMedia]?
}

private struct TraktWatchlistMedia: Encodable {
    let title: String
    let year: Int?
    let ids: TraktWatchlistIDs
}

private struct TraktWatchlistIDs: Encodable {
    let trakt: Int?
    let imdb: String?
    let tmdb: Int?
}

/// Identifies the profile and Trakt account that started a watchlist write.
/// Refresh rotation preserves accountBindingID; a new login replaces it.
struct TraktLibraryMutationContext {
    let store: UserDefaults
    private let profileID: String?
    private let settingsProfileID: String?
    private let clientID: String
    private let bindingID: String?
    private let accessToken: String?
    private let refreshToken: String?

    @MainActor
    init?() {
        let store = ProfileSettings.current
        guard TraktSettingsStore.librarySourceMode == .trakt,
              TraktAuthStore.isAuthenticated(in: store) else { return nil }
        self.store = store
        profileID = LibraryStore.activeProfileId
        settingsProfileID = ProfileSettings.activeProfileID
        clientID = TraktConfig.clientID(in: store)
        bindingID = TraktAuthStore.accountBindingID(in: store)
        let state = TraktAuthStore.state(in: store)
        accessToken = state.accessToken
        refreshToken = state.refreshToken
    }

    @MainActor
    var isCurrent: Bool {
        guard profileID == LibraryStore.activeProfileId,
              settingsProfileID == ProfileSettings.activeProfileID,
              ProfileSettings.isActiveStore(store),
              TraktSettingsStore.librarySourceMode == .trakt,
              TraktAuthStore.isAuthenticated(in: store),
              TraktConfig.clientID(in: store) == clientID else { return false }
        if let bindingID {
            return TraktAuthStore.accountBindingID(in: store) == bindingID
        }
        let state = TraktAuthStore.state(in: store)
        return state.accessToken == accessToken && state.refreshToken == refreshToken
    }
}

struct TraktLibraryMutation {
    let meta: NuvioMeta
    let isInWatchlist: Bool
    // Simkl and WeTrakr also use this legacy notification payload.
    // Trakt always supplies its captured context; their call sites stay intact.
    let context: TraktLibraryMutationContext?

    init(meta: NuvioMeta, isInWatchlist: Bool, context: TraktLibraryMutationContext? = nil) {
        self.meta = meta
        self.isInWatchlist = isInWatchlist
        self.context = context
    }
}

private struct TraktWatchlistMutationResponse: Decodable {
    let added: TraktWatchlistMutationCount?
    let existing: TraktWatchlistMutationCount?
    let deleted: TraktWatchlistMutationCount?

    func applied(isInWatchlist: Bool) -> Bool {
        if isInWatchlist {
            return (added?.total ?? 0) + (existing?.total ?? 0) > 0
        }
        return (deleted?.total ?? 0) > 0
    }
}

private struct TraktWatchlistMutationCount: Decodable {
    let movies: Int?
    let shows: Int?

    var total: Int { (movies ?? 0) + (shows ?? 0) }
}

private struct TraktPersonalListDTO: Decodable {
    let type: String?
    let ids: TraktPersonalListIDsDTO?
}

private struct TraktPersonalListIDsDTO: Decodable {
    let trakt: Int?
    let slug: String?
}

private struct EmptyResponse: Decodable {}

private struct HTTPResult<T: Decodable> {
    let statusCode: Int
    let value: T?
    let errorMessage: String?
    let headers: [String: String]

    func valueOrThrow() throws -> T {
        guard (200..<300).contains(statusCode) else {
            throw TraktServiceError.message(errorMessage ?? "Trakt request failed (\(statusCode)).")
        }
        guard let value else {
            throw TraktServiceError.message(errorMessage ?? "Trakt returned an empty response.")
        }
        return value
    }
}

private enum TraktServiceError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self {
        case .message(let message): return message
        }
    }
}

@MainActor
final class TraktSettingsViewModel: ObservableObject {
    @Published var mode: TraktConnectionMode = .disconnected
    @Published var credentialsConfigured = false
    @Published var isLoading = false
    @Published var isStatsLoading = false
    @Published var isPolling = false
    @Published var username: String?
    @Published var deviceUserCode: String?
    @Published var verificationURL: String?
    @Published var deviceCodeExpiresAtMillis: Double?
    @Published var tokenExpiresAtMillis: Double?
    @Published var pollInterval = 5
    @Published var statusMessage: String?
    @Published var errorMessage: String?
    @Published var connectedStats: TraktCachedStats?
    @Published var continueWatchingDaysCap = TraktSettingsStore.continueWatchingDaysCap
    @Published var showMetaComments = TraktSettingsStore.showMetaComments
    @Published var watchProgressSource = TraktSettingsStore.watchProgressSource
    @Published var librarySourceMode = TraktSettingsStore.librarySourceMode
    @Published var moreLikeThisSource = TraktSettingsStore.moreLikeThisSource

    private let store: UserDefaults
    private let service: TraktAuthService
    private var pollTask: Task<Void, Never>?
    private(set) var connectionTask: Task<Void, Never>?
    private var connectionGeneration = 0

    init(store: UserDefaults = ProfileSettings.current, session: URLSession = .shared) {
        self.store = store
        self.service = TraktAuthService(session: session, store: store)
        reload()
    }

    deinit {
        connectionTask?.cancel()
        pollTask?.cancel()
    }

    func reload() {
        credentialsConfigured = service.hasRequiredCredentials()
        let state = service.currentState()
        username = state.username
        deviceUserCode = state.userCode
        verificationURL = state.verificationURL
        deviceCodeExpiresAtMillis = state.expiresAt
        tokenExpiresAtMillis = state.tokenExpiresAtMillis
        pollInterval = state.pollInterval ?? 5
        let isAuthenticated = TraktAuthStore.isAuthenticated(in: store)
        mode = isAuthenticated
            ? .connected
            : (state.hasActiveDeviceFlow(in: store) ? .awaitingApproval : .disconnected)
        connectedStats = isAuthenticated ? TraktAuthStore.cachedStats(in: store) : nil
        continueWatchingDaysCap = TraktSettingsStore.continueWatchingDaysCap
        showMetaComments = TraktSettingsStore.showMetaComments
        watchProgressSource = TraktSettingsStore.watchProgressSource
        librarySourceMode = TraktSettingsStore.librarySourceMode
        moreLikeThisSource = TraktSettingsStore.moreLikeThisSource
        if mode == .awaitingApproval {
            startPolling()
        } else {
            pollTask?.cancel()
            isPolling = false
        }
    }

    func credentialsDidChange() {
        invalidatePendingConnection()
        errorMessage = nil
        statusMessage = nil
        reload()
    }

    private func invalidatePendingConnection() {
        connectionGeneration &+= 1
        connectionTask?.cancel()
        connectionTask = nil
        isLoading = false
    }

    func connect() {
        guard !isLoading, ProfileSettings.isActiveStore(store) else { return }
        guard credentialsConfigured else {
            errorMessage = "Enter your Trakt Client ID first."
            return
        }
        invalidatePendingConnection()
        let generation = connectionGeneration
        isLoading = true
        statusMessage = nil
        errorMessage = nil
        connectionTask = Task { [weak self, service, store] in
            defer {
                if let self, generation == self.connectionGeneration {
                    self.connectionTask = nil
                    self.isLoading = false
                }
            }
            do {
                let response = try await service.startDeviceAuth()
                guard let self, !Task.isCancelled,
                      generation == self.connectionGeneration,
                      ProfileSettings.isActiveStore(store),
                      TraktAuthStore.state(in: store).deviceCode == response.deviceCode else { return }
                self.deviceUserCode = response.userCode
                self.verificationURL = response.verificationURL
                self.deviceCodeExpiresAtMillis = Date().timeIntervalSince1970 * 1000.0 + Double(response.expiresIn * 1000)
                self.pollInterval = response.interval
                self.mode = .awaitingApproval
                self.statusMessage = "Waiting for approval…"
                self.isLoading = false
                self.connectionTask = nil
                self.startPolling()
            } catch {
                guard let self, generation == self.connectionGeneration else { return }
                self.connectionTask = nil
                self.isLoading = false
                guard !Task.isCancelled, !(error is CancellationError),
                      ProfileSettings.isActiveStore(store) else { return }
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func cancelDeviceFlow() {
        invalidatePendingConnection()
        pollTask?.cancel()
        TraktAuthStore.clearDeviceFlow(store: store)
        statusMessage = nil
        errorMessage = nil
        reload()
    }

    func retryPolling() {
        errorMessage = nil
        startPolling()
    }

    func disconnect() {
        invalidatePendingConnection()
        pollTask?.cancel()
        TraktAuthStore.clearDeviceFlow(store: store)
        isLoading = true
        let profileId = WatchedStore.activeProfileId
        Task {
            await service.revokeAndLogout()
            WatchedStore.clearPendingTraktMutations(profileId: profileId)
            isLoading = false
            statusMessage = "Disconnected from Trakt."
            connectedStats = nil
            reload()
        }
    }

    func refreshNow() {
        guard mode == .connected else { return }
        isLoading = true
        isStatsLoading = true
        statusMessage = "Syncing Trakt..."
        errorMessage = nil
        Task {
            _ = await service.refreshTokenIfNeeded()
            let historySynced = await TraktHistoryService.syncWatchedHistory(store: store)
            // Match Android TV's Sync Now sequence: refresh the Trakt progress
            // repository before updating account details and cached stats. Home
            // owns the tvOS progress snapshot, so its change notification is the
            // equivalent refresh signal here.
            NotificationCenter.default.post(
                name: TraktSettingsStore.continueWatchingChangedNotification,
                object: nil
            )
            TraktSettingsStore.notifyContinueWatchingSourceInvalidated(for: .trakt, in: store)
            _ = await service.fetchUserSettings()
            if let stats = await service.fetchUserStats() {
                TraktAuthStore.saveCachedStats(stats, store: store)
                connectedStats = stats
            }
            isStatsLoading = false
            isLoading = false
            statusMessage = historySynced
                ? "Trakt sync completed."
                : "Trakt account refreshed, but watched history could not be imported."
            reload()
        }
    }

    func loadConnectedData() {
        guard mode == .connected, !isLoading, !isStatsLoading else { return }
        isStatsLoading = true
        Task {
            guard await service.refreshTokenIfNeeded() else {
                isStatsLoading = false
                reload()
                return
            }
            if username?.isEmpty != false {
                _ = await service.fetchUserSettings()
            }
            if let stats = await service.fetchUserStats() {
                TraktAuthStore.saveCachedStats(stats, store: store)
                connectedStats = stats
            }
            isStatsLoading = false
            reload()
        }
    }

    func setLibrarySourceMode(_ source: TraktLibrarySourceMode) {
        librarySourceMode = source
        TraktSettingsStore.librarySourceMode = librarySourceMode
    }

    func setWatchProgressSource(_ source: TraktWatchProgressSource) {
        // A hand-picked source outranks the connect-time selection from then on.
        TraktSettingsStore.markWatchProgressSourceChosenByUser(in: store)
        watchProgressSource = source
        TraktSettingsStore.watchProgressSource = watchProgressSource
    }

    func setContinueWatchingDaysCap(_ days: Int) {
        continueWatchingDaysCap = days
        TraktSettingsStore.continueWatchingDaysCap = continueWatchingDaysCap
    }

    func setShowMetaComments(_ show: Bool) {
        showMetaComments = show
        TraktSettingsStore.showMetaComments = showMetaComments
    }

    func setMoreLikeThisSource(_ source: TraktMoreLikeThisSource) {
        moreLikeThisSource = source
        TraktSettingsStore.moreLikeThisSource = moreLikeThisSource
    }

    private func startPolling() {
        pollTask?.cancel()
        isPolling = true
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let state = self.service.currentState()
                if let expiresAt = state.expiresAt,
                   Date().timeIntervalSince1970 * 1000.0 >= expiresAt {
                    self.errorMessage = "Trakt device code expired. Start again."
                    TraktAuthStore.clearDeviceFlow(store: self.store)
                    self.isPolling = false
                    self.reload()
                    return
                }

                let wait = UInt64(max(state.pollInterval ?? self.pollInterval, 5))
                try? await Task.sleep(nanoseconds: wait * 1_000_000_000)
                if Task.isCancelled { return }

                let result = await self.service.pollDeviceToken()
                guard !Task.isCancelled, ProfileSettings.isActiveStore(self.store) else { return }
                switch result {
                case .pending:
                    self.statusMessage = "Waiting for Trakt approval..."
                case .alreadyUsed:
                    self.errorMessage = "This Trakt code was already used. Start again."
                    self.isPolling = false
                    self.reload()
                    return
                case .expired:
                    self.errorMessage = "Trakt device code expired. Start again."
                    self.isPolling = false
                    self.reload()
                    return
                case .denied:
                    self.errorMessage = "Trakt authorization was denied."
                    self.isPolling = false
                    self.reload()
                    return
                case .slowDown(let interval):
                    self.pollInterval = interval
                    self.statusMessage = "Trakt rate-limited polling. Slowing down..."
                case .approved(let username):
                    self.username = username
                    self.statusMessage = "Connected to Trakt."
                    self.isPolling = false
                    self.reload()
                    self.loadConnectedData()
                    return
                case .failed(let reason):
                    self.errorMessage = reason
                }
            }
        }
    }
}
