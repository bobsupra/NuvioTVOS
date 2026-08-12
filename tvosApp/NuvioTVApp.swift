//
//  NuvioTVApp.swift
//  NuvioTV
//
//  Main SwiftUI app entry point with Master view coordinator
//

import SwiftUI
import Foundation
import UIKit

@main
struct NuvioTVApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

enum TVScreen {
    case login
    case profileSelection
    case main
    case details(id: String, type: String)
    case player(url: URL, meta: NuvioMeta, subtitle: String, httpHeaders: [String: String], externalSubtitles: [NuvioSubtitle], resumeFrom: Double?)
    case cloudLibrary
    /// Browse titles inside one collection folder (catalogs grouped under it).
    case collectionFolder(TVCollectionFolderItem, collectionTitle: String)
    /// All titles from a production company or network.
    case productionBrowse(MetaCompany)
    /// Movies and series associated with a TMDB person.
    case personBrowse(TmdbPersonMetadata)
}

private enum PlaybackOrigin {
    case main
    case details
    case cloudLibrary
}

private enum DetailsReturnDestination {
    case main
    case collectionFolder(TVCollectionFolderItem, collectionTitle: String)
}

enum TVTab: String, CaseIterable, Identifiable {
    case profile = "Profile"
    case home = "Home"
    case search = "Search"
    case library = "Library"
    case settings = "Settings"

    var id: String { rawValue }

    /// Localized tab label (rawValue remains stable for selection identity).
    var title: String {
        switch self {
        case .profile:
            return L10n.string("settings_profiles", fallback: "Profile")
        case .home:
            return L10n.string("nav_home", fallback: "Home")
        case .search:
            return L10n.string("nav_search", fallback: "Search")
        case .library:
            return L10n.string("nav_library", fallback: "Library")
        case .settings:
            return L10n.string("nav_settings", fallback: "Settings")
        }
    }

    var symbol: String {
        switch self {
        case .profile: return "person.crop.circle"
        case .home: return "house"
        case .search: return "magnifyingglass"
        case .library: return "rectangle.stack"
        case .settings: return "gearshape"
        }
    }
}

/// Main content view - entry point for the app with screen routing
struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var activeScreen: TVScreen = .login
    @State private var resolvedInitialScreen = false
    /// `nil` until tvOS has actually backgrounded the app, so the initial
    /// `.active` callback is never treated as a resume.
    @State private var backgroundedAt: Date?
    private static let profileSelectionBackgroundGracePeriod: TimeInterval = 10 * 60
    // Holds the who's-watching screen back until the post-sign-in profile pull
    // lands, so freshly imported profile names show instead of local stubs.
    @State private var awaitingPostLoginSync = false
    @State private var enterMainAfterPostLoginSync = false
    /// Covers the switch to a freshly picked profile until its Home is built.
    ///
    /// Home re-points every profile-scoped store, reloads its catalogs and
    /// rebuilds Continue Watching when the profile changes. Rendering through
    /// that shows rows arriving one by one under a moving focus; the Android
    /// client instead holds a full-screen loader and reveals a finished Home,
    /// which is both calmer and easier to reason about.
    @State private var isPreparingProfile = false
    @State private var profileGateTask: Task<Void, Never>?
    @State private var profileGateStartedAt: Date?
    /// Every switch shows the cover for at least this long, even when the new
    /// profile's rows are already cached and come back instantly. A cover that
    /// appears only sometimes reads as a stutter; a switch that always takes the
    /// same short beat reads as the app doing something deliberate — which is
    /// how the Android client behaves, and why its switches feel settled.
    private static let profileGateMinimumDuration: TimeInterval = 1.8
    /// Ceiling on the profile-switch cover, whatever Home ends up publishing.
    private static let profileGateTimeout: TimeInterval = 5
    @State private var selectedTab: TVTab = .home
    /// Series context for the current playback, captured at play time so the
    /// player can offer/auto-play the next episode. Empty for movies/trailers.
    @State private var playbackEpisodes: [NuvioVideo] = []
    @State private var playbackCurrentEpisode: NuvioVideo?
    @State private var playbackOrigin: PlaybackOrigin = .main
    @State private var playbackDidStart = false
    @State private var reopenStreamPickerOnDetails = false
    @State private var reopenStreamPickerEpisode: NuvioVideo?
    /// Title whose liquid-glass quick-actions menu is showing (long-press on a
    /// card). Presented as an overlay over the tab view, like Details/Player.
    @State private var cardMenuMeta: NuvioMeta?
    /// Where Details opened from the quick-actions menu should return. Collection
    /// cards keep their browser in the navigation chain instead of falling Home.
    @State private var cardMenuReturnDestination: DetailsReturnDestination = .main
    /// Continue Watching entry whose quick-actions menu is showing. Held apart
    /// from `cardMenuMeta` because a resume card offers resume actions (play
    /// manually / restart / remove) rather than the generic title actions.
    @State private var continueWatchingMenuItem: ContinueWatchingItem?
    /// URL-less Continue Watching entries (for example synced progress or Next
    /// Up) resolve their stream in place instead of opening Details first.
    @State private var isResolvingContinueWatchingStream = false
    @State private var continueWatchingPlaybackTask: Task<Void, Never>?
    @State private var pendingDeepLinkURL: URL?
    /// Details title to restore when leaving a production company browse.
    @State private var productionBrowseReturn: (id: String, type: String)?
    /// Details title to restore when leaving a person browse.
    @State private var personBrowseReturn: (id: String, type: String)?
    /// Titles to walk back through when Details opened Details ("More like
    /// this"). Empty means the current Details is the root of its chain and back
    /// belongs to its recorded return destination.
    @State private var detailsBackStack: [(id: String, type: String)] = []
    /// Where the root Details screen should return. This is normally Home, but
    /// a title opened from a collection must return to that collection.
    @State private var detailsReturnDestination: DetailsReturnDestination = .main
    @StateObject private var authManager = AuthManager()
    @StateObject private var profileViewModel = ProfileViewModel()
    @StateObject private var syncManager = NuvioSyncManager()
    // Both search screens are backed by their own view model. Only the one
    // picked by `SettingsKey.searchStyle` is rendered, but both are held here
    // so switching styles doesn't tear down and refetch the other's state.
    // They share the same recent-search storage key.
    @StateObject private var searchViewModel = SearchViewModel()
    @StateObject private var netflixSearchViewModel = NetflixSearchViewModel()
    @StateObject private var libraryViewModel = LibraryViewModel()
    // Owned here (not inside TVHomeView) so the Home catalog + focused card
    // survive the details/player push, which tears TVHomeView down. Returning
    // then restores the exact card instead of reloading and jumping to the top.
    @StateObject private var homeStore = TVHomeStore()

    var body: some View {
        ZStack {
            ProfileScopedRootBackground()

            switch activeScreen {
            case .login:
                // `.login` is also the value this state starts at, before
                // `onAppear` has read the restored session — so it must not put
                // the login screen on screen yet. `LoginView` auto-continues the
                // moment it appears for an already-authenticated user, and that
                // continuation is the *post-login* path: it re-ran the account
                // bootstrap and raised the "Syncing your account" gate on every
                // single relaunch, not just on a real sign-in.
                if resolvedInitialScreen {
                    LoginView(auth: authManager) {
                        // Successful authentication owns the initial account pull.
                        // Profile selection remains a later, deliberate switch and
                        // is no longer needed to kick-start a missed bootstrap.
                        if authManager.isAuthenticated {
                            syncManager.beginPostLoginSync()
                        }
                        withAnimation(.easeInOut(duration: 0.28)) {
                            awaitingPostLoginSync = syncManager.isPullingAccountProfiles
                            activeScreen = .profileSelection
                        }
                    }
                    .transition(.opacity)
                } else {
                    // One frame at most: `onAppear` resolves the real screen
                    // immediately, and the root background is already drawn
                    // behind this.
                    Color.clear
                }

            case .profileSelection:
                if awaitingPostLoginSync && syncManager.isPullingAccountProfiles {
                    AccountSyncWaitView()
                        .transition(.opacity)
                } else {
                    UserProfileView(
                        viewModel: profileViewModel,
                        accountSyncError: syncManager.profileSyncError,
                        onRetryAccountSync: {
                            syncManager.retryInitialAccountPull()
                            awaitingPostLoginSync = syncManager.isPullingAccountProfiles
                        },
                        onProfileCreated: {
                            syncManager.syncProfilesAfterLocalEdit()
                        }
                    )
                        .transition(.opacity)
                        .onAppear {
                            // A failed owned bootstrap is recovered only through
                            // Retry, which re-arms the blocking gate. Do not start
                            // an ungated background pull behind the Guest card.
                            if syncManager.profileSyncError == nil {
                                syncManager.refreshProfilesForSelectionIfNeeded()
                            }
                        }
                        // Navigate only on an explicit pick. Listening to
                        // $activeProfile here would auto-enter a profile the
                        // moment the sync refreshes it mid-selection.
                        .onReceive(profileViewModel.profileChosen) { _ in
                            beginProfileGate()
                            withAnimation(.easeInOut(duration: 0.28)) {
                                activeScreen = .main
                            }
                            resumePendingDeepLinkIfPossible()
                        }
                }

            case .main, .details, .player, .cloudLibrary, .collectionFolder, .productionBrowse, .personBrowse:
                // The tab view (Home included) stays mounted for the whole
                // session; Details and Player are presented as overlays on TOP
                // of it rather than replacing it. Returning therefore leaves
                // Home exactly as the user left it -- same scroll, same focused
                // card (tvOS focus memory) -- instead of rebuilding it from
                // scratch and snapping back to the first card.
                appContainer
                    .transition(.opacity)
            }
        }
        // Resolve every @AppStorage in the app against the active profile's
        // settings suite, so each profile keeps its own theme, layout, playback
        // preferences, etc. Falls back to the shared store before a profile is picked.
        .defaultAppStorage(ProfileSettings.store(for: profileViewModel.activeProfile?.id))
        // Apply selected app language (locale + L10n catalog) and refresh UI on change.
        .appliesAppLocale()
        .onChange(of: profileViewModel.activeProfile?.id) { _ in
            AppLocaleManager.shared.reloadFromProfileStore()
        }
        // Keep the profile cover up until the progressive catalog stream has
        // finished. Revealing Home when its first row arrived let the user page
        // that row while later catalog updates were still replacing it; if a
        // focused, paged-in card disappeared during the replacement, tvOS moved
        // focus to the row above. `hasLoaded` flips only after the final tree is
        // published, so the first interactive frame is stable.
        .onChange(of: homeStore.hasLoaded) { loaded in
            guard isPreparingProfile, loaded else { return }
            profileGateContentReady()
        }
        // Backing out of the switch must not leave the cover behind.
        .onChange(of: isOnProfileSelection) { isSelecting in
            if isSelecting, isPreparingProfile {
                liftProfileGate()
            }
        }
        .background(Color.black.ignoresSafeArea())
        // Safety net for the Menu button while an overlay is up. During the
        // overlay's insert animation focus is briefly in limbo (the tab view is
        // disabled, the overlay hasn't taken focus yet); a Menu press then finds
        // no `.onExitCommand` handler and tvOS quits the app. This root handler
        // catches those stray presses and dismisses the overlay instead. When
        // focus is settled inside Details/Player their own handler fires first,
        // so this only kicks in for the in-between frames. No handler is attached
        // on Home, so Menu there keeps its normal tab-level behaviour.
        .onExitCommand(perform: isOverlayPresented ? dismissOverlay : nil)
        .onOpenURL(perform: handleDeepLink)
        .onAppear {
            syncManager.attach(authManager: authManager, profileViewModel: profileViewModel)
            guard !resolvedInitialScreen else { return }
            resolvedInitialScreen = true
            // Skip the login gate if a session was restored or the user has
            // previously chosen to continue without an account.
            if !authManager.shouldShowLoginGate {
                // Auto-select-last-profile (Settings → Profile) skips the
                // who's-watching stop on launch; navigation is otherwise
                // driven only by an explicit pick via `profileChosen`.
                let autoSelectLast = ProfileSettings.current.object(
                    forKey: SettingsKey.profileAutoSelectLast
                ) as? Bool ?? true
                // Signed in with the startup pull still running, so real
                // profiles are expected to land shortly and the local
                // placeholder must not be mistaken for the account.
                let awaitingRealProfiles = authManager.isAuthenticated
                    && AuthConfig.isConfigured
                    && syncManager.isPullingAccountProfiles
                if awaitingRealProfiles, hasOnlyLocalGuestPlaceholder {
                    // Nothing real to show or enter yet — a restored Keychain
                    // session can outlive missing/corrupt local profile data.
                    // Gate that startup pull exactly like a fresh login instead
                    // of auto-entering the local Guest.
                    awaitingPostLoginSync = true
                    enterMainAfterPostLoginSync = autoSelectLast
                    activeScreen = .profileSelection
                } else if autoSelectLast,
                          let activeProfile = profileViewModel.activeProfile,
                          !activeProfile.isPinProtected,
                          !(awaitingRealProfiles && isGuestPlaceholder(activeProfile)) {
                    activeScreen = .main
                    resumePendingDeepLinkIfPossible()
                } else {
                    // Profiles are already on disk, so the picker can be shown
                    // right away and refreshes itself when the pull lands. This
                    // is the ordinary cold launch: waiting behind the sync
                    // screen every time taught nothing the picker didn't
                    // already know.
                    activeScreen = .profileSelection
                }
            }
        }
        .onReceive(authManager.$authState) { state in
            syncManager.authStateChanged(state)
            if state == .signedOut, profileViewModel.activeProfile?.id != "guest" {
                profileViewModel.resetForSignedOut()
            }
        }
        .onReceive(syncManager.$isPullingAccountProfiles) { pulling in
            if !pulling, awaitingPostLoginSync {
                let shouldEnterMain = enterMainAfterPostLoginSync
                    && authManager.isAuthenticated
                    && syncManager.profileSyncError == nil
                    && profileViewModel.activeProfile?.id != "guest"
                    && profileViewModel.activeProfile?.isPinProtected != true
                withAnimation(.easeInOut(duration: 0.28)) {
                    awaitingPostLoginSync = false
                    enterMainAfterPostLoginSync = false
                    if shouldEnterMain {
                        activeScreen = .main
                        resumePendingDeepLinkIfPossible()
                    }
                }
            }
        }
        .onReceive(profileViewModel.$activeProfile) { profile in
            syncManager.activeProfileChanged(profile)
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .background:
                backgroundedAt = Date()
            case .active:
                syncManager.refreshAccountIfIdle()
                presentProfileSelectionAfterBackgroundIfNeeded()
            default:
                break
            }
        }
    }

    /// Mirrors the cold-start profile decision when returning to the foreground.
    /// Normally, the who's-watching screen appears after a ten-minute background
    /// grace period. When remembering the last profile is disabled, the profile
    /// setting can instead require a choice on every return.
    private func presentProfileSelectionAfterBackgroundIfNeeded() {
        guard let backgroundedAt else { return }
        self.backgroundedAt = nil
        guard resolvedInitialScreen, !isOnProfileSelection else { return }
        if case .login = activeScreen { return }

        let autoSelectLast = ProfileSettings.current.object(
            forKey: SettingsKey.profileAutoSelectLast
        ) as? Bool ?? true
        let requireSelectionOnEveryReturn = ProfileSettings.current.object(
            forKey: SettingsKey.profileRequireSelectionAfterBackground
        ) as? Bool ?? false
        let hasExceededGracePeriod = Date().timeIntervalSince(backgroundedAt)
            >= Self.profileSelectionBackgroundGracePeriod
        let shouldRequireSelection = hasExceededGracePeriod
            || (!autoSelectLast && requireSelectionOnEveryReturn)
        guard shouldRequireSelection else { return }
        guard !(autoSelectLast && profileViewModel.activeProfile?.isPinProtected == false) else {
            return
        }

        continueWatchingPlaybackTask?.cancel()
        continueWatchingPlaybackTask = nil
        isResolvingContinueWatchingStream = false
        cardMenuMeta = nil
        continueWatchingMenuItem = nil
        withAnimation(.easeInOut(duration: 0.28)) {
            activeScreen = .profileSelection
        }
    }

    /// Whether Details, Player, or the card quick-actions menu is currently
    /// covering the tab view (drives `.disabled` and the Menu-button safety net).
    /// True when the profile list on disk holds nothing but the fresh-install
    /// placeholder, so there is no real profile to show or enter.
    ///
    /// This deliberately asks about the *list*, not about `activeProfile`. Having
    /// no active profile is the ordinary state on a cold launch — nothing has
    /// been picked yet — and blocking the who's-watching screen behind the
    /// account-sync gate for it made every relaunch wait on a pull whose result
    /// the picker was already showing from disk.
    private var hasOnlyLocalGuestPlaceholder: Bool {
        profileViewModel.profiles.allSatisfy(isGuestPlaceholder)
    }

    /// The placeholder profile a fresh install seeds, which account sync
    /// replaces with the real primary profile.
    private func isGuestPlaceholder(_ profile: Profile) -> Bool {
        if profile.id == "guest" { return true }
        let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return profile.id == "1" && !profile.isAdmin && profile.avatarId.isEmpty
            && name == "nuvio guest"
    }

    private var isOverlayPresented: Bool {
        if isResolvingContinueWatchingStream { return true }
        if cardMenuMeta != nil || continueWatchingMenuItem != nil { return true }
        return fullScreenOverlayPresented
    }

    /// Details/Player fully replace Home, so the tab view fades to black under
    /// them. The card quick-actions menu is deliberately excluded — it keeps Home
    /// visible behind its glass panel.
    private var fullScreenOverlayPresented: Bool {
        if isResolvingContinueWatchingStream { return true }
        switch activeScreen {
        case .details, .player, .cloudLibrary, .collectionFolder, .productionBrowse, .personBrowse: return true
        default: return false
        }
    }

    /// Keep a collection browser mounted beneath the Details chain it opened.
    /// Its loaded rows, horizontal positions, focus memory, and watched badges
    /// then survive the round trip instead of being rebuilt on every Back press.
    private var presentedCollectionFolder: (
        folder: TVCollectionFolderItem,
        collectionTitle: String
    )? {
        if case let .collectionFolder(folder, collectionTitle) = activeScreen {
            return (folder, collectionTitle)
        }

        switch activeScreen {
        case .details, .player, .productionBrowse, .personBrowse:
            if case let .collectionFolder(folder, collectionTitle) = detailsReturnDestination {
                return (folder, collectionTitle)
            }
        default:
            break
        }
        return nil
    }

    private var isCollectionFolderActive: Bool {
        if case .collectionFolder = activeScreen { return true }
        return false
    }

    /// Dismisses the current overlay to the same destination its own back action
    /// would (Player returns to Details for series/trailers, otherwise Home).
    /// Used only by the root Menu-button safety net; changing `activeScreen`
    /// tears the overlay down, so Player's `onDisappear` cleanup still runs.
    private func dismissOverlay() {
        if isResolvingContinueWatchingStream {
            continueWatchingPlaybackTask?.cancel()
            continueWatchingPlaybackTask = nil
            isResolvingContinueWatchingStream = false
            return
        }
        if cardMenuMeta != nil {
            withAnimation(.easeInOut(duration: 0.2)) { cardMenuMeta = nil }
            cardMenuReturnDestination = .main
            return
        }
        if continueWatchingMenuItem != nil {
            withAnimation(.easeInOut(duration: 0.2)) { continueWatchingMenuItem = nil }
            return
        }
        switch activeScreen {
        case .details:
            leaveDetails()
        case let .player(_, meta, subtitle, _, _, _):
            dismissPlayer(meta: meta, subtitle: subtitle)
        case .cloudLibrary, .collectionFolder:
            withAnimation(.easeInOut(duration: 0.24)) {
                activeScreen = .main
            }
        case .productionBrowse:
            withAnimation(.easeInOut(duration: 0.24)) {
                if let ret = productionBrowseReturn {
                    activeScreen = .details(id: ret.id, type: ret.type)
                } else {
                    activeScreen = .main
                }
                productionBrowseReturn = nil
            }
        case .personBrowse:
            withAnimation(.easeInOut(duration: 0.24)) {
                if let ret = personBrowseReturn {
                    activeScreen = .details(id: ret.id, type: ret.type)
                } else {
                    activeScreen = .main
                }
                personBrowseReturn = nil
            }
        default:
            break
        }
    }

    /// Backs out of Details to the title it was opened from (a "More like this"
    /// chain), or to the screen that opened the root Details.
    private func leaveDetails() {
        withAnimation(.easeInOut(duration: 0.24)) {
            if let previous = detailsBackStack.popLast() {
                activeScreen = .details(id: previous.id, type: previous.type)
            } else {
                switch detailsReturnDestination {
                case .main:
                    activeScreen = .main
                case let .collectionFolder(folder, collectionTitle):
                    activeScreen = .collectionFolder(folder, collectionTitle: collectionTitle)
                }
                detailsReturnDestination = .main
            }
        }
    }

    /// Opens Details as a fresh navigation (Home, search, a card menu, a deep
    /// link). Any "More like this" chain belongs to the flow being left, so the
    /// back stack starts empty and back from here returns to Home.
    private func openDetailsRoot(
        id: String,
        type: String,
        returnDestination: DetailsReturnDestination = .main
    ) {
        detailsBackStack.removeAll()
        detailsReturnDestination = returnDestination
        activeScreen = .details(id: id, type: type)
    }

    /// Handles Top Shelf, `nuvio://` / `nuvio-tv://` title open, and
    /// `stremio://` add-on install deep links. Deferred while login/profile gate
    /// is up so Top Shelf cold-launch still works.
    private func handleDeepLink(_ url: URL) {
        let scheme = (url.scheme ?? "").lowercased()

        // stremio://host/path/manifest.json → install add-on
        if scheme == "stremio" {
            handleStremioInstallDeepLink(url)
            return
        }

        // nuvio://meta?type=&id=  |  nuvio-tv://details?…  |  nuvio-tv://continue-watching?…
        // Also accepts com.nuvio.app.tv and path-style /meta/… /details/…
        guard ["nuvio", "nuvio-tv", "com.nuvio.app.tv"].contains(scheme) else { return }

        switch activeScreen {
        case .login, .profileSelection:
            pendingDeepLinkURL = url
            return
        default:
            break
        }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let host = (url.host ?? "").lowercased()
        let pathParts = url.path.split(separator: "/").map(String.init)

        // Install: nuvio://addon?url=… or nuvio://install?manifest=…
        if host == "addon" || host == "install" || pathParts.first == "addon" {
            let manifest = components?.queryItems?.first(where: {
                $0.name == "url" || $0.name == "manifest"
            })?.value
            if let manifest, CommunityAddonCatalog.install(manifestURL: manifest) {
                withAnimation(.easeInOut(duration: 0.28)) {
                    selectedTab = .settings
                }
            }
            return
        }

        let id = components?.queryItems?.first(where: { $0.name == "id" })?.value
            ?? pathParts.dropFirst().first
        guard let id, !id.isEmpty else { return }
        let type = components?.queryItems?.first(where: { $0.name == "type" })?.value
            ?? (pathParts.count >= 3 ? pathParts[1] : nil)
            ?? "movie"

        if host == "continue-watching" || pathParts.first == "continue-watching",
           let item = ContinueWatchingStore.item(for: id) {
            resumePlayback(item)
            return
        }

        withAnimation(.easeInOut(duration: 0.28)) {
            openDetailsRoot(id: id, type: type)
        }
    }

    /// `stremio://…/manifest.json` installs the add-on (same as pasting the URL).
    private func handleStremioInstallDeepLink(_ url: URL) {
        switch activeScreen {
        case .login, .profileSelection:
            pendingDeepLinkURL = url
            return
        default:
            break
        }
        let raw = url.absoluteString
        let ok = CommunityAddonCatalog.install(manifestURL: raw)
        if ok {
            withAnimation(.easeInOut(duration: 0.28)) {
                selectedTab = .settings
            }
        }
    }

    /// A Top Shelf action can launch the app before authentication/profile
    /// routing has finished. Preserve it through that gate, then consume it on
    /// the next main-actor turn after the active profile has been installed.
    private func resumePendingDeepLinkIfPossible() {
        guard pendingDeepLinkURL != nil else { return }
        Task { @MainActor in
            await Task.yield()
            guard let url = pendingDeepLinkURL else { return }
            pendingDeepLinkURL = nil
            handleDeepLink(url)
        }
    }

    private var isOnProfileSelection: Bool {
        if case .profileSelection = activeScreen { return true }
        return false
    }

    /// Covers Home while the picked profile's stores are re-pointed and its rows
    /// rebuilt, so the user waits once instead of watching Home assemble itself.
    ///
    /// The deadline is the important part: the gate lifts on Home's first
    /// sections, but a profile with no catalogs never publishes any, and a cover
    /// that outlives its own condition is worse than no cover at all.
    private func beginProfileGate() {
        profileGateTask?.cancel()
        isPreparingProfile = true
        profileGateStartedAt = Date()
        profileGateTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.profileGateTimeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            liftProfileGate()
        }
    }

    /// Home has rows for the new profile. Hold the cover for the remainder of the
    /// minimum anyway: a cached profile publishes within a frame, and lifting
    /// then would flash the cover rather than show it.
    private func profileGateContentReady() {
        guard isPreparingProfile else { return }
        let elapsed = Date().timeIntervalSince(profileGateStartedAt ?? Date())
        let remaining = max(0, Self.profileGateMinimumDuration - elapsed)
        profileGateTask?.cancel()
        profileGateTask = Task { @MainActor in
            if remaining > 0 {
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            liftProfileGate()
        }
    }

    /// Unconditional: used by the deadline and by backing out, where the minimum
    /// no longer means anything.
    private func liftProfileGate() {
        profileGateTask?.cancel()
        profileGateTask = nil
        profileGateStartedAt = nil
        guard isPreparingProfile else { return }
        withAnimation(.easeInOut(duration: 0.22)) {
            isPreparingProfile = false
        }
    }

    /// Routes a chosen stream either to an installed external player (per the
    /// External Player setting) or the built-in mpv player. Trailers always use
    /// the built-in player since they are YouTube-resolved. If the external app
    /// isn't installed / declines to open, playback falls back to the built-in
    /// player so the user is never left on a dead end.
    /// Ordered episodes + the currently-resuming one for a Continue Watching /
    /// Next Up item, so Home-launched playback can also auto-advance.
    private static func episodeContext(for item: ContinueWatchingItem) -> (episodes: [NuvioVideo], current: NuvioVideo?) {
        guard item.meta.isSeries, let videos = item.meta.videos, !videos.isEmpty else { return ([], nil) }
        let sorted = videos.sorted {
            (seasonSortKey($0.season), $0.episode) < (seasonSortKey($1.season), $1.episode)
        }
        let numbers = item.episodeNumbers
        let current = sorted.first { $0.season == numbers?.season && $0.episode == numbers?.episode }
        return (sorted, current)
    }

    private static func resumePosition(for item: ContinueWatchingItem) -> Double? {
        let currentItem: ContinueWatchingItem
        if RemoteTrackingState.isProgressSourceAuthenticated,
           let latest = TraktProgressService.currentContinueWatchingItem(for: item.meta) {
            currentItem = latest
        } else {
            currentItem = item
        }

        if currentItem.meta.isSeries {
            // A Trakt card already carries the exact remote episode position.
            // Looking it up in Nuvio Sync's separate episode ledger can return
            // an older checkpoint for the same episode (or no checkpoint at
            // all), so never cross the two progress sources here.
            if RemoteTrackingState.isProgressSourceAuthenticated {
                return currentItem.isUpNextEntry ? nil : currentItem.resumePosition
            }
            guard let numbers = currentItem.episodeNumbers else { return nil }
            let episodeId = currentItem.meta.videos?.first {
                $0.season == numbers.season && $0.episode == numbers.episode
            }?.id
            return ContinueWatchingStore.resumePosition(
                for: currentItem.meta,
                season: numbers.season,
                episode: numbers.episode,
                episodeId: episodeId
            )
        }
        guard !WatchedStore.contains(meta: currentItem.meta) else { return nil }
        return currentItem.resumePosition
    }

    private static func resumePosition(for meta: NuvioMeta, episode: NuvioVideo?) -> Double? {
        if RemoteTrackingState.isProgressSourceAuthenticated {
            guard let item = TraktProgressService.currentContinueWatchingItem(for: meta),
                  !item.isUpNextEntry else { return nil }
            if meta.isSeries {
                guard let episode,
                      item.season == episode.season,
                      item.episode == episode.episode else { return nil }
            }
            return item.resumePosition
        }

        if meta.isSeries {
            guard let episode else { return nil }
            return ContinueWatchingStore.resumePosition(
                for: meta,
                season: episode.season,
                episode: episode.episode,
                episodeId: episode.id
            )
        }
        guard !WatchedStore.contains(meta: meta) else { return nil }
        return ContinueWatchingStore.item(for: meta.id)?.resumePosition
    }

    private static func seasonSortKey(_ season: Int) -> Int {
        season <= 0 ? Int.max : season
    }

    /// Starts a Continue Watching card immediately. Locally played entries use
    /// their last stream URL; synced and Next Up entries fetch and smart-select
    /// a stream in the background without opening Details first.
    ///
    /// `startFromBeginning` plays the same episode with no resume point, for the
    /// card menu's "Start from beginning".
    private func resumePlayback(_ item: ContinueWatchingItem, startFromBeginning: Bool = false) {
        continueWatchingPlaybackTask?.cancel()
        continueWatchingPlaybackTask = nil
        isResolvingContinueWatchingStream = false

        let item = RemoteTrackingState.isProgressSourceAuthenticated
            ? (TraktProgressService.currentContinueWatchingItem(for: item.meta) ?? item)
            : item
        let context = Self.episodeContext(for: item)
        playbackEpisodes = context.episodes
        playbackCurrentEpisode = context.current

        let profileId = profileViewModel.activeProfile?.id
        let storedStream = item.isUpNextEntry
            ? nil
            : LastPlaybackStreamStore.load(
                metaId: item.meta.id,
                season: item.season,
                episode: item.episode,
                profileId: profileId
            )
        let itemStreamURL = item.streamUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let streamURL = [itemStreamURL, storedStream?.url]
            .compactMap { $0 }
            .first { !$0.isEmpty } ?? ""
        let httpHeaders = streamURL == storedStream?.url ? (storedStream?.httpHeaders ?? [:]) : [:]
        if !streamURL.isEmpty, let url = URL(string: streamURL) {
            presentPlayback(
                url: url,
                meta: item.meta,
                subtitle: item.episodeSubtitle ?? "",
                externalSubtitles: [],
                resumeFrom: startFromBeginning ? nil : Self.resumePosition(for: item),
                httpHeaders: httpHeaders
            )
            return
        }

        isResolvingContinueWatchingStream = true
        continueWatchingPlaybackTask = Task {
            let prepared: PreparedNextStream?
            if let episode = context.current {
                prepared = await Self.resolveNextEpisodeStream(episode: episode, profileId: profileId)
            } else if item.meta.isSeries, let numbers = item.episodeNumbers {
                prepared = await Self.resolveStream(
                    contentId: "\(item.meta.id):\(numbers.season):\(numbers.episode)",
                    type: "series",
                    subtitleLine: item.episodeSubtitle ?? "",
                    profileId: profileId
                )
            } else {
                prepared = await Self.resolveStream(
                    contentId: item.meta.id,
                    type: item.meta.type,
                    subtitleLine: item.episodeSubtitle ?? "",
                    profileId: profileId
                )
            }

            guard !Task.isCancelled else { return }
            isResolvingContinueWatchingStream = false
            continueWatchingPlaybackTask = nil

            if let prepared {
                presentPlayback(
                    url: prepared.url,
                    meta: item.meta,
                    subtitle: prepared.subtitleLine,
                    externalSubtitles: prepared.subtitles,
                    resumeFrom: startFromBeginning ? nil : Self.resumePosition(for: item),
                    httpHeaders: prepared.httpHeaders
                )
            } else {
                // Keep the manual picker available when no add-on returns a
                // playable stream automatically.
                withAnimation(.easeInOut(duration: 0.28)) {
                    openDetailsRoot(id: item.meta.id, type: item.meta.type)
                }
            }
        }
    }

    /// Opens Details with the stream picker already raised for the episode the
    /// card would resume, so the user chooses the source by hand instead of
    /// taking the smart-selected one that pressing the card plays. The resume
    /// point still applies — Details' play path looks it up per episode.
    private func playContinueWatchingManually(_ item: ContinueWatchingItem) {
        let episode = Self.manualPlaybackEpisode(for: item)
        withAnimation(.easeInOut(duration: 0.28)) {
            continueWatchingMenuItem = nil
            reopenStreamPickerOnDetails = true
            reopenStreamPickerEpisode = episode
            openDetailsRoot(id: item.meta.id, type: item.meta.type)
        }
    }

    /// Episode entry the stream picker should open on, or nil for a movie.
    /// Provider-backed rows often arrive without an episode guide, so fall back
    /// to the same `id:season:episode` video id the resume path already uses.
    private static func manualPlaybackEpisode(for item: ContinueWatchingItem) -> NuvioVideo? {
        guard item.meta.isSeries, let numbers = item.episodeNumbers else { return nil }
        if let current = episodeContext(for: item).current { return current }
        return NuvioVideo(
            id: "\(item.meta.id):\(numbers.season):\(numbers.episode)",
            title: item.episodeDisplayTitle ?? "Episode \(numbers.episode)",
            season: numbers.season,
            episode: numbers.episode,
            thumbnail: item.episodeArtworkURL,
            overview: item.episodeOverview,
            released: item.released,
            rating: nil
        )
    }

    /// Drops a card from Continue Watching for good.
    ///
    /// Local progress is deleted outright and retired on the account, since a
    /// pull would otherwise restore what the user just removed. Trakt/Simkl rows
    /// are owned by the provider and are rebuilt on every refresh, so the
    /// removal is also recorded on this device — that record is what makes the
    /// card stay gone until the title is watched again.
    private func removeFromContinueWatching(_ item: ContinueWatchingItem) {
        ContinueWatchingDismissStore.dismiss(item)

        let keys = WatchProgressLedger.records()
            .filter { $0.contentId == item.meta.id }
            .map(\.progressKey)
        ContinueWatchingStore.remove(metaId: item.meta.id)
        TraktProgressService.forgetLocalPlayback(meta: item.meta)
        // Simkl owns its paused rows, so the local dismiss only hides the card
        // on this device. Retire the row on the account as well; it no-ops
        // unless Simkl is the selected progress source.
        Task { await SimklProgressService.removePlayback(for: item) }

        guard !keys.isEmpty else { return }
        Task { await syncManager.deleteRemoteWatchProgress(keys: keys) }
    }

    private func presentPlayback(
        url: URL,
        meta: NuvioMeta,
        subtitle: String,
        externalSubtitles: [NuvioSubtitle],
        resumeFrom: Double?,
        httpHeaders: [String: String] = [:],
        origin: PlaybackOrigin = .main
    ) {
        let isTrailer = subtitle == PlaybackMarkers.trailerSubtitle
        let store = ProfileSettings.store(for: profileViewModel.activeProfile?.id)
        let player = ExternalPlayer.from(store.string(forKey: SettingsKey.externalPlayer))
        let forwardSubtitles = (store.object(forKey: SettingsKey.externalPlayerForwardSubtitles) as? Bool) ?? true
        let subtitleURLs = forwardSubtitles
            ? externalSubtitles.compactMap { URL(string: $0.url) }
            : []

        // Hand off to the external app only when it is actually installed
        // (`canOpenURL` needs its scheme in LSApplicationQueriesSchemes); if it
        // isn't, fall through to the built-in player instead of a dead launch.
        // `smb://` never qualifies: it isn't a URL an external app like
        // Infuse/VLC/nPlayer can open, only Nuvio's own SMBConnection/
        // SMBIOReader pipeline can.
        if !isTrailer,
           url.scheme != "smb",
           let launchURL = player.launchURL(for: url, subtitleURLs: subtitleURLs),
           UIApplication.shared.canOpenURL(launchURL) {
            UIApplication.shared.open(launchURL, options: [:], completionHandler: nil)
            return
        }

        presentBuiltInPlayer(
            url: url,
            meta: meta,
            subtitle: subtitle,
            httpHeaders: httpHeaders,
            externalSubtitles: externalSubtitles,
            resumeFrom: resumeFrom,
            origin: origin
        )
    }

    private func presentBuiltInPlayer(
        url: URL,
        meta: NuvioMeta,
        subtitle: String,
        httpHeaders: [String: String],
        externalSubtitles: [NuvioSubtitle],
        resumeFrom: Double?,
        origin: PlaybackOrigin
    ) {
        playbackOrigin = origin
        playbackDidStart = false
        withAnimation(.easeInOut(duration: 0.28)) {
            activeScreen = .player(
                url: url,
                meta: meta,
                subtitle: subtitle,
                httpHeaders: httpHeaders,
                externalSubtitles: externalSubtitles,
                resumeFrom: resumeFrom
            )
        }
    }

    /// The persistent tab view plus any Details/Player overlay. Keeping the tab
    /// view here (never swapped out) is what preserves Home's state across the
    /// details push. The tab view is disabled while an overlay is up so focus
    /// can't bleed to the cards behind it; re-enabling on return hands focus
    /// back to the card the user left on.
    @ViewBuilder
    private var appContainer: some View {
        ZStack {
            mainTabView
                .disabled(isOverlayPresented)
                // `.disabled` stops the tab *content* from taking focus, but the
                // sidebar/tab bar itself can still attract the focus engine while
                // an overlay is settling; focus landing there un-highlights the
                // overlay's seeded item and makes the next Menu press suspend the
                // app (system behaviour for Menu on a root tab bar). Alpha-0
                // views are unfocusable, so fading the tab view out while it's
                // covered keeps focus inside the overlay. It stays mounted, so
                // Home's state and focus memory survive for the return trip.
                // The card quick-actions menu is the exception: it floats a
                // liquid-glass panel *over* a still-visible Home, so the tab view
                // stays on screen (fading it to black would leave the glass
                // nothing to refract) — it's only `.disabled` so its cards can't
                // steal focus, and the menu re-grabs focus if the engine drifts.
                .opacity(fullScreenOverlayPresented ? 0 : 1)

            if case .details(let contentId, let contentType) = activeScreen {
                detailsScreen(contentId: contentId, contentType: contentType)
                    .id("\(contentType):\(contentId)")
                    .transition(.opacity)
                    .zIndex(1)
            }

            if case .player(let url, let meta, let subtitle, let httpHeaders, let externalSubtitles, let resumeFrom) = activeScreen {
                playerScreen(
                    url: url,
                    meta: meta,
                    subtitle: subtitle,
                    httpHeaders: httpHeaders,
                    externalSubtitles: externalSubtitles,
                    resumeFrom: resumeFrom
                )
                .transition(.opacity)
                .zIndex(2)
            }

            if case .cloudLibrary = activeScreen {
                cloudLibraryScreen()
                    .transition(.opacity)
                    .zIndex(1)
            }

            if let collectionContext = presentedCollectionFolder {
                let folder = collectionContext.folder
                let collectionTitle = collectionContext.collectionTitle
                CollectionFolderBrowseView(
                    folder: folder,
                    collectionTitle: collectionTitle,
                    repository: CinemetaCatalogRepository(),
                    onSelect: { meta in
                        withAnimation(.easeInOut(duration: 0.28)) {
                            openDetailsRoot(
                                id: meta.id,
                                type: meta.type,
                                returnDestination: .collectionFolder(
                                    folder,
                                    collectionTitle: collectionTitle
                                )
                            )
                        }
                    },
                    onLongPress: { meta in
                        cardMenuReturnDestination = .collectionFolder(
                            folder,
                            collectionTitle: collectionTitle
                        )
                        withAnimation(.easeInOut(duration: 0.2)) {
                            cardMenuMeta = meta
                        }
                    },
                    onBack: {
                        if ["STREAMING_SERVICE", "STUDIO_FRANCHISE"].contains(
                            folder.presentationStyle?.uppercased() ?? ""
                        ) {
                            var transaction = Transaction()
                            transaction.animation = nil
                            withTransaction(transaction) {
                                activeScreen = .main
                            }
                        } else {
                            withAnimation(.easeInOut(duration: 0.24)) {
                                activeScreen = .main
                            }
                        }
                    }
                )
                .disabled(!isCollectionFolderActive || cardMenuMeta != nil)
                .transition(.opacity)
                .zIndex(isCollectionFolderActive ? 1 : 0)
            }

            if case .productionBrowse(let company) = activeScreen {
                ProductionBrowseView(
                    company: company,
                    onSelect: { title in
                        withAnimation(.easeInOut(duration: 0.28)) {
                            if let ret = productionBrowseReturn {
                                // Keep the originating Details screen in the
                                // same navigation chain. Otherwise backing out
                                // of the selected title falls all the way home.
                                detailsBackStack.append((id: ret.id, type: ret.type))
                                activeScreen = .details(id: title.id, type: title.type)
                            } else {
                                openDetailsRoot(id: title.id, type: title.type)
                            }
                            productionBrowseReturn = nil
                        }
                    },
                    onBack: {
                        withAnimation(.easeInOut(duration: 0.24)) {
                            if let ret = productionBrowseReturn {
                                activeScreen = .details(id: ret.id, type: ret.type)
                            } else {
                                activeScreen = .main
                            }
                            productionBrowseReturn = nil
                        }
                    }
                )
                .transition(.opacity)
                .zIndex(1)
            }

            if case .personBrowse(let person) = activeScreen {
                PersonBrowseView(
                    person: person,
                    onSelect: { title in
                        withAnimation(.easeInOut(duration: 0.28)) {
                            if let ret = personBrowseReturn {
                                // Keep the originating Details screen in the
                                // same navigation chain. Otherwise backing out
                                // of the selected title falls all the way home.
                                detailsBackStack.append((id: ret.id, type: ret.type))
                                activeScreen = .details(id: title.id, type: title.type)
                            } else {
                                openDetailsRoot(id: title.id, type: title.type)
                            }
                            personBrowseReturn = nil
                        }
                    },
                    onBack: {
                        withAnimation(.easeInOut(duration: 0.24)) {
                            if let ret = personBrowseReturn {
                                activeScreen = .details(id: ret.id, type: ret.type)
                            } else {
                                activeScreen = .main
                            }
                            personBrowseReturn = nil
                        }
                    }
                )
                .transition(.opacity)
                .zIndex(1)
            }

            if isResolvingContinueWatchingStream {
                ContinueWatchingPlaybackLoadingView()
                    .transition(.opacity)
                    .zIndex(3)
            }

            if let menuMeta = cardMenuMeta {
                CardActionMenuOverlay(
                    meta: menuMeta,
                    onDetails: {
                        // Hand off to Details without a focus flash: the tab view
                        // stays covered because activeScreen becomes .details in
                        // the same transaction the menu clears.
                        withAnimation(.easeInOut(duration: 0.28)) {
                            cardMenuMeta = nil
                            openDetailsRoot(
                                id: menuMeta.id,
                                type: menuMeta.type,
                                returnDestination: cardMenuReturnDestination
                            )
                            cardMenuReturnDestination = .main
                        }
                    },
                    onDismiss: {
                        withAnimation(.easeInOut(duration: 0.2)) { cardMenuMeta = nil }
                        cardMenuReturnDestination = .main
                    }
                )
                .transition(.opacity)
                .zIndex(3)
            }

            if let menuItem = continueWatchingMenuItem {
                ContinueWatchingActionMenuOverlay(
                    item: menuItem,
                    onDetails: {
                        withAnimation(.easeInOut(duration: 0.28)) {
                            continueWatchingMenuItem = nil
                            openDetailsRoot(id: menuItem.meta.id, type: menuItem.meta.type)
                        }
                    },
                    onPlayManually: {
                        playContinueWatchingManually(menuItem)
                    },
                    onStartFromBeginning: {
                        withAnimation(.easeInOut(duration: 0.2)) { continueWatchingMenuItem = nil }
                        resumePlayback(menuItem, startFromBeginning: true)
                    },
                    onRemove: {
                        withAnimation(.easeInOut(duration: 0.2)) { continueWatchingMenuItem = nil }
                        removeFromContinueWatching(menuItem)
                    },
                    onDismiss: {
                        withAnimation(.easeInOut(duration: 0.2)) { continueWatchingMenuItem = nil }
                    }
                )
                .transition(.opacity)
                .zIndex(3)
            }
        }
    }

    private var mainTabView: some View {
        TVMainTabView(
            selectedTab: $selectedTab,
            activeProfile: profileViewModel.activeProfile,
            searchViewModel: searchViewModel,
            netflixSearchViewModel: netflixSearchViewModel,
            libraryViewModel: libraryViewModel,
            homeStore: homeStore,
            homeCatalogRevision: syncManager.homeCatalogRevision,
            homeCollectionsRevision: syncManager.homeCollectionsRevision,
            accountEmail: authManager.currentEmail,
            isAuthenticated: authManager.isAuthenticated,
            sessionNeedsReauthentication: authManager.sessionNeedsReauthentication,
            isProfileSwitching: isPreparingProfile,
            onSwitchProfile: {
                // A fresh profile should get a fresh Home (different Continue
                // Watching, etc.), so drop the cached catalog.
                homeStore.reset()
                withAnimation(.easeInOut(duration: 0.28)) {
                    selectedTab = .home
                    profileViewModel.activeProfile = nil
                    activeScreen = .profileSelection
                }
            },
            onChangeProfileAvatar: { profileId, avatarId in
                profileViewModel.updateProfileAvatar(id: profileId, avatarId: avatarId)
                syncManager.syncProfilesAfterLocalEdit()
            },
            onChangeProfileName: { profileId, name in
                profileViewModel.updateProfileName(id: profileId, name: name)
                syncManager.syncProfilesAfterLocalEdit()
            },
            onChangeProfilePin: { profileId, pin, currentPin in
                if authManager.isAuthenticated {
                    return await syncManager.updateProfilePin(
                        profileId: profileId,
                        pin: pin,
                        currentPin: currentPin
                    )
                }
                return profileViewModel.updateProfilePin(id: profileId, pin: pin)
            },
            onVerifyProfilePin: { profileId, pin in
                if authManager.isAuthenticated {
                    return await syncManager.verifyProfilePin(profileId: profileId, pin: pin)
                }
                return profileViewModel.verifyProfilePin(id: profileId, pin: pin)
            },
            onSignIn: {
                authManager.requireLogin()
                homeStore.reset()
                withAnimation(.easeInOut(duration: 0.28)) {
                    selectedTab = .home
                    profileViewModel.activeProfile = nil
                    activeScreen = .login
                }
            },
            onSignOut: {
                // Order matters: signOut() flips auth state first so the sync
                // manager stops pushing before the local wipe below fires
                // store-changed notifications.
                authManager.signOut()
                profileViewModel.resetForSignedOut()
                homeStore.reset()
                searchViewModel.clear()
                searchViewModel.clearRecent()
                netflixSearchViewModel.clear()
                netflixSearchViewModel.clearRecent()
                withAnimation(.easeInOut(duration: 0.28)) {
                    selectedTab = .home
                    profileViewModel.activeProfile = nil
                    activeScreen = .login
                }
            },
            onNavigateToDetails: { contentId, contentType in
                withAnimation(.easeInOut(duration: 0.28)) {
                    openDetailsRoot(id: contentId, type: contentType)
                }
            },
            onRequestAccountRefresh: {
                syncManager.refreshAccountIfIdle()
            },
            onOpenCollectionFolder: { folder, collectionTitle in
                if ["STREAMING_SERVICE", "STUDIO_FRANCHISE"].contains(
                    folder.presentationStyle?.uppercased() ?? ""
                ) {
                    // This template owns a full-bleed backdrop and several
                    // poster rails. Cross-fading it with the equally heavy Home
                    // tree makes entry hitch, so hand off in one transaction.
                    var transaction = Transaction()
                    transaction.animation = nil
                    withTransaction(transaction) {
                        activeScreen = .collectionFolder(folder, collectionTitle: collectionTitle)
                    }
                } else {
                    withAnimation(.easeInOut(duration: 0.28)) {
                        activeScreen = .collectionFolder(folder, collectionTitle: collectionTitle)
                    }
                }
            },
            onResumePlayback: { item in
                resumePlayback(item)
            },
            onLongPressCard: { meta in
                cardMenuReturnDestination = .main
                withAnimation(.easeInOut(duration: 0.2)) {
                    cardMenuMeta = meta
                }
            },
            onLongPressContinueWatching: { item in
                withAnimation(.easeInOut(duration: 0.2)) {
                    continueWatchingMenuItem = item
                }
            },
            onOpenCloudLibrary: {
                withAnimation(.easeInOut(duration: 0.28)) {
                    activeScreen = .cloudLibrary
                }
            }
        )
    }

    private func detailsScreen(contentId: String, contentType: String) -> some View {
        DetailsScreen(
            id: contentId,
            type: contentType,
            repository: CinemetaCatalogRepository(),
            initiallyPresentStreamPicker: reopenStreamPickerOnDetails,
            initialStreamPickerEpisode: reopenStreamPickerEpisode,
            onInitialStreamPickerPresented: {
                reopenStreamPickerOnDetails = false
                reopenStreamPickerEpisode = nil
            },
            onPlayClick: { streamUrlString, httpHeaders, meta, subtitle, externalSubtitles, currentEpisode, episodes in
                if let url = URL(string: streamUrlString) {
                    let isTrailer = subtitle == PlaybackMarkers.trailerSubtitle
                    reopenStreamPickerOnDetails = false
                    reopenStreamPickerEpisode = nil
                    playbackEpisodes = episodes
                    playbackCurrentEpisode = currentEpisode
                    presentPlayback(
                        url: url,
                        meta: meta,
                        subtitle: subtitle,
                        externalSubtitles: externalSubtitles,
                        resumeFrom: isTrailer ? nil : Self.resumePosition(for: meta, episode: currentEpisode),
                        httpHeaders: httpHeaders,
                        origin: .details
                    )
                }
            },
            onBack: { leaveDetails() },
            onOpenTitle: { nextId, nextType in
                detailsBackStack.append((id: contentId, type: contentType))
                withAnimation(.easeInOut(duration: 0.28)) {
                    activeScreen = .details(id: nextId, type: nextType)
                }
            },
            onOpenProduction: { company in
                productionBrowseReturn = (contentId, contentType)
                withAnimation(.easeInOut(duration: 0.28)) {
                    activeScreen = .productionBrowse(company)
                }
            },
            onOpenPerson: { person in
                personBrowseReturn = (contentId, contentType)
                withAnimation(.easeInOut(duration: 0.28)) {
                    activeScreen = .personBrowse(person)
                }
            }
        )
    }

    private func cloudLibraryScreen() -> some View {
        CloudLibraryView(
            store: ProfileSettings.store(for: profileViewModel.activeProfile?.id),
            onPlay: { url, meta in
                playbackEpisodes = []
                playbackCurrentEpisode = nil
                presentPlayback(
                    url: url,
                    meta: meta,
                    subtitle: "",
                    externalSubtitles: [],
                    resumeFrom: nil,
                    origin: .cloudLibrary
                )
            },
            onBack: {
                withAnimation(.easeInOut(duration: 0.24)) {
                    activeScreen = .main
                }
            }
        )
    }

    /// Resolves a next episode into a ready-to-play stream for the player's
    /// seamless auto-advance: fetches the episode's streams (concurrently) and
    /// applies the same smart selection the details screen uses. Returns nil when
    /// nothing real is available, so the player falls back to a normal end.
    private static func resolveNextEpisodeStream(episode: NuvioVideo, profileId: String?) async -> PreparedNextStream? {
        await resolveStream(
            contentId: episode.id,
            type: "series",
            subtitleLine: "S\(episode.season) · E\(episode.episode) · \(episode.title)",
            profileId: profileId
        )
    }

    /// Fetches a content id's streams (concurrently) and applies smart selection,
    /// returning a ready-to-play stream. Used both to advance to the next episode
    /// and to reload a fresh link for the current title when one expires or fails.
    /// `excludingURLs` skips sources already tried this session (failover).
    private static func resolveStream(
        contentId: String,
        type: String,
        subtitleLine: String,
        profileId: String?,
        excludingURLs: Set<String> = []
    ) async -> PreparedNextStream? {
        let streams = await StreamsRepository.shared.collectStreams(type: type, videoId: contentId)
        guard !streams.isEmpty else { return nil }

        let store = ProfileSettings.store(for: profileId)
        let quality = store.string(forKey: SettingsKey.smartStreamQuality) ?? "Highest"
        let matchSubtitles = store.object(forKey: SettingsKey.smartSubtitleMatching) as? Bool ?? true
        let languages = SubtitleLanguagePreferences.orderedFromDefaults(defaults: store)
        let cachedOnly = (store.object(forKey: SettingsKey.cachedOnlyStreams) as? Bool) ?? false
        // Prefer the series meta id for quality memory when content id is an episode.
        let metaIdForTags = contentId.split(separator: ":").first.map(String.init) ?? contentId
        let preferredTags = LastStreamQualityStore.load(metaId: metaIdForTags, profileId: profileId)
            ?? LastStreamQualityStore.load(metaId: contentId, profileId: profileId)

        let debrid = DebridResolver(store: store)
        let ranked = Self.rankedPlayableStreams(
            from: streams,
            qualityPreference: quality,
            subtitleLanguages: languages,
            shouldMatchSubtitles: matchSubtitles,
            includeDebrid: debrid.isEnabled,
            preferredTags: preferredTags,
            cachedOnly: cachedOnly
        )
        guard !ranked.isEmpty else { return nil }

        let (season, episode) = Self.seasonEpisode(fromContentId: contentId)
        for candidate in ranked {
            // Direct URL already known-bad this session.
            if let urlString = candidate.url?.trimmingCharacters(in: .whitespacesAndNewlines),
               !urlString.isEmpty,
               excludingURLs.contains(urlString) {
                continue
            }

            if candidate.isDebridResolvable {
                guard case let .success(url, _, _)? = await debrid.resolvedURL(
                    for: candidate,
                    season: season,
                    episode: episode
                ) else { continue }
                if excludingURLs.contains(url.absoluteString) { continue }
                LastStreamQualityStore.save(
                    metaId: metaIdForTags,
                    stream: candidate,
                    profileId: profileId
                )
                return PreparedNextStream(
                    url: url,
                    httpHeaders: candidate.httpHeaders ?? [:],
                    subtitleLine: subtitleLine,
                    subtitles: candidate.subtitles,
                    streamName: candidate.name,
                    streamDescription: candidate.description,
                    filename: candidate.filename
                )
            }

            guard let urlString = candidate.url, let url = URL(string: urlString) else { continue }
            LastStreamQualityStore.save(
                metaId: metaIdForTags,
                stream: candidate,
                profileId: profileId
            )
            return PreparedNextStream(
                url: url,
                httpHeaders: candidate.httpHeaders ?? [:],
                subtitleLine: subtitleLine,
                subtitles: candidate.subtitles,
                streamName: candidate.name,
                streamDescription: candidate.description,
                filename: candidate.filename
            )
        }
        return nil
    }

    /// All playable sources for the Sources side panel, in the same order the
    /// Details stream picker lists them. `collectStreams` already returns the
    /// add-on groups flattened in configured order, so running the picker's own
    /// derivation (playable filter + Default sort) reproduces that list exactly
    /// — smart-best-first ranking here would have shown a different order for
    /// the same content.
    private static func fetchSources(
        contentId: String,
        type: String,
        profileId: String?
    ) async -> [NuvioStream] {
        let streams = await StreamsRepository.shared.collectStreams(type: type, videoId: contentId)
        let store = ProfileSettings.store(for: profileId)
        let debrid = DebridResolver(store: store)
        let cachedOnly = (store.object(forKey: SettingsKey.cachedOnlyStreams) as? Bool) ?? false
        return StreamPickerListBuilder.displayedStreams(
            streams: streams,
            groups: [],
            selectedAddonId: nil,
            sortOption: .default,
            includeDebrid: debrid.isEnabled,
            cachedOnly: cachedOnly
        )
    }

    /// Resolves one user-picked source (direct URL or debrid) for mid-playback switch.
    private static func resolveChosenStream(
        _ stream: NuvioStream,
        contentId: String,
        subtitleLine: String,
        profileId: String?
    ) async -> PreparedNextStream? {
        let store = ProfileSettings.store(for: profileId)
        let debrid = DebridResolver(store: store)
        let (season, episode) = seasonEpisode(fromContentId: contentId)
        let metaIdForTags = contentId.split(separator: ":").first.map(String.init) ?? contentId

        if stream.isDebridResolvable {
            guard case let .success(url, _, _)? = await debrid.resolvedURL(
                for: stream,
                season: season,
                episode: episode
            ) else { return nil }
            LastStreamQualityStore.save(
                metaId: metaIdForTags,
                stream: stream,
                profileId: profileId
            )
            return PreparedNextStream(
                url: url,
                httpHeaders: stream.httpHeaders ?? [:],
                subtitleLine: subtitleLine,
                subtitles: stream.subtitles,
                streamName: stream.name,
                streamDescription: stream.description,
                filename: stream.filename
            )
        }

        guard let urlString = stream.url, let url = URL(string: urlString) else { return nil }
        LastStreamQualityStore.save(
            metaId: metaIdForTags,
            stream: stream,
            profileId: profileId
        )
        return PreparedNextStream(
            url: url,
            httpHeaders: stream.httpHeaders ?? [:],
            subtitleLine: subtitleLine,
            subtitles: stream.subtitles,
            streamName: stream.name,
            streamDescription: stream.description,
            filename: stream.filename
        )
    }

    /// Ordered candidates for playback / failover: smart-best first (including
    /// last-watched DV/HDR/Atmos match), then remaining playable streams.
    private static func rankedPlayableStreams(
        from streams: [NuvioStream],
        qualityPreference: String,
        subtitleLanguages: [String],
        shouldMatchSubtitles: Bool,
        includeDebrid: Bool,
        preferredTags: StreamQualityTags? = nil,
        cachedOnly: Bool = false
    ) -> [NuvioStream] {
        SmartPlaybackSelector.rankedStreams(
            from: streams,
            qualityPreference: qualityPreference,
            subtitleLanguages: subtitleLanguages,
            shouldMatchSubtitles: shouldMatchSubtitles,
            includeDebrid: includeDebrid,
            preferredTags: preferredTags,
            cachedOnly: cachedOnly
        )
    }

    /// Parses the season/episode out of a Stremio series content id of the form
    /// `tt1234567:2:5` (imdb-id : season : episode). Returns `(nil, nil)` for
    /// movies or ids without the trailing numbers.
    private static func seasonEpisode(fromContentId contentId: String) -> (season: Int?, episode: Int?) {
        let parts = contentId.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3, let season = Int(parts[parts.count - 2]), let episode = Int(parts[parts.count - 1]) else {
            return (nil, nil)
        }
        return (season, episode)
    }

    @ViewBuilder
    private func playerScreen(
        url: URL,
        meta: NuvioMeta,
        subtitle: String,
        httpHeaders: [String: String],
        externalSubtitles: [NuvioSubtitle],
        resumeFrom: Double?
    ) -> some View {
        let isTrailer = subtitle == PlaybackMarkers.trailerSubtitle
        let store = ProfileSettings.store(for: profileViewModel.activeProfile?.id)
        let autoPlayNext = store.object(forKey: SettingsKey.autoPlayNext) as? Bool ?? true
        let autoPlayNextCountdown = store.object(forKey: SettingsKey.autoPlayNextCountdown) as? Int ?? 10
        PlayerView(
            url: url,
            meta: meta,
            subtitle: subtitle,
            httpHeaders: httpHeaders,
            externalSubtitles: externalSubtitles,
            resumeFrom: resumeFrom,
            episodes: isTrailer ? [] : playbackEpisodes,
            currentEpisode: isTrailer ? nil : playbackCurrentEpisode,
            autoPlayNextEnabled: autoPlayNext,
            autoPlayNextCountdownSeconds: autoPlayNextCountdown,
            resolveNextStream: (isTrailer || !meta.isSeries) ? nil : { episode in
                await Self.resolveNextEpisodeStream(episode: episode, profileId: profileViewModel.activeProfile?.id)
            },
            reloadCurrentStream: isTrailer ? nil : { excludedURLs in
                let profileId = profileViewModel.activeProfile?.id
                let excluded = Set(excludedURLs)
                if let episode = playbackCurrentEpisode {
                    return await Self.resolveStream(
                        contentId: episode.id,
                        type: "series",
                        subtitleLine: "S\(episode.season) · E\(episode.episode) · \(episode.title)",
                        profileId: profileId,
                        excludingURLs: excluded
                    )
                }
                return await Self.resolveStream(
                    contentId: meta.id,
                    type: meta.type,
                    subtitleLine: subtitle,
                    profileId: profileId,
                    excludingURLs: excluded
                )
            },
            fetchPlaybackSources: isTrailer ? nil : { contentId, type in
                await Self.fetchSources(
                    contentId: contentId,
                    type: type,
                    profileId: profileViewModel.activeProfile?.id
                )
            },
            resolvePlaybackStream: isTrailer ? nil : { stream, contentId, subtitleLine in
                await Self.resolveChosenStream(
                    stream,
                    contentId: contentId,
                    subtitleLine: subtitleLine,
                    profileId: profileViewModel.activeProfile?.id
                )
            },
            onFinished: isTrailer ? {
                withAnimation(.easeInOut(duration: 0.24)) {
                    activeScreen = .details(id: meta.id, type: meta.type)
                }
            } : nil,
            onPlaybackStarted: {
                playbackDidStart = true
            }
        ) {
            dismissPlayer(meta: meta, subtitle: subtitle)
        }
    }

    private func dismissPlayer(meta: NuvioMeta, subtitle: String) {
        let isTrailer = subtitle == PlaybackMarkers.trailerSubtitle
        withAnimation(.easeInOut(duration: 0.24)) {
            switch playbackOrigin {
            case .details:
                // A stream that never reached playback should return to the
                // exact decision point so another source is one click away.
                reopenStreamPickerOnDetails = !playbackDidStart && !isTrailer
                reopenStreamPickerEpisode = reopenStreamPickerOnDetails ? playbackCurrentEpisode : nil
                activeScreen = .details(id: meta.id, type: meta.type)
            case .cloudLibrary:
                activeScreen = .cloudLibrary
            case .main:
                activeScreen = (isTrailer || meta.isSeries)
                    ? .details(id: meta.id, type: meta.type)
                    : .main
            }
        }
    }
}

/// Brief full-screen state while a URL-less Continue Watching entry finds its
/// preferred stream. Keeping this outside Details avoids an extra focus stop.
private struct ContinueWatchingPlaybackLoadingView: View {
    var body: some View {
        VStack(spacing: 24) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white)
                .scaleEffect(1.5)

            Text("Finding your stream")
                .font(.custom("Inter-Bold", size: 36))
                .foregroundColor(.white)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .focusable()
    }
}

/// Shown between login and who's-watching while the first account pull is in
/// flight, so profile names arrive before the selection grid renders.
private struct AccountSyncWaitView: View {
    var body: some View {
        VStack(spacing: 26) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white)
                .scaleEffect(1.6)

            Text("Syncing your account")
                .font(.custom("Inter-Bold", size: 44))
                .foregroundColor(.white)

            Text("Hang tight while we import your profiles and watch history.")
                .font(.custom("Inter-Regular", size: 28))
                .foregroundColor(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Give the focus engine somewhere to land; with no focusable view on
        // screen a Menu press would quit the app.
        .focusable()
    }
}

/// Root background that reads the appearance settings from the active profile's
/// store (through the inherited `.defaultAppStorage`), so the theme color follows
/// the selected profile rather than being shared across all profiles.
private struct ProfileScopedRootBackground: View {
    @AppStorage(SettingsKey.amoled) private var amoled = false
    @AppStorage(SettingsKey.bodyColor) private var bodyColor = SettingsBackground.charcoal.rawValue

    var body: some View {
        Color.nuvioBackground(amoled: amoled, body: bodyColor).ignoresSafeArea()
    }
}

/// Full-screen backdrop that crossfades between images without flashing the
/// placeholder colour. `AsyncImage(url:).id(url)` tears the current image down
/// the instant the URL changes and shows its placeholder until the next image
/// decodes — which is the "blink" seen when focus moves slowly poster-by-poster.
/// This keeps the current image on screen, decodes the next one in the
/// background, and only then fades it in. Rapid URL changes (fast scrolling)
/// cancel the in-flight load via `.task(id:)`, so the visible image never
/// changes mid-scroll.
///
/// `alignment` controls which edge of a taller/wider image stays visible when
/// aspect-filled (Android Modern Home uses top-trailing for hero art so faces
/// and subjects aren't cropped off the top).
private struct CrossfadingBackdrop: View {
    let url: String?
    let placeholder: Color
    /// Crop anchor for `.fill`. Collection folder heroes use `.topTrailing`
    /// (Android `Alignment.TopEnd`); title posters keep center.
    var alignment: Alignment = .center

    @State private var image: UIImage?
    @State private var loadedURL: String?
    @State private var outgoingImage: UIImage?
    @State private var outgoingOpacity = 0.0
    @State private var imageOpacity = 1.0

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                placeholder
                if let outgoingImage {
                    backdropImage(outgoingImage, size: proxy.size)
                        .opacity(outgoingOpacity)
                }
                if let image {
                    backdropImage(image, size: proxy.size)
                        .opacity(imageOpacity)
                        .id(loadedURL)
                }
            }
            // Portrait poster fallbacks must be cropped inside the screen, not
            // enlarge the root Home layout and let tvOS pan the hero offscreen.
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .task(id: url) {
            guard let url, url != loadedURL, let imageURL = URL(string: url) else {
                outgoingImage = nil
                outgoingOpacity = 0
                return
            }
            guard let loaded = await BackdropImageCache.shared.image(for: imageURL) else { return }
            // Some catalog add-ons (including BetterPosters) only provide a
            // poster URL. PosterCard uses that same image for its landscape
            // state, so allow the full-screen aspect-fill to use it as well.
            // `.task(id:)` cancels when `url` changes, so reaching here means this
            // URL is still the focused one. Cancellation leaves the old image up.
            guard !Task.isCancelled else { return }
            let previousImage = image
            if previousImage != nil {
                outgoingImage = previousImage
                outgoingOpacity = 1
            }
            image = loaded
            loadedURL = url
            imageOpacity = previousImage == nil ? 1 : 0

            withAnimation(.easeInOut(duration: 0.30)) {
                imageOpacity = 1
                outgoingOpacity = 0
            }

            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, loadedURL == url else { return }
            outgoingImage = nil
            outgoingOpacity = 0
        }
    }

    @ViewBuilder
    private func backdropImage(_ uiImage: UIImage, size: CGSize) -> some View {
        Image(uiImage: uiImage)
            .resizable()
            .aspectRatio(contentMode: .fill)
            // Alignment anchors the crop when the filled image overflows the
            // screen — critical for tall hero art (collection folder backdrops).
            .frame(width: size.width, height: size.height, alignment: alignment)
            .clipped()
    }
}

/// Small in-memory cache + loader for backdrop images so revisiting a poster is
/// instant (no decode flicker) and repeated focus changes don't refetch.
private actor BackdropImageCache {
    static let shared = BackdropImageCache()

    private let cache = NSCache<NSString, UIImage>()

    init() {
        cache.countLimit = 40
    }

    func image(for url: URL) async -> UIImage? {
        let key = url.absoluteString as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let decoded = UIImage(data: data) else { return nil }
        cache.setObject(decoded, forKey: key)
        return decoded
    }
}

/// Composites the active profile's avatar (catalog face over its accent circle)
/// into a static, circular bitmap for use as the profile tab's icon.
///
/// tvOS tab items can only display a still image, not a live `AsyncImage`/SwiftUI
/// view, so `ProfileAvatarView` can't be dropped into a `.tabItem` directly. We
/// draw the same composition off-screen once per avatar and hand the finished
/// bitmap to the tab bar; until it's ready (or when no avatar is set) the tab
/// falls back to the generic person symbol.
@MainActor
final class ProfileTabAvatarRenderer: ObservableObject {
    @Published private(set) var image: UIImage?
    /// The avatar id the current `image` (or in-flight render) belongs to, so we
    /// skip redundant work and ignore renders that finish after a profile swap.
    private var renderedAvatarId: String?

    /// Point size of the composited icon. tvOS scales tab images down to fit, so
    /// a generous size keeps the avatar crisp in the sidebar.
    private let diameter: CGFloat = 50

    func refresh(avatarId: String?) {
        guard let avatarId, !avatarId.isEmpty,
              let item = AvatarCatalogStore.shared.item(for: avatarId),
              let url = item.imageURL else {
            // No avatar chosen, or the catalog hasn't loaded yet: show the
            // symbol. Clearing `renderedAvatarId` lets a later `refresh` (once
            // the catalog arrives) re-attempt the render.
            renderedAvatarId = nil
            image = nil
            return
        }
        guard avatarId != renderedAvatarId else { return }
        renderedAvatarId = avatarId
        image = nil
        let background = UIColor(item.backgroundColor)
        Task { await render(avatarId: avatarId, url: url, background: background) }
    }

    private func render(avatarId: String, url: URL, background: UIColor) async {
        guard let face = await BackdropImageCache.shared.image(for: url) else { return }
        let size = CGSize(width: diameter, height: diameter)
        let composed = UIGraphicsImageRenderer(size: size).image { ctx in
            let rect = CGRect(origin: .zero, size: size)
            ctx.cgContext.addEllipse(in: rect)
            ctx.cgContext.clip()
            background.setFill()
            ctx.fill(rect)

            // Aspect-fill the (transparent-PNG) face inside the circle.
            let faceSize = face.size
            guard faceSize.width > 0, faceSize.height > 0 else { return }
            let scale = max(rect.width / faceSize.width, rect.height / faceSize.height)
            let drawSize = CGSize(width: faceSize.width * scale, height: faceSize.height * scale)
            let origin = CGPoint(x: (rect.width - drawSize.width) / 2,
                                 y: (rect.height - drawSize.height) / 2)
            face.draw(in: CGRect(origin: origin, size: drawSize))
        }.withRenderingMode(.alwaysOriginal)

        // Bail if the active profile changed while the face was downloading.
        guard renderedAvatarId == avatarId else { return }
        image = composed
    }
}

private struct TVMainTabView: View {
    @Binding var selectedTab: TVTab
    let activeProfile: Profile?
    @ObservedObject var searchViewModel: SearchViewModel
    @ObservedObject var netflixSearchViewModel: NetflixSearchViewModel
    @ObservedObject var libraryViewModel: LibraryViewModel
    @ObservedObject var homeStore: TVHomeStore
    let homeCatalogRevision: UInt
    let homeCollectionsRevision: UInt
    let accountEmail: String?
    let isAuthenticated: Bool
    let sessionNeedsReauthentication: Bool
    let isProfileSwitching: Bool
    let onSwitchProfile: () -> Void
    let onChangeProfileAvatar: (String, String) -> Void
    let onChangeProfileName: (String, String) -> Void
    let onChangeProfilePin: (String, String?, String?) async -> Bool
    let onVerifyProfilePin: (String, String) async -> Bool
    let onSignIn: () -> Void
    let onSignOut: () -> Void
    let onNavigateToDetails: (String, String) -> Void
    let onRequestAccountRefresh: () -> Void
    let onOpenCollectionFolder: (TVCollectionFolderItem, String) -> Void
    let onResumePlayback: (ContinueWatchingItem) -> Void
    let onLongPressCard: (NuvioMeta) -> Void
    /// Long press on a Continue Watching card, which gets its own resume-centric
    /// menu instead of the generic title actions.
    let onLongPressContinueWatching: (ContinueWatchingItem) -> Void
    let onOpenCloudLibrary: () -> Void
    @AppStorage(SettingsKey.amoled) private var amoled = false
    @AppStorage(SettingsKey.bodyColor) private var bodyColor = SettingsBackground.charcoal.rawValue
    @AppStorage(SettingsKey.discoverLocation) private var discoverLocation = "Search"
    @AppStorage(SettingsKey.searchStyle) private var searchStyle = "Netflix"
    @AppStorage(SettingsKey.profileName) private var settingsProfileName = "Nuvio User"
    @StateObject private var profileTabAvatar = ProfileTabAvatarRenderer()

    private var displayedProfile: Profile? {
        if isAuthenticated { return activeProfile }
        return activeProfile?.id == "guest" ? activeProfile : nil
    }

    /// Name shown on the profile tab, mirroring the sidebar header's
    /// display-name logic.
    private var profileTabTitle: String {
        guard let displayedProfile else { return "Nuvio Guest" }
        return ProfileDisplayName.resolve(profile: displayedProfile, settingsName: settingsProfileName)
    }

    var body: some View {
        if #available(tvOS 18.0, *) {
            tabs
                .tabViewStyle(.sidebarAdaptable)
        } else {
            tabs
        }
    }

    /// Search screen chosen in Settings → Layout & Discovery → Search Style.
    @ViewBuilder
    private var searchTab: some View {
        if searchStyle == "Classic" {
            SearchView(
                viewModel: searchViewModel,
                showDiscover: discoverLocation == "Search",
                onContentClick: onNavigateToDetails,
                onLongPress: onLongPressCard
            )
        } else {
            NetflixSearchView(
                viewModel: netflixSearchViewModel,
                showDiscover: discoverLocation == "Search",
                onContentClick: onNavigateToDetails,
                onLongPress: onLongPressCard
            )
        }
    }

    private var tabs: some View {
        TabView(selection: $selectedTab) {
            // Keep profile switching as a regular tab on every supported tvOS
            // version. This compiles with the tvOS 26.5 SDK and remains visible
            // when the app is sideloaded onto tvOS 27.
            // The tab label carries the profile name + avatar icon so the menu
            // shows who's signed in instead of a generic "Profile" entry. Its
            // content stays empty: selecting it goes straight to profile
            // switching, while editing now lives in Settings.
            Color.clear
                .tabItem {
                    Label {
                        Text(profileTabTitle)
                    } icon: {
                        if let avatar = profileTabAvatar.image {
                            Image(uiImage: avatar).renderingMode(.original)
                        } else {
                            Image(systemName: ProfileAvatarCatalog.symbolName(for: displayedProfile?.avatarId))
                        }
                    }
                }
                .tag(TVTab.profile)

            TVHomeView(
                store: homeStore,
                repository: CinemetaCatalogRepository(),
                isActive: selectedTab == .home,
                isProfileSwitching: isProfileSwitching,
                contentIdentity: TVHomeContentIdentity(
                    profileId: activeProfile?.id ?? "none",
                    catalogRevision: homeCatalogRevision
                ),
                collectionsRevision: homeCollectionsRevision,
                onNavigateToDetails: onNavigateToDetails,
                onOpenCollectionFolder: onOpenCollectionFolder,
                onResumePlayback: onResumePlayback,
                onLongPressCard: onLongPressCard,
                onLongPressContinueWatching: onLongPressContinueWatching,
                onRequestAccountRefresh: onRequestAccountRefresh
            )
                .id(activeProfile?.id ?? "none")
                .tabItem {
                    Label(TVTab.home.title, systemImage: TVTab.home.symbol)
                }
                .tag(TVTab.home)

            searchTab
                .tabItem {
                    Label(TVTab.search.title, systemImage: TVTab.search.symbol)
                }
                .tag(TVTab.search)

            LibraryView(viewModel: libraryViewModel, onContentClick: onNavigateToDetails, onLongPress: onLongPressCard, onOpenCloudLibrary: onOpenCloudLibrary)
                .id(activeProfile?.id ?? "none")
                .tabItem {
                    Label(TVTab.library.title, systemImage: TVTab.library.symbol)
                }
                .tag(TVTab.library)

            SettingsView(
                activeProfile: displayedProfile,
                accountEmail: accountEmail,
                isAuthenticated: isAuthenticated,
                sessionNeedsReauthentication: sessionNeedsReauthentication,
                onChangeProfileName: onChangeProfileName,
                onChangeProfileAvatar: onChangeProfileAvatar,
                onChangeProfilePin: onChangeProfilePin,
                onVerifyProfilePin: onVerifyProfilePin,
                onSignIn: onSignIn,
                onSignOut: onSignOut
            )
                .tabItem {
                    Label(TVTab.settings.title, systemImage: TVTab.settings.symbol)
                }
                .tag(TVTab.settings)
        }
        .background(Color.nuvioBackground(amoled: amoled, body: bodyColor).ignoresSafeArea())
        .onAppear {
            AvatarCatalogStore.shared.loadIfNeeded()
            profileTabAvatar.refresh(avatarId: displayedProfile?.avatarId)
        }
        .onChange(of: displayedProfile?.avatarId) { newValue in
            profileTabAvatar.refresh(avatarId: newValue)
        }
        .onChange(of: selectedTab) { tab in
            if tab == .profile {
                onSwitchProfile()
            }
        }
        // Re-attempt once the catalog finishes loading, since the first refresh
        // can't resolve the avatar image before then.
        .onReceive(AvatarCatalogStore.shared.$items) { _ in
            profileTabAvatar.refresh(avatarId: displayedProfile?.avatarId)
        }
    }
}

@available(tvOS 27.0, *)
private struct TVSidebarProfileHeader: View {
    let profile: Profile?
    let action: () -> Void

    @FocusState private var isFocused: Bool
    @AppStorage(SettingsKey.profileName) private var settingsProfileName = "Nuvio User"

    var body: some View {
        HStack(spacing: 12) {
            TVSidebarAvatar(profile: profile, isFocused: isFocused)

            VStack(alignment: .leading, spacing: 3) {
                Text(displayName)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .layoutPriority(1)

                if isFocused {
                    Text("Change Profile")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white.opacity(0.72))
                        .lineLimit(1)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .layoutPriority(1)

            Spacer(minLength: 8)

            if !isFocused {
                TimelineView(.periodic(from: Date(), by: 30)) { context in
                    Text(context.date, format: .dateTime.hour().minute())
                        .font(.system(size: 23, weight: .medium))
                        .foregroundColor(.white.opacity(0.68))
                        .lineLimit(1)
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
        .focusable(true)
        .focused($isFocused)
        .focusEffectDisabled()
        .onTapGesture(perform: action)
        .animation(.easeInOut(duration: 0.2), value: isFocused)
    }

    private var displayName: String {
        ProfileDisplayName.resolve(profile: profile, settingsName: settingsProfileName)
    }
}

private struct TVSidebarAvatar: View {
    let profile: Profile?
    let isFocused: Bool

    var body: some View {
        ProfileAvatarView(
            avatarId: profile?.avatarId ?? ProfileAvatarCatalog.defaultId,
            size: 44,
            isFocused: isFocused
        )
        .scaleEffect(isFocused ? 1.12 : 1)
        .offset(y: isFocused ? -3 : 0)
        .shadow(color: .black.opacity(isFocused ? 0.32 : 0), radius: 12, x: 0, y: 8)
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: isFocused)
    }
}

enum ProfileDisplayName {
    static func resolve(profile: Profile?, settingsName: String) -> String {
        if let profileName = profile?.name.trimmingCharacters(in: .whitespacesAndNewlines),
           !profileName.isEmpty {
            return profileName
        }
        let trimmed = settingsName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Nuvio User" : trimmed
    }
}

/// Clips only the top and bottom edges, leaving the horizontal axis unclipped.
/// The rows container needs vertical clipping (so rows scrolled above/below the
/// window are hidden) but must NOT clip horizontally -- each card strip already
/// extends itself to the physical screen edges, and a plain `.clipped()` here
/// would re-cut the cards at the safe-area margin, making them clip mid-screen
/// instead of sliding off behind the bezel.
private struct VerticalEdgeClip: Shape {
    func path(in rect: CGRect) -> Path {
        Path(rect.insetBy(dx: -10000, dy: 0))
    }
}

/// Per-section measured heights for Home rows. Collection folder rows and
/// catalog poster rows are different heights — using a single max height for
/// vertical offset was scrolling focused catalog rows too far up and clipping
/// their section titles (e.g. "Popular Movies").
private struct HomeRowHeightsKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private final class TVHomeFocusWork {
    var pendingFocusedMeta: NuvioMeta?
    var pendingFocusedFolder: TVCollectionFolderItem?
    var pendingSectionId: String?
    var focusSettleTask: Task<Void, Never>?
    var enrichedHeroMetadata: [String: NuvioMeta] = [:]
    var pendingLandscapeFocusedId: String?
    var landscapeFocusTask: Task<Void, Never>?

    func cancelAll() {
        focusSettleTask?.cancel()
        landscapeFocusTask?.cancel()
        focusSettleTask = nil
        landscapeFocusTask = nil
        pendingFocusedMeta = nil
        pendingFocusedFolder = nil
        pendingSectionId = nil
        pendingLandscapeFocusedId = nil
    }
}

/// Keeps each row's horizontal position even when that row is outside the
/// materialized vertical window. This deliberately is not observable: the row
/// owns the live `@State`, and the cache is only read when a row is remounted.
private final class TVHomeRowScrollStore {
    private var indices: [String: Int] = [:]

    func index(for sectionId: String) -> Int {
        indices[sectionId] ?? 0
    }

    func setIndex(_ index: Int, for sectionId: String) {
        indices[sectionId] = index
    }

    func removeAll() {
        indices.removeAll()
    }
}

/// Supplies the native vertical scroll state that tvOS uses to collapse the
/// sidebar pill. Home keeps its catalog rows manually positioned for focus and
/// performance, so this noninteractive scroll view mirrors whether focus is at
/// the top of the catalog without changing Home's visible layout.
private struct HomeTabBarScrollState: View {
    let rowIndex: Int

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        Color.clear
                            .frame(height: geometry.size.height)
                            .id(0)
                        Color.clear
                            .frame(height: geometry.size.height)
                            .id(1)
                    }
                }
                .onAppear {
                    scroll(to: rowIndex, using: proxy)
                }
                .onChange(of: rowIndex) { newValue in
                    scroll(to: newValue, using: proxy)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func scroll(to rowIndex: Int, using proxy: ScrollViewProxy) {
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            proxy.scrollTo(rowIndex == 0 ? 0 : 1, anchor: .top)
        }
    }
}

struct TVHomeView: View {
    /// Failure sets a retry already ran against without improving them, keyed by
    /// the signature itself (which encodes the add-on set, so two profiles never
    /// share a verdict). Static because Home is torn down on every profile
    /// switch, and a per-view copy would forget the verdict exactly when the
    /// next entry needs it. A relaunch clears it, giving a genuinely transient
    /// outage a fresh try.
    @MainActor private static var unimprovedHomeFailures: Set<String> = []

    @ObservedObject var store: TVHomeStore
    let repository: CatalogRepository
    let isActive: Bool
    /// True while a freshly picked profile is being prepared. Keeps Home's own
    /// loader on screen for that whole beat, so the switch shows one screen
    /// instead of a cover handing over to a spinner.
    var isProfileSwitching: Bool = false
    let contentIdentity: TVHomeContentIdentity
    let collectionsRevision: UInt
    let onNavigateToDetails: (String, String) -> Void
    let onOpenCollectionFolder: (TVCollectionFolderItem, String) -> Void
    let onResumePlayback: (ContinueWatchingItem) -> Void
    var onLongPressCard: ((NuvioMeta) -> Void)? = nil
    /// Raised instead of `onLongPressCard` for cards in the Continue Watching
    /// row, which carry resume actions the generic title menu has no use for.
    var onLongPressContinueWatching: ((ContinueWatchingItem) -> Void)? = nil
    /// Asks the account for fresh data when Nuvio Sync owns Continue Watching.
    /// That row is read from the local ledger, so nothing else here would ever
    /// notice a title deleted on another device.
    var onRequestAccountRefresh: () -> Void = {}

    @AppStorage(SettingsKey.amoled) private var amoled = false
    @AppStorage(SettingsKey.bodyColor) private var bodyColor = SettingsBackground.charcoal.rawValue
    @AppStorage(SettingsKey.heroEnabled) private var heroEnabled = true
    @AppStorage(SettingsKey.focusedPosterBackdropEnabled) private var focusedPosterBackdropEnabled = true
    @AppStorage(SettingsKey.focusedPosterBackdropDelay) private var focusedPosterBackdropDelay = 3
    @AppStorage(SettingsKey.fastNavigation) private var fastNavigation = false
    @AppStorage(SettingsKey.hideUnreleased) private var hideUnreleased = false
    @AppStorage(SettingsKey.continueWatchingSort) private var continueWatchingSort = "Default"
    @AppStorage(SettingsKey.upNextFromFurthestEpisode) private var upNextFromFurthestEpisode = true
    @AppStorage(SettingsKey.showUnairedNextUp) private var showUnairedNextUp = true
    @AppStorage(SettingsKey.smoothFocus) private var smoothFocus = true
    @AppStorage(SettingsKey.homeLayout) private var homeLayout = "Modern"
    @AppStorage(SettingsKey.heroCatalogs) private var heroCatalogsData = Data()
    @AppStorage(SettingsKey.posterLabels) private var posterLabels = false
    @AppStorage(SettingsKey.tmdbEnabled) private var tmdbEnabled = false
    @AppStorage(SettingsKey.tmdbLanguage) private var tmdbLanguage = "en"
    @AppStorage(SettingsKey.tmdbUseArtwork) private var tmdbUseArtwork = true
    @AppStorage(SettingsKey.tmdbUseBasicInfo) private var tmdbUseBasicInfo = true
    @AppStorage(SettingsKey.smbLocalRowEnabled) private var smbLocalRowEnabled = true

    /// Hydrated via `repository.getMetadata`, the same path remote catalog
    /// rows use, so TMDB/MDBList enrichment and artwork are identical. `nil`
    /// when there is nothing indexed (or the row is off in Settings) rather
    /// than an empty section, so `visibleSections` never inserts a blank row.
    @State private var localTitlesSection: TVHomeSection?
    @State private var isLoading = true
    @State private var focusedMeta: NuvioMeta?
    /// Collection folder currently focused on Home. When set, the hero shows
    /// emoji + folder title instead of title poster meta/description.
    @State private var focusedCollectionFolder: TVCollectionFolderItem?
    /// Row the settled focus lives in; the hero only shows Continue Watching
    /// context (episode line, time left) for cards focused in that row.
    @State private var focusedSectionId: String?
    @State private var landscapeFocusedId: String?
    @State private var focusWork = TVHomeFocusWork()
    @State private var rowScrollStore = TVHomeRowScrollStore()
    @State private var homeReloadTask: Task<Void, Never>?
    /// Add-on/catalog settings the last completed load actually read.
    @State private var lastLoadedInputSignature: String?
    @State private var continueWatching: [ContinueWatchingItem] = []
    @State private var displayedProgressSource: TraktWatchProgressSource?
    @State private var continueWatchingRefreshGeneration = 0
    @State private var continueWatchingRefreshTask: Task<Void, Never>?
    @State private var isLoadingMoreContinueWatching = false
    /// Rows the current load still owes, rendered as spinner skeletons until
    /// their catalog answers. Empty whenever no load is in flight.
    @State private var homeLoadingPlaceholders: [TVHomeSection] = []
    @State private var watchedTitleKeys: Set<String> = []
    @State private var errorMessage: String?
    @State private var didRequestInitialCardFocus = false
    @State private var shouldRestoreHomeFocus = false
    /// Card to actively re-focus once the Details/Player overlay dismisses.
    /// Captured when the tab view gets disabled (overlay up), consumed when it
    /// is re-enabled. See `restoreOverlayFocus`.
    @State private var overlayRestoreCardID: String?
    /// Increments for every overlay presentation. Delayed focus callbacks from
    /// an older Details/Player return must never clear the next return's focus
    /// lock when the user opens the same card twice in quick succession.
    @State private var overlayRestoreGeneration = 0
    /// Row order as of the last render, so a card that leaves Continue Watching
    /// can be traced back to the slot it occupied. See the retarget below.
    @State private var continueWatchingCardIDs: [String] = []
    @Environment(\.isEnabled) private var isEnabled
    @State private var focusedRowIndex = 0
    /// Explicit destination for an Up/Down move between manually positioned
    /// rows. A row below the vertical clip may be mounted but still invisible
    /// to tvOS spatial focus until it has held focus once, which otherwise
    /// creates a one-way wall partway down Home.
    @State private var verticalMoveTargetCardID: String?
    @State private var verticalMoveGeneration = 0
    /// Measured height per section id (collection vs catalog rows differ).
    @State private var measuredRowHeights: [String: CGFloat] = [:]
    @State private var verticalOffset: CGFloat = 0
    @State private var browsingSection: TVHomeSection?
    @State private var gridHeroIndex = 0
    @State private var didRequestInitialGridHeroFocus = false
    /// The Grid hero owns its own focus state, so `focusedCardID` goes nil while
    /// it is focused. Home still holds focus then, and arming the focus restore
    /// there would let `defaultFocus` reclaim focus the moment Menu tries to
    /// hand it to the sidebar.
    @State private var isGridHeroFocused = false
    /// Suppress the one focus/layout animation caused by returning to Home from
    /// another tab. Normal left/right focus animations remain enabled.
    @State private var suppressReturnFocusAnimations = false
    @State private var returnFocusAnimationGeneration = 0

    private var tmdbHomeSettingsKey: String {
        "\(tmdbEnabled)|\(tmdbLanguage)|\(tmdbUseArtwork)|\(tmdbUseBasicInfo)"
    }
    @FocusState private var isLoadingFocusActive: Bool
    @FocusState private var focusedCardID: String?

    var body: some View {
        ZStack(alignment: .topLeading) {
            HomeTabBarScrollState(rowIndex: focusedRowIndex)

            // 1. Bottom Layer: Full Screen Crossfading Backdrop
            // Collection folder heroes: top-trailing crop (Android TopEnd) so
            // portrait hero art isn't center-cropped with the subject too high.
            CrossfadingBackdrop(
                // Android Grid Home owns a contained 400pt hero backdrop. Keep
                // the full-screen backdrop for Modern/Compact only.
                //
                // While loading there is deliberately no artwork: during a
                // profile switch the backdrop still holds the previous profile's
                // hero, and showing a spinner over someone else's content is the
                // opposite of a clean handover.
                url: showsLoading || homeLayout == "Grid View" ? nil : homeBackdropURL,
                placeholder: Color.nuvioBackground(amoled: amoled, body: bodyColor),
                alignment: focusedCollectionFolder != nil ? .topTrailing : .center
            )
            .ignoresSafeArea()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            // 2. Gradients overlay for backdrop blending and readability.
            // Uses the selected body background color (not pure black) so the
            // chosen theme tint is visible behind the hero on the home screen.
            let backdropColor = Color.nuvioBackground(amoled: amoled, body: bodyColor)
            GeometryReader { proxy in
                LinearGradient(
                    stops: [
                        .init(color: backdropColor.opacity(0.94), location: 0),
                        .init(color: backdropColor.opacity(0.84), location: 0.22),
                        .init(color: backdropColor.opacity(0.52), location: 0.46),
                        .init(color: backdropColor.opacity(0.14), location: 0.76),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: proxy.size.width * 0.58)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
            .ignoresSafeArea()

            GeometryReader { proxy in
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: backdropColor.opacity(0.20), location: 0.42),
                            .init(color: backdropColor.opacity(0.58), location: 0.78),
                            .init(color: backdropColor, location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: proxy.size.height * 0.40)
                }
            }
            .ignoresSafeArea()

            // 3. Scrollable catalog rows overlay, with pinned Hero at the top
            VStack(alignment: .leading, spacing: 0) {
                if showsLoading {
                    TVLoadingView()
                        .overlay {
                            Color.clear
                                .frame(width: 1, height: 1)
                                .focusable(true)
                                .focused($isLoadingFocusActive)
                        }
                        .onAppear {
                            requestLoadingFocus()
                        }
                } else if let errorMessage, store.sections.isEmpty && continueWatching.isEmpty {
                    TVErrorView(message: errorMessage) {
                        homeReloadTask?.cancel()
                        homeReloadTask = Task { @MainActor in
                            await loadWithAutomaticRetry(for: contentIdentity)
                        }
                    }
                } else {
                    // Header Hero Meta block (static, outside the rows). Folder
                    // focus swaps poster meta for emoji + folder title (browse-style).
                    if heroEnabled && homeLayout != "Grid View" {
                        if let folder = focusedCollectionFolder {
                            TVCollectionFolderHeroView(folder: folder)
                        } else if let heroMeta = visibleFocusedMeta ?? visibleHero {
                            TVHeroView(meta: heroMeta, continueItem: heroContinueItem(for: heroMeta)) {
                                onNavigateToDetails(heroMeta.id, heroMeta.type)
                            }
                        }
                    }
                    
                    // Only a small window around the focused row is materialized.
                    // Add-ons can contribute many catalogs (BetterPosters adds 13),
                    // and eagerly mounting every poster in every row makes each
                    // focus update rebuild hundreds of SwiftUI nodes. Fixed-height
                    // placeholders preserve the stack geometry and manual paging
                    // while the focused row plus its neighbours stay focusable.
                    GeometryReader { proxy in
                        let sections = visibleSections.filter(\.hasContent)
                        if homeLayout == "Grid View" {
                            // Grid Home has no row strip to hold open, so a
                            // skeleton there would just be an empty heading.
                            // This proxy is laid out inside the horizontal safe
                            // area, so hand the grid the inset it has to cancel
                            // out for a hero that reaches the screen edges.
                            homeGrid(
                                sections: sections.filter { !$0.isLoadingPlaceholder },
                                heroBleed: max(0, (UIScreen.main.bounds.width - proxy.size.width) / 2)
                            )
                        } else {
                        // Same cadence as the gap under the hero (see TVHeroView
                        // bottom padding + this top padding) so the first section
                        // title does not sit farther from the hero title than
                        // later section titles sit from the row above.
                        VStack(spacing: TVHomeLayout.sectionSpacing) {
                            ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                                if shouldMaterializeHomeRow(index, sectionId: section.id, sections: sections) {
                                    if section.isLoadingPlaceholder {
                                        TVLoadingCatalogRow(title: section.title)
                                            .background(
                                                GeometryReader { rowGeo in
                                                    Color.clear.preference(
                                                        key: HomeRowHeightsKey.self,
                                                        value: [section.id: rowGeo.size.height.rounded()]
                                                    )
                                                }
                                            )
                                    } else if !section.collectionFolders.isEmpty {
                                        TVCollectionFolderRow(
                                            id: section.id,
                                            title: section.title,
                                            folders: section.collectionFolders,
                                            initialScrollIndex: rowScrollStore.index(for: section.id),
                                            onScrollIndexChange: { newIndex in
                                                rowScrollStore.setIndex(newIndex, for: section.id)
                                            },
                                            initialFocusCardKey: initialFocusCardKey,
                                            externalFocus: $focusedCardID,
                                            restrictFocusToCardKey: homeRowFocusRestriction(for: section),
                                            retainFocusAppearanceForCardKey: overlayRestoreCardID,
                                            suppressFocusAnimations: suppressReturnFocusAnimations,
                                            onInitialFocusRequested: {
                                                didRequestInitialCardFocus = true
                                            },
                                            onFocus: { folder in
                                                if focusedRowIndex != index {
                                                    scrollHomeRows(to: index, in: sections)
                                                }
                                                // Row window + card focus update immediately; hero /
                                                // full-screen backdrop wait for settle so horizontal
                                                // paging does not thrash decode + layout each step.
                                                overlayRestoreCardID = nil
                                                let cardKey = "\(section.id)\u{1}\(folder.id)"
                                                focusedCardID = cardKey
                                                settleFolderFocus(folder, in: section.id)
                                            },
                                            onSelect: { folder in
                                                overlayRestoreCardID = "\(section.id)\u{1}\(folder.id)"
                                                onOpenCollectionFolder(folder, section.title)
                                            }
                                        )
                                        .onMoveCommand { direction in
                                            moveFocusVertically(from: index, direction: direction)
                                        }
                                        .background(
                                            GeometryReader { rowGeo in
                                                Color.clear.preference(
                                                    key: HomeRowHeightsKey.self,
                                                    value: [section.id: rowGeo.size.height.rounded()]
                                                )
                                            }
                                        )
                                    } else {
                                    TVCatalogRow(
                                        id: section.id,
                                        title: section.title,
                                        items: section.items,
                                        progressByItemId: section.id == TVHomeSection.continueWatchingId ? continueWatchingByMetaId : [:],
                                        watchedTitleKeys: watchedTitleKeys,
                                        initialScrollIndex: rowScrollStore.index(for: section.id),
                                        onScrollIndexChange: { newIndex in
                                            rowScrollStore.setIndex(newIndex, for: section.id)
                                        },
                                        initialFocusCardKey: initialFocusCardKey,
                                        landscapeFocusedId: landscapeFocusedId(for: section.id),
                                        externalFocus: $focusedCardID,
                                        restrictFocusToCardKey: homeRowFocusRestriction(for: section),
                                        retainFocusAppearanceForCardKey: overlayRestoreCardID,
                                        suppressFocusAnimations: suppressReturnFocusAnimations,
                                        onInitialFocusRequested: {
                                            didRequestInitialCardFocus = true
                                        },
                                        onFocus: { meta in
                                            // Only re-anchor vertically when the
                                            // focused ROW changes -- horizontal
                                            // moves keep the offset rock-steady so
                                            // lower rows don't flicker at the clip.
                                            if focusedRowIndex != index {
                                                scrollHomeRows(to: index, in: sections)
                                            }
                                            // Immediate: focus engine + row window.
                                            // Deferred: hero text + full-screen backdrop.
                                            focusedCardID = "\(section.id)\u{1}\(meta.id)"
                                            settleCatalogFocus(on: meta, in: section.id)
                                            scheduleLandscapeFocus(cardKey: "\(section.id)\u{1}\(meta.id)")
                                        },
                                        onBlur: { meta in
                                            clearLandscapeFocus(cardKey: "\(section.id)\u{1}\(meta.id)")
                                        },
                                        onApproachEnd: { meta in
                                            loadMoreSectionIfNeeded(sectionId: section.id, currentItem: meta)
                                        },
                                        onSelect: { meta in
                                            if section.id == TVHomeSection.continueWatchingId,
                                               let item = continueWatchingByMetaId[meta.id] {
                                                onResumePlayback(item)
                                            } else {
                                                // Latch the visual focus before
                                                // Details takes ownership of the
                                                // focus engine, avoiding a one-
                                                // frame outline flicker on entry.
                                                let cardKey = "\(section.id)\u{1}\(meta.id)"
                                                overlayRestoreCardID = cardKey
                                                onNavigateToDetails(meta.id, meta.type)
                                            }
                                        },
                                        onLongPress: longPressHandler(for: section.id)
                                    )
                                    .onMoveCommand { direction in
                                        moveFocusVertically(from: index, direction: direction)
                                    }
                                    .background(
                                        GeometryReader { rowGeo in
                                            Color.clear.preference(
                                                key: HomeRowHeightsKey.self,
                                                value: [section.id: rowGeo.size.height.rounded()]
                                            )
                                        }
                                    )
                                    } // end catalog vs collection branch
                                } else {
                                    Color.clear
                                        .frame(height: estimatedHeight(for: section))
                                        .accessibilityHidden(true)
                                }
                            }
                        }
                        .padding(.top, TVHomeLayout.rowsTopPadding)
                        .frame(width: proxy.size.width, alignment: .topLeading)
                        .offset(y: verticalOffset)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .clipShape(VerticalEdgeClip())
                    .onPreferenceChange(HomeRowHeightsKey.self) { heights in
                        var changed = false
                        for (id, height) in heights where height > 0 {
                            if abs((measuredRowHeights[id] ?? 0) - height) > 0.5 {
                                measuredRowHeights[id] = height
                                changed = true
                            }
                        }
                        guard changed else { return }
                        let sections = visibleSections.filter(\.hasContent)
                        let target = offsetForRow(focusedRowIndex, in: sections)
                        if target != verticalOffset { verticalOffset = target }
                    }
                    // Treat the rows as a focus section so focus can jump in/out
                    // cleanly. The default focus is only armed after Home loses
                    // focus, so the first Menu press can still reach the sidebar,
                    // while returning from the sidebar restores the saved card.
                    .focusSection()
                    .defaultFocusIfAvailable($focusedCardID, shouldRestoreHomeFocus ? store.lastFocusedCardID : nil)
                }
            }
            // Ignore the bottom safe-area inset too, so the scrolling rows window
            // runs to the screen's bottom edge instead of stopping short and
            // leaving a black bar below the lowest visible row.
            .ignoresSafeArea(.container, edges: [.top, .bottom])

        }
        .task(id: "\(contentIdentity.profileId):\(contentIdentity.catalogRevision):\(tmdbHomeSettingsKey)") {
            await loadWithAutomaticRetry(for: contentIdentity, forceReload: true)
            // Add-on metadata providers are configured by the time Home has
            // loaded, so this is the pass that recovers titles an earlier sync
            // could not resolve. Mirrors the phone's
            // `retryMetadataResolutionWhenAddonMetaProvidersReady`.
            await ContinueWatchingBuilder.rebuild(reason: "home loaded")
            await ContinueWatchingStore.refreshMissingEpisodeDetails()
        }
        .task(id: "\(contentIdentity.profileId):\(collectionsRevision)") {
            await refreshCollectionSections(for: contentIdentity)
        }
        .task(id: "\(contentIdentity.profileId):smbLocalTitles:\(smbLocalRowEnabled)") {
            await loadLocalTitlesSection()
        }
        .onReceive(NotificationCenter.default.publisher(for: SMBLibraryIndex.changedNotification)) { _ in
            Task { await loadLocalTitlesSection() }
        }
        .onAppear {
            #if DEBUG
            print("[ContinueWatching] Home appeared source=\(selectedProgressSource.rawValue)")
            #endif
            // A TabView may recreate Home instead of keeping it mounted. Arm
            // before its saved focus is restored so the first layout pass is
            // already non-animated.
            if isActive, store.lastFocusedCardID != nil {
                armReturnFocusAnimationSuppression()
            }
            // Classic was never a distinct layout; collapse legacy values to Modern.
            if homeLayout == "Classic" { homeLayout = "Modern" }
            refreshContinueWatching()
            refreshWatchedTitles()
            scheduleContinueWatchingRefresh()
        }
        // Grid Home scrolls with a real ScrollView and only moves
        // `focusedRowIndex`; the rows layout positions itself with a manual
        // `verticalOffset` that nothing recomputes on the way back. Switching to
        // Grid, scrolling down, then switching to Modern left the row window
        // centered far down the list while the offset still pointed at the top —
        // an empty viewport with no focusable card, which reads as a freeze.
        .onChange(of: homeLayout) { _ in
            syncRowOffsetToFocusedRow()
        }
        // Home stays mounted behind Details/Player, so `onAppear` no longer
        // fires on return. Refresh the Continue Watching row whenever the store
        // changes (progress saved during playback, item finished/removed).
        .onReceive(NotificationCenter.default.publisher(for: ContinueWatchingStore.changedNotification)) { _ in
            refreshContinueWatching()
        }
        // A removal has to leave the row immediately, including under Trakt/Simkl
        // where the displayed list belongs to the provider and only changes on
        // the next fetch.
        .onReceive(NotificationCenter.default.publisher(for: ContinueWatchingDismissStore.changedNotification)) { _ in
            let remaining = continueWatching.filter { !ContinueWatchingDismissStore.isDismissed($0) }
            if remaining.count != continueWatching.count {
                continueWatching = remaining
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: TraktAuthStore.changedNotification)) { _ in
            scheduleContinueWatchingRefresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: TraktSettingsStore.continueWatchingChangedNotification)) { _ in
            scheduleContinueWatchingRefresh()
        }
        // TabView can keep Home mounted while Settings is selected, so returning
        // to Home does not reliably produce another onAppear.
        .onChange(of: isActive) { active in
            if active {
                // A tab switch can also toggle the environment's `isEnabled`.
                // That is not an overlay dismissal, so discard any focus lock
                // accidentally captured while Home was becoming inactive.
                if overlayRestoreCardID != nil {
                    overlayRestoreGeneration &+= 1
                    overlayRestoreCardID = nil
                }
                // Usually armed while leaving Home. Re-arm here as a fallback
                // for TabView implementations that recreate the selected tab.
                if !suppressReturnFocusAnimations {
                    armReturnFocusAnimationSuppression()
                }
                if focusedCardID != nil {
                    releaseReturnFocusAnimationSuppression()
                }
                #if DEBUG
                logRowWindow("home became active")
                #endif
                scheduleContinueWatchingRefresh()
            } else {
                // Details and Player leave Home selected; a real tab change
                // must never carry their one-card restoration lock back Home.
                overlayRestoreGeneration &+= 1
                overlayRestoreCardID = nil
                // Arm before tvOS removes card focus. Waiting until Home becomes
                // active again is too late: focus restoration has already begun.
                armReturnFocusAnimationSuppression()
            }
        }
        .onChange(of: continueWatchingSort) { _ in
            refreshContinueWatching()
        }
        .onChange(of: hideUnreleased) { _ in
            if usesRemoteProgress {
                scheduleContinueWatchingRefresh()
            } else {
                refreshContinueWatching()
            }
        }
        .onChange(of: showUnairedNextUp) { _ in
            // Local Next Up cards are derived from the episode guide, so the
            // preference must rebuild that row rather than merely re-sort the
            // already materialized cards. Remote rows need a fresh fetch because
            // previously hidden upcoming cards are no longer in view state.
            if usesRemoteProgress {
                scheduleContinueWatchingRefresh()
            } else {
                Task { @MainActor in
                    await ContinueWatchingBuilder.rebuild(reason: "unaired preference changed")
                    refreshContinueWatching()
                }
            }
        }
        .onChange(of: upNextFromFurthestEpisode) { _ in
            if usesRemoteProgress {
                scheduleContinueWatchingRefresh()
            } else {
                Task { @MainActor in
                    await ContinueWatchingBuilder.rebuild(reason: "up next episode preference changed")
                    refreshContinueWatching()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: WatchedStore.changedNotification)) { _ in
            refreshWatchedTitles()
        }
        // Settings → Home Catalogs reorder applies to the mounted Home live.
        .onReceive(NotificationCenter.default.publisher(for: TVHomeCatalogOrder.changedNotification)) { _ in
            let reordered = homeOrderedSections(store.sections)
            if reordered.map(\.id) != store.sections.map(\.id) {
                store.sections = reordered
            }
        }
        // Individual revision changes can arrive while the initial physical-
        // device load is still in flight. Once account sync confirms that all
        // Home inputs have landed, queue one replacement load from that final
        // add-on and catalog-settings snapshot.
        .onReceive(NotificationCenter.default.publisher(for: NuvioSyncManager.homeContentSyncedNotification)) { _ in
            homeReloadTask?.cancel()
            let identity = contentIdentity
            homeReloadTask = Task { @MainActor in
                await reloadHomeAfterSyncedInputs(for: identity)
            }
        }
        .onDisappear {
            #if DEBUG
            print("[ContinueWatching] Home disappeared; cancelling refresh")
            #endif
            focusWork.cancelAll()
            homeReloadTask?.cancel()
            continueWatchingRefreshTask?.cancel()
            continueWatchingRefreshTask = nil
            continueWatchingRefreshGeneration &+= 1
        }
        .onChange(of: isLoading) { loading in
            if loading {
                requestLoadingFocus()
            }
        }
        .onChange(of: focusedPosterBackdropEnabled) { enabled in
            guard !enabled else { return }
            focusWork.pendingLandscapeFocusedId = nil
            focusWork.landscapeFocusTask?.cancel()
            landscapeFocusedId = nil
        }
        .onChange(of: focusedCardID) { newValue in
            if let newValue {
                store.lastFocusedCardID = newValue
                shouldRestoreHomeFocus = false
                if isActive {
                    releaseReturnFocusAnimationSuppression()
                }
                // Restoration complete -- lift the focus restriction.
                if isEnabled, newValue == overlayRestoreCardID {
                    overlayRestoreCardID = nil
                }
            } else if store.lastFocusedCardID != nil, !isGridHeroFocused {
                shouldRestoreHomeFocus = true
            }
        }
        // Leaving the Grid hero for the sidebar has to arm the restore too — it
        // is the only way out of Home that never passes through a card.
        .onChange(of: isGridHeroFocused) { focused in
            if focused {
                shouldRestoreHomeFocus = false
            } else if focusedCardID == nil, store.lastFocusedCardID != nil {
                shouldRestoreHomeFocus = true
            }
        }
        // The tab view is `.disabled` while Details/Player covers it. On
        // dismissal the focus engine re-places focus geometrically (top-left
        // card) WITHOUT consulting the armed `defaultFocus` -- that only fires
        // for scoped entries like coming back from the sidebar. So capture the
        // card when the overlay goes up; while the capture is set every other
        // card is unfocusable (the Settings sidebar trick), so the engine can
        // only land back on the saved card -- no scroll-to-top flash.
        .onChange(of: isEnabled) { enabled in
            // TabView may disable an unselected Home tab. Only Details/Player
            // restoration happens while Home is still the selected tab.
            guard isActive else {
                overlayRestoreGeneration &+= 1
                overlayRestoreCardID = nil
                return
            }
            if !enabled {
                // Home remains mounted underneath full-screen overlays. Disable
                // its focus-driven springs before focus is removed so restoring
                // the saved card cannot bounce the vertical row stack.
                armReturnFocusAnimationSuppression()
                overlayRestoreGeneration &+= 1
                overlayRestoreCardID = focusedCardID ?? store.lastFocusedCardID
            } else if let target = overlayRestoreCardID {
                restoreOverlayFocus(to: target, generation: overlayRestoreGeneration)
            }
        }
        // Removing a card takes the focus capture with it: the restore target
        // still names the card that just left, and because every other card is
        // unfocusable while a capture stands, focus lands nowhere at all. Hand
        // the slot to whatever moved into it instead.
        .onChange(of: continueWatching.map(\.meta.id)) { ids in
            let previous = continueWatchingCardIDs
            continueWatchingCardIDs = ids
            guard let target = overlayRestoreCardID,
                  let removedID = continueWatchingMetaID(inCardKey: target),
                  !ids.contains(removedID),
                  let removedIndex = previous.firstIndex(of: removedID) else { return }

            // Invalidates the in-flight restores aimed at the removed card:
            // they only write focus while their own generation is current.
            overlayRestoreGeneration &+= 1
            guard !ids.isEmpty else {
                // Row is gone entirely. Drop the capture so the engine can place
                // focus itself rather than leaving every card disabled behind a
                // target that will never exist.
                overlayRestoreCardID = nil
                return
            }
            // The card that shifted into the slot, or the new last card when the
            // removed one was at the end.
            let successorID = ids[min(removedIndex, ids.count - 1)]
            let successorKey = "\(TVHomeSection.continueWatchingId)\u{1}\(successorID)"
            overlayRestoreCardID = successorKey
            store.lastFocusedCardID = successorKey
            restoreOverlayFocus(to: successorKey, generation: overlayRestoreGeneration)
        }
        .fullScreenCover(item: $browsingSection) { section in
            TVHomeCatalogBrowseView(
                section: section,
                repository: repository,
                watchedTitleKeys: watchedTitleKeys,
                onDismiss: { browsingSection = nil },
                onSelect: { meta in
                    browsingSection = nil
                    DispatchQueue.main.async {
                        onNavigateToDetails(meta.id, meta.type)
                    }
                },
                onLongPress: onLongPressCard
            )
        }
    }

    /// - Parameter heroBleed: Horizontal safe-area inset this grid sits inside.
    ///   The scroll view gives it back so the hero backdrop runs to the physical
    ///   screen edges; every row below re-applies it so the posters keep the
    ///   gutter the rest of Home uses.
    @ViewBuilder
    private func homeGrid(sections: [TVHomeSection], heroBleed: CGFloat) -> some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: TVHomeGridLayout.sectionSpacing) {
                if heroEnabled && !gridHeroItems.isEmpty {
                    TVGridHeroSlideshowView(
                        items: gridHeroItems,
                        selectedIndex: $gridHeroIndex,
                        shouldRequestInitialFocus: store.lastFocusedCardID == nil
                            && !didRequestInitialCardFocus
                            && !didRequestInitialGridHeroFocus,
                        onInitialFocusRequested: {
                            didRequestInitialGridHeroFocus = true
                            didRequestInitialCardFocus = true
                        },
                        backdropBleed: heroBleed,
                        onFocusChange: { isGridHeroFocused = $0 }
                    ) { selectedMeta in
                        onNavigateToDetails(selectedMeta.id, selectedMeta.type)
                    }
                }

                ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                    if !section.collectionFolders.isEmpty {
                        TVCollectionFolderRow(
                            id: section.id,
                            title: section.title,
                            folders: section.collectionFolders,
                            initialScrollIndex: rowScrollStore.index(for: section.id),
                            onScrollIndexChange: { rowScrollStore.setIndex($0, for: section.id) },
                            initialFocusCardKey: initialFocusCardKey,
                            externalFocus: $focusedCardID,
                            restrictFocusToCardKey: overlayRestoreCardID,
                            retainFocusAppearanceForCardKey: overlayRestoreCardID,
                            suppressFocusAnimations: suppressReturnFocusAnimations,
                            onInitialFocusRequested: { didRequestInitialCardFocus = true },
                            onFocus: { folder in
                                focusedRowIndex = index
                                overlayRestoreCardID = nil
                                focusedCardID = "\(section.id)\u{1}\(folder.id)"
                                settleFolderFocus(folder, in: section.id)
                            },
                            onSelect: { folder in
                                overlayRestoreCardID = "\(section.id)\u{1}\(folder.id)"
                                onOpenCollectionFolder(folder, section.title)
                            }
                        )
                    } else if section.id == TVHomeSection.continueWatchingId {
                        TVCatalogRow(
                            id: section.id,
                            title: section.title,
                            items: section.items,
                            progressByItemId: continueWatchingByMetaId,
                            watchedTitleKeys: watchedTitleKeys,
                            initialScrollIndex: rowScrollStore.index(for: section.id),
                            onScrollIndexChange: { rowScrollStore.setIndex($0, for: section.id) },
                            initialFocusCardKey: initialFocusCardKey,
                            landscapeFocusedId: nil,
                            externalFocus: $focusedCardID,
                            restrictFocusToCardKey: overlayRestoreCardID,
                            retainFocusAppearanceForCardKey: overlayRestoreCardID,
                            suppressFocusAnimations: suppressReturnFocusAnimations,
                            onInitialFocusRequested: { didRequestInitialCardFocus = true },
                            onFocus: { meta in
                                focusedRowIndex = index
                                focusedCardID = "\(section.id)\u{1}\(meta.id)"
                                settleCatalogFocus(on: meta, in: section.id)
                            },
                            onBlur: { _ in },
                            onApproachEnd: { _ in },
                            onSelect: { meta in
                                if let item = continueWatchingByMetaId[meta.id] {
                                    onResumePlayback(item)
                                }
                            },
                            onLongPress: longPressHandler(for: section.id)
                        )
                    } else {
                        TVHomeCatalogGridSection(
                            section: section,
                            watchedTitleKeys: watchedTitleKeys,
                            initialFocusCardKey: initialFocusCardKey,
                            externalFocus: $focusedCardID,
                            restrictFocusToCardKey: overlayRestoreCardID,
                            onInitialFocusRequested: { didRequestInitialCardFocus = true },
                            onFocus: { meta in
                                focusedRowIndex = index
                                focusedCardID = "\(section.id)\u{1}\(meta.id)"
                                settleCatalogFocus(on: meta, in: section.id)
                            },
                            onSelect: { meta in
                                overlayRestoreCardID = "\(section.id)\u{1}\(meta.id)"
                                onNavigateToDetails(meta.id, meta.type)
                            },
                            onLongPress: onLongPressCard,
                            onSeeAllFocus: {
                                focusedRowIndex = index
                                focusedSectionId = section.id
                                focusedCardID = "\(section.id)\u{1}\(TVHomeGridLayout.seeAllID)"
                            },
                            onSeeAll: { browsingSection = section }
                        )
                    }
                }
            }
            // The poster grids have a narrower intrinsic width than the screen.
            // Without this, LazyVStack proposes that width to the hero too,
            // leaving an empty strip along the trailing edge.
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(
                .top,
                heroEnabled && !gridHeroItems.isEmpty ? 0 : TVHomeLayout.rowsTopPadding
            )
            .padding(.bottom, 80)
        }
        .scrollIndicators(.hidden)
        // Lets the hero's backdrop paint past this scroll view's bounds. Only
        // clipping is relaxed — widening the scroll view itself would push its
        // leading edge under the collapsed sidebar, and the focus engine reads
        // that geometry when deciding where a left press should land.
        .scrollClipDisabledIfAvailable()
    }

    /// Nudges focus back to `target` after an overlay dismissal, in case the
    /// engine parked focus outside the rows (hero, sidebar) while the tab view
    /// was still fading in. Two attempts because cards are unfocusable at
    /// near-zero opacity; the trailing clear lifts the card restriction even
    /// if the saved card no longer exists (e.g. Continue Watching reordered),
    /// so the rows can never be left permanently unfocusable.
    /// The meta id inside a Continue Watching card key, or nil for any other row.
    private func continueWatchingMetaID(inCardKey key: String) -> String? {
        let prefix = "\(TVHomeSection.continueWatchingId)\u{1}"
        guard key.hasPrefix(prefix) else { return nil }
        return String(key.dropFirst(prefix.count))
    }

    private func restoreOverlayFocus(to target: String, generation: Int) {
        for delay in [0.12, 0.45] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                if overlayRestoreGeneration == generation, overlayRestoreCardID == target {
                    focusedCardID = target
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if overlayRestoreGeneration == generation, overlayRestoreCardID == target {
                overlayRestoreCardID = nil
            }
        }
    }

    /// The loading spinner should only replace the catalog on a genuine first
    /// load. When returning from a card the sections are already cached in the
    /// store, so we render them straight away instead of flashing the spinner.
    private var showsLoading: Bool {
        // A profile switch holds this on regardless of what is cached: the rows
        // underneath belong to the profile being left, and swapping them in
        // place is what made a switch look like Home assembling itself.
        if isProfileSwitching { return true }
        // Account progress is available before the add-on catalog requests
        // finish. Do not cover a ready Continue Watching row with the global
        // spinner while BetterPosters (or another large add-on) is loading.
        return isLoading && store.sections.isEmpty && continueWatching.isEmpty
    }

    private var firstFocusableSectionId: String? {
        visibleSections.first { $0.hasContent && !$0.isLoadingPlaceholder }?.id
    }

    /// Composite key of the card that should grab focus when the rows appear.
    /// On a fresh load that's the first card; when returning from details it's
    /// the card the user left on (persisted in the store), so focus lands back
    /// exactly where it was — the same behaviour as coming out of the menu.
    private var initialFocusCardKey: String? {
        guard !didRequestInitialCardFocus else { return nil }
        if store.hasLoaded, let saved = store.lastFocusedCardID {
            return saved
        }
        guard let section = visibleSections.first(where: {
            $0.hasContent && !$0.isLoadingPlaceholder
        }) else { return nil }
        if let folder = section.collectionFolders.first {
            return "\(section.id)\u{1}\(folder.id)"
        }
        guard let first = section.items.first else { return nil }
        return "\(section.id)\u{1}\(first.id)"
    }

    /// Catalog poster row estimate (title + strip + labels padding).
    private var estimatedCatalogRowHeight: CGFloat {
        let imageHeight: CGFloat = homeLayout == "Compact" ? 255 : 315
        let stripHeight = imageHeight + (posterLabels ? 48 : 0) + TVHomeLayout.stripVerticalPadding * 2
        // One 30pt Inter title line plus the row's 10pt internal spacing.
        return stripHeight + TVHomeLayout.rowTitleBlock
    }

    /// Collection folder row estimate. Curated templates may hide every folder
    /// label even when poster labels are enabled globally.
    private func estimatedCollectionRowHeight(for section: TVHomeSection) -> CGFloat {
        let imageHeight: CGFloat = homeLayout == "Compact" ? 255 : 315
        let showsLabels = posterLabels && section.collectionFolders.contains { !$0.hideTitle }
        let stripHeight = imageHeight + (showsLabels ? 48 : 0) + TVHomeLayout.stripVerticalPadding * 2
        return stripHeight + TVHomeLayout.rowTitleBlock
    }

    private func estimatedHeight(for section: TVHomeSection) -> CGFloat {
        if let measured = measuredRowHeights[section.id], measured > 0 {
            return measured
        }
        return section.collectionFolders.isEmpty
            ? estimatedCatalogRowHeight
            : estimatedCollectionRowHeight(for: section)
    }

    /// Keep a small working set of Home rows mounted for the focus engine.
    ///
    /// ±1 is enough for a single step, but rapid reverse (up → down → up → down)
    /// demounts the next row before tvOS evaluates the next press, so that press
    /// is eaten and the user has to click again. ±2 keeps one extra row in each
    /// direction so the engine always has a live focus target after a direction
    /// change. Prefer the currently focused section id when it is known so the
    /// window tracks real focus even if `focusedRowIndex` lags by a frame.
    ///
    /// Everything outside the window renders as an unfocusable placeholder, so a
    /// window centred on the wrong row leaves the real focused row with dead
    /// neighbours: the row still scrolls left/right while up/down does nothing.
    /// `focusedRowIndex` is a bare position, and the Continue Watching row
    /// appearing or disappearing (a sync pull, a tab return) renumbers every row
    /// under it. So resolve the centre from identity first — the focused card's
    /// own section, then `focusedSectionId` — and when a card is focused whose
    /// section is nowhere in the list, mount every row rather than guessing. One
    /// pass of extra rows in a rare case is a far better trade than a Home the
    /// user cannot navigate out of.
    private func shouldMaterializeHomeRow(
        _ index: Int,
        sectionId: String,
        sections: [TVHomeSection]
    ) -> Bool {
        let total = sections.count
        guard total > 0 else { return false }

        // A normal Home (including GG's 20 sections) is small enough to keep
        // its row containers stable. Sliding the row window on every Up/Down
        // press removed and recreated hundreds of focusable UIKit descendants,
        // stalling the main thread before the offset animation could start.
        // Card-level virtualization below keeps the retained rows lightweight.
        if total <= 24 { return true }

        let focusedSection = focusedCardID.flatMap { key in
            key.split(separator: "\u{1}", maxSplits: 1).first.map(String.init)
        } ?? focusedSectionId
        let sectionFocusIndex = focusedSection.flatMap { id in
            sections.firstIndex(where: { $0.id == id })
        }

        let center: Int
        if let sectionFocusIndex {
            center = sectionFocusIndex
        } else if focusedSection == nil {
            // Nothing focused yet (first load, or focus is on the hero): the
            // stored row index is all there is, and it is trustworthy because no
            // row can have been renumbered out from under a focus that does not
            // exist.
            center = min(max(focusedRowIndex, 0), total - 1)
        } else {
            return true
        }

        let lower = max(0, center - 2)
        let upper = min(total - 1, center + 2)
        if (lower...upper).contains(index) { return true }

        // A restored focus target can be outside the initial row window.
        let rowPrefix = "\(sectionId)\u{1}"
        return initialFocusCardKey?.hasPrefix(rowPrefix) == true
            || overlayRestoreCardID?.hasPrefix(rowPrefix) == true
            || verticalMoveTargetCardID?.hasPrefix(rowPrefix) == true
    }

    /// Settings-style entry lock for catalog rows. While one row owns focus,
    /// every other row exposes only its horizontally anchored card to tvOS.
    /// That makes the native spatial hop land beneath the catalog title before
    /// `onMoveCommand` runs; entering the row then unlocks all of its cards.
    private func homeRowFocusRestriction(for section: TVHomeSection) -> String? {
        if let overlayRestoreCardID {
            return overlayRestoreCardID
        }

        guard let focusedCardID,
              let currentSectionId = focusedCardID
                .split(separator: "\u{1}", maxSplits: 1)
                .first
                .map(String.init),
              currentSectionId != section.id else {
            return nil
        }

        if !section.collectionFolders.isEmpty {
            let index = min(
                max(rowScrollStore.index(for: section.id), 0),
                section.collectionFolders.count - 1
            )
            return "\(section.id)\u{1}\(section.collectionFolders[index].id)"
        }

        guard !section.items.isEmpty else { return nil }
        let index = min(
            max(rowScrollStore.index(for: section.id), 0),
            section.items.count - 1
        )
        return "\(section.id)\u{1}\(section.items[index].id)"
    }

    /// Routes vertical focus to the target row's anchored card: whichever card
    /// is currently positioned beneath that row's catalog title. Loading
    /// skeletons are skipped because they contain no focusable controls.
    private func moveFocusVertically(from sourceIndex: Int, direction: MoveCommandDirection) {
        let delta: Int
        switch direction {
        case .up:
            delta = -1
        case .down:
            delta = 1
        default:
            return
        }

        let sections = visibleSections.filter(\.hasContent)
        guard sections.indices.contains(sourceIndex), overlayRestoreCardID == nil else { return }

        var targetIndex = sourceIndex + delta
        while sections.indices.contains(targetIndex), sections[targetIndex].isLoadingPlaceholder {
            targetIndex += delta
        }
        guard sections.indices.contains(targetIndex) else { return }

        let targetSection = sections[targetIndex]
        let targetCardID: String
        if !targetSection.collectionFolders.isEmpty {
            let cardIndex = min(
                max(rowScrollStore.index(for: targetSection.id), 0),
                targetSection.collectionFolders.count - 1
            )
            rowScrollStore.setIndex(cardIndex, for: targetSection.id)
            targetCardID = "\(targetSection.id)\u{1}\(targetSection.collectionFolders[cardIndex].id)"
        } else {
            guard !targetSection.items.isEmpty else { return }
            let cardIndex = min(
                max(rowScrollStore.index(for: targetSection.id), 0),
                targetSection.items.count - 1
            )
            rowScrollStore.setIndex(cardIndex, for: targetSection.id)
            targetCardID = "\(targetSection.id)\u{1}\(targetSection.items[cardIndex].id)"
        }

        verticalMoveGeneration &+= 1
        let generation = verticalMoveGeneration
        verticalMoveTargetCardID = targetCardID

        // Match horizontal paging: move focus immediately and let the focused
        // card's callback drive the row offset. Reassert once on the next turn
        // so a late spatial-focus update cannot undo a fast Up/Down press.
        focusedCardID = targetCardID
        DispatchQueue.main.async {
            guard verticalMoveGeneration == generation else { return }
            focusedCardID = targetCardID
            verticalMoveTargetCardID = nil
        }
    }

    /// Moves the vertical strip from the destination card's focus callback,
    /// exactly like `TVCatalogRow` updates its horizontal `scrollIndex`.
    /// Keeping animation inside the user-driven update prevents geometry and
    /// restoration corrections from accidentally animating the whole stack.
    private func scrollHomeRows(to index: Int, in sections: [TVHomeSection]) {
        let targetOffset = offsetForRow(index, in: sections)
        let updateScrollPosition = {
            focusedRowIndex = index
            verticalOffset = targetOffset
        }

        if smoothFocus && !suppressReturnFocusAnimations {
            withAnimation(TVHomeLayout.scrollSpring) {
                updateScrollPosition()
            }
        } else {
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) {
                updateScrollPosition()
            }
        }
    }

    /// Vertical translation that lands the row at `index` flush under the hero.
    /// Sums actual/estimated heights of rows above — required because collection
    /// folder rows and catalog poster rows are not the same height.
    /// Realigns the rows layout's manual offset with whichever row currently
    /// holds focus, using the same center `shouldMaterializeHomeRow` picks so the
    /// materialized window and the visible viewport can't disagree.
    private func syncRowOffsetToFocusedRow() {
        let sections = visibleSections.filter(\.hasContent)
        guard !sections.isEmpty else {
            focusedRowIndex = 0
            verticalOffset = 0
            return
        }
        let focusedSection = focusedCardID.flatMap { key in
            key.split(separator: "\u{1}", maxSplits: 1).first.map(String.init)
        } ?? focusedSectionId
        let index = focusedSection.flatMap { id in
            sections.firstIndex(where: { $0.id == id })
        } ?? min(max(focusedRowIndex, 0), sections.count - 1)
        focusedRowIndex = index
        verticalOffset = offsetForRow(index, in: sections)
    }

    private func offsetForRow(_ index: Int, in sections: [TVHomeSection]) -> CGFloat {
        guard index > 0 else { return 0 }
        var y: CGFloat = 0
        let end = min(index, sections.count)
        for i in 0..<end {
            y += estimatedHeight(for: sections[i]) + TVHomeLayout.sectionSpacing
        }
        return -y
    }

    private var visibleSections: [TVHomeSection] {
        let resumeSection = TVHomeSection(
            id: TVHomeSection.continueWatchingId,
            title: "Continue Watching",
            items: continueWatching.map(\.meta)
        )
        let baseSections = continueWatching.isEmpty ? store.sections : [resumeSection] + store.sections
        // Pinned above Continue Watching: files the user already owns on their
        // own network take priority over resume state. Excluded from
        // `TVHomeCatalogOrder` (see `publishHomeSections`) so it can't be
        // reordered/hidden like a catalog row, same as Continue Watching.
        let allSections = (localTitlesSection.map { [$0] } ?? []) + baseSections

        // The common path does not need to copy and filter every add-on row on
        // each focus update. Keep the original copy-on-write item arrays intact.
        guard hideUnreleased else { return allSections }

        let today = ContentReleasePolicy.todayIsoDay()
        return allSections.map { section in
            // Collection folder rows don't carry title posters; leave them intact.
            // Local titles are files the user already owns — a release-date
            // heuristic has no business hiding them.
            if !section.collectionFolders.isEmpty || section.id == TVHomeSection.localTitlesId {
                return section
            }
            var copy = section
            copy.items = section.items.filter {
                !ContentReleasePolicy.isUnreleased($0, today: today)
            }
            return copy
        }
    }

    /// One progress bar per card, and a card is a title — so two rows for the
    /// same series (a remote provider can hand back a playback per episode)
    /// have to collapse rather than trap. `uniqueKeysWithValues` crashes on the
    /// collision; keep the most recent entry, which is the one the card is
    /// meant to resume.
    private var continueWatchingByMetaId: [String: ContinueWatchingItem] {
        Dictionary(continueWatching.map { ($0.meta.id, $0) }) { older, newer in
            newer.lastWatchedAt > older.lastWatchedAt ? newer : older
        }
    }

    /// Held cards in the Continue Watching row open the resume menu; every other
    /// row keeps the generic title menu. A Continue Watching card whose entry has
    /// since gone (the row refreshed mid-press) falls back rather than doing
    /// nothing.
    private func longPressHandler(for sectionId: String) -> ((NuvioMeta) -> Void)? {
        guard sectionId == TVHomeSection.continueWatchingId,
              let onLongPressContinueWatching else {
            return onLongPressCard
        }
        return { meta in
            if let item = continueWatchingByMetaId[meta.id] {
                onLongPressContinueWatching(item)
            } else {
                onLongPressCard?(meta)
            }
        }
    }

    /// Continue Watching context for the hero — only when the focused card is
    /// actually in the Continue Watching row. The same title can also appear in
    /// catalog rows (Popular etc.), where the hero should stay generic.
    private func heroContinueItem(for meta: NuvioMeta) -> ContinueWatchingItem? {
        guard visibleFocusedMeta != nil,
              focusedSectionId == TVHomeSection.continueWatchingId else { return nil }
        return continueWatchingByMetaId[meta.id]
    }

    private var visibleHero: NuvioMeta? {
        guard let hero = store.hero, isVisible(hero) else { return visibleSections.first?.items.first }
        return hero
    }

    private var visibleFocusedMeta: NuvioMeta? {
        guard let focusedMeta, isVisible(focusedMeta) else { return nil }
        return focusedMeta
    }

    /// Featured titles for Grid View's automatic hero. Start with one item from
    /// each catalog for variety, then fill any remaining carousel slots from
    /// the catalog order without duplicates.
    private var gridHeroItems: [NuvioMeta] {
        let catalogSections = visibleSections.filter {
            $0.id != TVHomeSection.continueWatchingId && $0.collectionFolders.isEmpty
        }
        let selectedIDs = (try? JSONDecoder().decode([String].self, from: heroCatalogsData)) ?? []
        let selectedSet = Set(selectedIDs)
        let selectedSections = catalogSections.filter { selectedSet.contains($0.id) }
        // Empty is the default "all catalogs" state. If saved catalogs are no
        // longer available, also fall back to all rows instead of losing Hero.
        let heroSections = selectedSet.isEmpty || selectedSections.isEmpty
            ? catalogSections
            : selectedSections
        var seen: Set<String> = []
        var result: [NuvioMeta] = []

        func appendIfNeeded(_ item: NuvioMeta) {
            let key = "\(item.type.lowercased())\u{1f}\(item.id)"
            guard seen.insert(key).inserted else { return }
            result.append(item)
        }

        for section in heroSections {
            if let first = section.items.first { appendIfNeeded(first) }
            if result.count == TVHomeGridLayout.heroPageLimit { return result }
        }
        for section in heroSections {
            for item in section.items {
                appendIfNeeded(item)
                if result.count == TVHomeGridLayout.heroPageLimit { return result }
            }
        }
        return result
    }

    private func landscapeFocusedId(for sectionId: String) -> String? {
        guard let landscapeFocusedId,
              landscapeFocusedId.hasPrefix("\(sectionId)\u{1}") else {
            return nil
        }
        return landscapeFocusedId
    }

    private var homeBackdropURL: String? {
        // Collection folder focus uses its own hero backdrop (Android Modern
        // Home parity). Fall back to the focused/hero title poster otherwise.
        if let folder = focusedCollectionFolder {
            return folder.preferredHeroBackdropURLString
                ?? preferredBackdropURL(for: visibleHero)
        }
        return preferredBackdropURL(for: visibleFocusedMeta) ?? preferredBackdropURL(for: visibleHero)
    }

    private func preferredBackdropURL(for meta: NuvioMeta?) -> String? {
        guard let meta else { return nil }

        // Match PosterCard's landscape artwork selection. BetterPosters catalog
        // entries intentionally contain `poster` without `background`; falling
        // back here keeps the focused card and the Home backdrop in sync.
        for candidate in [meta.backgroundUrl, meta.posterUrl] {
            let url = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !url.isEmpty { return url }
        }
        return nil
    }

    private func isVisible(_ meta: NuvioMeta) -> Bool {
        guard hideUnreleased else { return true }
        return !ContentReleasePolicy.isUnreleased(meta)
    }

    private func shouldDisplayContinueWatchingItem(_ item: ContinueWatchingItem) -> Bool {
        isVisible(item.meta)
            && (showUnairedNextUp || !item.isUpNextEntry || item.hasAired || item.isAiringToday)
            && !ContinueWatchingDismissStore.isDismissed(item)
    }

    private func requestLoadingFocus() {
        DispatchQueue.main.async {
            isLoadingFocusActive = true
        }
    }

    @MainActor
    private func loadWithAutomaticRetry(
        for identity: TVHomeContentIdentity,
        forceReload: Bool = false
    ) async {
        let maximumAttempts = 3
        for attempt in 0..<maximumAttempts {
            await load(for: identity, forceReload: forceReload || attempt > 0)
            guard !Task.isCancelled else { return }
            if store.isLoaded(for: identity) {
                // Add-on rows are best-effort, so a partial response is still
                // useful. Keep it visible, wait briefly, then replace the tree
                // once instead of caching the omission for the whole session.
                guard repository.homeCatalogLoadWasPartial else { return }
                let failure = repository.homeCatalogFailureSignature
                // This recovery is for a transient outage. A failure set an
                // earlier retry already failed to change is permanent -- a dead
                // add-on URL, or a catalog its host always rejects -- and
                // retrying it re-fetches every row from every add-on to recover
                // nothing, on every profile entry for the rest of the session.
                if let failure, Self.unimprovedHomeFailures.contains(failure) { return }
                do {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                } catch {
                    return
                }
                await load(for: identity, forceReload: true)
                if let failure, repository.homeCatalogFailureSignature == failure {
                    Self.unimprovedHomeFailures.insert(failure)
                }
                return
            }
            guard attempt < maximumAttempts - 1 else { return }

            do {
                try await Task.sleep(
                    nanoseconds: UInt64(attempt + 1) * 1_000_000_000
                )
            } catch {
                return
            }
        }
    }

    @MainActor
    private func load(
        for identity: TVHomeContentIdentity,
        forceReload: Bool = false
    ) async {
        // Progress is local/account-synced state and does not depend on the
        // catalog network request below. Publish it first so Home is useful
        // even while a large add-on is still resolving its rows.
        refreshContinueWatching()
        refreshWatchedTitles()

        // Returning from a card: the catalog is still cached in the store, so
        // skip the network round-trip. The saved card re-focuses itself via
        // `initialFocusCardKey`, which restores the row/scroll position too.
        if !forceReload, store.isLoaded(for: identity) {
            isLoading = false
            refreshContinueWatching()
            refreshWatchedTitles()
            return
        }

        let generation = store.beginLoad(for: identity)
        // Captured before the first request so it describes what this load read,
        // not what a settings change mid-flight left behind.
        let inputSignature = repository.homeCatalogInputSignature
        isLoading = true
        errorMessage = nil

        // Collections are already local once account sync applies them. Publish
        // their folder rows before starting provider requests so a slow catalog
        // host cannot hold the user's collections off Home.
        let collectionSections = await loadCollectionSections()
        guard store.isCurrentLoad(generation, for: identity) else { return }
        let previouslyLoadedCatalogSections = store.sections.filter {
            !$0.isCollectionRow
                && !$0.isLoadingPlaceholder
                && isHomeCatalogSectionFromEnabledSource($0)
        }
        // Seeded before the first publish so a cold Home shows its rows'
        // titles and spinning cards immediately, rather than assembling itself
        // row by row under the user.
        homeLoadingPlaceholders = homeSkeletonSections(
            excluding: Set(previouslyLoadedCatalogSections.map(\.id))
                .union(collectionSections.map(\.id))
        )
        publishHomeSections(
            catalogSections: previouslyLoadedCatalogSections,
            collectionSections: collectionSections,
            resetFocusIfEmpty: true
        )

        var receivedCatalogUpdate = false
        do {
            var latestCatalogSections: [TVHomeSection] = []
            for try await catalogs in repository.homeCatalogsProgressively() {
                try Task.checkCancellation()
                guard store.isCurrentLoad(generation, for: identity) else { return }
                let catalogSections = await makeHomeCatalogSections(from: catalogs)
                try Task.checkCancellation()
                guard store.isCurrentLoad(generation, for: identity) else { return }
                latestCatalogSections = catalogSections
                receivedCatalogUpdate = receivedCatalogUpdate || !catalogSections.isEmpty
                let loadedIds = Set(catalogSections.map(\.id))
                let retainedPrevious = previouslyLoadedCatalogSections.filter {
                    !loadedIds.contains($0.id)
                }
                publishHomeSections(
                    // Keep the previous successful tree while this replacement
                    // is still arriving, then publish the exact final result
                    // below. Late rows append without making earlier rows flash.
                    catalogSections: catalogSections + retainedPrevious,
                    collectionSections: collectionSections,
                    resetFocusIfEmpty: true
                )
            }
            guard receivedCatalogUpdate || !collectionSections.isEmpty else {
                throw URLError(.cannotLoadFromNetwork)
            }
            guard store.isCurrentLoad(generation, for: identity) else { return }
            // Every row this load was going to produce has arrived; whatever is
            // still a skeleton is never coming.
            clearHomeLoadingPlaceholders()
            publishHomeSections(
                catalogSections: receivedCatalogUpdate
                    ? latestCatalogSections
                    : previouslyLoadedCatalogSections,
                collectionSections: collectionSections,
                resetFocusIfEmpty: true
            )
            store.finishLoad(generation, for: identity)
            lastLoadedInputSignature = inputSignature
            refreshContinueWatching()
            refreshWatchedTitles()
            isLoading = false
        } catch is CancellationError {
            guard store.isCurrentLoad(generation, for: identity) else { return }
            store.cancelLoad(generation, for: identity)
            clearHomeLoadingPlaceholders()
            isLoading = false
        } catch {
            guard store.isCurrentLoad(generation, for: identity) else { return }
            clearHomeLoadingPlaceholders()
            errorMessage = error.localizedDescription
            // Synced collections or progressively loaded catalogs remain useful
            // even if another provider failed after they were published.
            if receivedCatalogUpdate || !collectionSections.isEmpty {
                store.finishLoad(generation, for: identity)
                lastLoadedInputSignature = inputSignature
            } else {
                store.cancelLoad(generation, for: identity)
            }
            isLoading = false
        }
    }

    @MainActor
    private func reloadHomeAfterSyncedInputs(for identity: TVHomeContentIdentity) async {
        // Do not overlap the revision-owned load. Waiting preserves its useful
        // rows, then forceReload replaces them using the complete synced inputs.
        while store.isLoading(for: identity) {
            do {
                try await Task.sleep(nanoseconds: 200_000_000)
            } catch {
                return
            }
        }
        guard !Task.isCancelled, identity == contentIdentity else { return }
        // The notification means sync finished, not that it changed anything
        // Home reads. When the add-on and catalog settings are byte-identical
        // to the ones the completed load already used, this reload re-fetches
        // every catalog from every add-on to rebuild the same tree.
        guard repository.homeCatalogInputSignature != lastLoadedInputSignature else { return }
        await load(for: identity, forceReload: true)
    }

    @MainActor
    private func makeHomeCatalogSections(from catalogs: [NuvioCatalog]) async -> [TVHomeSection] {
        var loadedSections: [TVHomeSection] = []
        loadedSections.reserveCapacity(catalogs.count)

        for catalog in catalogs {
            guard !Task.isCancelled else { return loadedSections }
            let items: [NuvioMeta]
            let pendingItems: [NuvioMeta]
            let nextSkip: Int
            if let catalogItems = catalog.items {
                let initialItems = Array(catalogItems.prefix(18))
                items = await TmdbDetailsService.localizedMetadata(for: initialItems)
                pendingItems = Array(catalogItems.dropFirst(initialItems.count))
                // The add-on already returned these records, even though Home
                // reveals them in smaller UI batches.
                nextSkip = catalogItems.count
            } else {
                var resolvedItems: [NuvioMeta] = []
                for id in catalog.itemIds.prefix(18) {
                    if let meta = try? await repository.getMetadata(
                        id: id,
                        type: catalog.contentType ?? "movie"
                    ) {
                        resolvedItems.append(meta)
                    }
                }
                items = resolvedItems
                pendingItems = []
                nextSkip = items.count
            }

            let canRequestMore = catalog.contentType != nil && catalog.catalogId != nil
            loadedSections.append(
                TVHomeSection(
                    id: catalog.id,
                    title: catalog.name,
                    items: items,
                    contentType: catalog.contentType,
                    catalogId: catalog.catalogId,
                    addonId: catalog.addonId,
                    addonName: catalog.addonName,
                    catalogGenre: catalog.catalogGenre,
                    pendingItems: pendingItems,
                    nextSkip: nextSkip,
                    hasMore: !items.isEmpty && (!pendingItems.isEmpty || canRequestMore)
                )
            )
        }
        return loadedSections
    }

    /// Pinning is an invariant above the user/catalog order: saved cross-device
    /// row positions may arrange the remainder, but can never push a pinned
    /// collection below a catalog.
    private func homeOrderedSections(_ sections: [TVHomeSection]) -> [TVHomeSection] {
        let pinnedCollections = sections.filter {
            $0.isCollectionRow && $0.isPinnedCollection
        }
        let remainder = sections.filter {
            !($0.isCollectionRow && $0.isPinnedCollection)
        }
        return pinnedCollections + TVHomeCatalogOrder.apply(to: remainder)
    }

    @MainActor
    private func publishHomeSections(
        catalogSections: [TVHomeSection],
        collectionSections: [TVHomeSection],
        resetFocusIfEmpty: Bool
    ) {
        let pinned = collectionSections.filter(\.isPinnedCollection)
        let unpinned = collectionSections.filter { !$0.isPinnedCollection }
        let composed = homeOrderedSections(pinned + catalogSections + unpinned)

        // Rows this load still owes, drawn as skeletons in their saved position.
        let published = Set(composed.map(\.id))
        let skeletons = homeLoadingPlaceholders.filter { !published.contains($0.id) }
        guard !composed.isEmpty || !skeletons.isEmpty else {
            store.sections = []
            store.hero = nil
            return
        }
        let visible = skeletons.isEmpty
            ? composed
            : homeOrderedSections(composed + skeletons)

        // "Empty" means nothing real was on screen yet — skeletons must not
        // count, or the focus seeding below would be skipped once the first
        // genuine row lands.
        let wasEmpty = store.sections.allSatisfy(\.isLoadingPlaceholder)
        // The snapshot is what the next launch seeds skeletons *from*, so only
        // rows that actually resolved belong in it.
        TVHomeCatalogOrder.writeSnapshot(composed)
        store.sections = visible
        store.hero = composed.lazy.compactMap { $0.items.first }.first

        guard wasEmpty && resetFocusIfEmpty else { return }
        store.lastFocusedCardID = nil
        focusedMeta = store.hero
        focusedSectionId = nil
        focusedCollectionFolder = nil
        focusWork.pendingFocusedMeta = focusedMeta
        // Keep folder-hero state clear until a folder card is focused.
        landscapeFocusedId = nil
        focusWork.pendingLandscapeFocusedId = nil
        didRequestInitialCardFocus = false
        shouldRestoreHomeFocus = false
    }

    /// Skeleton rows for catalogs this load has not returned yet, taken from the
    /// last Home's snapshot so each one lands in its saved position.
    ///
    /// Hidden rows survive in that snapshot on purpose — Settings needs them to
    /// offer them back — so they are filtered out here; a row the user removed
    /// must not reappear as a spinner. Collection rows are excluded too: they
    /// come from the local store and are already on screen before the first
    /// catalog request goes out.
    private func homeSkeletonSections(excluding published: Set<String>) -> [TVHomeSection] {
        let hiddenCatalogs = TVHomeCatalogOrder.disabledCatalogKeys()
        let hiddenCollections = TVHomeCatalogOrder.disabledCollectionIds()

        return TVHomeCatalogOrder.snapshotRows().compactMap { row in
            guard !published.contains(row.id),
                  !row.id.hasPrefix(TVHomeSection.collectionIdPrefix),
                  row.id != TVHomeSection.continueWatchingId,
                  !hiddenCollections.contains(row.id),
                  isHomeCatalogSnapshotRowFromEnabledSource(row) else {
                return nil
            }
            if let settingsKey = row.settingsKey, hiddenCatalogs.contains(settingsKey) {
                return nil
            }
            return TVHomeSection(
                id: row.id,
                title: row.title,
                items: [],
                addonName: row.addonName,
                isLoadingPlaceholder: true
            )
        }
    }

    /// A disabled provider must not leave its previous rows or loading
    /// placeholders visible while the replacement Home tree is being built.
    /// Built-in rows have no `addonId`, but their persisted settings key still
    /// carries Cinemeta's manifest id.
    private func isHomeCatalogSectionFromEnabledSource(_ section: TVHomeSection) -> Bool {
        guard section.contentType != nil, section.catalogId != nil else { return true }
        guard section.addonId == nil else { return true }
        return CinemetaCatalogRepository.isCinemetaEnabled
    }

    private func isHomeCatalogSnapshotRowFromEnabledSource(
        _ row: TVHomeCatalogOrder.SnapshotRow
    ) -> Bool {
        guard !CinemetaCatalogRepository.isCinemetaEnabled else { return true }
        return !(row.settingsKey?.hasPrefix("\(CinemetaCatalogRepository.cinemetaAddonId)_") ?? false)
    }

    /// Drops every skeleton, from the pending list and from what is on screen.
    /// A row that failed has to stop spinning, not spin until the next load.
    private func clearHomeLoadingPlaceholders() {
        homeLoadingPlaceholders = []
        guard store.sections.contains(where: \.isLoadingPlaceholder) else { return }
        store.sections = store.sections.filter { !$0.isLoadingPlaceholder }
    }

    /// Builds one Home row per synced collection with emoji/folder cards.
    /// Uses the same vertical paging / spacing rhythm as catalog rows
    /// (`TVHomeLayout`, measured heights, neighbor materialization) so the
    /// next section (e.g. Popular) peeks under a focused collection the same
    /// way catalog rows do — without flattening folders into title posters.
    private func loadCollectionSections() async -> [TVHomeSection] {
        let disabledCollectionIds = TVHomeCatalogOrder.disabledCollectionIds()
        let stored = CollectionsStore.collections()
        var sections: [TVHomeSection] = []
        for collection in stored {
            if disabledCollectionIds.contains(collection.id) {
                print("Home: skip disabled collection id=\(collection.id) title=\(collection.title)")
                continue
            }
            // Keep every folder card — including empty / TMDB / Trakt-only.
            // Previously those were dropped, so a collection with no add-on
            // catalogs never appeared on Home even though sync had it.
            let folders: [TVCollectionFolderItem] = collection.folders.map { folder in
                TVCollectionFolderItem(
                    collectionId: collection.id,
                    folder: folder,
                    sources: folder.resolvedSources,
                    viewMode: collection.viewMode,
                    showAllTab: collection.showAllTab
                )
            }
            if folders.isEmpty {
                print("Home: skip collection with no folders id=\(collection.id) title=\(collection.title)")
                continue
            }
            sections.append(
                TVHomeSection(
                    id: "\(TVHomeSection.collectionIdPrefix)\(collection.id)",
                    title: collection.title,
                    items: [],
                    isPinnedCollection: collection.pinToTop,
                    collectionFolders: folders
                )
            )
        }
        print("Home: \(sections.count)/\(stored.count) collection row(s) from store")
        return sections
    }

    /// Re-resolves collection rows in place after a sync pull / local edit
    /// lands while Home is already loaded, without disturbing catalog rows.
    private func refreshCollectionSections(for identity: TVHomeContentIdentity) async {
        // The revision is retained even if it changes during the initial catalog
        // request. Wait for that identity to finish, then apply the latest store
        // snapshot instead of dropping an early collection update.
        while store.isLoading(for: identity) {
            do {
                try await Task.sleep(nanoseconds: 100_000_000)
            } catch {
                return
            }
        }
        guard store.isLoaded(for: identity) else { return }
        let fresh = await loadCollectionSections()
        guard store.isLoaded(for: identity) else { return }
        let catalogRows = store.sections.filter { !$0.isCollectionRow }
        let pinned = fresh.filter(\.isPinnedCollection)
        let unpinned = fresh.filter { !$0.isPinnedCollection }
        let merged = homeOrderedSections(pinned + catalogRows + unpinned)
        TVHomeCatalogOrder.writeSnapshot(merged)
        // Compare ids *and* folder tile shapes / titles so edits like switching
        // Poster ↔ Landscape actually re-render Home (id-only checks skip them).
        let currentSignature = collectionSectionsSignature(store.sections)
        let nextSignature = collectionSectionsSignature(merged)
        if currentSignature != nextSignature {
            store.sections = merged
        }
    }

    private func collectionSectionsSignature(_ sections: [TVHomeSection]) -> String {
        sections.map { section in
            let folders = section.collectionFolders
                .map {
                    "\($0.id):\($0.tileShape.rawValue):\($0.title):\($0.focusGifEnabled):\($0.focusGifUrl ?? ""):\($0.heroBackdropUrl ?? ""):\($0.titleLogoUrl ?? ""):\($0.viewMode.rawValue):\($0.showAllTab)"
                }
                .joined(separator: ",")
            return "\(section.id)|\(section.title)|\(section.isPinnedCollection)|\(folders)"
        }.joined(separator: ";")
    }

    /// Idle delay before hero text + full-screen backdrop swap. Short enough to
    /// feel responsive when parked, long enough that continuous left/right/up/down
    /// focus does not kick off decode/crossfade every step.
    private var heroSettleNanoseconds: UInt64 {
        fastNavigation ? 120_000_000 : 300_000_000
    }

    /// Catalog title focus: card strip + row offset are immediate; hero/backdrop
    /// publish only after the settle delay (and cancel if focus moves again).
    private func settleCatalogFocus(on meta: NuvioMeta, in sectionId: String) {
        focusWork.pendingFocusedMeta = meta
        focusWork.pendingFocusedFolder = nil
        focusWork.pendingSectionId = sectionId
        scheduleHeroSettle()
    }

    /// Collection folder focus: same freeze as catalog — keep previous hero art
    /// until the user rests on a folder card.
    private func settleFolderFocus(_ folder: TVCollectionFolderItem, in sectionId: String) {
        focusWork.pendingFocusedMeta = nil
        focusWork.pendingFocusedFolder = folder
        focusWork.pendingSectionId = sectionId
        scheduleHeroSettle()
    }

    private func scheduleHeroSettle() {
        focusWork.focusSettleTask?.cancel()

        let targetMetaId = focusWork.pendingFocusedMeta?.id
        let targetFolderId = focusWork.pendingFocusedFolder?.id
        let targetSectionId = focusWork.pendingSectionId
        let hasFolderPending = targetFolderId != nil

        focusWork.focusSettleTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: heroSettleNanoseconds)
            guard !Task.isCancelled else { return }

            if hasFolderPending {
                guard let folder = focusWork.pendingFocusedFolder,
                      folder.id == targetFolderId,
                      let targetSectionId,
                      focusWork.pendingSectionId == targetSectionId else { return }
                // The section is part of the hero state: Continue Watching can
                // change the episode line and description for the same title.
                // Publish it with the settled card, not with the first focus
                // callback during a rapid move.
                focusedSectionId = targetSectionId
                // Publish folder hero only when it actually changes.
                if focusedCollectionFolder?.id != folder.id {
                    focusedCollectionFolder = folder
                }
                if focusedMeta != nil {
                    focusedMeta = nil
                }
                return
            }

            guard let settledMeta = focusWork.pendingFocusedMeta,
                  settledMeta.id == targetMetaId,
                  let targetSectionId,
                  focusWork.pendingSectionId == targetSectionId else { return }

            // Leaving a folder hero: clear only after settle so backdrop stays frozen.
            focusedSectionId = targetSectionId
            if focusedCollectionFolder != nil {
                focusedCollectionFolder = nil
            }
            if focusedMeta?.id != settledMeta.id {
                focusedMeta = settledMeta
            }

            // Third-party catalog responses are often intentionally compact
            // and omit runtime/status. Once focus settles, ask for the full
            // metadata record and fill just those missing hero fields.
            guard settledMeta.needsHeroMetadataEnrichment else { return }
            let enrichmentKey = "\(settledMeta.type.lowercased())\u{1f}\(settledMeta.id)"
            if let fullMeta = focusWork.enrichedHeroMetadata[enrichmentKey] {
                focusedMeta = settledMeta.fillingMissingHeroMetadata(from: fullMeta)
                return
            }

            guard let fullMeta = try? await repository.refreshMetadata(
                      id: settledMeta.id,
                      type: settledMeta.type
                  ) else {
                return
            }
            focusWork.enrichedHeroMetadata[enrichmentKey] = fullMeta
            guard !Task.isCancelled,
                  focusWork.pendingFocusedMeta?.id == targetMetaId,
                  focusWork.pendingFocusedFolder == nil else {
                return
            }
            focusedMeta = settledMeta.fillingMissingHeroMetadata(from: fullMeta)
        }
    }

    @MainActor
    private func loadMoreSectionIfNeeded(sectionId: String, currentItem: NuvioMeta) {
        // The resume row is built locally from the ledger rather than fetched
        // from an add-on catalog, so it pages through its own path.
        if sectionId == TVHomeSection.continueWatchingId {
            loadMoreContinueWatchingIfNeeded(currentItem: currentItem)
            return
        }
        guard let sectionIndex = store.sections.firstIndex(where: { $0.id == sectionId }) else { return }
        let section = store.sections[sectionIndex]
        guard section.hasMore,
              !section.isLoadingMore,
              let contentType = section.contentType,
              let catalogId = section.catalogId,
              let itemIndex = section.items.firstIndex(where: { $0.id == currentItem.id }),
              itemIndex >= max(section.items.count - TVHomeRowPrefetchThreshold, 0) else {
            return
        }

        let requestedSkip = section.nextSkip ?? section.items.count

        // Some add-ons return hundreds of items in their first response. Home
        // mounts them in small batches to keep the horizontal row responsive;
        // reveal those before making another network request.
        if !section.pendingItems.isEmpty {
            let batchCount = min(18, section.pendingItems.count)
            let batch = Array(section.pendingItems.prefix(batchCount))
            let existingIds = Set(section.items.map(\.id))
            store.sections[sectionIndex].items.append(contentsOf: batch.filter { !existingIds.contains($0.id) })
            store.sections[sectionIndex].pendingItems.removeFirst(batchCount)
            store.sections[sectionIndex].hasMore = !store.sections[sectionIndex].pendingItems.isEmpty
                || (section.contentType != nil && section.catalogId != nil)
            return
        }

        store.sections[sectionIndex].isLoadingMore = true

        Task { @MainActor in
            do {
                let page = try await repository.browseCatalog(
                    addonId: section.addonId,
                    contentType: contentType,
                    catalogId: catalogId,
                    skip: requestedSkip,
                    genre: section.catalogGenre
                )

                guard let latestIndex = store.sections.firstIndex(where: { $0.id == sectionId }) else { return }
                let existingIds = Set(store.sections[latestIndex].items.map(\.id))
                let newItems = page.items.filter { !existingIds.contains($0.id) }

                store.sections[latestIndex].items.append(contentsOf: newItems)
                store.sections[latestIndex].nextSkip = page.nextSkip ?? (requestedSkip + page.items.count)
                store.sections[latestIndex].hasMore = page.hasMore && !newItems.isEmpty
                store.sections[latestIndex].isLoadingMore = false
            } catch {
                guard let latestIndex = store.sections.firstIndex(where: { $0.id == sectionId }) else { return }
                store.sections[latestIndex].isLoadingMore = false
            }
        }
    }

    private func scheduleLandscapeFocus(cardKey: String) {
        guard !suppressReturnFocusAnimations, focusedPosterBackdropEnabled else {
            focusWork.pendingLandscapeFocusedId = nil
            landscapeFocusedId = nil
            focusWork.landscapeFocusTask?.cancel()
            return
        }

        if focusWork.pendingLandscapeFocusedId == cardKey && landscapeFocusedId == nil { return }
        if landscapeFocusedId == cardKey { return }

        focusWork.pendingLandscapeFocusedId = cardKey
        if landscapeFocusedId != nil {
            landscapeFocusedId = nil
        }
        focusWork.landscapeFocusTask?.cancel()

        let targetKey = cardKey
        let delaySeconds = max(1, focusedPosterBackdropDelay)
        focusWork.landscapeFocusTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds) * 1_000_000_000)
            guard !Task.isCancelled,
                  focusWork.pendingLandscapeFocusedId == targetKey else {
                return
            }

            landscapeFocusedId = targetKey
        }
    }

    private func armReturnFocusAnimationSuppression() {
        returnFocusAnimationGeneration &+= 1
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            suppressReturnFocusAnimations = true
            landscapeFocusedId = nil
        }
        focusWork.pendingLandscapeFocusedId = nil
        focusWork.landscapeFocusTask?.cancel()
    }

    private func releaseReturnFocusAnimationSuppression() {
        guard suppressReturnFocusAnimations else { return }
        let generation = returnFocusAnimationGeneration

        // Let the restored card and row settle for a couple of frames while
        // animations are disabled, then restore normal navigation motion.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            guard isActive, returnFocusAnimationGeneration == generation else { return }
            suppressReturnFocusAnimations = false

            // Switching tabs leaves `focusedCardID` intact, so coming back
            // from Settings does not emit PosterCard's normal onFocus callback.
            // Restart the landscape settle timer for that retained card once
            // the no-animation restoration window has finished.
            if let focusedCardID {
                scheduleLandscapeFocus(cardKey: focusedCardID)
            }
        }
    }

    private func clearLandscapeFocus(cardKey: String) {
        if focusWork.pendingLandscapeFocusedId == cardKey {
            focusWork.pendingLandscapeFocusedId = nil
            focusWork.landscapeFocusTask?.cancel()
        }

        if landscapeFocusedId == cardKey {
            landscapeFocusedId = nil
        }
    }

    private func refreshContinueWatching() {
        guard !usesRemoteProgress else {
            if displayedProgressSource != selectedProgressSource {
                continueWatching = []
                displayedProgressSource = selectedProgressSource
            }
            #if DEBUG
            logRowWindow("remote progress source (\(selectedProgressSource.rawValue))")
            #endif
            return
        }
        // The store holds the persisted first page and is authoritative — a save
        // during playback lands there immediately. Pages scrolled in beyond it
        // live only in the builder, so merge them back, letting the store win on
        // any title present in both.
        var byId: [String: ContinueWatchingItem] = [:]
        for item in ContinueWatchingBuilder.pagedItems {
            byId[item.meta.id] = item
        }
        for item in ContinueWatchingStore.items() {
            byId[item.meta.id] = item
        }
        // `recencySortDate`, not `lastWatchedAt`: this pass is what the "Default"
        // sort preference ends up being, and a new drop belongs at the top of it
        // on the day it airs rather than wherever the seeding episode's age puts
        // it. They are the same value for every other card.
        let visibleItems = byId.values
            .sorted { $0.recencySortDate > $1.recencySortDate }
            .filter(shouldDisplayContinueWatchingItem)
        continueWatching = ContinueWatchingSortPolicy.sorted(
            visibleItems,
            preference: continueWatchingSort
        )
        displayedProgressSource = .nuvioSync
        #if DEBUG
        logRowWindow("after CW refresh (\(continueWatching.count) item(s))")
        #endif
    }

    #if DEBUG
    /// Reports which rows are focusable versus placeholders, and what the row
    /// window is centred on. Vertical navigation dying on Home means the centre
    /// disagrees with where focus actually is, and that is invisible otherwise.
    private func logRowWindow(_ reason: String) {
        let sections = visibleSections.filter(\.hasContent)
        let focusIndex = focusedSectionId.flatMap { id in
            sections.firstIndex(where: { $0.id == id })
        }
        let materialized = sections.indices.filter {
            shouldMaterializeHomeRow($0, sectionId: sections[$0].id, sections: sections)
        }
        print("[HomeRows] \(reason): focusedCardID=\(focusedCardID ?? "nil") "
            + "focusedSectionId=\(focusedSectionId ?? "nil") focusedRowIndex=\(focusedRowIndex) "
            + "resolvedIndex=\(focusIndex.map(String.init) ?? "NOT FOUND") "
            + "sections=\(sections.map(\.id)) materialized=\(materialized)")
    }
    #endif

    /// Pages in more of the account's history as focus nears the end of the
    /// Continue Watching row, the same way a catalog row loads its next page.
    /// Everything is already in the local ledger, so this only costs metadata
    /// lookups for titles this device has not rendered before.
    private func loadMoreContinueWatchingIfNeeded(currentItem: NuvioMeta) {
        guard !usesRemoteProgress,
              ContinueWatchingBuilder.canLoadMore,
              !isLoadingMoreContinueWatching,
              let index = continueWatching.firstIndex(where: { $0.meta.id == currentItem.id }),
              index >= max(continueWatching.count - TVHomeRowPrefetchThreshold, 0) else {
            return
        }
        isLoadingMoreContinueWatching = true
        Task { @MainActor in
            defer { isLoadingMoreContinueWatching = false }
            _ = await ContinueWatchingBuilder.loadNextPage()
            guard !usesRemoteProgress else { return }
            refreshContinueWatching()
        }
    }

    private func scheduleContinueWatchingRefresh() {
        guard isActive else { return }
        #if DEBUG
        print("[ContinueWatching] Scheduling source=\(selectedProgressSource.rawValue)")
        #endif
        continueWatchingRefreshTask?.cancel()
        continueWatchingRefreshTask = Task {
            await refreshContinueWatchingFromSelectedSource()
        }
    }

    @MainActor
    private func refreshContinueWatchingFromSelectedSource() async {
        continueWatchingRefreshGeneration &+= 1
        let generation = continueWatchingRefreshGeneration
        let profileID = ContinueWatchingStore.activeProfileId
        let source = selectedProgressSource

        #if DEBUG
        print("[ContinueWatching] Refresh \(generation) started source=\(source.rawValue) profile=\(profileID ?? "none")")
        #endif
        refreshContinueWatching()
        guard usesRemoteProgress else {
            #if DEBUG
            print("[ContinueWatching] Refresh \(generation) using local source")
            #endif
            // The ledger this just read is only as fresh as the last account
            // pull. Ask for a new one; it lands via the store's change
            // notification, which already refreshes the row.
            onRequestAccountRefresh()
            return
        }

        let items = await TraktProgressService.fetchContinueWatching(
            repository: repository,
            source: source
        )
        guard !Task.isCancelled else {
            #if DEBUG
            print("[ContinueWatching] Refresh \(generation) discarded: task cancelled")
            #endif
            return
        }
        guard generation == continueWatchingRefreshGeneration else {
            #if DEBUG
            print("[ContinueWatching] Refresh \(generation) discarded: newer generation \(continueWatchingRefreshGeneration)")
            #endif
            return
        }
        guard profileID == ContinueWatchingStore.activeProfileId else {
            #if DEBUG
            print("[ContinueWatching] Refresh \(generation) discarded: profile changed")
            #endif
            return
        }
        guard source == selectedProgressSource, usesRemoteProgress else {
            #if DEBUG
            print("[ContinueWatching] Refresh \(generation) discarded: source changed")
            #endif
            return
        }
        guard let items else {
            #if DEBUG
            print("[ContinueWatching] Refresh \(generation) failed: provider returned nil")
            #endif
            return
        }
        #if DEBUG
        print("[ContinueWatching] Refresh \(generation) displaying \(items.count) items")
        #endif
        // The row shows one card per title, but a remote provider can return a
        // paused playback per episode — two rows for one series otherwise, and
        // a duplicate-key trap downstream. The provider already sorts newest
        // first, so keeping the first occurrence keeps both the order and the
        // episode the user would resume. The local path dedupes the same way.
        var seenMetaIds = Set<String>()
        let visibleItems = items.filter {
            shouldDisplayContinueWatchingItem($0)
                && seenMetaIds.insert($0.meta.id).inserted
        }
        continueWatching = ContinueWatchingSortPolicy.sorted(
            visibleItems,
            preference: continueWatchingSort
        )
        displayedProgressSource = source

        // Continue Watching is visible now. Refresh watched checkmarks afterward
        // so a full history sync never blocks the row during a source switch.
        switch source {
        case .nuvioSync:
            break
        case .trakt:
            _ = await TraktHistoryService.syncWatchedHistory()
        case .simkl:
            _ = await SimklHistoryService.syncWatchedHistory()
        }
    }

    private var selectedProgressSource: TraktWatchProgressSource {
        TraktSettingsStore.watchProgressSource
    }

    private var usesRemoteProgress: Bool {
        RemoteTrackingState.isProgressSourceAuthenticated
    }

    private func refreshWatchedTitles() {
        watchedTitleKeys = Set(
            WatchedStore.visibleItems()
                .filter { $0.season == nil && $0.episode == nil }
                .map { watchedTitleKey(for: $0.meta) }
        )
    }

    private func watchedTitleKey(for meta: NuvioMeta) -> String {
        "\(meta.type.lowercased())\u{1f}\(meta.id)"
    }

    /// Hydrates the "Local titles" row from `SMBLibraryIndex` through the same
    /// `getMetadata` path remote catalog rows use — TMDB/MDBList enrichment,
    /// artwork, and ratings all come along for free. Bounded concurrency keeps
    /// a large library from firing dozens of requests at once; order matches
    /// `SMBLibraryIndex.titles()` (most-recently-configured server first).
    @MainActor
    private func loadLocalTitlesSection() async {
        guard smbLocalRowEnabled else {
            localTitlesSection = nil
            return
        }
        let indexed = SMBLibraryIndex.shared.titles()
        guard !indexed.isEmpty else {
            localTitlesSection = nil
            return
        }

        let maxConcurrent = 6
        var metasByContentId: [String: NuvioMeta] = [:]
        var iterator = indexed.makeIterator()
        await withTaskGroup(of: (String, NuvioMeta?).self) { group in
            func startNext() {
                guard let title = iterator.next() else { return }
                group.addTask { [repository] in
                    let meta = try? await repository.getMetadata(id: title.contentId, type: title.type)
                    return (title.contentId, meta)
                }
            }
            for _ in 0..<maxConcurrent { startNext() }
            while let (contentId, meta) = await group.next() {
                if let meta { metasByContentId[contentId] = meta }
                startNext()
            }
        }

        let metas = indexed.compactMap { metasByContentId[$0.contentId] }
        guard !metas.isEmpty else {
            localTitlesSection = nil
            return
        }
        localTitlesSection = TVHomeSection(
            id: TVHomeSection.localTitlesId,
            title: L10n.string("home_local_titles", fallback: "Local titles"),
            items: metas
        )
    }
}

struct TVHomeSection: Identifiable {
    static let continueWatchingId = "continue_watching"
    /// Local SMB titles, pinned above Continue Watching. Not a catalog row —
    /// excluded from `TVHomeCatalogOrder` reordering/hiding and from hero
    /// selection, same treatment as Continue Watching.
    static let localTitlesId = "local_titles"
    /// Id prefix for rows built from account-synced collections.
    static let collectionIdPrefix = "collection_"

    let id: String
    let title: String
    var items: [NuvioMeta]
    var contentType: String? = nil
    var catalogId: String? = nil
    var addonId: String? = nil
    /// Display name of the add-on this row came from, for the Settings list.
    var addonName: String? = nil
    var catalogGenre: String? = nil
    /// Items already returned by the first add-on response but not mounted yet.
    var pendingItems: [NuvioMeta] = []
    var nextSkip: Int? = nil
    var hasMore: Bool = false
    var isLoadingMore: Bool = false
    /// A row the last Home had, whose catalog request has not answered yet. It
    /// holds the row's place with spinner cards instead of letting the row pop
    /// in underneath the user later. Mirrors the Android app, which seeds the
    /// same skeleton from placeholder items (it shimmers where this spins).
    var isLoadingPlaceholder: Bool = false
    /// Pinned collections render above the standard catalog rows.
    var isPinnedCollection: Bool = false
    /// Folder cards for a collection row (emoji / cover tiles). When non-empty,
    /// Home renders `TVCollectionFolderRow` with the same paging rhythm as
    /// catalog rows; catalogs stay grouped inside folders.
    var collectionFolders: [TVCollectionFolderItem] = []

    var isCollectionRow: Bool { id.hasPrefix(Self.collectionIdPrefix) }
    /// Skeletons count as content so every consumer — row rendering, the
    /// materialization window, paging offsets — sees one list with one set of
    /// indices. The few places that need a *real* row (hero, initial focus)
    /// filter on `isLoadingPlaceholder` instead.
    var hasContent: Bool { !items.isEmpty || !collectionFolders.isEmpty || isLoadingPlaceholder }

    /// The key this row is hidden/shown by, in the account's format. Collections
    /// use `collection_<id>`; catalogs use `<addonId>_<type>_<catalogId>`, with
    /// the built-in rows attributed to Cinemeta since they have no manifest of
    /// their own. Nil for rows that are not a catalog at all (Continue
    /// Watching), which therefore cannot be toggled.
    var catalogSettingsKey: String? {
        if isCollectionRow { return id }
        guard let contentType, let catalogId else { return nil }
        return TVHomeCatalogOrder.catalogSettingsKey(
            addonId: addonId ?? CinemetaCatalogRepository.cinemetaAddonId,
            contentType: contentType,
            catalogId: catalogId
        )
    }
}

/// User-controlled ordering of Home rows (Settings → Layout → Home Catalogs).
/// The saved order lives in the active profile's settings; Home records a
/// titles snapshot on every load so the Settings list can render row names
/// without refetching catalogs.
enum TVHomeCatalogOrder {
    static let changedNotification = Notification.Name("nuvio.tv.homeCatalogOrder.changed")

    static func savedOrder() -> [String] {
        guard let data = ProfileSettings.current.data(forKey: SettingsKey.homeCatalogOrder),
              let keys = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return normalizedOrder(keys)
    }

    static func save(_ keys: [String]) {
        let keys = normalizedOrder(keys)
        guard let data = try? JSONEncoder().encode(keys) else { return }
        ProfileSettings.current.set(data, forKey: SettingsKey.homeCatalogOrder)
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }

    /// Home sections use `addon_<catalog-key>` ids while the account layout
    /// uses the catalog key without that UI prefix. Store the canonical form
    /// locally too, so a locally saved reorder survives the next catalog load.
    private static func normalizedOrder(_ keys: [String]) -> [String] {
        var seen = Set<String>()
        return keys.compactMap { rawKey in
            let key = sectionOrderKey(rawKey)
            guard !key.isEmpty, seen.insert(key).inserted else { return nil }
            return key
        }
    }

    private static func sectionOrderKey(_ id: String) -> String {
        if id.hasPrefix("addon_") {
            return String(id.dropFirst("addon_".count))
        }
        return id
    }

    /// Account catalog keys (`<addonId>_<type>_<catalogId>`) the user has hidden
    /// from Home on another device, pulled from the account. The repository
    /// consults this to drop hidden catalog rows before building Home.
    static func disabledCatalogKeys() -> Set<String> {
        guard let data = ProfileSettings.current.data(forKey: SettingsKey.homeCatalogDisabled),
              let keys = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(keys)
    }

    /// Collection ids the user has hidden from Home on another device.
    static func disabledCollectionIds() -> Set<String> {
        guard let data = ProfileSettings.current.data(forKey: SettingsKey.homeCollectionDisabled),
              let keys = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(keys)
    }

    /// Account catalog keys in the account's Home order → position, used by the
    /// repository to order the add-on catalog rows. Empty when nothing synced.
    static func syncedCatalogOrderIndex() -> [String: Int] {
        guard let data = ProfileSettings.current.data(forKey: SettingsKey.homeCatalogSyncedOrder),
              let keys = try? JSONDecoder().decode([String].self, from: data) else { return [:] }
        var index: [String: Int] = [:]
        for (position, key) in keys.enumerated() where index[key] == nil {
            index[key] = position
        }
        return index
    }

    /// Saved order first (rows the user has placed), then any new rows in
    /// their natural position order — mirrors Android's orderedKeys behavior.
    /// Falls back to the account-synced order when no local reorder exists.
    static func apply(to sections: [TVHomeSection]) -> [TVHomeSection] {
        let localOrder = savedOrder()
        let syncedKeys: [String] = {
            guard let data = ProfileSettings.current.data(forKey: SettingsKey.homeCatalogSyncedOrder),
                  let keys = try? JSONDecoder().decode([String].self, from: data) else { return [] }
            return normalizedOrder(keys)
        }()
        // Prefer the local Settings reorder; otherwise honor the account layout
        // (including `collection_<id>` slots among catalogs).
        let order = localOrder.isEmpty ? syncedKeys : localOrder
        guard !order.isEmpty else { return sections }
        var indexByKey: [String: Int] = [:]
        for (index, key) in order.enumerated() where indexByKey[key] == nil {
            indexByKey[key] = index
        }
        // Catalog rows from addons use `addon_<key>` ids; order keys omit the
        // prefix. Collection rows already use `collection_<id>`.
        func orderKey(for section: TVHomeSection) -> String {
            if section.isCollectionRow { return section.id }
            return sectionOrderKey(section.id)
        }
        let known = sections
            .filter { indexByKey[orderKey(for: $0)] != nil }
            .sorted {
                (indexByKey[orderKey(for: $0)] ?? 0) < (indexByKey[orderKey(for: $1)] ?? 0)
            }
        let unknown = sections.filter { indexByKey[orderKey(for: $0)] == nil }
        return known + unknown
    }

    /// One row as the Settings list needs it: what to call it, which add-on it
    /// came from, and the key that hides it.
    struct SnapshotRow: Equatable {
        let id: String
        let title: String
        let addonName: String?
        let addonId: String?
        let contentType: String?
        let catalogId: String?
        /// Nil for a row that cannot be hidden (Continue Watching).
        let settingsKey: String?
    }

    /// The account's key for a catalog row. Kept here so the repository, Home
    /// and Settings cannot drift into two spellings of the same key.
    static func catalogSettingsKey(addonId: String, contentType: String, catalogId: String) -> String {
        "\(addonId)_\(contentType)_\(catalogId)"
    }

    /// Records the effective rows after a Home load.
    ///
    /// Rows the user has hidden are absent from `sections` — Home never built
    /// them — so they are carried over from the previous snapshot at the index
    /// they last held. Without that, hiding a row also removed it from the
    /// Settings list and there was no way left to bring it back.
    static func writeSnapshot(_ sections: [TVHomeSection]) {
        let hiddenCatalogs = disabledCatalogKeys()
        let hiddenCollections = disabledCollectionIds()
        var rows = sections.map {
            SnapshotRow(
                id: $0.id,
                title: $0.title,
                addonName: $0.addonName,
                addonId: $0.addonId,
                contentType: $0.contentType,
                catalogId: $0.catalogId,
                settingsKey: $0.catalogSettingsKey
            )
        }

        let live = Set(rows.map(\.id))
        for (index, previous) in snapshotRows().enumerated() {
            guard !live.contains(previous.id) else { continue }
            let isHidden = previous.settingsKey.map { key in
                key.hasPrefix(TVHomeSection.collectionIdPrefix)
                    ? hiddenCollections.contains(
                        String(key.dropFirst(TVHomeSection.collectionIdPrefix.count))
                      )
                    : hiddenCatalogs.contains(key)
            } ?? false
            guard isHidden else { continue }
            rows.insert(previous, at: min(index, rows.count))
        }

        writeSnapshotRows(rows)
    }

    /// Keeps the Settings list's snapshot aligned after an in-list move so
    /// re-entering the pane shows the new order even before Home reloads.
    static func writeSnapshotRows(_ rows: [SnapshotRow]) {
        let payload = rows.map { row -> [String: String] in
            var entry = ["id": row.id, "title": row.title]
            if let addonName = row.addonName { entry["addon"] = addonName }
            if let addonId = row.addonId { entry["addonId"] = addonId }
            if let contentType = row.contentType { entry["type"] = contentType }
            if let catalogId = row.catalogId { entry["catalogId"] = catalogId }
            if let settingsKey = row.settingsKey { entry["key"] = settingsKey }
            return entry
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        ProfileSettings.current.set(data, forKey: SettingsKey.homeCatalogTitles)
    }

    /// Rows for the Settings reorder list, from the last Home snapshot.
    static func snapshotRows() -> [SnapshotRow] {
        guard let data = ProfileSettings.current.data(forKey: SettingsKey.homeCatalogTitles),
              let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: String]] else {
            return []
        }
        return rows.compactMap { row in
            guard let id = row["id"], let title = row["title"] else { return nil }
            return SnapshotRow(
                id: id,
                title: title,
                addonName: row["addon"],
                addonId: row["addonId"],
                contentType: row["type"],
                catalogId: row["catalogId"],
                settingsKey: row["key"]
            )
        }
    }

    /// Builds the account payload for the current Home catalog snapshot.
    /// Home's `addon_...` ids are UI-only; sync receives the source add-on id,
    /// media type, catalog id, enabled state, and saved row order.
    static func syncItems() -> [[String: Any]] {
        var items: [[String: Any]] = []
        for row in snapshotRows() {
            guard let settingsKey = row.settingsKey else { continue }

            if settingsKey.hasPrefix(TVHomeSection.collectionIdPrefix) {
                let collectionId = String(settingsKey.dropFirst(TVHomeSection.collectionIdPrefix.count))
                guard !collectionId.isEmpty else { continue }
                items.append([
                    "addon_id": "",
                    "type": "",
                    "catalog_id": "",
                    "enabled": isRowEnabled(row),
                    "order": items.count,
                    "custom_title": "",
                    "is_collection": true,
                    "collection_id": collectionId
                ])
                continue
            }

            let source = catalogSyncSource(for: row)
            guard !source.addonId.isEmpty,
                  !source.contentType.isEmpty,
                  !source.catalogId.isEmpty else { continue }
            items.append([
                "addon_id": source.addonId,
                "type": source.contentType,
                "catalog_id": source.catalogId,
                "enabled": isRowEnabled(row),
                "order": items.count,
                "custom_title": "",
                "is_collection": false,
                "collection_id": ""
            ])
        }
        return items
    }

    private static func catalogSyncSource(
        for row: SnapshotRow
    ) -> (addonId: String, contentType: String, catalogId: String) {
        if let addonId = row.addonId,
           let contentType = row.contentType,
           let catalogId = row.catalogId {
            return (addonId, contentType, catalogId)
        }

        switch row.id {
        case "movie_top": return (CinemetaCatalogRepository.cinemetaAddonId, "movie", "top")
        case "series_top": return (CinemetaCatalogRepository.cinemetaAddonId, "series", "top")
        case "movie_rating": return (CinemetaCatalogRepository.cinemetaAddonId, "movie", "imdbRating")
        case "series_rating": return (CinemetaCatalogRepository.cinemetaAddonId, "series", "imdbRating")
        default: return ("", "", "")
        }
    }

    /// True when the row is currently shown on Home.
    static func isRowEnabled(_ row: SnapshotRow) -> Bool {
        guard let key = row.settingsKey else { return true }
        if key.hasPrefix(TVHomeSection.collectionIdPrefix) {
            let id = String(key.dropFirst(TVHomeSection.collectionIdPrefix.count))
            return !disabledCollectionIds().contains(id)
        }
        return !disabledCatalogKeys().contains(key)
    }

    /// Hides or restores one Home row. Writes the same profile settings the
    /// account pull writes, so the repository drops the row on Home's next load
    /// exactly as it would for a catalog hidden on another device.
    static func setRowEnabled(_ row: SnapshotRow, isEnabled: Bool) {
        guard let key = row.settingsKey else { return }
        if key.hasPrefix(TVHomeSection.collectionIdPrefix) {
            let id = String(key.dropFirst(TVHomeSection.collectionIdPrefix.count))
            var ids = disabledCollectionIds()
            if isEnabled { ids.remove(id) } else { ids.insert(id) }
            persist(ids, forKey: SettingsKey.homeCollectionDisabled)
        } else {
            var keys = disabledCatalogKeys()
            if isEnabled { keys.remove(key) } else { keys.insert(key) }
            persist(keys, forKey: SettingsKey.homeCatalogDisabled)
        }
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }

    private static func persist(_ keys: Set<String>, forKey key: String) {
        guard let data = try? JSONEncoder().encode(Array(keys).sorted()) else { return }
        ProfileSettings.current.set(data, forKey: key)
    }
}

/// Cache key for the profile-scoped inputs that build Home's catalog tree.
/// The sync revision is retained by `NuvioSyncManager`, so Home sees the latest
/// identity even when account sync finishes before this view is mounted.
struct TVHomeContentIdentity: Hashable {
    let profileId: String
    let catalogRevision: UInt
}

/// Holds the Home screen's browsing state outside `TVHomeView` so it survives
/// the details/player push (which tears the view down). Owned by `ContentView`;
/// lets returning from a card restore the cached catalog + the focused card
/// instead of reloading and jumping back to the top.
final class TVHomeStore: ObservableObject {
    @Published var sections: [TVHomeSection] = []
    @Published var hero: NuvioMeta?
    /// True when any last-known-good tree is available. Cache reuse additionally
    /// requires `loadedContentIdentity` to match the requested profile/revision.
    @Published private(set) var hasLoaded = false
    /// Composite "<sectionId>\u{1}<metaId>" key of the last focused card.
    var lastFocusedCardID: String?
    private var loadedContentIdentity: TVHomeContentIdentity?
    private var loadingContentIdentity: TVHomeContentIdentity?
    private var loadGeneration: UInt = 0

    func isLoaded(for identity: TVHomeContentIdentity) -> Bool {
        hasLoaded && loadedContentIdentity == identity
    }

    func isLoading(for identity: TVHomeContentIdentity) -> Bool {
        loadingContentIdentity == identity
    }

    @discardableResult
    func beginLoad(for identity: TVHomeContentIdentity) -> UInt {
        let previousProfileId = loadedContentIdentity?.profileId
            ?? loadingContentIdentity?.profileId
        if let previousProfileId, previousProfileId != identity.profileId {
            sections = []
            hero = nil
            lastFocusedCardID = nil
            loadedContentIdentity = nil
        }

        loadGeneration &+= 1
        loadingContentIdentity = identity
        hasLoaded = false
        return loadGeneration
    }

    func isCurrentLoad(
        _ generation: UInt,
        for identity: TVHomeContentIdentity
    ) -> Bool {
        loadGeneration == generation && loadingContentIdentity == identity
    }

    func finishLoad(
        _ generation: UInt,
        for identity: TVHomeContentIdentity
    ) {
        guard isCurrentLoad(generation, for: identity) else { return }
        loadedContentIdentity = identity
        loadingContentIdentity = nil
        hasLoaded = true
    }

    func cancelLoad(
        _ generation: UInt,
        for identity: TVHomeContentIdentity
    ) {
        guard isCurrentLoad(generation, for: identity) else { return }
        loadingContentIdentity = nil
        hasLoaded = loadedContentIdentity != nil
    }

    func reset() {
        loadGeneration &+= 1
        sections = []
        hero = nil
        hasLoaded = false
        lastFocusedCardID = nil
        loadedContentIdentity = nil
        loadingContentIdentity = nil
    }
}

// Android triggers pagination from the last visible card, six cards from the
// end. tvOS triggers from the focused card instead, so include the roughly six
// cards already visible ahead of focus to give network requests the same runway.
private let TVHomeRowPrefetchThreshold = 12

/// Hero header while a collection folder card is focused.
/// Full-screen backdrop is driven by `homeBackdropURL` (folder hero backdrop).
/// This view only draws the title area: optional title logo, else emoji + name.
///
/// Unlike `TVHeroView` (title + meta + multi-line description that fills the
/// block), folder heroes are a single short line. They must sit at the bottom
/// of the hero frame — where a poster description's last line ends — matching
/// Android Modern Home. A large top padding (copied from poster heroes) was
/// making this line sit too high.
private struct TVCollectionFolderHeroView: View {
    let folder: TVCollectionFolderItem
    @AppStorage(SettingsKey.homeLayout) private var homeLayout = "Modern"

    private var emoji: String? {
        let raw = folder.coverEmoji?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? nil : raw
    }

    private var displayTitle: String {
        folder.title.isEmpty ? "Folder" : folder.title
    }

    private var heroHeight: CGFloat {
        homeLayout == "Compact" ? 390 : 500
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Push the title line to the bottom of the fixed hero frame.
            Spacer(minLength: 0)

            Group {
                if let logoURL = folder.preferredTitleLogoURLString {
                    CachedHeroLogo(url: logoURL, title: displayTitle)
                } else {
                    HStack(alignment: .center, spacing: 18) {
                        if let emoji {
                            Text(emoji)
                                .font(.system(size: 52))
                        } else {
                            Image(systemName: "movieclapper")
                                .font(.system(size: 44, weight: .semibold))
                                .foregroundColor(.white.opacity(0.92))
                        }

                        Text(displayTitle)
                            .font(.custom("Inter-Bold", size: 48))
                            .foregroundColor(.white)
                            .lineLimit(2)
                            .minimumScaleFactor(0.7)
                    }
                }
            }
            .padding(.leading, TVLayout.rowLeading)
            // Match the gap under poster-hero descriptions so the first catalog
            // title sits the same distance below (Android-style).
            .padding(.bottom, TVHomeLayout.heroBottomPadding)
        }
        .foregroundColor(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: heroHeight, alignment: .bottomLeading)
    }
}

private struct TVHeroView: View {
    let meta: NuvioMeta
    /// Continue Watching entry for this title, when one exists. Lets the hero
    /// say which episode is in progress, how much is left, and show the
    /// episode's own overview instead of the series blurb.
    var continueItem: ContinueWatchingItem? = nil
    let onSelect: () -> Void
    @AppStorage(SettingsKey.homeLayout) private var homeLayout = "Modern"

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let logoUrl = meta.logoUrl {
                CachedHeroLogo(url: logoUrl, title: meta.name)
            } else {
                Text(meta.name)
                    .font(.custom("Inter-Bold", size: 54))
                    .lineLimit(2)
                    .foregroundColor(.white)
            }

            TVHeroMetaLine(meta: meta, episodeLine: episodeLine)

            if let continueItem {
                Text(continueItem.isUpNextEntry ? continueItem.upNextBadgeText : continueItem.remainingText.uppercased())
                    .font(.custom("Inter-SemiBold", size: 22))
                    .foregroundColor(.white.opacity(0.66))
            }

            if let description = heroDescription {
                Text(description.wrappedEveryNWords(9))
                    .font(.custom("Inter-Regular", size: 24))
                    .foregroundColor(.white)
                    .lineSpacing(3)
                    .lineLimit(4)
                    .frame(maxWidth: 900, alignment: .leading)
                    .padding(.top, 4)
            }
        }
        .foregroundColor(.white)
        .padding(.leading, TVLayout.rowLeading)
        .padding(.top, homeLayout == "Compact" ? 82 : 140)
        .padding(.bottom, TVHomeLayout.heroBottomPadding)
        .frame(height: homeLayout == "Compact" ? 390 : 500, alignment: .bottomLeading)
    }

    /// "S1 E3 · Title" for the episode in progress; nil for movies or when the
    /// entry predates episode tracking.
    private var episodeLine: String? {
        continueItem?.episodeDisplayLine
    }

    /// Prefer the in-progress episode's overview; fall back to the series/movie
    /// description.
    private var heroDescription: String? {
        if let overview = continueItem?.episodeOverview, !overview.isEmpty {
            return overview
        }
        return meta.description
    }
}

/// Grid View's featured carousel, matching Android TV's `HeroCarousel`: a
/// large near-full-screen banner, local backdrop/gradients, remote paging, Select to
/// open details, and auto-advance only while the hero is not focused.
private struct TVGridHeroSlideshowView: View {
    let items: [NuvioMeta]
    @Binding var selectedIndex: Int
    let shouldRequestInitialFocus: Bool
    let onInitialFocusRequested: () -> Void
    /// Safe-area inset the artwork bleeds past on each side. Only the backdrop
    /// widens — the hero's frame, its text, and the focus geometry stay inside
    /// the safe area.
    var backdropBleed: CGFloat = 0
    var onFocusChange: ((Bool) -> Void)? = nil
    let onSelect: (NuvioMeta) -> Void

    @AppStorage(SettingsKey.amoled) private var amoled = false
    @AppStorage(SettingsKey.bodyColor) private var bodyColor = SettingsBackground.charcoal.rawValue
    @FocusState private var isFocused: Bool

    private var index: Int {
        guard !items.isEmpty else { return 0 }
        return min(max(selectedIndex, 0), items.count - 1)
    }

    private var activeItem: NuvioMeta? { items.indices.contains(index) ? items[index] : nil }

    /// Backdrop + scrims. Drawn as a `background` so it can be widened past the
    /// hero without changing the hero's own frame — the focus engine routes a
    /// left press off that frame, and a hero reaching x=0 sits under the
    /// collapsed sidebar.
    @ViewBuilder
    private func artLayer(_ item: NuvioMeta) -> some View {
        let background = Color.nuvioBackground(amoled: amoled, body: bodyColor)

        ZStack {
            CrossfadingBackdrop(
                url: item.backgroundUrl ?? item.posterUrl,
                placeholder: background,
                alignment: .top
            )

            LinearGradient(
                stops: [
                    .init(color: background.opacity(0.98), location: 0),
                    .init(color: background.opacity(0.88), location: 0.16),
                    .init(color: background.opacity(0.56), location: 0.34),
                    .init(color: background.opacity(0.20), location: 0.56),
                    .init(color: .clear, location: 0.72)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )

            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.30),
                    .init(color: background.opacity(0.50), location: 0.60),
                    .init(color: background.opacity(0.85), location: 0.80),
                    .init(color: background, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .padding(.horizontal, -backdropBleed)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            if let activeItem {
                gridHeroContent(activeItem)
                    .id(activeItem.id)
                    .transition(.opacity)
            }

            if items.count > 1 {
                HStack(spacing: 12) {
                    ForEach(items.indices, id: \.self) { dotIndex in
                        Capsule()
                            .fill(indicatorColor(for: dotIndex))
                            .frame(
                                width: dotIndex == index ? (isFocused ? 48 : 36) : 18,
                                height: isFocused && dotIndex == index ? 6 : 4
                            )
                    }
                }
                .animation(.easeInOut(duration: 0.30), value: index)
                .padding(.bottom, 24)
            }
        }
        .frame(maxWidth: .infinity)
        // Match the tall Android Grid hero. Besides giving the design the same
        // visual weight, this keeps 16:9 artwork from being vertically cropped
        // into an ultra-wide 5:1 strip where the subject disappears.
        .frame(height: 820)
        .clipped()
        // After `clipped()`, so the widened artwork isn't trimmed back to the
        // hero's frame.
        .background {
            if let activeItem { artLayer(activeItem) }
        }
        .contentShape(Rectangle())
        .focusable(true)
        .focusEffectDisabledIfAvailable()
        .focused($isFocused)
        .onAppear {
            guard shouldRequestInitialFocus else { return }
            onInitialFocusRequested()
            DispatchQueue.main.async { isFocused = true }
        }
        .onTapGesture {
            if let activeItem { onSelect(activeItem) }
        }
        .onMoveCommand { direction in
            switch direction {
            case .left where index > 0:
                setIndex(index - 1)
                // The sidebar sits to our left and the focus engine acts on this
                // same press, so paging back would also open the menu. Claim
                // focus again to keep the press here. At index 0 it is left
                // alone, so the first slide still exits to the menu.
                isFocused = true
                DispatchQueue.main.async { isFocused = true }
            case .right where index < items.count - 1:
                setIndex(index + 1)
            default:
                break
            }
        }
        .onChange(of: isFocused) { focused in
            onFocusChange?(focused)
        }
        .task(id: "\(items.map(\.id).joined(separator: "|"))|\(isFocused)") {
            guard items.count > 1 else { return }
            // Android lets the initial GPU/image work settle for 20 seconds,
            // then checks for the next unfocused advance every 10 seconds.
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard !Task.isCancelled else { return }
                if !isFocused { setIndex((index + 1) % items.count) }
            }
        }
        .onChange(of: items.count) { _, count in
            if count == 0 { selectedIndex = 0 }
            else if selectedIndex >= count { selectedIndex = count - 1 }
        }
    }

    @ViewBuilder
    private func gridHeroContent(_ item: NuvioMeta) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let logoURL = item.logoUrl, !logoURL.isEmpty {
                CachedHeroLogo(url: logoURL, title: item.name)
                    .frame(maxHeight: 88, alignment: .leading)
            } else {
                Text(item.name)
                    .font(.custom("Inter-Bold", size: 46))
                    .foregroundColor(.white)
                    .lineLimit(2)
            }

            HStack(spacing: 18) {
                if let rating = item.rating {
                    Text(String(format: "IMDb %.1f", rating))
                }
                if let year = item.year {
                    Text(String(year))
                }
            }
            .font(.custom("Inter-SemiBold", size: 21))
            .foregroundColor(.white.opacity(0.80))

            if let genres = item.genres, !genres.isEmpty {
                HStack(spacing: 10) {
                    ForEach(Array(genres.prefix(3)), id: \.self) { genre in
                        Text(genre)
                            .font(.custom("Inter-Medium", size: 18))
                            .foregroundColor(.white.opacity(0.72))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }

            if let description = item.description, !description.isEmpty {
                Text(description)
                    .font(.custom("Inter-Regular", size: 21))
                    .foregroundColor(.white.opacity(0.72))
                    .lineLimit(2)
                    .lineSpacing(2)
            }
        }
        .frame(maxWidth: 860, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(.leading, TVLayout.rowLeading)
        .padding(.trailing, TVLayout.rowLeading)
        .padding(.bottom, 58)
    }

    private func indicatorColor(for dotIndex: Int) -> Color {
        if dotIndex == index { return AppFocusOutline.color }
        return isFocused ? AppFocusOutline.color.opacity(0.40) : Color.white.opacity(0.30)
    }

    private func setIndex(_ newIndex: Int) {
        withAnimation(.easeInOut(duration: 0.30)) {
            selectedIndex = newIndex
        }
    }
}

private struct CachedHeroLogo: View {
    let url: String
    let title: String

    @State private var image: UIImage?
    @State private var loadedURL: String?
    @State private var outgoingImage: UIImage?
    @State private var outgoingOpacity = 0.0
    @State private var imageOpacity = 1.0

    private var showsLogoImage: Bool {
        image != nil || outgoingImage != nil
    }

    var body: some View {
        // Size to the logo's intrinsic aspect (capped at 520×136) instead of a
        // fixed 114pt slot. A short/wide wordmark centered in a tall frame left
        // a dead band under the title before the first catalog row; text
        // fallback must not reserve that slot either.
        Group {
            if showsLogoImage {
                ZStack(alignment: .bottomLeading) {
                    if let outgoingImage {
                        Image(uiImage: outgoingImage)
                            .resizable()
                            .scaledToFit()
                            .opacity(outgoingOpacity)
                    }
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .opacity(imageOpacity)
                            .id(loadedURL)
                    }
                }
                .frame(maxWidth: 520, maxHeight: 136, alignment: .bottomLeading)
            } else {
                Text(title)
                    .font(.custom("Inter-Bold", size: 54))
                    .lineLimit(2)
                    .foregroundColor(.white)
            }
        }
        .task(id: url) {
            guard url != loadedURL, let imageURL = URL(string: url) else {
                outgoingImage = nil
                outgoingOpacity = 0
                return
            }
            guard let loaded = await BackdropImageCache.shared.image(for: imageURL) else {
                guard !Task.isCancelled else { return }
                image = nil
                loadedURL = nil
                outgoingImage = nil
                outgoingOpacity = 0
                return
            }
            guard !Task.isCancelled else { return }
            let previousImage = image
            if previousImage != nil {
                outgoingImage = previousImage
                outgoingOpacity = 1
            }
            image = loaded
            loadedURL = url
            imageOpacity = previousImage == nil ? 1 : 0

            withAnimation(.easeInOut(duration: 0.14)) {
                imageOpacity = 1
                outgoingOpacity = 0
            }

            try? await Task.sleep(nanoseconds: 140_000_000)
            guard !Task.isCancelled, loadedURL == url else { return }
            outgoingImage = nil
            outgoingOpacity = 0
        }
    }
}

/// A row whose catalog is still in flight: its real title over a strip of
/// spinning cards, sized exactly like `TVCatalogRow` so the row keeps its height
/// and the rows below it do not jump when the real cards arrive.
///
/// The Android app draws this same skeleton with a shimmer sweep; here it is a
/// spinner. Deliberately not focusable — focus lands on the first row that has
/// real titles, so the user is never parked on a card that is about to become
/// something else.
private struct TVLoadingCatalogRow: View {
    let title: String

    @AppStorage(SettingsKey.homeLayout) private var homeLayout = "Modern"
    @AppStorage(SettingsKey.posterLabels) private var posterLabels = false

    private var cardWidth: CGFloat { homeLayout == "Compact" ? 170 : 210 }
    private var cardHeight: CGFloat { homeLayout == "Compact" ? 255 : 315 }
    private var cardSpacing: CGFloat { homeLayout == "Compact" ? 22 : 28 }

    /// Matches `TVCatalogRow.stripHeight`, so swapping a skeleton for the real
    /// row changes nothing about the rows below it.
    private var stripHeight: CGFloat {
        cardHeight + (posterLabels ? 48 : 0) + TVHomeLayout.stripVerticalPadding * 2
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.custom("Inter-Bold", size: 30))
                .foregroundColor(.white)
                .padding(.leading, TVLayout.rowLeading)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Same definite-size window as `TVCatalogRow`: a strip wider than
            // the screen must be clipped here, never allowed to size the parent
            // — that is what used to push the row titles and hero off-screen.
            GeometryReader { geo in
                HStack(alignment: .bottom, spacing: cardSpacing) {
                    // Enough to run past the right edge at either card size, so
                    // the strip reads as a row rather than a few loose tiles.
                    ForEach(0..<9, id: \.self) { _ in
                        LoadingPosterCard(width: cardWidth, height: cardHeight)
                    }
                }
                .padding(.leading, TVLayout.rowLeading)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
                .clipped()
            }
            .frame(height: stripHeight)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TVCatalogRow: View {
    let id: String
    let title: String
    let items: [NuvioMeta]
    var progressByItemId: [String: ContinueWatchingItem] = [:]
    var watchedTitleKeys: Set<String> = []
    var initialScrollIndex: Int = 0
    var onScrollIndexChange: (Int) -> Void = { _ in }
    /// Composite key ("<sectionId>\u{1}<metaId>") of the card that should take
    /// focus on appear — the first card on a fresh load, or the card the user
    /// left on when returning from details.
    let initialFocusCardKey: String?
    let landscapeFocusedId: String?
    var externalFocus: FocusState<String?>.Binding? = nil
    /// While non-nil, every card except this key is unfocusable — the Settings
    /// sidebar trick. Used during overlay-dismiss focus restoration so the
    /// engine can only land on the saved card, never flashing the first one.
    var restrictFocusToCardKey: String? = nil
    /// Separate from focus restriction so row-entry locks do not draw a focus
    /// outline; only overlay restoration retains focused appearance.
    var retainFocusAppearanceForCardKey: String? = nil
    /// Suppresses the one focus/layout animation caused by returning to Home
    /// from another tab. Normal left/right focus animation remains enabled.
    var suppressFocusAnimations: Bool = false
    let onInitialFocusRequested: () -> Void
    let onFocus: (NuvioMeta) -> Void
    let onBlur: (NuvioMeta) -> Void
    let onApproachEnd: (NuvioMeta) -> Void
    let onSelect: (NuvioMeta) -> Void
    var onLongPress: ((NuvioMeta) -> Void)? = nil

    // Nil means this row was just remounted: render from the cached index on its
    // very first frame instead of briefly drawing at zero. That first-frame jump
    // can make tvOS choose the adjacent poster during rapid vertical reversal.
    @State private var scrollIndex: Int?
    @AppStorage(SettingsKey.homeLayout) private var homeLayout = "Modern"
    @AppStorage(SettingsKey.posterLabels) private var posterLabels = false
    @AppStorage(SettingsKey.smoothFocus) private var smoothFocus = true
    @AppStorage(SettingsKey.focusHighlighter) private var focusHighlighter = false

    private var compactPosterWidth: CGFloat {
        homeLayout == "Compact" ? 170 : 210
    }

    private var rowSpacing: CGFloat {
        homeLayout == "Compact" ? 22 : 28
    }

    // Step between successive (portrait) card leading edges. Only the focused
    // card ever becomes landscape, and that never changes the leading edge of
    // cards before it, so the step is always the portrait width + spacing.
    private var step: CGFloat { compactPosterWidth + rowSpacing }

    private var effectiveScrollIndex: Int {
        scrollIndex ?? initialScrollIndex
    }

    /// Keep a complete visible page ahead plus four cards behind for fast
    /// reverse movement. This fills the row even when the focused Modern card
    /// expands to landscape, while retained row containers keep Up/Down smooth.
    private func materializedCardIndices(visibleCardCount: Int) -> [Int] {
        guard !items.isEmpty else { return [] }
        let focusIndex = min(max(effectiveScrollIndex, 0), items.count - 1)
        var lowerBound = max(0, focusIndex - 4)
        var upperBound = min(items.count - 1, focusIndex + visibleCardCount)

        // Focus restoration targets must exist even if the stored horizontal
        // index has not caught up with the saved card yet.
        let rowPrefix = "\(id)\u{1}"
        for key in [initialFocusCardKey, restrictFocusToCardKey] {
            guard let key, key.hasPrefix(rowPrefix) else { continue }
            let itemID = String(key.dropFirst(rowPrefix.count))
            if let targetIndex = items.firstIndex(where: { $0.id == itemID }) {
                lowerBound = min(lowerBound, targetIndex)
                upperBound = max(upperBound, targetIndex)
            }
        }

        return Array(lowerBound...upperBound)
    }

    // Card height (315) + vertical breathing room for the focus border/shadow.
    private var stripHeight: CGFloat {
        let imageHeight: CGFloat = homeLayout == "Compact" ? 255 : 315
        return imageHeight + (posterLabels ? 48 : 0) + TVHomeLayout.stripVerticalPadding * 2
    }

    private func isWatched(_ item: NuvioMeta) -> Bool {
        let normalizedType = item.type.lowercased()
        guard !["series", "tv", "show", "tvshow"].contains(normalizedType) else {
            return false
        }
        return watchedTitleKeys.contains("\(normalizedType)\u{1f}\(item.id)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Keep the section title above the card strip (landscape art / focus
            // scale can overflow the strip and would otherwise paint over it).
            Text(title)
                .font(.custom("Inter-Bold", size: 30))
                .foregroundColor(.white)
                .padding(.leading, TVLayout.rowLeading)
                .offset(y: 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .zIndex(1)

            cardStrip
                .zIndex(0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // A definite-size clipping window for the cards. A GeometryReader imposes
    // its OWN frame size and never grows to fit its (very wide) child, so the
    // overflowing HStack can no longer blow out the parent width -- which was
    // what hid the row titles and the hero block. The cards still slide inside
    // the window via a manual offset; overflow is clipped.
    private var cardStrip: some View {
        GeometryReader { geo in
            let edgeInset = max(0, geo.frame(in: .global).minX)
            let stripWidth = geo.size.width + edgeInset * 2
            let rowHomeLayout = homeLayout
            let rowPosterLabels = posterLabels
            let rowSmoothFocus = smoothFocus
            let rowFocusHighlighter = focusHighlighter
            let rowCardFocusAnimations = rowSmoothFocus && !suppressFocusAnimations
            let rowPosterWidth: CGFloat = rowHomeLayout == "Compact" ? 170 : 210
            let rowCardSpacing: CGFloat = rowHomeLayout == "Compact" ? 22 : 28
            let visibleCardCount = max(1, Int(ceil(stripWidth / (rowPosterWidth + rowCardSpacing))) + 1)
            let materializedIndices = materializedCardIndices(visibleCardCount: visibleCardCount)

            HStack(alignment: .bottom, spacing: rowCardSpacing) {
                ForEach(materializedIndices, id: \.self) { itemIndex in
                    let item = items[itemIndex]
                    let cardKey = "\(id)\u{1}\(item.id)"
                    let shouldRequestInitialFocus = cardKey == initialFocusCardKey
                    let progressItem = progressByItemId[item.id]
                    PosterCard(
                        meta: item,
                        isLandscape: rowHomeLayout == "Modern" && landscapeFocusedId == cardKey,
                        continueProgress: progressItem?.progress,
                        continueRemainingText: progressItem?.remainingText,
                        continueEpisodeText: progressItem?.episodeLabel,
                        continueEpisodeTitleText: progressItem?.episodeDisplayTitle,
                        continueEpisodeArtworkURL: progressItem?.episodeArtworkURL,
                        continueIsUpNext: progressItem?.isUpNextEntry == true,
                        continueUpNextBadgeText: progressItem?.upNextBadgeText,
                        showsWatchedBadge: id != TVHomeSection.continueWatchingId,
                        shouldRequestInitialFocus: shouldRequestInitialFocus,
                        onInitialFocusRequested: shouldRequestInitialFocus ? onInitialFocusRequested : nil,
                        onFocus: { focused in
                            if effectiveScrollIndex != itemIndex {
                                let updateScrollPosition = {
                                    scrollIndex = itemIndex
                                    onScrollIndexChange(itemIndex)
                                }
                                if rowSmoothFocus && !suppressFocusAnimations {
                                    withAnimation(TVHomeLayout.scrollSpring) {
                                        updateScrollPosition()
                                    }
                                } else {
                                    var transaction = Transaction()
                                    transaction.animation = nil
                                    withTransaction(transaction) {
                                        updateScrollPosition()
                                    }
                                }
                            }
                            onApproachEnd(focused)
                            onFocus(focused)
                        },
                        onBlur: { blurred in
                            onBlur(blurred)
                        },
                        externalFocus: externalFocus,
                        externalFocusValue: cardKey,
                        onLongPress: onLongPress,
                        layoutMode: rowHomeLayout,
                        showPosterLabels: rowPosterLabels,
                        smoothFocusAnimations: rowCardFocusAnimations,
                        focusHighlighterEnabled: rowFocusHighlighter,
                        retainFocusAppearance: retainFocusAppearanceForCardKey == cardKey,
                        isWatched: isWatched(item)
                    ) {
                        onSelect(item)
                    }
                    .disabled(restrictFocusToCardKey != nil && restrictFocusToCardKey != cardKey)
                }
            }
            .padding(.leading, CGFloat(materializedIndices.first ?? 0) * (rowPosterWidth + rowCardSpacing))
            .padding(.vertical, TVHomeLayout.stripVerticalPadding)
            // Pin the focused card's leading edge directly under the title
            // (TVLayout.rowLeading) by translating the strip left scrollIndex steps.
            // The clipping window expands to the physical screen edge while the
            // card offset stays in the row's safe-area coordinate space.
            // tvOS overrides ScrollViewReader.scrollTo (no-op once a card is
            // already on-screen, which the focus engine guarantees), so we
            // position manually -- mirroring the Android TV BringIntoViewSpec.
            .offset(x: edgeInset + TVLayout.rowLeading - CGFloat(effectiveScrollIndex) * (rowPosterWidth + rowCardSpacing))
            .frame(
                width: stripWidth,
                height: (rowHomeLayout == "Compact" ? 255 : 315)
                    + (rowPosterLabels ? 48 : 0)
                    + TVHomeLayout.stripVerticalPadding * 2,
                alignment: .leading
            )
            .clipped()
            .offset(x: -edgeInset)
            // `scrollIndex` is animated explicitly in the focus callback so
            // user navigation still springs while restoration can snap quietly.
            .animation(rowCardFocusAnimations ? TVHomeLayout.scrollSpring : nil, value: landscapeFocusedId)
        }
        .frame(height: stripHeight)
    }
}

private enum TVHomeGridLayout {
    static let columns = 7
    static let rows = 3
    static let previewItemCount = columns * rows - 1
    // Same poster geometry as the See All catalog this grid links into
    // (`CollectionFolderGridMetrics`), so a title is the same size on both.
    static let posterWidth: CGFloat = 210
    static let posterHeight: CGFloat = 315
    static let itemSpacing: CGFloat = 28
    static let sectionSpacing: CGFloat = 54
    static let heroPageLimit = 7
    static let seeAllID = "__see_all__"

    static var gridColumns: [GridItem] {
        Array(
            repeating: GridItem(.fixed(posterWidth), spacing: itemSpacing, alignment: .top),
            count: columns
        )
    }

    static func isWatched(_ item: NuvioMeta, watchedTitleKeys: Set<String>) -> Bool {
        let type = item.type.lowercased()
        guard !["series", "tv", "show", "tvshow"].contains(type) else { return false }
        return watchedTitleKeys.contains("\(type)\u{1f}\(item.id)")
    }
}

/// Three-row Home preview used by the Grid View layout. Every catalog keeps its
/// existing order and title; only its presentation changes to the same 210×315
/// poster geometry used by Search and Library. The eighteenth cell is reserved
/// for See All, so each preview remains exactly six columns by three rows.
private struct TVHomeCatalogGridSection: View {
    let section: TVHomeSection
    let watchedTitleKeys: Set<String>
    let initialFocusCardKey: String?
    var externalFocus: FocusState<String?>.Binding? = nil
    var restrictFocusToCardKey: String? = nil
    var suppressFocusAnimations = false
    let onInitialFocusRequested: () -> Void
    let onFocus: (NuvioMeta) -> Void
    let onSelect: (NuvioMeta) -> Void
    var onLongPress: ((NuvioMeta) -> Void)? = nil
    let onSeeAllFocus: () -> Void
    let onSeeAll: () -> Void

    private var previewItems: [NuvioMeta] {
        Array(section.items.prefix(TVHomeGridLayout.previewItemCount))
    }

    private var seeAllKey: String {
        "\(section.id)\u{1}\(TVHomeGridLayout.seeAllID)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(section.title)
                .font(.custom("Inter-Bold", size: 30))
                .foregroundColor(.white)

            LazyVGrid(
                columns: TVHomeGridLayout.gridColumns,
                alignment: .leading,
                spacing: TVHomeGridLayout.itemSpacing
            ) {
                ForEach(previewItems) { item in
                    let cardKey = "\(section.id)\u{1}\(item.id)"
                    let shouldRequestInitialFocus = cardKey == initialFocusCardKey
                    PosterGridCard(
                        meta: item,
                        width: TVHomeGridLayout.posterWidth,
                        height: TVHomeGridLayout.posterHeight,
                        externalFocus: externalFocus,
                        focusValue: cardKey,
                        retainFocusAppearance: restrictFocusToCardKey == cardKey,
                        isWatched: TVHomeGridLayout.isWatched(item, watchedTitleKeys: watchedTitleKeys),
                        shouldRequestInitialFocus: shouldRequestInitialFocus,
                        onInitialFocusRequested: shouldRequestInitialFocus ? onInitialFocusRequested : nil,
                        onFocus: { onFocus($0) },
                        onLongPress: onLongPress.map { cb in { cb(item) } }
                    ) {
                        onSelect(item)
                    }
                    .disabled(restrictFocusToCardKey != nil && restrictFocusToCardKey != cardKey)
                }

                TVHomeSeeAllCard(
                    title: section.title,
                    externalFocus: externalFocus,
                    externalFocusValue: seeAllKey,
                    retainFocusAppearance: restrictFocusToCardKey == seeAllKey,
                    onFocus: onSeeAllFocus,
                    action: onSeeAll
                )
                .disabled(restrictFocusToCardKey != nil && restrictFocusToCardKey != seeAllKey)
            }
        }
        .padding(.horizontal, TVLayout.rowLeading)
    }
}

private struct TVHomeSeeAllCard: View {
    let title: String
    var externalFocus: FocusState<String?>.Binding? = nil
    let externalFocusValue: String
    var retainFocusAppearance = false
    let onFocus: () -> Void
    let action: () -> Void

    @FocusState private var isFocused: Bool
    @AppStorage(SettingsKey.smoothFocus) private var smoothFocus = true
    @AppStorage(SettingsKey.focusHighlighter) private var focusHighlighter = false

    private var showsFocusedAppearance: Bool { isFocused || retainFocusAppearance }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
    }

    var body: some View {
        Button(action: action) {
            // Same glass plate a portrait collection folder uses for its emoji
            // cover, so the two tile kinds read as one material.
            VStack(spacing: 18) {
                Image(systemName: "rectangle.grid.3x2.fill")
                    .font(.system(size: 48, weight: .medium))
                Text(L10n.string("action_see_all", fallback: "See All"))
                    .font(.system(size: 24, weight: .bold))
                Text(title)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(.white.opacity(0.58))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
            }
            .foregroundColor(.white)
            .frame(width: TVHomeGridLayout.posterWidth, height: TVHomeGridLayout.posterHeight)
            .modifier(LiquidGlassSurface(cornerRadius: 16, prominent: showsFocusedAppearance))
            .overlay(
                shape.stroke(
                    showsFocusedAppearance ? AppFocusOutline.color : .clear,
                    lineWidth: focusHighlighter ? AppFocusOutline.emphasizedWidth : AppFocusOutline.width
                )
            )
            .shadow(
                color: .black.opacity(showsFocusedAppearance ? 0.5 : 0.2),
                radius: showsFocusedAppearance ? 16 : 6
            )
            .scaleEffect(showsFocusedAppearance ? 1.06 : 1)
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($isFocused)
        .modifier(ExternalFocusBinding(binding: externalFocus, id: externalFocusValue))
        .focusEffectDisabledIfAvailable()
        .onChange(of: isFocused) { focused in
            if focused { onFocus() }
        }
        .animation(smoothFocus ? .spring(response: 0.28, dampingFraction: 0.75) : nil, value: showsFocusedAppearance)
    }
}

/// Full catalog reached from a Home grid's See All tile. It starts with the
/// already-loaded Home items and continues through pending/network pages as the
/// viewer approaches the end, avoiding a duplicate first-page request.
private struct TVHomeCatalogBrowseView: View {
    let section: TVHomeSection
    let repository: CatalogRepository
    let watchedTitleKeys: Set<String>
    let onDismiss: () -> Void
    let onSelect: (NuvioMeta) -> Void
    var onLongPress: ((NuvioMeta) -> Void)? = nil

    @State private var items: [NuvioMeta]
    @State private var pendingItems: [NuvioMeta]
    @State private var nextSkip: Int
    @State private var hasMore: Bool
    @State private var isLoadingMore = false
    @FocusState private var focusedItemID: String?
    @AppStorage(SettingsKey.amoled) private var amoled = false
    @AppStorage(SettingsKey.bodyColor) private var bodyColor = SettingsBackground.charcoal.rawValue
    @AppStorage(SettingsKey.posterLabels) private var posterLabels = false
    @AppStorage(SettingsKey.smoothFocus) private var smoothFocus = true
    @AppStorage(SettingsKey.focusHighlighter) private var focusHighlighter = false

    init(
        section: TVHomeSection,
        repository: CatalogRepository,
        watchedTitleKeys: Set<String>,
        onDismiss: @escaping () -> Void,
        onSelect: @escaping (NuvioMeta) -> Void,
        onLongPress: ((NuvioMeta) -> Void)?
    ) {
        self.section = section
        self.repository = repository
        self.watchedTitleKeys = watchedTitleKeys
        self.onDismiss = onDismiss
        self.onSelect = onSelect
        self.onLongPress = onLongPress
        _items = State(initialValue: section.items)
        _pendingItems = State(initialValue: section.pendingItems)
        _nextSkip = State(initialValue: section.nextSkip ?? section.items.count)
        _hasMore = State(initialValue: section.hasMore || !section.pendingItems.isEmpty)
    }

    var body: some View {
        ZStack {
            Color.nuvioBackground(amoled: amoled, body: bodyColor).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(section.title)
                        .font(.system(size: 42, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text("1 catalog")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(.white.opacity(0.55))
                }
                .padding(.horizontal, 60)
                .padding(.top, 48)

                ScrollView(.vertical) {
                    LazyVGrid(
                        columns: [GridItem(
                            .adaptive(
                                minimum: CollectionFolderGridMetrics.posterWidth,
                                maximum: CollectionFolderGridMetrics.posterWidth
                            ),
                            spacing: CollectionFolderGridMetrics.posterGap,
                            alignment: .top
                        )],
                        alignment: .leading,
                        spacing: CollectionFolderGridMetrics.posterGap
                    ) {
                        ForEach(items) { item in
                            CollectionFolderResultCard(
                                meta: item,
                                externalFocus: $focusedItemID
                            ) {
                                onSelect(item)
                            }
                            .onAppear {
                                loadMoreIfNeeded(currentItem: item)
                            }
                        }

                        if isLoadingMore {
                            ProgressView()
                                .tint(.white)
                                .scaleEffect(1.25)
                                .frame(
                                    width: CollectionFolderGridMetrics.posterWidth,
                                    height: CollectionFolderGridMetrics.posterHeight
                                )
                        }
                    }
                    .padding(.top, 16)
                    .padding(.horizontal, 60)

                    Color.clear.frame(height: 60)
                }
                .scrollIndicators(.hidden)
                .focusSection()
                .defaultFocusIfAvailable($focusedItemID, items.first?.id)
            }
        }
        .onExitCommand(perform: onDismiss)
    }

    @MainActor
    private func loadMoreIfNeeded(currentItem: NuvioMeta) {
        guard hasMore,
              !isLoadingMore,
              let index = items.firstIndex(where: { $0.id == currentItem.id }),
              index >= max(items.count - TVHomeRowPrefetchThreshold, 0) else { return }

        if !pendingItems.isEmpty {
            let batchCount = min(18, pendingItems.count)
            let batch = Array(pendingItems.prefix(batchCount))
            let existingIDs = Set(items.map(\.id))
            items.append(contentsOf: batch.filter { !existingIDs.contains($0.id) })
            pendingItems.removeFirst(batchCount)
            hasMore = !pendingItems.isEmpty || (section.contentType != nil && section.catalogId != nil)
            return
        }

        guard let contentType = section.contentType,
              let catalogId = section.catalogId else {
            hasMore = false
            return
        }

        isLoadingMore = true
        let requestedSkip = nextSkip
        Task { @MainActor in
            defer { isLoadingMore = false }
            do {
                let page = try await repository.browseCatalog(
                    addonId: section.addonId,
                    contentType: contentType,
                    catalogId: catalogId,
                    skip: requestedSkip,
                    genre: section.catalogGenre
                )
                let existingIDs = Set(items.map(\.id))
                let newItems = page.items.filter { !existingIDs.contains($0.id) }
                items.append(contentsOf: newItems)
                nextSkip = page.nextSkip ?? (requestedSkip + page.items.count)
                hasMore = page.hasMore && !newItems.isEmpty
            } catch {
                hasMore = false
            }
        }
    }
}

// MARK: - Collection folder row (Home)

/// Shared sizing for collection folder tiles.
/// All shapes share the same poster height; width varies by `tileShape`
/// (poster / square / landscape) so mixed shapes align on one baseline.
private enum TVCollectionFolderCardLayout {
    static func cardHeight(layoutMode: String) -> CGFloat {
        layoutMode == "Compact" ? 255 : 315
    }

    /// Width from fixed height × shape aspect ratio.
    /// Matches Settings `CollectionTileShapePreview` and keeps landscape/square
    /// the same height as portrait — only wider.
    static func cardWidth(shape: CollectionTileShape, layoutMode: String) -> CGFloat {
        let height = cardHeight(layoutMode: layoutMode)
        switch shape {
        case .poster:
            // Match catalog `PosterCard` portrait width exactly.
            return layoutMode == "Compact" ? 170 : 210
        case .landscape:
            // Match PosterCard's focused Home landscape width exactly.
            return layoutMode == "Compact" ? (height * CGFloat(shape.aspectRatio)).rounded() : 560
        case .square:
            return (height * CGFloat(shape.aspectRatio)).rounded()
        }
    }

    static func rowSpacing(layoutMode: String) -> CGFloat {
        layoutMode == "Compact" ? 22 : 28
    }

    /// Leading-edge offset of the card at `index` (sum of prior widths + gaps).
    static func scrollOffset(
        to index: Int,
        folders: [TVCollectionFolderItem],
        layoutMode: String
    ) -> CGFloat {
        guard index > 0 else { return 0 }
        let spacing = rowSpacing(layoutMode: layoutMode)
        var offset: CGFloat = 0
        let end = min(index, folders.count)
        for i in 0..<end {
            offset += cardWidth(shape: folders[i].tileShape, layoutMode: layoutMode) + spacing
        }
        return offset
    }
}

/// Home row for a synced collection — same structure as `TVCatalogRow`
/// (title + clipping poster strip + horizontal paging). Cards look like
/// `PosterCard`; tap opens the folder instead of title details.
private struct TVCollectionFolderRow: View {
    let id: String
    let title: String
    let folders: [TVCollectionFolderItem]
    let initialScrollIndex: Int
    let onScrollIndexChange: (Int) -> Void
    let initialFocusCardKey: String?
    var externalFocus: FocusState<String?>.Binding? = nil
    var restrictFocusToCardKey: String? = nil
    var retainFocusAppearanceForCardKey: String? = nil
    var suppressFocusAnimations = false
    let onInitialFocusRequested: () -> Void
    let onFocus: (TVCollectionFolderItem) -> Void
    let onSelect: (TVCollectionFolderItem) -> Void

    @State private var scrollIndex: Int = 0
    @AppStorage(SettingsKey.homeLayout) private var homeLayout = "Modern"
    @AppStorage(SettingsKey.posterLabels) private var posterLabels = false
    @AppStorage(SettingsKey.smoothFocus) private var smoothFocus = true
    @AppStorage(SettingsKey.focusHighlighter) private var focusHighlighter = false

    private var rowSpacing: CGFloat {
        TVCollectionFolderCardLayout.rowSpacing(layoutMode: homeLayout)
    }

    private var imageHeight: CGFloat {
        TVCollectionFolderCardLayout.cardHeight(layoutMode: homeLayout)
    }

    /// Same strip math as `TVCatalogRow`.
    private var stripHeight: CGFloat {
        imageHeight + (showsAnyLabels ? 48 : 0) + TVHomeLayout.stripVerticalPadding * 2
    }

    private var showsAnyLabels: Bool {
        posterLabels && folders.contains { !$0.hideTitle }
    }

    /// Match `TVCatalogRow`'s bounded focus graph while accounting for mixed
    /// poster, square, and landscape widths. Keep one complete screen ahead and
    /// four cards behind so the next focus target already exists before tvOS
    /// starts a horizontal move.
    private func materializedCardIndices(
        stripWidth: CGFloat,
        layoutMode: String
    ) -> [Int] {
        guard !folders.isEmpty else { return [] }

        let focusIndex = min(max(scrollIndex, 0), folders.count - 1)
        var lowerBound = max(0, focusIndex - 4)
        var upperBound = focusIndex
        let spacing = TVCollectionFolderCardLayout.rowSpacing(layoutMode: layoutMode)
        var coveredWidth: CGFloat = 0

        while upperBound < folders.count {
            coveredWidth += TVCollectionFolderCardLayout.cardWidth(
                shape: folders[upperBound].tileShape,
                layoutMode: layoutMode
            ) + spacing
            if coveredWidth >= stripWidth { break }
            upperBound += 1
        }
        upperBound = min(upperBound + 1, folders.count - 1)

        // A restored focus target must be mounted even if the persisted scroll
        // index has not caught up with it yet.
        let rowPrefix = "\(id)\u{1}"
        for key in [initialFocusCardKey, restrictFocusToCardKey] {
            guard let key, key.hasPrefix(rowPrefix) else { continue }
            let folderID = String(key.dropFirst(rowPrefix.count))
            if let targetIndex = folders.firstIndex(where: { $0.id == folderID }) {
                lowerBound = min(lowerBound, targetIndex)
                upperBound = max(upperBound, targetIndex)
            }
        }

        return Array(lowerBound...upperBound)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.custom("Inter-Bold", size: 30))
                .foregroundColor(.white)
                .padding(.leading, TVLayout.rowLeading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .zIndex(1)

            cardStrip
                .zIndex(0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            if scrollIndex != initialScrollIndex {
                scrollIndex = initialScrollIndex
            }
        }
    }

    private var cardStrip: some View {
        GeometryReader { geo in
            let edgeInset = max(0, geo.frame(in: .global).minX)
            let stripWidth = geo.size.width + edgeInset * 2
            let rowHomeLayout = homeLayout
            let rowPosterLabels = posterLabels
            let rowSmoothFocus = smoothFocus
            let rowFocusHighlighter = focusHighlighter
            let rowSpacing = TVCollectionFolderCardLayout.rowSpacing(layoutMode: rowHomeLayout)
            let imageHeight = TVCollectionFolderCardLayout.cardHeight(layoutMode: rowHomeLayout)
            let scrollX = TVCollectionFolderCardLayout.scrollOffset(
                to: scrollIndex,
                folders: folders,
                layoutMode: rowHomeLayout
            )
            let materializedIndices = materializedCardIndices(
                stripWidth: stripWidth,
                layoutMode: rowHomeLayout
            )

            HStack(alignment: .bottom, spacing: rowSpacing) {
                ForEach(materializedIndices, id: \.self) { index in
                    let folder = folders[index]
                    let cardKey = "\(id)\u{1}\(folder.id)"
                    let shouldRequestInitialFocus = cardKey == initialFocusCardKey
                    TVCollectionFolderCard(
                        folder: folder,
                        shouldRequestInitialFocus: shouldRequestInitialFocus,
                        onInitialFocusRequested: shouldRequestInitialFocus ? onInitialFocusRequested : nil,
                        externalFocus: externalFocus,
                        externalFocusValue: cardKey,
                        onFocus: {
                            if scrollIndex != index {
                                scrollIndex = index
                                onScrollIndexChange(index)
                            }
                            onFocus(folder)
                        },
                        layoutMode: rowHomeLayout,
                        showPosterLabels: rowPosterLabels,
                        smoothFocusAnimations: rowSmoothFocus,
                        focusHighlighterEnabled: rowFocusHighlighter,
                        retainFocusAppearance: retainFocusAppearanceForCardKey == cardKey,
                        onSelect: { onSelect(folder) }
                    )
                    .disabled(restrictFocusToCardKey != nil && restrictFocusToCardKey != cardKey)
                }
            }
            .padding(
                .leading,
                TVCollectionFolderCardLayout.scrollOffset(
                    to: materializedIndices.first ?? 0,
                    folders: folders,
                    layoutMode: rowHomeLayout
                )
            )
            .padding(.vertical, TVHomeLayout.stripVerticalPadding)
            .offset(x: edgeInset + TVLayout.rowLeading - scrollX)
            .frame(
                width: stripWidth,
                height: imageHeight
                    + (rowPosterLabels && folders.contains { !$0.hideTitle } ? 48 : 0)
                    + TVHomeLayout.stripVerticalPadding * 2,
                alignment: .leading
            )
            .clipped()
            .offset(x: -edgeInset)
            .animation(
                rowSmoothFocus && !suppressFocusAnimations ? TVHomeLayout.scrollSpring : nil,
                value: scrollIndex
            )
        }
        .frame(height: stripHeight)
    }
}

/// Folder tile chrome matching Search / Library cards (`SearchResultCard`):
/// scale on focus, stronger shadow, label styling. Select opens the folder.
private struct TVCollectionFolderCard: View {
    let folder: TVCollectionFolderItem
    var shouldRequestInitialFocus: Bool = false
    var onInitialFocusRequested: (() -> Void)? = nil
    var externalFocus: FocusState<String?>.Binding? = nil
    var externalFocusValue: String? = nil
    var onFocus: (() -> Void)? = nil
    var layoutMode: String = "Modern"
    var showPosterLabels: Bool = false
    var smoothFocusAnimations: Bool = true
    var focusHighlighterEnabled: Bool = false
    var retainFocusAppearance: Bool = false
    let onSelect: () -> Void

    @FocusState private var isFocused: Bool
    @State private var didRequestInitialFocus = false

    private var showFocus: Bool { isFocused || retainFocusAppearance }

    /// All shapes share the same height; landscape/square only widen.
    private var cardWidth: CGFloat {
        TVCollectionFolderCardLayout.cardWidth(shape: folder.tileShape, layoutMode: layoutMode)
    }

    private var cardHeight: CGFloat {
        TVCollectionFolderCardLayout.cardHeight(layoutMode: layoutMode)
    }

    /// Keep the focus surface identical to the visible card, matching normal
    /// collection folders and allowing tvOS to navigate Left natively.
    private var layoutWidth: CGFloat { cardWidth }

    /// Search-style labels use two lines (title + subtitle); reserve space.
    private var totalCardHeight: CGFloat {
        cardHeight + (showPosterLabels && !folder.hideTitle ? 48 : 0)
    }

    private var displayTitle: String {
        let t = folder.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "Folder" : t
    }

    private var subtitle: String {
        let count = folder.sources.count
        return count == 1 ? "1 catalog" : "\(count) catalogs"
    }

    private var cardCornerRadius: CGFloat { 16 }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
    }

    /// Image URL wins when present; otherwise a non-nil `coverEmoji` means the
    /// user picked emoji cover mode (value may still be empty).
    private var coverImageURL: URL? {
        guard let raw = folder.coverImageUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    private var usesEmojiCover: Bool {
        coverImageURL == nil && folder.coverEmoji != nil
    }

    private var usesLogoCoverPresentation: Bool {
        let style = folder.presentationStyle?.uppercased()
        return style == "STREAMING_SERVICE"
            || style == "STUDIO_FRANCHISE"
            || style == "BRAND_COLLECTION"
    }

    private var emojiText: String? {
        let t = folder.coverEmoji?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return t.isEmpty ? nil : t
    }

    private var emojiFontSize: CGFloat {
        min(cardWidth, cardHeight) * 0.28
    }

    private var focusedBorderColor: Color {
        guard showFocus else { return .clear }
        return AppFocusOutline.color
    }

    private var focusedBorderWidth: CGFloat {
        showFocus ? (focusHighlighterEnabled ? AppFocusOutline.emphasizedWidth : AppFocusOutline.width) : 0
    }

    /// Match SearchResultCard / LibraryItemButton shadow.
    private var shadowOpacity: Double { showFocus ? 0.5 : 0.2 }
    private var shadowRadius: CGFloat { showFocus ? 16 : 6 }

    /// Focus GIF overlay — same contract as Android TV: only while focused
    /// (or focus retained under an overlay) and only when enabled + URL set.
    private var focusGifURLString: String? {
        folder.activeFocusGifURLString
    }

    var body: some View {
        // Home rows keep focusable + tap (like PosterCard) so external focus
        // restoration and strip paging stay intact; chrome matches Search cards.
        cardContent
            .contentShape(Rectangle())
            .focusable(true)
            .focused($isFocused)
            .modifier(ExternalFocusBinding(binding: externalFocus, id: externalFocusValue ?? folder.id))
            .focusEffectDisabledIfAvailable()
            .onTapGesture(perform: onSelect)
            .onChange(of: isFocused) { focused in
                if focused { onFocus?() }
            }
            .onAppear {
                guard shouldRequestInitialFocus, !didRequestInitialFocus else { return }
                didRequestInitialFocus = true
                onInitialFocusRequested?()
                DispatchQueue.main.async {
                    isFocused = true
                }
            }
            .frame(width: cardWidth, height: totalCardHeight, alignment: .topLeading)
            .zIndex(showFocus ? 1 : 0)
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            artTile

            if showPosterLabels && !folder.hideTitle {
                VStack(alignment: .leading, spacing: 3) {
                    Text(displayTitle)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.white.opacity(0.86))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.white.opacity(0.45))
                        .lineLimit(1)
                }
                .frame(width: cardWidth, alignment: .leading)
                .animation(nil, value: showFocus)
            }
        }
        .frame(width: layoutWidth, height: totalCardHeight, alignment: .topLeading)
    }

    @ViewBuilder
    private var artTile: some View {
        if let url = coverImageURL {
            imageCover(url: url)
        } else if usesEmojiCover {
            emojiGlassCover
        } else {
            emptyCover
        }
    }

    /// Shared focus-GIF layer drawn over cover image / emoji / empty chrome.
    @ViewBuilder
    private var focusGifOverlay: some View {
        if let gifURL = focusGifURLString {
            AnimatedRemoteGIFView(urlString: gifURL, isActive: showFocus)
                .frame(width: cardWidth, height: cardHeight)
                .clipped()
                // Prefetch while the row is on screen so focus feels instant.
                .opacity(1)
                .allowsHitTesting(false)
        }
    }

    private func imageCover(url: URL) -> some View {
        ZStack {
            if usesLogoCoverPresentation {
                Color.clear
                    .frame(width: cardWidth, height: cardHeight)
                    .modifier(
                        LiquidGlassSurface(
                            cornerRadius: cardCornerRadius,
                            prominent: showFocus
                        )
                    )
            }
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    if usesLogoCoverPresentation {
                        image
                            .resizable()
                            .scaledToFit()
                            .padding(.horizontal, cardWidth * 0.10)
                            .padding(.vertical, cardHeight * 0.10)
                    } else {
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    }
                default:
                    // Loading / failed image falls back to empty art chrome.
                    emptyCoverFill
                }
            }
            focusGifOverlay
        }
        .frame(width: cardWidth, height: cardHeight)
        .clipped()
        .clipShape(cardShape)
        .overlay(cardShape.stroke(focusedBorderColor, lineWidth: focusedBorderWidth))
        .shadow(color: .black.opacity(shadowOpacity), radius: shadowRadius)
    }

    /// Liquid-glass tile when the folder uses an emoji cover (not a flat grey plate).
    /// Glass + emoji sit underneath; the focus GIF paints on top when active.
    private var emojiGlassCover: some View {
        ZStack {
            ZStack {
                coverGlyph
            }
            .frame(width: cardWidth, height: cardHeight)
            .modifier(LiquidGlassSurface(cornerRadius: cardCornerRadius, prominent: showFocus))

            focusGifOverlay
                .clipShape(cardShape)
        }
        .frame(width: cardWidth, height: cardHeight)
        .overlay(cardShape.stroke(focusedBorderColor, lineWidth: focusedBorderWidth))
        .shadow(color: .black.opacity(shadowOpacity), radius: shadowRadius)
    }

    private var emptyCover: some View {
        ZStack {
            emptyCoverFill
            coverGlyph
            focusGifOverlay
        }
        .frame(width: cardWidth, height: cardHeight)
        .clipShape(cardShape)
        .overlay(cardShape.stroke(focusedBorderColor, lineWidth: focusedBorderWidth))
        .shadow(color: .black.opacity(shadowOpacity), radius: shadowRadius)
    }

    /// Flat grey fill for non-emoji empty / image-loading states (matches Search cards).
    private var emptyCoverFill: some View {
        Rectangle()
            .fill(Color.white.opacity(0.07))
    }

    @ViewBuilder
    private var coverGlyph: some View {
        if let emojiText {
            Text(emojiText)
                .font(.system(size: emojiFontSize))
        } else {
            Image(systemName: "folder")
                .font(.system(size: 40))
                .foregroundColor(.white.opacity(0.25))
        }
    }
}

// MARK: - Collection folder browse

/// Grid metrics matching Search / Library poster cards (Tabs view mode).
private enum CollectionFolderGridMetrics {
    static let posterWidth: CGFloat = 210
    static let posterHeight: CGFloat = 315
    static let posterGap: CGFloat = 28
}

/// One catalog strip inside Rows view mode (Android `RowsContent`).
private struct CollectionFolderCatalogRow: Identifiable {
    let id: String
    let title: String
    let source: NuvioCollectionSource
    var items: [NuvioMeta]
    var nextSkip: Int
    var hasMore: Bool
    var isLoadingMore: Bool = false
}

private struct CollectionFolderSourceLoad {
    let index: Int
    let source: NuvioCollectionSource
    let page: CatalogPage?
    let errorMessage: String?
}

/// Full-screen folder browser. Honors collection `viewMode`:
/// - **Tabs** (`TABBED_GRID`): poster grid (optional source tabs + All).
/// - **Rows** / **Follow layout**: Home-style horizontal catalog rows per source.
struct CollectionFolderBrowseView: View {
    let folder: TVCollectionFolderItem
    let collectionTitle: String
    let repository: CatalogRepository
    let onSelect: (NuvioMeta) -> Void
    let onLongPress: (NuvioMeta) -> Void
    let onBack: () -> Void

    @State private var items: [NuvioMeta] = []
    @State private var catalogRows: [CollectionFolderCatalogRow] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var selectedTabIndex = 0
    @FocusState private var focusedItemID: String?
    @State private var lastFocusedItemID: String?
    @State private var focusRestoreGeneration = 0
    @State private var watchedTitleKeys: Set<String> = []
    @Environment(\.isEnabled) private var isEnabled
    @AppStorage(SettingsKey.amoled) private var amoled = false
    @AppStorage(SettingsKey.bodyColor) private var bodyColor = SettingsBackground.charcoal.rawValue
    @AppStorage(SettingsKey.homeLayout) private var homeLayout = "Modern"
    @AppStorage(SettingsKey.posterLabels) private var posterLabels = false

    private let pageSize = 40

    private var usesRows: Bool { folder.viewMode.usesCatalogRows }
    private var usesCinematicPresentation: Bool {
        guard usesRows else { return false }
        return ["STREAMING_SERVICE", "STUDIO_FRANCHISE"].contains(
            folder.presentationStyle?.uppercased() ?? ""
        )
    }
    /// A folder opened in Rows mode should retain Home-row behavior even when
    /// the top-level Home preference is Grid View. Compact remains compact;
    /// every other layout uses the normal portrait-to-landscape Home row.
    private var collectionRowLayoutMode: String {
        homeLayout == "Compact" ? "Compact" : "Modern"
    }

    private var heading: String {
        if collectionTitle.caseInsensitiveCompare(folder.title) == .orderedSame {
            return collectionTitle
        }
        return "\(collectionTitle) • \(folder.title)"
    }

    /// Tab labels for Tabs mode: optional "All" + one tab per source.
    private var tabLabels: [String] {
        guard !usesRows, folder.sources.count > 1 else { return [] }
        var labels: [String] = []
        if folder.showAllTab {
            labels.append("All")
        }
        for source in folder.sources {
            labels.append(Self.sourceLabel(source))
        }
        return labels
    }

    private var displayedGridItems: [NuvioMeta] {
        guard !usesRows else { return items }
        guard !tabLabels.isEmpty else { return items }
        if folder.showAllTab, selectedTabIndex == 0 {
            return items
        }
        let sourceIndex = folder.showAllTab ? selectedTabIndex - 1 : selectedTabIndex
        guard folder.sources.indices.contains(sourceIndex) else { return items }
        let source = folder.sources[sourceIndex]
        // Items were loaded per-source into catalogRows when multi-source.
        if let row = catalogRows.first(where: { $0.id == Self.sourceKey(source) }) {
            return row.items
        }
        return []
    }

    private var columns: [GridItem] {
        [GridItem(
            .adaptive(minimum: CollectionFolderGridMetrics.posterWidth, maximum: CollectionFolderGridMetrics.posterWidth),
            spacing: CollectionFolderGridMetrics.posterGap,
            alignment: .top
        )]
    }

    var body: some View {
        Group {
            if usesCinematicPresentation {
                cinematicRowsBrowser
            } else {
                gridBrowser
            }
        }
        .onExitCommand(perform: onBack)
        .task {
            refreshWatchedTitles()
            await load()
        }
        .onReceive(NotificationCenter.default.publisher(for: WatchedStore.changedNotification)) { _ in
            refreshWatchedTitles()
        }
        .onChange(of: focusedItemID) { newValue in
            if let newValue { lastFocusedItemID = newValue }
        }
        .onChange(of: isEnabled) { enabled in
            if !enabled {
                focusRestoreGeneration &+= 1
                if let focusedItemID { lastFocusedItemID = focusedItemID }
            } else if let target = lastFocusedItemID {
                let generation = focusRestoreGeneration
                DispatchQueue.main.async {
                    guard focusRestoreGeneration == generation else { return }
                    focusedItemID = target
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    guard focusRestoreGeneration == generation else { return }
                    focusedItemID = target
                }
            }
        }
    }

    private var gridBrowser: some View {
        ZStack {
            Color.nuvioBackground(amoled: amoled, body: bodyColor)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 20) {
                header

                if !tabLabels.isEmpty {
                    tabBar
                }

                if isLoading {
                    Spacer()
                    ProgressView()
                        .scaleEffect(1.6)
                        .tint(.white)
                        .frame(maxWidth: .infinity)
                    Spacer()
                } else if let errorMessage {
                    Spacer()
                    Text(errorMessage)
                        .font(.system(size: 22))
                        .foregroundColor(.white.opacity(0.7))
                        .frame(maxWidth: .infinity)
                    Spacer()
                } else if usesRows {
                    rowsContent
                } else if displayedGridItems.isEmpty {
                    Spacer()
                    Text("No titles found in this folder")
                        .font(.system(size: 22))
                        .foregroundColor(.white.opacity(0.7))
                        .frame(maxWidth: .infinity)
                    Spacer()
                } else {
                    gridContent
                }
            }
        }
    }

    /// Rows-mode collections share the same cinematic identity treatment as
    /// network/company pages: full-bleed artwork, a large logo hero, then rails.
    private var cinematicRowsBrowser: some View {
        ZStack(alignment: .top) {
            cinematicBackdrop

            ScrollView {
                VStack(alignment: .leading, spacing: 34) {
                    cinematicHero

                    if isLoading {
                        ProgressView()
                            .scaleEffect(1.6)
                            .tint(.white)
                            .frame(maxWidth: .infinity, minHeight: 260)
                    } else if let errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 28, weight: .medium))
                            .foregroundColor(.white.opacity(0.7))
                            .frame(maxWidth: .infinity, minHeight: 260)
                    } else if catalogRows.isEmpty {
                        Text("No titles found in this folder")
                            .font(.system(size: 28, weight: .medium))
                            .foregroundColor(.white.opacity(0.7))
                            .frame(maxWidth: .infinity, minHeight: 260)
                    } else {
                        ForEach(catalogRows) { row in
                            CollectionFolderHomeStyleRow(
                                id: row.id,
                                title: row.title,
                                items: row.items,
                                isLoadingMore: row.isLoadingMore,
                                layoutMode: collectionRowLayoutMode,
                                showPosterLabels: posterLabels,
                                externalFocus: $focusedItemID,
                                watchedTitleKeys: watchedTitleKeys,
                                onApproachEnd: { item in
                                    loadMoreRowIfNeeded(rowId: row.id, currentItem: item)
                                },
                                onLongPress: onLongPress,
                                onSelect: onSelect
                            )
                        }
                    }
                }
                .padding(.bottom, 70)
            }
            .focusSection()
            .defaultFocusIfAvailable($focusedItemID, firstFocusID)
        }
        .ignoresSafeArea(edges: .top)
    }

    private var cinematicBackdrop: some View {
        let backdropColor = Color.nuvioBackground(amoled: amoled, body: bodyColor)

        return ZStack {
            if let url = cinematicBackdropURL {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image
                            .resizable()
                            .scaledToFill()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            } else {
                backdropColor
            }

            GeometryReader { proxy in
                LinearGradient(
                    stops: [
                        .init(color: backdropColor.opacity(0.96), location: 0),
                        .init(color: backdropColor.opacity(0.86), location: 0.25),
                        .init(color: backdropColor.opacity(0.64), location: 0.50),
                        .init(color: backdropColor.opacity(0.34), location: 0.70),
                        .init(color: backdropColor.opacity(0.10), location: 0.88),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: proxy.size.width * 0.76)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }

            LinearGradient(
                colors: [.clear, backdropColor.opacity(0.74), backdropColor],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var cinematicBackdropURL: URL? {
        let firstItem = catalogRows.lazy.flatMap { $0.items }.first
        for candidate in [folder.heroBackdropUrl, firstItem?.backgroundUrl, firstItem?.posterUrl] {
            let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !value.isEmpty, let url = URL(string: value) { return url }
        }
        return nil
    }

    private var cinematicHero: some View {
        HStack(alignment: .bottom, spacing: 50) {
            VStack(alignment: .leading, spacing: 12) {
                Text(cinematicCategoryLabel)
                    .font(.system(size: 32, weight: .medium))
                    .foregroundColor(.white.opacity(0.72))

                Text(folder.title)
                    .font(.system(size: 64, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(2)

                Text("Movies and series • \(folder.sources.count) catalogs")
                    .font(.system(size: 28, weight: .regular))
                    .foregroundColor(.white.opacity(0.68))
            }

            Spacer(minLength: 20)

            if let logo = folder.preferredTitleLogoURLString ?? folder.coverImageUrl,
               let url = URL(string: logo) {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image
                            .resizable()
                            .scaledToFit()
                    } else {
                        Text(folder.title)
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundColor(.white)
                    }
                }
                .frame(width: 520, height: 190)
            }
        }
        .padding(.horizontal, TVLayout.rowLeading)
        .padding(.top, 72)
        .frame(maxWidth: .infinity, minHeight: 390, alignment: .bottom)
    }

    private var cinematicCategoryLabel: String {
        folder.presentationStyle?.uppercased() == "STUDIO_FRANCHISE"
            ? "Studio & Franchise"
            : "Streaming Service"
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 6) {
                Text(heading)
                    .font(.system(size: 42, weight: .bold))
                    .foregroundColor(.white)
                Text(subtitleLine)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(.white.opacity(0.55))
            }
            Spacer()
        }
        .padding(.horizontal, 60)
        .padding(.top, 48)
    }

    private var subtitleLine: String {
        let count = folder.sources.count
        let catalogs = count == 1 ? "1 catalog" : "\(count) catalogs"
        if usesRows {
            return "\(catalogs) · Rows"
        }
        return catalogs
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(Array(tabLabels.enumerated()), id: \.offset) { index, label in
                    Button {
                        selectedTabIndex = index
                        focusedItemID = displayedGridItems.first?.id
                    } label: {
                        Text(label)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(selectedTabIndex == index ? .black : .white.opacity(0.85))
                            .padding(.horizontal, 22)
                            .frame(height: 48)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(selectedTabIndex == index ? Color.white : Color.white.opacity(0.12))
                            )
                    }
                    .buttonStyle(PosterCardButtonStyle())
                }
            }
            .padding(.horizontal, 60)
        }
        .focusSection()
    }

    /// Home-style vertical list of horizontal catalog strips.
    private var rowsContent: some View {
        Group {
            if catalogRows.isEmpty {
                Spacer()
                Text("No titles found in this folder")
                    .font(.system(size: 22))
                    .foregroundColor(.white.opacity(0.7))
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: TVHomeLayout.sectionSpacing) {
                        ForEach(catalogRows) { row in
                            CollectionFolderHomeStyleRow(
                                id: row.id,
                                title: row.title,
                                items: row.items,
                                isLoadingMore: row.isLoadingMore,
                                layoutMode: collectionRowLayoutMode,
                                showPosterLabels: posterLabels,
                                externalFocus: $focusedItemID,
                                watchedTitleKeys: watchedTitleKeys,
                                onApproachEnd: { item in
                                    loadMoreRowIfNeeded(rowId: row.id, currentItem: item)
                                },
                                onLongPress: onLongPress,
                                onSelect: onSelect
                            )
                        }
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 60)
                }
                .focusSection()
                .defaultFocusIfAvailable($focusedItemID, firstFocusID)
            }
        }
    }

    private var gridContent: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: CollectionFolderGridMetrics.posterGap) {
                ForEach(displayedGridItems) { item in
                    CollectionFolderResultCard(
                        meta: item,
                        externalFocus: $focusedItemID,
                        isWatched: isTitleWatched(item),
                        onLongPress: { onLongPress(item) }
                    ) {
                        onSelect(item)
                    }
                    .onAppear {
                        loadMoreGridIfNeeded(currentItem: item)
                    }
                }
            }
            .padding(.top, 16)
            .padding(.horizontal, 60)

            if isGridLoadingMore {
                ProgressView()
                    .tint(.white)
                    .padding(.vertical, 28)
                    .frame(maxWidth: .infinity)
            }

            Color.clear.frame(height: 60)
        }
        .focusSection()
        .defaultFocusIfAvailable($focusedItemID, firstFocusID)
        .id(selectedTabIndex)
    }

    private var firstFocusID: String? {
        if usesRows {
            guard let row = catalogRows.first(where: { !$0.items.isEmpty }),
                  let item = row.items.first else {
                return nil
            }
            return "\(row.id)\u{1}\(item.id)"
        }
        return displayedGridItems.first?.id
    }

    private func refreshWatchedTitles() {
        watchedTitleKeys = Set(
            WatchedStore.visibleItems()
                .filter { $0.season == nil && $0.episode == nil }
                .map { "\($0.meta.type.lowercased())\u{1f}\($0.meta.id)" }
        )
    }

    private func isTitleWatched(_ meta: NuvioMeta) -> Bool {
        watchedTitleKeys.contains("\(meta.type.lowercased())\u{1f}\(meta.id)")
    }

    @MainActor
    private func load() async {
        isLoading = true
        errorMessage = nil
        selectedTabIndex = 0

        let sources = folder.sources
        if sources.isEmpty {
            items = []
            catalogRows = []
            errorMessage = "This folder has no sources."
            isLoading = false
            return
        }

        // Always load per-source so Rows mode (and Tabs without All) can split.
        var rows: [CollectionFolderCatalogRow] = []
        var all: [NuvioMeta] = []
        var seen = Set<String>()
        var firstFailureMessage: String?
        let loadedSources = await withTaskGroup(
            of: CollectionFolderSourceLoad.self,
            returning: [CollectionFolderSourceLoad].self
        ) { group in
            for (index, source) in sources.enumerated() {
                group.addTask {
                    do {
                        let page = try await CollectionSourceResolver(repository: repository)
                            .browse(source)
                        return CollectionFolderSourceLoad(
                            index: index,
                            source: source,
                            page: page,
                            errorMessage: nil
                        )
                    } catch {
                        return CollectionFolderSourceLoad(
                            index: index,
                            source: source,
                            page: nil,
                            errorMessage: error.localizedDescription
                        )
                    }
                }
            }

            var results: [CollectionFolderSourceLoad] = []
            for await result in group {
                results.append(result)
            }
            return results.sorted { $0.index < $1.index }
        }

        for result in loadedSources {
            let source = result.source
            guard let page = result.page else {
                if firstFailureMessage == nil {
                    firstFailureMessage = result.errorMessage
                }
                continue
            }
            let batch = pageItems(page, source: source)
            var sourceIds = Set<String>()
            let resolved = batch.filter { sourceIds.insert($0.id).inserted }
            rows.append(
                CollectionFolderCatalogRow(
                    id: Self.sourceKey(source),
                    title: Self.sourceLabel(source),
                    source: source,
                    items: resolved,
                    nextSkip: nextCursor(
                        page,
                        source: source,
                        requestedCursor: 0,
                        receivedCount: batch.count
                    ),
                    hasMore: page.hasMore && !batch.isEmpty
                )
            )
            for meta in resolved where seen.insert(meta.id).inserted {
                all.append(meta)
            }
        }
        // Tabs must retain their source-to-row mapping even when one source is
        // empty. Rows mode can omit empty strips.
        catalogRows = usesRows ? rows.filter { !$0.items.isEmpty } : rows
        items = all
        if items.isEmpty, let firstFailureMessage {
            errorMessage = firstFailureMessage
        }
        isLoading = false

        // The first card does not exist during the loading render, so the
        // default-focus modifier cannot select it by itself. Re-arm focus once
        // the catalog has been inserted into the view hierarchy.
        await Task.yield()
        focusedItemID = firstFocusID
    }

    private var isGridLoadingMore: Bool {
        if folder.showAllTab, !tabLabels.isEmpty, selectedTabIndex == 0 {
            return catalogRows.contains(where: \.isLoadingMore)
        }
        guard let rowId = selectedGridRowId else { return false }
        return catalogRows.first(where: { $0.id == rowId })?.isLoadingMore == true
    }

    private var selectedGridRowId: String? {
        guard !usesRows, !tabLabels.isEmpty else { return catalogRows.first?.id }
        if folder.showAllTab, selectedTabIndex == 0 { return nil }
        let sourceIndex = folder.showAllTab ? selectedTabIndex - 1 : selectedTabIndex
        guard folder.sources.indices.contains(sourceIndex) else { return nil }
        return Self.sourceKey(folder.sources[sourceIndex])
    }

    private func loadMoreGridIfNeeded(currentItem: NuvioMeta) {
        guard displayedGridItems.suffix(8).contains(where: { $0.id == currentItem.id }) else { return }

        if folder.showAllTab, !tabLabels.isEmpty, selectedTabIndex == 0 {
            for row in catalogRows where row.hasMore && !row.isLoadingMore {
                loadMoreSource(rowId: row.id)
            }
        } else if let rowId = selectedGridRowId {
            loadMoreSource(rowId: rowId)
        }
    }

    private func loadMoreRowIfNeeded(rowId: String, currentItem: NuvioMeta) {
        guard let row = catalogRows.first(where: { $0.id == rowId }),
              row.items.suffix(8).contains(where: { $0.id == currentItem.id }) else { return }
        loadMoreSource(rowId: rowId)
    }

    private func loadMoreSource(rowId: String) {
        guard let rowIndex = catalogRows.firstIndex(where: { $0.id == rowId }),
              catalogRows[rowIndex].hasMore,
              !catalogRows[rowIndex].isLoadingMore else { return }

        let source = catalogRows[rowIndex].source
        let requestedSkip = catalogRows[rowIndex].nextSkip
        catalogRows[rowIndex].isLoadingMore = true

        Task { @MainActor in
            do {
                let page = try await CollectionSourceResolver(repository: repository)
                    .browse(source, cursor: requestedSkip)
                guard let latestIndex = catalogRows.firstIndex(where: { $0.id == rowId }) else { return }

                let batch = pageItems(page, source: source)
                var existingRowIds = Set(catalogRows[latestIndex].items.map(\.id))
                let newItems = batch.filter { existingRowIds.insert($0.id).inserted }
                catalogRows[latestIndex].items.append(contentsOf: newItems)
                catalogRows[latestIndex].nextSkip = nextCursor(
                    page,
                    source: source,
                    requestedCursor: requestedSkip,
                    receivedCount: batch.count
                )
                catalogRows[latestIndex].hasMore = page.hasMore && !newItems.isEmpty
                catalogRows[latestIndex].isLoadingMore = false

                var existingAllIds = Set(items.map(\.id))
                items.append(contentsOf: newItems.filter { existingAllIds.insert($0.id).inserted })
            } catch {
                guard let latestIndex = catalogRows.firstIndex(where: { $0.id == rowId }) else { return }
                catalogRows[latestIndex].isLoadingMore = false
            }
        }
    }

    private func pageItems(
        _ page: CatalogPage,
        source: NuvioCollectionSource
    ) -> [NuvioMeta] {
        source.normalizedProvider == "addon"
            ? Array(page.items.prefix(pageSize))
            : page.items
    }

    private func nextCursor(
        _ page: CatalogPage,
        source: NuvioCollectionSource,
        requestedCursor: Int,
        receivedCount: Int
    ) -> Int {
        if source.normalizedProvider == "addon" {
            return requestedCursor + receivedCount
        }
        return page.nextSkip ?? requestedCursor
    }

    private static func sourceKey(_ source: NuvioCollectionSource) -> String {
        source.routeKey
    }

    private static func sourceLabel(_ source: NuvioCollectionSource) -> String {
        CollectionSourceResolver.label(for: source)
    }
}

/// One Home-like catalog strip inside Rows mode.
/// Uses the same focus-driven strip offset + spring as `TVCatalogRow` (not
/// a native ScrollView), so left/right focus slides cards under the title.
private struct CollectionFolderHomeStyleRow: View {
    let id: String
    let title: String
    let items: [NuvioMeta]
    var isLoadingMore: Bool = false
    var layoutMode: String = "Modern"
    var showPosterLabels: Bool = false
    var externalFocus: FocusState<String?>.Binding? = nil
    let watchedTitleKeys: Set<String>
    let onApproachEnd: (NuvioMeta) -> Void
    let onLongPress: (NuvioMeta) -> Void
    let onSelect: (NuvioMeta) -> Void

    /// Stable row id so composite card keys stay unique across strips.
    private var rowId: String { id }

    @State private var scrollIndex: Int = 0
    @State private var landscapeFocusedId: String?
    @State private var pendingLandscapeFocusedId: String?
    @State private var landscapeFocusTask: Task<Void, Never>?
    @AppStorage(SettingsKey.smoothFocus) private var smoothFocus = true
    @AppStorage(SettingsKey.focusHighlighter) private var focusHighlighter = false
    @AppStorage(SettingsKey.focusedPosterBackdropEnabled) private var focusedPosterBackdropEnabled = true
    @AppStorage(SettingsKey.focusedPosterBackdropDelay) private var focusedPosterBackdropDelay = 3

    private var posterWidth: CGFloat {
        layoutMode == "Compact" ? 170 : 210
    }

    private var rowSpacing: CGFloat {
        layoutMode == "Compact" ? 22 : 28
    }

    private var step: CGFloat { posterWidth + rowSpacing }

    private var stripHeight: CGFloat {
        let imageHeight: CGFloat = layoutMode == "Compact" ? 255 : 315
        return imageHeight + (showPosterLabels ? 48 : 0) + TVHomeLayout.stripVerticalPadding * 2
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.custom("Inter-Bold", size: 30))
                .foregroundColor(.white)
                .padding(.leading, TVLayout.rowLeading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .zIndex(1)

            cardStrip
                .zIndex(0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
        .onDisappear {
            landscapeFocusTask?.cancel()
            landscapeFocusTask = nil
            pendingLandscapeFocusedId = nil
        }
        .onChange(of: focusedPosterBackdropEnabled) { enabled in
            guard !enabled else { return }
            pendingLandscapeFocusedId = nil
            landscapeFocusTask?.cancel()
            landscapeFocusTask = nil
            landscapeFocusedId = nil
        }
    }

    /// Same clipping-window + manual offset pattern as `TVCatalogRow.cardStrip`.
    private var cardStrip: some View {
        GeometryReader { geo in
            let edgeInset = max(0, geo.frame(in: .global).minX)
            let stripWidth = geo.size.width + edgeInset * 2
            let rowHomeLayout = layoutMode
            let rowPosterLabels = showPosterLabels
            let rowSmoothFocus = smoothFocus
            let rowFocusHighlighter = focusHighlighter
            let rowStep = (rowHomeLayout == "Compact" ? 170.0 : 210.0)
                + (rowHomeLayout == "Compact" ? 22.0 : 28.0)

            HStack(alignment: .bottom, spacing: rowHomeLayout == "Compact" ? 22 : 28) {
                ForEach(items) { item in
                    let cardKey = "\(rowId)\u{1}\(item.id)"
                    PosterCard(
                        meta: item,
                        isLandscape: rowHomeLayout == "Modern" && landscapeFocusedId == cardKey,
                        onFocus: { focused in
                            if let index = items.firstIndex(where: { $0.id == focused.id }) {
                                if scrollIndex != index {
                                    scrollIndex = index
                                }
                            }
                            scheduleLandscapeFocus(cardKey: cardKey)
                            onApproachEnd(focused)
                        },
                        onBlur: { blurred in
                            let key = "\(rowId)\u{1}\(blurred.id)"
                            clearLandscapeFocus(cardKey: key)
                        },
                        externalFocus: externalFocus,
                        externalFocusValue: cardKey,
                        onLongPress: onLongPress,
                        layoutMode: rowHomeLayout,
                        showPosterLabels: rowPosterLabels,
                        smoothFocusAnimations: rowSmoothFocus,
                        focusHighlighterEnabled: rowFocusHighlighter,
                        isWatched: watchedTitleKeys.contains(
                            "\(item.type.lowercased())\u{1f}\(item.id)"
                        )
                    ) {
                        onSelect(item)
                    }
                }

                if isLoadingMore {
                    ProgressView()
                        .tint(.white)
                        .frame(width: posterWidth, height: rowHomeLayout == "Compact" ? 255 : 315)
                }
            }
            .padding(.vertical, TVHomeLayout.stripVerticalPadding)
            // Pin the focused card under the title (Home BringIntoViewSpec).
            .offset(x: edgeInset + TVLayout.rowLeading - CGFloat(scrollIndex) * rowStep)
            .frame(
                width: stripWidth,
                height: (rowHomeLayout == "Compact" ? 255 : 315)
                    + (rowPosterLabels ? 48 : 0)
                    + TVHomeLayout.stripVerticalPadding * 2,
                alignment: .leading
            )
            .clipped()
            .offset(x: -edgeInset)
            .animation(rowSmoothFocus ? TVHomeLayout.scrollSpring : nil, value: scrollIndex)
            .animation(rowSmoothFocus ? TVHomeLayout.scrollSpring : nil, value: landscapeFocusedId)
        }
        .frame(height: stripHeight)
    }

    /// Wait for the configured backdrop delay before expanding the settled
    /// portrait card, and cancel when focus moves away.
    private func scheduleLandscapeFocus(cardKey: String) {
        guard layoutMode == "Modern", focusedPosterBackdropEnabled else {
            pendingLandscapeFocusedId = nil
            landscapeFocusedId = nil
            landscapeFocusTask?.cancel()
            return
        }
        if pendingLandscapeFocusedId == cardKey && landscapeFocusedId == nil { return }
        if landscapeFocusedId == cardKey { return }

        pendingLandscapeFocusedId = cardKey
        landscapeFocusedId = nil
        landscapeFocusTask?.cancel()

        let targetKey = cardKey
        let delaySeconds = max(1, focusedPosterBackdropDelay)
        landscapeFocusTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds) * 1_000_000_000)
            guard !Task.isCancelled,
                  pendingLandscapeFocusedId == targetKey else { return }
            landscapeFocusedId = targetKey
        }
    }

    private func clearLandscapeFocus(cardKey: String) {
        if pendingLandscapeFocusedId == cardKey {
            pendingLandscapeFocusedId = nil
            landscapeFocusTask?.cancel()
        }
        if landscapeFocusedId == cardKey {
            landscapeFocusedId = nil
        }
    }
}

/// Poster card chrome matching Search / Library grids (Tabs view mode).
private struct CollectionFolderResultCard: View {
    let meta: NuvioMeta
    var externalFocus: FocusState<String?>.Binding? = nil
    var isWatched: Bool? = nil
    var onLongPress: (() -> Void)? = nil
    let action: () -> Void

    @FocusState private var focused: Bool
    @AppStorage(SettingsKey.posterLabels) private var posterLabels = false
    @AppStorage(SettingsKey.smoothFocus) private var smoothFocus = true
    @AppStorage(SettingsKey.focusHighlighter) private var focusHighlighter = false

    private let cardCornerRadius: CGFloat = 16

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                AsyncImage(url: URL(string: meta.posterUrl ?? "")) { phase in
                    if case .success(let image) = phase {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        ZStack {
                            Rectangle().fill(Color.white.opacity(0.07))
                            Image(systemName: meta.type == "series" ? "tv" : "film")
                                .font(.system(size: 40))
                                .foregroundColor(.white.opacity(0.25))
                        }
                    }
                }
                .frame(
                    width: CollectionFolderGridMetrics.posterWidth,
                    height: CollectionFolderGridMetrics.posterHeight
                )
                .clipShape(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if let isWatched {
                        if isWatched { WatchedCheckmarkIcon() }
                    } else {
                        WatchedCheckmarkBadge(meta: meta)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                        .stroke(
                            focused ? AppFocusOutline.color : .clear,
                            lineWidth: focusHighlighter ? AppFocusOutline.emphasizedWidth : AppFocusOutline.width
                        )
                )
                .shadow(
                    color: .black.opacity(focused ? 0.5 : 0.2),
                    radius: focused ? 16 : 6
                )

                if posterLabels {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(meta.name)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(focused ? .white : .white.opacity(0.78))
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.white.opacity(0.45))
                            .lineLimit(1)
                    }
                    .frame(width: CollectionFolderGridMetrics.posterWidth, alignment: .leading)
                }
            }
            .scaleEffect(focused ? 1.06 : 1.0)
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($focused)
        .modifier(ExternalFocusBinding(binding: externalFocus, id: meta.id))
        .focusEffectDisabledIfAvailable()
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.45).onEnded { _ in
                onLongPress?()
            }
        )
        .animation(smoothFocus ? .spring(response: 0.28, dampingFraction: 0.75) : nil, value: focused)
        .zIndex(focused ? 1 : 0)
    }

    private var subtitle: String {
        var parts: [String] = [meta.type == "series" ? "Series" : "Movie"]
        if let year = meta.year { parts.append(String(year)) }
        if let rating = meta.rating, rating > 0 { parts.append(String(format: "★ %.1f", rating)) }
        return parts.joined(separator: "  ·  ")
    }
}

private struct TVHeroMetaLine: View {
    let meta: NuvioMeta
    /// "S1 E3 · Title" for a series in progress; replaces the type/runtime
    /// items so the line reads "S1 E3 · Title • Crime • 2026–".
    var episodeLine: String? = nil
    @AppStorage(SettingsKey.showFullDates) private var showFullDates = true

    var body: some View {
        let values = [
            episodeLine ?? meta.type.capitalized,
            meta.genres?.first,
            episodeLine == nil ? formattedRuntime : nil,
            episodeLine == nil ? releaseDate : (meta.releaseInfo ?? meta.year.map(String.init))
        ].compactMap { $0 }.filter { !$0.isEmpty }

        let badge = meta.statusBadgeLabel
        let rating = meta.rating.map { String(format: "IMDb %.1f", $0) }
        // Movies have no status badge, so their rating would sit alone on the
        // second line; ride it on the primary line right after the date instead.
        let isMovie = !meta.isSeries
        let primaryValues = isMovie ? values + [rating].compactMap { $0 } : values
        let showSecondLine = !isMovie && (badge != nil || rating != nil)
        // An empty `Text("")` still consumes a full line height and, with the
        // hero VStack spacing, opens a dead gap between the title and the first
        // catalog row (e.g. "The Chi" → "gg"). Collapse entirely when blank.
        let hasPrimary = !primaryValues.isEmpty

        if hasPrimary || showSecondLine {
            VStack(alignment: .leading, spacing: 10) {
                if hasPrimary {
                    Text(primaryValues.joined(separator: "  •  "))
                        .font(.custom("Inter-SemiBold", size: 22))
                        .foregroundColor(.white.opacity(0.66))
                        .lineLimit(1)
                }

                // Second line, like the Android hero: "[ONGOING] • IMDb 7.4".
                if showSecondLine {
                    HStack(spacing: 14) {
                        if let badge {
                            Text(badge)
                                .font(.custom("Inter-SemiBold", size: 17))
                                .foregroundColor(.white.opacity(0.88))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .stroke(Color.white.opacity(0.45), lineWidth: 1.5)
                                )
                        }

                        if let rating {
                            Text(badge != nil ? "•  \(rating)" : rating)
                                .font(.custom("Inter-SemiBold", size: 22))
                                .foregroundColor(.white.opacity(0.66))
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
    }

    private var formattedRuntime: String? {
        NuvioRuntimeDisplay.formatted(meta.runtime)
    }

    private var releaseDate: String? {
        if showFullDates, let released = meta.released, !released.isEmpty {
            return NuvioDateDisplay.formattedDate(released)
        }
        return meta.year.map(String.init)
    }
}


private struct TVLoadingView: View {
    @AppStorage(SettingsKey.theme) private var theme = SettingsAccent.white.rawValue

    var body: some View {
        ProgressView()
            .progressViewStyle(.circular)
            .tint(SettingsAccent.color(for: theme))
            .scaleEffect(1.8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .focusable(true)
    }
}

private struct TVErrorView: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Catalog failed")
                .font(.largeTitle.bold())
            Text(message)
                .font(.title3)
                .foregroundColor(.white.opacity(0.68))
            Button("Retry", action: onRetry)
                .buttonStyle(.borderedProminent)
        }
        .foregroundColor(.white)
        .padding(.leading, TVLayout.contentLeading)
        .frame(maxWidth: .infinity, minHeight: 560, alignment: .leading)
        .focusable(true)
    }
}

enum NuvioDateDisplay {
    static func formattedDate(_ value: String?) -> String? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }

        let datePart = String(raw.prefix(10))
        if !showsFullDates {
            let year = String(datePart.prefix(4))
            return Int(year) == nil ? raw : year
        }
        guard datePart.count == 10,
              let date = isoDay.date(from: datePart) else {
            return raw
        }

        return display.string(from: date)
    }

    private static var showsFullDates: Bool {
        let key = "nuvio.tv.settings.layout.showFullDates"
        let defaults = UserDefaults.standard
        return defaults.object(forKey: key) == nil || defaults.bool(forKey: key)
    }

    private static let isoDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let display: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMMM d, yyyy"
        return f
    }()
}

/// Formats Stremio/Cinemeta runtime strings ("142 min", "120", "1h 55min")
/// into hour/minute display ("2h 22m", "2h", "45m").
enum NuvioRuntimeDisplay {
    static func formatted(_ runtime: String?) -> String? {
        guard let runtime = runtime?.trimmingCharacters(in: .whitespacesAndNewlines),
              !runtime.isEmpty else {
            return nil
        }

        let normalized = runtime.lowercased()
        let hours = firstNumber(in: normalized, pattern: #"(\d+)\s*h"#)
        let minutes = firstNumber(in: normalized, pattern: #"(\d+)\s*m(?:in)?"#)
        let totalMinutes: Int?

        if hours != nil || minutes != nil {
            totalMinutes = (hours ?? 0) * 60 + (minutes ?? 0)
        } else {
            totalMinutes = Int(normalized.filter(\.isNumber))
        }

        guard let totalMinutes, totalMinutes > 0 else {
            return runtime
        }

        let wholeHours = totalMinutes / 60
        let remainingMinutes = totalMinutes % 60

        if wholeHours > 0 && remainingMinutes > 0 {
            return "\(wholeHours)h \(remainingMinutes)m"
        } else if wholeHours > 0 {
            return "\(wholeHours)h"
        } else {
            return "\(remainingMinutes)m"
        }
    }

    private static func firstNumber(in value: String, pattern: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: value,
                range: NSRange(value.startIndex..<value.endIndex, in: value)
              ),
              let range = Range(match.range(at: 1), in: value) else {
            return nil
        }
        return Int(value[range])
    }
}

/// Shared Home vertical rhythm for catalog *and* collection folder rows.
private enum TVHomeLayout {
    static let sectionSpacing: CGFloat = 28
    /// Split of `sectionSpacing` across hero bottom + rows top.
    static let heroBottomPadding: CGFloat = 12
    static let rowsTopPadding: CGFloat = 16
    /// Focus breathing room above/below cards inside a strip.
    static let stripVerticalPadding: CGFloat = 28
    /// Section title line (~30pt) + VStack spacing under the title (~10pt) + slack.
    static let rowTitleBlock: CGFloat = 46

    /// Horizontal strip + vertical page offset. Critically damped (`1.0`) so
    /// paging settles without the rubber-band overshoot of underdamped springs
    /// (matches Android TV row feel — smooth slide, no bounce).
    static var scrollSpring: Animation {
        .spring(response: 0.3, dampingFraction: 1.0)
    }
}

private enum TVLayout {
    static let contentLeading: CGFloat = 150
    static let rowLeading: CGFloat = 48
}

extension Color {
    static let tvBackground = Color(red: 0.015, green: 0.015, blue: 0.018)
    static let tvCard = Color(red: 0.105, green: 0.108, blue: 0.115)
    static let tvAccent = Color(red: 0.94, green: 0.13, blue: 0.13)

    /// App body background. AMOLED forces pure black; otherwise the selected
    /// background tint (Settings → Appearance → App Background) is used.
    static func nuvioBackground(amoled: Bool, body: String = SettingsBackground.charcoal.rawValue) -> Color {
        amoled ? .black : SettingsBackground.color(for: body)
    }

    /// Builds a color from a `#RRGGBB` (or `RRGGBB`) hex string. Falls back to
    /// white for malformed input. Used by the subtitle styling swatches/preview.
    init(hex: String) {
        let raw = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        var value: UInt64 = 0xFFFFFF
        Scanner(string: String(raw.prefix(6))).scanHexInt64(&value)
        self.init(
            red: Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8) & 0xFF) / 255.0,
            blue: Double(value & 0xFF) / 255.0
        )
    }
}

extension String {
    /// Inserts a hard line break after every `n` whitespace-separated words, so
    /// long descriptions wrap at a fixed word count (hero + details on tvOS).
    func wrappedEveryNWords(_ n: Int) -> String {
        guard n > 0 else { return self }
        let words = split(whereSeparator: { $0.isWhitespace })
        guard words.count > n else { return self }

        var lines: [String] = []
        var index = 0
        while index < words.count {
            let end = Swift.min(index + n, words.count)
            lines.append(words[index..<end].joined(separator: " "))
            index += n
        }
        return lines.joined(separator: "\n")
    }
}
