import Foundation

/// Account ownership captured when a Details write is enqueued, before any wait.
/// OAuth bindings survive refresh but never a new grant. API keys have no refresh
/// grant: their exact credential and continued API-key-only mode identify ownership.
@MainActor
struct SelectedLibraryMutationContext {
    private let store: UserDefaults
    private let profileID: String?
    private let settingsProfileID: String?
    private let source: TraktLibrarySourceMode
    private let accountIsCurrent: @MainActor () -> Bool
    /// The service's profile scope captured with the account (Simkl, WeTrakr, MDBList).
    private var serviceProfileScope: String?
    private var traktContext: TraktLibraryMutationContext?

    /// Where a write for this owner goes: its settings store, service, scope and
    /// account, as captured, never whichever profile is active when it runs.
    var target: LibraryWriteTarget {
        LibraryWriteTarget(source: source, store: store, profileScope: serviceProfileScope, trakt: traktContext)
    }

    init?(
        simklTokens: SimklTokenStorage = SimklKeychainTokenStorage(),
        weTrakrTokens: WeTrakrTokenStorage = WeTrakrKeychainTokenStorage(),
        mdbListTokens: MdbListTokenStorage = MdbListKeychainTokenStorage()
    ) {
        let store = ProfileSettings.current
        self.store = store
        profileID = LibraryStore.activeProfileId
        settingsProfileID = ProfileSettings.activeProfileID
        source = TraktSettingsStore.librarySourceMode
        switch source {
        case .local:
            return nil
        case .trakt:
            guard let context = TraktLibraryMutationContext() else { return nil }
            traktContext = context
            accountIsCurrent = { context.isCurrent }
        case .simkl:
            let scope = SimklRuntimeSession.profileScope()
            serviceProfileScope = scope
            guard let state = SimklRuntimeSession.authenticatedState(
                store: store, tokenStorage: simklTokens, profileScope: scope
            ) else { return nil }
            let binding = SimklAuthStore.accountBindingID(in: store)
            let clientID = SimklConfig.clientID(in: store)
            let isV2 = state.isV2
            accountIsCurrent = {
                SimklConfig.clientID(in: store) == clientID
                    && (SimklRuntimeSession.authenticatedState(
                        store: store, tokenStorage: simklTokens, profileScope: scope
                    )?.isV2 == isV2)
                    && SimklAuthStore.accountBindingID(in: store) == binding
            }
        case .wetrakr:
            let scope = WeTrakrRuntimeSession.profileScope()
            serviceProfileScope = scope
            guard WeTrakrRuntimeSession.isAuthenticated(
                in: store, tokenStorage: weTrakrTokens, profileScope: scope
            ) else { return nil }
            let binding = WeTrakrAuthStore.accountBindingID(in: store)
            let clientID = WeTrakrConfig.clientID(in: store)
            accountIsCurrent = {
                WeTrakrConfig.clientID(in: store) == clientID
                    && WeTrakrRuntimeSession.isAuthenticated(
                        in: store, tokenStorage: weTrakrTokens, profileScope: scope
                    )
                    && WeTrakrAuthStore.accountBindingID(in: store) == binding
            }
        case .mdblist:
            let scope = MdbListRuntimeSession.profileScope()
            serviceProfileScope = scope
            if mdbListTokens.tokens(for: scope) != nil {
                let binding = MdbListAuthStore.accountBindingID(in: store)
                accountIsCurrent = {
                    mdbListTokens.tokens(for: scope) != nil
                        && MdbListAuthStore.accountBindingID(in: store) == binding
                }
            } else {
                let key = store.string(forKey: SettingsKey.mdbListApiKey)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !key.isEmpty else { return nil }
                accountIsCurrent = {
                    mdbListTokens.tokens(for: scope) == nil
                        && store.string(forKey: SettingsKey.mdbListApiKey)?
                            .trimmingCharacters(in: .whitespacesAndNewlines) == key
                }
            }
        }
    }

    var isCurrent: Bool {
        ProfileSettings.isActiveStore(store)
            && ProfileSettings.activeProfileID == settingsProfileID
            && LibraryStore.activeProfileId == profileID
            && TraktSettingsStore.librarySourceMode == source
            && accountIsCurrent()
    }
}

/// The captured destination of a library write.
struct LibraryWriteTarget {
    let source: TraktLibrarySourceMode
    let store: UserDefaults
    let profileScope: String?
    let trakt: TraktLibraryMutationContext?
}

