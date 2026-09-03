//
//  NuvioTVApp.swift
//  NuvioTV
//
//  Main SwiftUI app entry point with Master view coordinator
//

import SwiftUI
import Foundation
import UIKit
import ImageIO
import OSLog

@main
struct NuvioTVApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

/// Temporary Home performance tracing. Enabled only by DEBUG builds so the
/// release app does not pay for the timestamps or console formatting.
enum TVHomeDebugTrace {
    private static let enabled = false
    private static let logger = Logger(
        subsystem: "com.pyksel.nuviotvos",
        category: "TVTrace"
    )
    static func now() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    static func elapsedMilliseconds(since start: UInt64) -> String {
        String(format: "%.1f", Double(now() - start) / 1_000_000)
    }

    static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        let line = "[TVTrace] \(message())"
        print(line)
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

public enum PlaybackOrigin {
    case main
    case details
    case cloudLibrary
}

private enum DetailsReturnDestination {
    case main
    case collectionFolder(TVCollectionFolderItem, collectionTitle: String)
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
    @State private var resolvingContinueWatchingItem: ContinueWatchingItem?
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
    /// Bumped only after the Details view has actually left the hierarchy.
    /// Home uses this lifecycle signal to request focus at the first moment
    /// tvOS can accept it, instead of guessing with delayed timers.
    @State private var detailsDidDisappearGeneration: UInt = 0
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
                            selectedTab = .home
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
        .onChange(of: profileViewModel.activeProfile?.id) { _, _ in
            AppLocaleManager.shared.reloadFromProfileStore()
        }
        // Keep the profile cover up until the progressive catalog stream has
        // finished. Revealing Home when its first row arrived let the user page
        // that row while later catalog updates were still replacing it; if a
        // focused, paged-in card disappeared during the replacement, tvOS moved
        // focus to the row above. `hasLoaded` flips only after the final tree is
        // published, so the first interactive frame is stable.
        .onChange(of: homeStore.hasLoaded) { _, loaded in
            guard isPreparingProfile, loaded else { return }
            profileGateContentReady()
        }
        // Backing out of the switch must not leave the cover behind.
        .onChange(of: isOnProfileSelection) { _, isSelecting in
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
            ICloudSettingsSyncManager.shared.start()
            setupPictureInPicture()
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
                    beginProfileGate()
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
                        beginProfileGate()
                        activeScreen = .main
                        resumePendingDeepLinkIfPossible()
                    }
                }
            }
        }
        .onReceive(profileViewModel.$activeProfile) { profile in
            syncManager.activeProfileChanged(profile)
            guard profile != nil else { return }
            SMBServerStore.shared.reload()
            JellyfinServerStore.shared.reload()
            Task(priority: .utility) {
                await SMBSessionManager.shared.connectAll()
                await JellyfinSessionManager.shared.connectAll()
            }
        }
        .onChange(of: scenePhase) { _, phase in
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
        return fullScreenOverlayPresented
    }

    /// Full-screen overlays already hide Home with alpha zero. Propagating
    /// `.disabled` through that hidden tree changes `isEnabled` for every
    /// resident card and forces the shelves to lay themselves out again while
    /// Details is entering. Keep the environment lock for visible menus, where
    /// Home still needs to stay on screen but must not receive focus.
    private var shouldDisableHomeContent: Bool {
        isOverlayPresented && !fullScreenOverlayPresented
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
            resolvingContinueWatchingItem = nil
            isResolvingContinueWatchingStream = false
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
        TVHomeDebugTrace.log(
            "details.leave backStackRemaining=\(detailsBackStack.count) returnDest=\(detailsReturnDestination)"
        )
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
        TVHomeDebugTrace.log(
            "details.open.root id=\(id) type=\(type) returnDest=\(returnDestination)"
        )
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

        // Infuse returns here after its player closes. Keep this before the
        // generic id guard: callback URLs intentionally carry only a session
        // UUID, not a title id.
        if let callback = ExternalPlaybackCallback.parse(url) {
            switch activeScreen {
            case .login, .profileSelection:
                pendingDeepLinkURL = url
            default:
                handleExternalPlaybackCallback(callback)
            }
            return
        }

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

    private func handleExternalPlaybackCallback(_ callback: ExternalPlaybackCallback) {
        let profileID = profileViewModel.activeProfile?.id ?? WatchedStore.activeProfileId
        guard let session = ExternalPlaybackSessionStore.consume(id: callback.id, profileID: profileID) else {
            return
        }
        // An Infuse error callback means the handoff failed. Consuming the
        // session still makes retries/idempotent duplicate callbacks harmless.
        guard !callback.isError else { return }

        let duration = session.duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let progress = callback.progress ?? callback.position.flatMap { position in
            guard let duration, position.isFinite, position >= 0 else { return nil }
            return position / duration
        }
        guard let progress, progress.isFinite, (0...1).contains(progress) else { return }

        let isEpisode = session.meta.isSeries && session.season != nil && session.episode != nil
        guard !session.meta.isSeries || isEpisode else { return }

        if RemoteTrackingState.isProgressSourceAuthenticated {
            // Keep the provider-backed path aligned with built-in playback:
            // optimistic local state plus one pause/stop report. A zero
            // fraction is an Infuse close-before-play signal, not playback.
            if progress > 0 {
                let reportDuration = duration ?? 100
                let reportPosition = duration.map { $0 * progress } ?? (100 * progress)
                let action: TraktScrobbleAction = progress >= WatchProgressLedger.completionFraction
                    ? .stop
                    : .pause
                let store = ProfileSettings.current
                if let duration {
                    TraktProgressService.recordLocalPlayback(
                        meta: session.meta,
                        position: reportPosition,
                        duration: duration,
                        season: session.season,
                        episode: session.episode,
                        notify: action == .stop
                    )
                }
                Task {
                    _ = await TraktProgressService.reportPlayback(
                        meta: session.meta,
                        position: reportPosition,
                        duration: reportDuration,
                        season: session.season,
                        episode: session.episode,
                        action: action,
                        store: store
                    )
                }
            }
            if progress >= WatchProgressLedger.completionFraction {
                _ = WatchedStore.markWatched(
                    session.meta,
                    season: session.season,
                    episode: session.episode
                )
            }
            return
        }

        if progress >= WatchProgressLedger.completionFraction {
            if let duration {
                ContinueWatchingStore.markPlaybackCompleted(
                    meta: session.meta,
                    duration: duration,
                    season: session.season,
                    episode: session.episode
                )
            }
            _ = WatchedStore.markWatched(
                session.meta,
                season: session.season,
                episode: session.episode
            )
        } else if let duration, progress > 0 {
            ContinueWatchingStore.save(
                meta: session.meta,
                streamUrl: session.sourceURL,
                position: duration * progress,
                duration: duration,
                season: session.season,
                episode: session.episode
            )
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

        resolvingContinueWatchingItem = item
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
            resolvingContinueWatchingItem = nil
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
        var keysToDelete = Set<String>()
        keysToDelete.insert(item.meta.id)
        let itemProgressKey = WatchProgressLedger.progressKey(
            contentId: item.meta.id,
            season: item.episodeNumbers?.season,
            episode: item.episodeNumbers?.episode
        )
        keysToDelete.insert(itemProgressKey)

        let ledgerKeys = WatchProgressLedger.records()
            .filter { $0.contentId == item.meta.id }
            .map(\.progressKey)
        for key in ledgerKeys {
            keysToDelete.insert(key)
        }

        ContinueWatchingDismissStore.dismiss(item)
        ContinueWatchingDismissStore.dismiss(contentId: item.meta.id)

        _ = WatchProgressLedger.removeContent(id: item.meta.id)
        ContinueWatchingStore.remove(metaId: item.meta.id)
        TraktProgressService.forgetLocalPlayback(meta: item.meta)
        // Simkl owns its paused rows, so the local dismiss only hides the card
        // on this device. Retire the row on the account as well; it no-ops
        // unless Simkl is the selected progress source.
        Task { await SimklProgressService.removePlayback(for: item) }

        let keysArray = Array(keysToDelete)
        if !keysArray.isEmpty {
            Task { await syncManager.deleteRemoteWatchProgress(keys: keysArray) }
        }
    }

    private func presentPlayback(
        url: URL,
        meta: NuvioMeta,
        subtitle: String,
        externalSubtitles: [NuvioSubtitle],
        resumeFrom: Double?,
        httpHeaders: [String: String] = [:],
        origin: PlaybackOrigin = .main,
        customPlayer: ExternalPlayer? = nil
    ) {
        let isTrailer = subtitle == PlaybackMarkers.trailerSubtitle
        let store = ProfileSettings.store(for: profileViewModel.activeProfile?.id)
        let defaultPlayer = ExternalPlayer.from(store.string(forKey: SettingsKey.externalPlayer))
        let player = customPlayer ?? defaultPlayer
        let forwardSubtitles = (store.object(forKey: SettingsKey.externalPlayerForwardSubtitles) as? Bool) ?? true
        let subtitleURLs = forwardSubtitles
            ? externalSubtitles.compactMap { URL(string: $0.url) }
            : []

        let externalSession: ExternalPlaybackSession?
        let successCallback: URL?
        let errorCallback: URL?
        if player == .infuse {
            let id = UUID().uuidString
            let numbers: (season: Int, episode: Int)?
            if let current = playbackCurrentEpisode, current.season > 0, current.episode > 0 {
                numbers = (current.season, current.episode)
            } else if let parsed = Self.episodeNumbers(fromSubtitle: subtitle) {
                numbers = parsed
            } else {
                let parsed = Self.seasonEpisode(fromContentId: url.deletingPathExtension().lastPathComponent)
                numbers = parsed.season.flatMap { season in
                    parsed.episode.map { (season: season, episode: $0) }
                }
            }
            let profileID = profileViewModel.activeProfile?.id ?? WatchedStore.activeProfileId
            externalSession = ExternalPlaybackSession(
                id: id,
                meta: meta.persistenceSnapshot,
                sourceURL: url.absoluteString,
                season: meta.isSeries ? numbers?.season : nil,
                episode: meta.isSeries ? numbers?.episode : nil,
                duration: Self.runtimeSeconds(meta.runtime),
                profileID: profileID
            )
            successCallback = URL(string: "nuvio-tv://external-playback/\(id)")
            errorCallback = URL(string: "nuvio-tv://external-playback/error/\(id)")
        } else {
            externalSession = nil
            successCallback = nil
            errorCallback = nil
        }

        // Hand off to the external app only when it is actually installed
        // (`canOpenURL` needs its scheme in LSApplicationQueriesSchemes); if it
        // isn't, fall through to the built-in player instead of a dead launch.
        if !isTrailer,
           url.scheme?.lowercased() != "smb",
           let launchURL = player.launchURL(
               for: url,
               subtitleURLs: subtitleURLs,
               successURL: successCallback,
               errorURL: errorCallback
           ),
           UIApplication.shared.canOpenURL(launchURL) {
            if let externalSession {
                ExternalPlaybackSessionStore.save(externalSession)
            }
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
        if PictureInPictureManager.shared.isPictureInPictureActive,
           PictureInPictureManager.shared.activeContext?.url != url {
            PictureInPictureManager.shared.invalidateSession()
        }
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

    private func setupPictureInPicture() {
        PictureInPictureManager.shared.onRestoreUI = { [self] context, completion in
            withAnimation(.easeInOut(duration: 0.24)) {
                self.playbackOrigin = context.playbackOrigin
                self.playbackEpisodes = context.episodes
                self.playbackCurrentEpisode = context.currentEpisode
                self.activeScreen = .player(
                    url: context.url,
                    meta: context.meta,
                    subtitle: context.subtitle,
                    httpHeaders: context.httpHeaders,
                    externalSubtitles: context.externalSubtitles,
                    resumeFrom: context.resumeFrom
                )
            }
            completion(true)
        }

        PictureInPictureManager.shared.onDidStopPiPWithoutRestoring = {
            PlaybackWakeLock.release()
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
                .disabled(shouldDisableHomeContent)
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
                    .onDisappear {
                        detailsDidDisappearGeneration &+= 1
                    }
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

            if isResolvingContinueWatchingStream, let item = resolvingContinueWatchingItem {
                PlayerLoadingOverlay(
                    backdropUrl: item.meta.backgroundUrl ?? item.meta.posterUrl,
                    logoUrl: item.meta.logoUrl,
                    title: item.meta.name,
                    message: L10n.string("player_status_starting_stream", fallback: "Starting stream")
                )
                .transition(.opacity)
                .zIndex(3)
            }

            // The adaptive tab sidebar is briefly expanded while its first
            // focus pass runs. Keep the full tab container covered while Home
            // loads so its loading/card default focus and native scroll state
            // can settle before the user sees it. This applies equally to an
            // automatic cold launch and a newly selected profile.
            if isPreparingProfile {
                ZStack {
                    ProfileScopedRootBackground()
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                        .scaleEffect(1.8)
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .transition(.opacity)
                .zIndex(4)
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
            isFullScreenOverlayPresented: fullScreenOverlayPresented,
            detailsDidDisappearGeneration: detailsDidDisappearGeneration,
            accountEmail: authManager.currentEmail,
            isAuthenticated: authManager.isAuthenticated,
            sessionNeedsReauthentication: authManager.sessionNeedsReauthentication,
            isProfileSwitching: isPreparingProfile,
            authManager: authManager,
            syncManager: syncManager,
            onSwitchProfile: {
                // A fresh profile should get a fresh Home (different Continue
                // Watching, etc.), so drop the cached catalog.
                homeStore.reset()
                withAnimation(.easeInOut(duration: 0.28)) {
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
                // Home defers its focus-restoration render until Details closes,
                // so every tab can now use the same presentation transaction.
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
            onPlayContinueWatchingManually: { item in
                playContinueWatchingManually(item)
            },
            onStartContinueWatchingFromBeginning: { item in
                resumePlayback(item, startFromBeginning: true)
            },
            onRemoveFromContinueWatching: { item in
                removeFromContinueWatching(item)
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
            },
            onPlayCloudFile: { url, meta in
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
            onPlayClick: { streamUrlString, httpHeaders, meta, subtitle, externalSubtitles, currentEpisode, episodes, player in
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
                        origin: .details,
                        customPlayer: player
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
                    filename: candidate.filename,
                    addonName: candidate.addonName,
                    videoSize: candidate.videoSize,
                    provider: debrid.selectedKind.rawValue
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
                filename: candidate.filename,
                addonName: candidate.addonName,
                videoSize: candidate.videoSize,
                provider: "Direct"
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
        let sortRaw = store.string(forKey: SettingsKey.streamSortOption)
        let sortOption = sortRaw.flatMap(StreamSortOption.init(rawValue:)) ?? .quality
        return StreamPickerListBuilder.displayedStreams(
            streams: streams,
            groups: [],
            selectedAddonId: nil,
            sortOption: sortOption,
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
                filename: stream.filename,
                addonName: stream.addonName,
                videoSize: stream.videoSize,
                provider: debrid.selectedKind.rawValue
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
            filename: stream.filename,
            addonName: stream.addonName,
            videoSize: stream.videoSize,
            provider: "Direct"
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

    private static func episodeNumbers(fromSubtitle subtitle: String) -> (season: Int, episode: Int)? {
        let pattern = #"S(\d+)\s*[·.\-–—]?\s*E(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(
                  in: subtitle,
                  range: NSRange(subtitle.startIndex..., in: subtitle)
              ),
              let seasonRange = Range(match.range(at: 1), in: subtitle),
              let episodeRange = Range(match.range(at: 2), in: subtitle),
              let season = Int(subtitle[seasonRange]),
              let episode = Int(subtitle[episodeRange]) else { return nil }
        return (season, episode)
    }

    private static func runtimeSeconds(_ runtime: String?) -> Double? {
        guard let runtime = runtime?.lowercased(), !runtime.isEmpty else { return nil }
        let hours = firstRuntimeNumber(runtime, pattern: #"(\d+)\s*h"#) ?? 0
        let minutes = firstRuntimeNumber(runtime, pattern: #"(\d+)\s*m(?:in)?"#)
            ?? (hours == 0 ? firstRuntimeNumber(runtime, pattern: #"^\s*(\d+)\s*$"#) : 0)
        let seconds = (hours * 60 + (minutes ?? 0)) * 60
        return seconds > 0 ? Double(seconds) : nil
    }

    private static func firstRuntimeNumber(_ value: String, pattern: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let range = Range(match.range(at: 1), in: value) else { return nil }
        return Int(value[range])
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
            playbackOrigin: playbackOrigin,
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
            },
            onPlayRecommendation: { recMeta, playManually in
                dismissPlayer(meta: meta, subtitle: subtitle)
                playRecommendedTitle(meta: recMeta, playManually: playManually)
            },
            onOpenRecommendationDetails: { recMeta in
                dismissPlayer(meta: meta, subtitle: subtitle)
                withAnimation(.easeInOut(duration: 0.28)) {
                    openDetailsRoot(id: recMeta.id, type: recMeta.type)
                }
            }
        ) {
            dismissPlayer(meta: meta, subtitle: subtitle)
        }
    }

    private func playRecommendedTitle(meta: NuvioMeta, playManually: Bool) {
        if playManually || meta.isSeries {
            withAnimation(.easeInOut(duration: 0.28)) {
                openDetailsRoot(id: meta.id, type: meta.type)
            }
            return
        }

        let profileId = profileViewModel.activeProfile?.id
        Task {
            let prepared = await Self.resolveStream(
                contentId: meta.id,
                type: meta.type,
                subtitleLine: "",
                profileId: profileId
            )
            guard !Task.isCancelled else { return }
            if let prepared {
                presentPlayback(
                    url: prepared.url,
                    meta: meta,
                    subtitle: prepared.subtitleLine,
                    externalSubtitles: prepared.subtitles,
                    resumeFrom: nil,
                    httpHeaders: prepared.httpHeaders
                )
            } else {
                withAnimation(.easeInOut(duration: 0.28)) {
                    openDetailsRoot(id: meta.id, type: meta.type)
                }
            }
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
                activeScreen = .main
            case .main:
                activeScreen = (isTrailer || meta.isSeries)
                    ? .details(id: meta.id, type: meta.type)
                    : .main
            }
        }
    }
}


private struct SimklHomeLoadingDebugReport: View {
    let report: String

    var body: some View {
        VStack(spacing: 12) {
            Text("SIMKL DEBUG REPORT")
                .font(.system(size: 20, weight: .bold, design: .monospaced))
                .foregroundColor(.yellow)

            ScrollView {
                Text(report)
                    .font(.system(size: 15, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.86))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 250)
            .padding(16)
            .background(Color.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 14))

            Text("Read or screenshot this report and send it to the developer.")
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(.white.opacity(0.66))
        }
        .padding(22)
        .background(Color.black.opacity(0.84), in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.yellow.opacity(0.45), lineWidth: 1)
        }
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

extension CrossfadingBackdrop: Equatable {
    static func == (lhs: CrossfadingBackdrop, rhs: CrossfadingBackdrop) -> Bool {
        lhs.url == rhs.url
            && lhs.placeholder == rhs.placeholder
            && lhs.alignment == rhs.alignment
    }
}

/// Small in-memory cache + loader for backdrop images so revisiting a poster is
/// instant (no decode flicker) and repeated focus changes don't refetch.
private actor BackdropImageCache {
    static let shared = BackdropImageCache()

    private let cache = NSCache<NSString, UIImage>()

    init() {
        // Backdrops are shown at screen size. Retaining a bounded decoded-byte
        // budget avoids keeping dozens of full-resolution source images alive
        // after rapid focus changes.
        cache.totalCostLimit = 96 * 1024 * 1024
    }

    func image(for url: URL) async -> UIImage? {
        let key = url.absoluteString as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let decoded = downsampleBackdropImage(data: data) else { return nil }
        cache.setObject(decoded, forKey: key, cost: decoded.backdropDecodedByteCost)
        return decoded
    }
}

private func downsampleBackdropImage(data: Data) -> UIImage? {
    let maxPixelSize = max(UIScreen.main.bounds.width, UIScreen.main.bounds.height)
        * UIScreen.main.scale
    let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
    guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else {
        return nil
    }
    let thumbnailOptions: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceThumbnailMaxPixelSize: Int(ceil(maxPixelSize))
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(
        source,
        0,
        thumbnailOptions as CFDictionary
    ) else {
        return nil
    }
    return UIImage(cgImage: image)
}

private extension UIImage {
    var backdropDecodedByteCost: Int {
        guard let cgImage else { return 0 }
        return cgImage.bytesPerRow * cgImage.height
    }
}

/// Composites the active profile's avatar (catalog face or custom web image
/// over its accent circle)
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
              let url = AvatarCatalogStore.shared.imageURL(for: avatarId) else {
            // No avatar chosen, or the catalog/custom URL is not available:
            // show the symbol. Clearing `renderedAvatarId` lets a later
            // refresh (once the catalog arrives) re-attempt the render.
            renderedAvatarId = nil
            image = nil
            return
        }
        guard avatarId != renderedAvatarId else { return }
        renderedAvatarId = avatarId
        image = nil
        let background = UIColor(
            AvatarCatalogStore.shared.item(for: avatarId)?.backgroundColor
                ?? Color(red: 0.12, green: 0.30, blue: 0.55)
        )
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

private final class TVHomeFocusWork {
    var defersOverlayPreparation = false
    var pendingOverlayRestoreCardID: String?
    /// Remains set until the restored card's actual focus callback runs. The
    /// shared FocusState can be updated before that callback, so it cannot be
    /// used as the restore-in-progress marker by itself.
    var restoringOverlayCardID: String?
    var restoreReleaseTask: Task<Void, Never>?
    var pendingFocusedMeta: NuvioMeta?
    var pendingFocusedFolder: TVCollectionFolderItem?
    var pendingSectionId: String?
    var focusSettleTask: Task<Void, Never>?
    var enrichedHeroMetadata: [String: NuvioMeta] = [:]
    var pendingLandscapeFocusedId: String?
    var landscapeFocusTask: Task<Void, Never>?

    func cancelAll() {
        restoreReleaseTask?.cancel()
        focusSettleTask?.cancel()
        landscapeFocusTask?.cancel()
        restoreReleaseTask = nil
        focusSettleTask = nil
        landscapeFocusTask = nil
        pendingFocusedMeta = nil
        pendingFocusedFolder = nil
        pendingSectionId = nil
        pendingLandscapeFocusedId = nil
        defersOverlayPreparation = false
        pendingOverlayRestoreCardID = nil
        restoringOverlayCardID = nil
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


struct TVReauthBannerView: View {
    let onSignIn: () -> Void
    var onDismiss: (() -> Void)? = nil
    @FocusState private var isButtonFocused: Bool
    @FocusState private var isDismissFocused: Bool

    var body: some View {
        HStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(Color(red: 1.0, green: 0.72, blue: 0.2).opacity(0.22))
                    .frame(width: 46, height: 46)
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(Color(red: 1.0, green: 0.72, blue: 0.2))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.string("reauth_banner_title", fallback: "Account Sync Paused"))
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.white)

                Text(L10n.string(
                    "reauth_banner_subtitle",
                    fallback: "Your Nuvio session expired. Sign in to resume syncing your library, add-ons, and watch progress."
                ))
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(.white.opacity(0.75))
                .lineLimit(2)
            }

            Spacer(minLength: 16)

            Button(action: onSignIn) {
                HStack(spacing: 8) {
                    Image(systemName: "qrcode")
                    Text(L10n.string("tvos_account_sign_in", fallback: "Sign In"))
                }
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(isButtonFocused ? .black : .white)
                .padding(.horizontal, 22)
                .frame(height: 48)
                .loginGlassCapsule(highlighted: isButtonFocused, prominent: true)
            }
            .buttonStyle(PosterCardButtonStyle())
            .focused($isButtonFocused)
            .focusEffectDisabledIfAvailable()
            .scaleEffect(isButtonFocused ? 1.04 : 1)
            .animation(.easeOut(duration: 0.12), value: isButtonFocused)

            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(isDismissFocused ? .black : .white.opacity(0.75))
                        .frame(width: 44, height: 44)
                        .loginGlassCapsule(highlighted: isDismissFocused)
                }
                .buttonStyle(PosterCardButtonStyle())
                .focused($isDismissFocused)
                .focusEffectDisabledIfAvailable()
                .scaleEffect(isDismissFocused ? 1.05 : 1)
                .animation(.easeOut(duration: 0.12), value: isDismissFocused)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(red: 1.0, green: 0.72, blue: 0.2).opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color(red: 1.0, green: 0.72, blue: 0.2).opacity(0.32), lineWidth: 1.2)
                )
        )
        .padding(.top, 8)
        .padding(.bottom, 6)
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
    let isFullScreenOverlayPresented: Bool
    let detailsDidDisappearGeneration: UInt
    /// True while a freshly picked profile is being prepared. Keeps Home's own
    /// loader on screen for that whole beat, so the switch shows one screen
    /// instead of a cover handing over to a spinner.
    var isProfileSwitching: Bool = false
    let contentIdentity: TVHomeContentIdentity
    let collectionsRevision: UInt
    var sessionNeedsReauthentication: Bool = false
    let onNavigateToDetails: (String, String) -> Void
    let onOpenCollectionFolder: (TVCollectionFolderItem, String) -> Void
    let onResumePlayback: (ContinueWatchingItem) -> Void
    var onPlayContinueWatchingManually: ((ContinueWatchingItem) -> Void)? = nil
    var onStartContinueWatchingFromBeginning: ((ContinueWatchingItem) -> Void)? = nil
    var onRemoveFromContinueWatching: ((ContinueWatchingItem) -> Void)? = nil
    var onLongPressCard: ((NuvioMeta) -> Void)? = nil
    /// Raised instead of `onLongPressCard` for cards in the Continue Watching
    /// row, which carry resume actions the generic title menu has no use for.
    var onLongPressContinueWatching: ((ContinueWatchingItem) -> Void)? = nil
    /// Asks the account for fresh data when Nuvio Sync owns Continue Watching.
    /// That row is read from the local ledger, so nothing else here would ever
    /// notice a title deleted on another device.
    var onRequestAccountRefresh: () -> Void = {}
    var onRequestReauth: () -> Void = {}

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
    @AppStorage(SettingsKey.jellyfinLocalRowEnabled) private var jellyfinLocalRowEnabled = true

    @State private var isBannerDismissed = false

    @State private var localTitlesSection: TVHomeSection?
    @State private var jellyfinSection: TVHomeSection?
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
    @State private var rawContinueWatchingItems: [ContinueWatchingItem] = []
    @State private var continueWatching: [ContinueWatchingItem] = []
    @State private var upcomingItems: [ContinueWatchingItem] = []
    /// Derived once when Continue Watching changes. Recomputing these from the
    /// entire history inside `body` made every focus update scale with the
    /// number of loaded progress items.
    @State private var continueWatchingMetas: [NuvioMeta] = []
    @State private var upcomingMetas: [NuvioMeta] = []
    @State private var continueWatchingByMetaId: [String: ContinueWatchingItem] = [:]
    @State private var continueWatchingIndexByMetaId: [String: Int] = [:]
    @State private var continueWatchingIDs: [String] = []
    @State private var displayedProgressSource: TraktWatchProgressSource?
    @State private var continueWatchingRefreshGeneration = 0
    @State private var continueWatchingRefreshTask: Task<Void, Never>?
    @State private var simklLoadingDebugInfo: String?
    @State private var simklLoadingTimeoutTask: Task<Void, Never>?
    @State private var simklLoadingStartedAt: Date?
    @State private var isLoadingMoreContinueWatching = false
    /// Rows the current load still owes, rendered as spinner skeletons until
    /// their catalog answers. Empty whenever no load is in flight.
    @State private var homeLoadingPlaceholders: [TVHomeSection] = []
    @State private var watchedTitleKeys: Set<String> = []
    @State private var errorMessage: String?
    @State private var didRequestInitialCardFocus = false
    @State private var didPrepareInitialFocusViewport = false
    @State private var pendingInitialFocusCardKey: String?
    @State private var shouldRestoreHomeFocus = false
    /// Keeps the one externally bound card structurally unchanged while focus
    /// crosses between Home and the adaptive sidebar. This does not request
    /// focus; it only prevents removing/re-adding `.focused` around the artwork.
    @State private var retainedFocusBindingCardID: String?
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
        let _ = TVHomeDebugTrace.log("home.body.render active=\(isActive) isEnabled=\(isEnabled)")
        withFocusHandlers(withLifecycleHandlers(withSettingsHandlers(withLoadHandlers(homeContent))))
    }

    // MARK: - Body modifier groups
    //
    // `body` used to be one ~700-line expression (layout + 28 handler
    // closures); Swift 6.3's type-checker refuses it. Each group below is
    // type-checked on its own. They are methods rather than ViewModifiers so
    // they keep access to the view's private state.

    private func withLoadHandlers<Content: View>(_ content: Content) -> some View {
        content
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
            guard isActive else { return }
            Task { await loadLocalTitlesSection() }
        }
        .task(id: "\(contentIdentity.profileId):jellyfinTitles:\(jellyfinLocalRowEnabled)") {
            await loadJellyfinSection()
        }
        .onReceive(NotificationCenter.default.publisher(for: JellyfinLibraryIndex.changedNotification)) { _ in
            guard isActive else { return }
            Task { await loadJellyfinSection() }
        }
        .onAppear {
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
        // Home stays mounted behind Details/Player, so `onAppear` no longer
        // fires on return. Refresh the Continue Watching row whenever the store
        // changes (progress saved during playback, item finished/removed).
        .onReceive(NotificationCenter.default.publisher(for: ContinueWatchingStore.changedNotification).receive(on: RunLoop.main)) { _ in
            guard isActive else { return }
            refreshContinueWatching()
        }
        // A removal has to leave the row immediately, including under Trakt/Simkl
        // where the displayed list belongs to the provider and only changes on
        // the next fetch.
        .onReceive(NotificationCenter.default.publisher(for: ContinueWatchingDismissStore.changedNotification).receive(on: RunLoop.main)) { _ in
            guard isActive else { return }
            let all = continueWatching + upcomingItems
            let remaining = all.filter { !ContinueWatchingDismissStore.isDismissed($0) }
            if remaining.count != all.count {
                setContinueWatching(remaining)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: TraktAuthStore.changedNotification).receive(on: RunLoop.main)) { _ in
            guard isActive else { return }
            scheduleContinueWatchingRefresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: TraktSettingsStore.continueWatchingChangedNotification).receive(on: RunLoop.main)) { _ in
            guard isActive else { return }
            scheduleContinueWatchingRefresh()
        }
    }

    private func withSettingsHandlers<Content: View>(_ content: Content) -> some View {
        content
        // TabView can keep Home mounted while Settings is selected, so returning
        // to Home does not reliably produce another onAppear.
        .onChange(of: isActive) { _, active in
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
                if !rawContinueWatchingItems.isEmpty {
                    setContinueWatching(rawContinueWatchingItems)
                }
                if usesRemoteProgress {
                    scheduleContinueWatchingRefresh()
                } else {
                    refreshContinueWatching()
                }
                #if DEBUG
                logRowWindow("home became active")
                #endif
            } else {
                // Details and Player leave Home selected; a real tab change
                // must never carry their one-card restoration lock back Home.
                overlayRestoreGeneration &+= 1
                overlayRestoreCardID = nil
                // Android disposes Home's composition on a tab switch, which
                // cancels screen-scoped work. Mirror that cancellation while
                // keeping the shared Home store warm for the next entry.
                continueWatchingRefreshTask?.cancel()
                continueWatchingRefreshTask = nil
                continueWatchingRefreshGeneration &+= 1
                // A real tab switch can destroy the conditional Home tree
                // before LazyVStack gets another appearance callback. Keep
                // the saved target and let the next activation seed its
                // distant row/scroll position again.
                pendingInitialFocusCardKey = store.lastFocusedCardID
                didRequestInitialCardFocus = false
                didPrepareInitialFocusViewport = false
                // Arm before tvOS removes card focus. Waiting until Home becomes
                // active again is too late: focus restoration has already begun.
                armReturnFocusAnimationSuppression()
            }
        }
        .onChange(of: continueWatchingSort) { _, _ in
            if !rawContinueWatchingItems.isEmpty {
                setContinueWatching(rawContinueWatchingItems)
            }
            if usesRemoteProgress {
                scheduleContinueWatchingRefresh()
            } else {
                refreshContinueWatching()
            }
        }
        .onChange(of: hideUnreleased) { _, _ in
            if usesRemoteProgress {
                scheduleContinueWatchingRefresh()
            } else {
                refreshContinueWatching()
            }
        }
        .onChange(of: showUnairedNextUp) { _, _ in
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
        .onChange(of: upNextFromFurthestEpisode) { _, _ in
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
            guard isActive else { return }
            refreshWatchedTitles()
            // A watched mark can be the only history left for a completed
            // series. Rebuild the local row so a newly aired episode can seed a
            // fresh "Airs Today" card even after the old row was retired.
            if !usesRemoteProgress {
                ContinueWatchingBuilder.scheduleRebuild(reason: "watched state changed")
            }
        }
    }

    private func withLifecycleHandlers<Content: View>(_ content: Content) -> some View {
        content
        // Settings → Home Catalogs reorder applies to the mounted Home live.
        .onReceive(NotificationCenter.default.publisher(for: TVHomeCatalogOrder.changedNotification)) { _ in
            guard isActive else { return }
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
            guard isActive && !isFullScreenOverlayPresented else { return }
            homeReloadTask?.cancel()
            let identity = contentIdentity
            homeReloadTask = Task { @MainActor in
                await reloadHomeAfterSyncedInputs(for: identity)
            }
        }
        .onDisappear {
            focusWork.cancelAll()
            homeReloadTask?.cancel()
            continueWatchingRefreshTask?.cancel()
            continueWatchingRefreshTask = nil
            finishSimklHomeLoadingDiagnostic()
            continueWatchingRefreshGeneration &+= 1
        }
        .onChange(of: isLoading) { _, loading in
            if loading {
                requestLoadingFocus()
            }
        }
        .onChange(of: focusedPosterBackdropEnabled) { _, enabled in
            guard !enabled else { return }
            focusWork.pendingLandscapeFocusedId = nil
            focusWork.landscapeFocusTask?.cancel()
            landscapeFocusedId = nil
        }
    }

    private func withFocusHandlers<Content: View>(_ content: Content) -> some View {
        content
        .onChange(of: focusedCardID) { _, newValue in
            if let newValue {
                if let pendingInitialFocusCardKey {
                    guard pendingInitialFocusCardKey == newValue else { return }
                    self.pendingInitialFocusCardKey = nil
                } else if !didPrepareInitialFocusViewport,
                          let saved = store.lastFocusedCardID,
                          saved != newValue
                {
                    pendingInitialFocusCardKey = saved
                    return
                }
                store.lastFocusedCardID = newValue
                shouldRestoreHomeFocus = false
                if isActive {
                    releaseReturnFocusAnimationSuppression()
                }
                if isEnabled,
                   newValue == overlayRestoreCardID,
                   focusWork.restoringOverlayCardID != newValue {
                    overlayRestoreCardID = nil
                }
            } else if !focusWork.defersOverlayPreparation,
                      store.lastFocusedCardID != nil,
                      !isGridHeroFocused {
                shouldRestoreHomeFocus = true
            }
        }
        // Leaving the Grid hero for the sidebar has to arm the restore too — it
        // is the only way out of Home that never passes through a card.
        .onChange(of: isGridHeroFocused) { _, focused in
            if focused {
                shouldRestoreHomeFocus = false
            } else if !focusWork.defersOverlayPreparation,
                      focusedCardID == nil,
                      store.lastFocusedCardID != nil {
                shouldRestoreHomeFocus = true
            }
        }
        // Visible menus still toggle Home's disabled environment. Full-screen
        // overlays do not: their opacity-zero Home tree is already unfocusable,
        // and handling the overlay transition directly avoids invalidating all
        // resident shelves on Details entry.
        .onChange(of: isEnabled) { _, enabled in
            TVHomeDebugTrace.log(
                "home.overlay.isEnabled changed to \(enabled) active=\(isActive) defersPrep=\(focusWork.defersOverlayPreparation)"
            )
            // Full-screen transitions have their own handler below. This one
            // remains for the visible card-menu path and inactive TabView tabs.
            guard !isFullScreenOverlayPresented else { return }
            handleHomeOverlayStateChange(isPresented: !enabled)
        }
        .onChange(of: isFullScreenOverlayPresented) { _, presented in
            TVHomeDebugTrace.log(
                "home.overlay.fullScreen changed to \(presented) active=\(isActive) defersPrep=\(focusWork.defersOverlayPreparation)"
            )
            handleHomeOverlayStateChange(isPresented: presented)
        }
        .onChange(of: detailsDidDisappearGeneration) { _, generation in
            guard !isFullScreenOverlayPresented else { return }
            guard let target = overlayRestoreCardID,
                  focusWork.restoringOverlayCardID == target else { return }
            TVHomeDebugTrace.log(
                "home.details.disappeared generation=\(generation) restoring target=\(target)"
            )
            // Details is now out of the hierarchy, so this is the first focus
            // request that tvOS can actually commit. The card's focus callback
            // will release the one-card lock on the next run-loop turn.
            focusedCardID = target
        }
        // Removing a card takes the focus capture with it: the restore target
        // still names the card that just left, and because every other card is
        // unfocusable while a capture stands, focus lands nowhere at all. Hand
        // the slot to whatever moved into it instead.
        .onChange(of: continueWatchingIDs) { _, ids in
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
            let sectionPrefix = target.hasPrefix("\(TVHomeSection.upcomingId)\u{1}")
                ? TVHomeSection.upcomingId
                : TVHomeSection.continueWatchingId
            let successorKey = "\(sectionPrefix)\u{1}\(successorID)"
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
                        navigateToDetailsFromHome(id: meta.id, type: meta.type)
                    }
                },
                onLongPress: onLongPressCard
            )
        }
    }

    /// The Home layout tree, kept out of `body` so the layout and the
    /// 28-handler modifier chain are not one expression: the Swift 6.3
    /// type-checker gives up on the combined ~700-line version.
    private var homeContent: some View {
        ZStack(alignment: .topLeading) {
            // Match Android's AppTabHost ownership: only the selected tab owns
            // a Home render tree. TVHomeStore and this view's @State preserve
            // data/position, while image, focus, and row subtrees are released
            if isActive {
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
            .equatable()
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
                        // Match Settings: make the content a focus section with
                        // an explicit default target during the initial focus
                        // pass. The async write below remains a fallback.
                        .focusSection()
                        .defaultFocusIfAvailable($isLoadingFocusActive, true)
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
                                navigateToDetailsFromHome(id: heroMeta.id, type: heroMeta.type)
                            }
                            .equatable()
                        }
                    }
                    
                    // Android uses a LazyColumn of LazyRows: only viewport rows
                    // and cards own render work. Keep the vertical Home strip
                    // lazy as well; rows retain their horizontal position in
                    // `rowScrollStore` while focused-row shells preserve focus.
                    GeometryReader { proxy in
                        let sections = visibleSections.filter(\.hasContent)
                        let horizontalEdgeInset = max(
                            0,
                            (UIScreen.main.bounds.width - proxy.size.width) / 2
                        )
                        if homeLayout == "Grid View" {
                            // Grid Home has no row strip to hold open, so a
                            // skeleton there would just be an empty heading.
                            // This proxy is laid out inside the horizontal safe
                            // area, so hand the grid the inset it has to cancel
                            // out for a hero that reaches the screen edges.
                            homeGrid(
                                sections: sections.filter { !$0.isLoadingPlaceholder },
                                heroBleed: horizontalEdgeInset
                            )
                        } else {
                            // Native lazy vertical scrolling for the rows. The
                            // focused row ±2 window controls real card/artwork
                            // materialization; lazy mounting limits row work
                            // outside the viewport without changing row geometry.
                            ScrollViewReader { verticalScrollProxy in
                                ScrollView(.vertical, showsIndicators: false) {
                                    LazyVStack(alignment: .leading, spacing: TVHomeLayout.sectionSpacing) {
                                        if sessionNeedsReauthentication && !isBannerDismissed {
                                            TVReauthBannerView(
                                                onSignIn: onRequestReauth,
                                                onDismiss: {
                                                    withAnimation(.easeInOut(duration: 0.2)) {
                                                        isBannerDismissed = true
                                                    }
                                                }
                                            )
                                            .padding(.horizontal, horizontalEdgeInset)
                                        }

                                        ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                                        if section.isLoadingPlaceholder {
                                            TVLoadingCatalogRow(title: section.title)
                                                .frame(
                                                    height: estimatedHeight(for: section),
                                                    alignment: .topLeading
                                                )
                                        } else if !section.collectionFolders.isEmpty {
                                            TVCollectionFolderRow(
                                                id: section.id,
                                                title: section.title,
                                                horizontalEdgeInset: horizontalEdgeInset,
                                                folders: section.collectionFolders,
                                                initialScrollIndex: rowScrollStore.index(for: section.id),
                                                onScrollIndexChange: { newIndex in
                                                    rowScrollStore.setIndex(newIndex, for: section.id)
                                                },
                                                initialFocusCardKey: initialFocusCardKey,
                                                externalFocus: $focusedCardID,
                                                restrictFocusToCardKey: overlayRestoreCardID,
                                                retainFocusAppearanceForCardKey: overlayRestoreCardID,
                                                suppressFocusAnimations: suppressReturnFocusAnimations
                                                    && focusedRowIndex == index,
                                                isRowFocused: focusedRowIndex == index,
                                                onInitialFocusRequested: {
                                                    didRequestInitialCardFocus = true
                                                },
                                                onFocus: { folder in
                                                    let cardKey = "\(section.id)\u{1}\(folder.id)"
                                                    if focusWork.restoringOverlayCardID == cardKey {
                                                        completeOverlayFocusRestore(for: cardKey)
                                                    }
                                                    let changedRow = focusedRowIndex != index
                                                    if changedRow {
                                                        focusedRowIndex = index
                                                        withAnimation(TVHomeLayout.verticalScrollAnimation) {
                                                            verticalScrollProxy.scrollTo(section.id, anchor: .top)
                                                        }
                                                    } else {
                                                        var transaction = Transaction()
                                                        transaction.animation = nil
                                                        withTransaction(transaction) {
                                                            verticalScrollProxy.scrollTo(section.id, anchor: .top)
                                                        }
                                                    }
                                                    focusedCardID = cardKey
                                                    settleFolderFocus(folder, in: section.id)
                                                },
                                                onSelect: { folder in
                                                    overlayRestoreCardID = "\(section.id)\u{1}\(folder.id)"
                                                    onOpenCollectionFolder(folder, section.title)
                                                }
                                            )
                                            .equatable()
                                            .id(section.id)
                                         } else {
                                            TVCatalogRow(
                                                id: section.id,
                                                title: section.title,
                                                horizontalEdgeInset: horizontalEdgeInset,
                                                items: section.items,
                                                progressByItemId: (section.id == TVHomeSection.continueWatchingId || section.id == TVHomeSection.upcomingId)
                                                    ? continueWatchingByMetaId : [:],
                                                watchedTitleKeys: watchedTitleKeys,
                                                initialScrollIndex: rowScrollStore.index(for: section.id),
                                                onScrollIndexChange: { newIndex in
                                                    rowScrollStore.setIndex(newIndex, for: section.id)
                                                },
                                                initialFocusCardKey: initialFocusCardKey,
                                                landscapeFocusedId: landscapeFocusedId(for: section.id),
                                                externalFocus: $focusedCardID,
                                                restrictFocusToCardKey: overlayRestoreCardID,
                                                retainFocusAppearanceForCardKey: overlayRestoreCardID,
                                                suppressFocusAnimations: suppressReturnFocusAnimations
                                                    && focusedRowIndex == index,
                                                isRowFocused: focusedRowIndex == index,
                                                onInitialFocusRequested: {
                                                    didRequestInitialCardFocus = true
                                                },
                                                onFocus: { meta in
                                                    let focusStarted = TVHomeDebugTrace.now()
                                                    let cardKey = "\(section.id)\u{1}\(meta.id)"
                                                    let changedRow = focusedRowIndex != index
                                                    TVHomeDebugTrace.log(
                                                        "home.focus.begin section=\(section.id) meta=\(meta.id) "
                                                            + "changedRow=\(changedRow) fromRow=\(focusedRowIndex) toRow=\(index)"
                                                    )
                                                    if focusWork.restoringOverlayCardID == cardKey {
                                                        completeOverlayFocusRestore(for: cardKey)
                                                    }
                                                    if changedRow {
                                                        focusedRowIndex = index
                                                        TVHomeDebugTrace.log(
                                                            "home.scrollTo section=\(section.id) anchor=top"
                                                        )
                                                        withAnimation(TVHomeLayout.verticalScrollAnimation) {
                                                            verticalScrollProxy.scrollTo(section.id, anchor: .top)
                                                        }
                                                    } else {
                                                        var transaction = Transaction()
                                                        transaction.animation = nil
                                                        withTransaction(transaction) {
                                                            verticalScrollProxy.scrollTo(section.id, anchor: .top)
                                                        }
                                                    }
                                                    focusedCardID = cardKey
                                                    settleCatalogFocus(on: meta, in: section.id)
                                                    scheduleLandscapeFocus(cardKey: cardKey)
                                                    TVHomeDebugTrace.log(
                                                        "home.focus.end section=\(section.id) meta=\(meta.id) "
                                                            + "ms=\(TVHomeDebugTrace.elapsedMilliseconds(since: focusStarted))"
                                                    )
                                                },
                                                onBlur: { meta in
                                                    clearLandscapeFocus(cardKey: "\(section.id)\u{1}\(meta.id)")
                                                },
                                                onApproachEnd: { meta in
                                                    loadMoreSectionIfNeeded(
                                                        sectionId: section.id, currentItem: meta)
                                                },
                                                onSelect: { meta in
                                                    if (section.id == TVHomeSection.continueWatchingId || section.id == TVHomeSection.upcomingId),
                                                        let item = continueWatchingByMetaId[meta.id]
                                                    {
                                                        if item.isUpNextEntry && !item.hasAired && !item.isAiringToday {
                                                            let cardKey = "\(section.id)\u{1}\(meta.id)"
                                                            navigateToDetailsFromHome(
                                                                id: meta.id,
                                                                type: meta.type,
                                                                restoreCardID: cardKey
                                                            )
                                                        } else {
                                                            onResumePlayback(item)
                                                        }
                                                    } else {
                                                        let cardKey = "\(section.id)\u{1}\(meta.id)"
                                                        navigateToDetailsFromHome(
                                                            id: meta.id,
                                                            type: meta.type,
                                                            restoreCardID: cardKey
                                                        )
                                                    }
                                                },
                                                onLongPress: longPressHandler(for: section.id),
                                                onOpenDetails: { meta in
                                                    let cardKey = "\(section.id)\u{1}\(meta.id)"
                                                    navigateToDetailsFromHome(
                                                        id: meta.id,
                                                        type: meta.type,
                                                        restoreCardID: cardKey
                                                    )
                                                },
                                                onPlayContinueWatchingManually: onPlayContinueWatchingManually,
                                                onStartContinueWatchingFromBeginning: onStartContinueWatchingFromBeginning,
                                                onRemoveFromContinueWatching: onRemoveFromContinueWatching
                                            )
                                            .equatable()
                                            .id(section.id)
                                        }  // end catalog vs collection branch
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.top, TVHomeLayout.rowsTopPadding)
                                    .padding(.bottom, 80)
                                    .onAppear {
                                        prepareInitialFocusViewport(
                                            for: sections,
                                            using: verticalScrollProxy
                                        )
                                    }
                                    .onChange(of: initialFocusContentSignature) { _, _ in
                                        prepareInitialFocusViewport(
                                            for: sections,
                                            using: verticalScrollProxy
                                        )
                                    }

                                    // The final row otherwise hits the
                                    // ScrollView's bottom limit before it can
                                    // reach the same fixed position as the
                                    // preceding rows. Keep a full viewport of
                                    // non-focusable runway, plus the 24pt
                                    // design inset, after the last catalog.
                                    Color.clear
                                        .frame(height: proxy.size.height + TVHomeLayout.finalRowScrollRunway)
                                        .accessibilityHidden(true)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    // Treat the rows as a focus section so focus can jump in/out
                    // cleanly. The default focus is only armed after Home loses
                    // focus, so the first Menu press can still reach the sidebar,
                    // while returning from the sidebar restores the saved card.
                    .focusSection()
                    .defaultFocusIfAvailable($focusedCardID, store.lastFocusedCardID ?? focusWork.pendingOverlayRestoreCardID)
                }
            }
            // Ignore the bottom safe-area inset too, so the scrolling rows window
            // runs to the screen's bottom edge instead of stopping short and
            // leaving a black bar below the lowest visible row.
            .ignoresSafeArea(.container, edges: [.top, .bottom])

            }

            if let report = simklLoadingDebugInfo, !report.isEmpty {
                SimklHomeLoadingDebugReport(report: report)
                    .frame(maxWidth: 920)
                    .padding(.horizontal, 48)
                    .padding(.top, 48)
                    .zIndex(20)
                    .allowsHitTesting(false)
            }
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
                if sessionNeedsReauthentication && !isBannerDismissed {
                    TVReauthBannerView(
                        onSignIn: onRequestReauth,
                        onDismiss: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isBannerDismissed = true
                            }
                        }
                    )
                    .padding(.horizontal, heroBleed)
                }

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
                        navigateToDetailsFromHome(id: selectedMeta.id, type: selectedMeta.type)
                    }
                }

                ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                    if !section.collectionFolders.isEmpty {
                        TVCollectionFolderRow(
                            id: section.id,
                            title: section.title,
                            horizontalEdgeInset: heroBleed,
                            folders: section.collectionFolders,
                            initialScrollIndex: rowScrollStore.index(for: section.id),
                            onScrollIndexChange: { rowScrollStore.setIndex($0, for: section.id) },
                            initialFocusCardKey: initialFocusCardKey,
                            externalFocus: $focusedCardID,
                            restrictFocusToCardKey: overlayRestoreCardID,
                            retainFocusAppearanceForCardKey: overlayRestoreCardID,
                            suppressFocusAnimations: suppressReturnFocusAnimations
                                && focusedRowIndex == index,
                            isRowFocused: focusedRowIndex == index,
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
                    } else if section.id == TVHomeSection.continueWatchingId || section.id == TVHomeSection.upcomingId {
                        TVCatalogRow(
                            id: section.id,
                            title: section.title,
                            horizontalEdgeInset: heroBleed,
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
                            suppressFocusAnimations: suppressReturnFocusAnimations
                                && focusedRowIndex == index,
                            isRowFocused: focusedRowIndex == index,
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
                                    if item.isUpNextEntry && !item.hasAired && !item.isAiringToday {
                                        let cardKey = "\(section.id)\u{1}\(meta.id)"
                                        navigateToDetailsFromHome(
                                            id: meta.id,
                                            type: meta.type,
                                            restoreCardID: cardKey
                                        )
                                    } else {
                                        onResumePlayback(item)
                                    }
                                }
                            },
                            onLongPress: longPressHandler(for: section.id),
                            onOpenDetails: { meta in
                                let cardKey = "\(section.id)\u{1}\(meta.id)"
                                navigateToDetailsFromHome(
                                    id: meta.id,
                                    type: meta.type,
                                    restoreCardID: cardKey
                                )
                            },
                            onPlayContinueWatchingManually: onPlayContinueWatchingManually,
                            onStartContinueWatchingFromBeginning: onStartContinueWatchingFromBeginning,
                            onRemoveFromContinueWatching: onRemoveFromContinueWatching
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
                                navigateToDetailsFromHome(
                                    id: meta.id,
                                    type: meta.type,
                                    restoreCardID: "\(section.id)\u{1}\(meta.id)"
                                )
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
    /// The meta id inside a Continue Watching or Upcoming card key, or nil for any other row.
    private func continueWatchingMetaID(inCardKey key: String) -> String? {
        let cwPrefix = "\(TVHomeSection.continueWatchingId)\u{1}"
        if key.hasPrefix(cwPrefix) {
            return String(key.dropFirst(cwPrefix.count))
        }
        let upPrefix = "\(TVHomeSection.upcomingId)\u{1}"
        if key.hasPrefix(upPrefix) {
            return String(key.dropFirst(upPrefix.count))
        }
        return nil
    }

    /// Handles focus capture for both visible menus and full-screen overlays.
    /// Full-screen presentation intentionally does not toggle Home's disabled
    /// environment, so this transition hook replaces the old Details-specific
    /// `isEnabled` callback without rebuilding every resident shelf.
    private func handleHomeOverlayStateChange(isPresented: Bool) {
        // TabView may disable an unselected Home tab. Only overlay restoration
        // while Home remains selected should touch the saved focus target.
        guard isActive else {
            overlayRestoreGeneration &+= 1
            overlayRestoreCardID = nil
            return
        }

        if isPresented {
            // Direct Home → Details navigation already captured the target in
            // reference storage. Avoid publishing the one-card lock now; doing
            // so would rebuild every resident shelf before Details can draw.
            if focusWork.defersOverlayPreparation {
                TVHomeDebugTrace.log("home.overlay.presentation deferring preparation")
                focusWork.landscapeFocusTask?.cancel()
                focusWork.pendingLandscapeFocusedId = nil
                focusWork.focusSettleTask?.cancel()
                return
            }

            // For visible menus and non-Home overlay entry, capture the target
            // before focus is removed so the return path cannot jump to the
            // first card.
            armReturnFocusAnimationSuppression()
            overlayRestoreGeneration &+= 1
            let target = focusedCardID ?? store.lastFocusedCardID
            TVHomeDebugTrace.log("home.overlay.presentation setting target=\(target ?? "nil")")
            overlayRestoreCardID = target
        } else if focusWork.defersOverlayPreparation {
            let target = focusWork.pendingOverlayRestoreCardID
            focusWork.defersOverlayPreparation = false
            focusWork.pendingOverlayRestoreCardID = nil
            guard let target else {
                TVHomeDebugTrace.log("home.overlay.dismissal defersPrep with nil target")
                return
            }

            // Build the restriction only on return. Details is no longer
            // competing with this Home render, and delayed focus writes run
            // after the target modifier is mounted.
            armReturnFocusAnimationSuppression()
            overlayRestoreGeneration &+= 1
            TVHomeDebugTrace.log("home.overlay.dismissal restoring to target=\(target) gen=\(overlayRestoreGeneration)")
            overlayRestoreCardID = target
            restoreOverlayFocus(
                to: target,
                generation: overlayRestoreGeneration,
                waitForDetailsDisappearance: true
            )
        } else if let target = overlayRestoreCardID {
            TVHomeDebugTrace.log("home.overlay.dismissal fallback restoring to target=\(target) gen=\(overlayRestoreGeneration)")
            restoreOverlayFocus(to: target, generation: overlayRestoreGeneration)
        }
    }

    private func restoreOverlayFocus(
        to target: String,
        generation: Int,
        waitForDetailsDisappearance: Bool = false
    ) {
        TVHomeDebugTrace.log(
            "home.restoreOverlayFocus begin target=\(target) gen=\(generation) "
                + "waitForDetailsDisappearance=\(waitForDetailsDisappearance)"
        )
        focusWork.restoringOverlayCardID = target

        if waitForDetailsDisappearance {
            // The Details view is still mounted at this point. Its actual
            // onDisappear callback will issue the first focus request that
            // tvOS can commit; timer writes here only create a visible delay.
            TVHomeDebugTrace.log("home.restoreOverlayFocus waiting for details.disappear")
        } else {
            focusedCardID = target
            // Visible menus do not have a Details transition to wait for, so
            // retain their short retry window.
            for delay in [0.04, 0.12, 0.25, 0.45] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    if overlayRestoreGeneration == generation, overlayRestoreCardID == target {
                        TVHomeDebugTrace.log("home.restoreOverlayFocus fire target=\(target) delay=\(delay)")
                        focusedCardID = target
                    }
                }
            }
        }

        // Safety fallback if the lifecycle callback is lost. Normally the
        // target card's focus callback clears the lock much earlier.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            if overlayRestoreGeneration == generation, overlayRestoreCardID == target {
                TVHomeDebugTrace.log("home.restoreOverlayFocus safety cleanup target=\(target)")
                if waitForDetailsDisappearance {
                    focusedCardID = target
                }
                overlayRestoreCardID = nil
                if focusWork.restoringOverlayCardID == target {
                    focusWork.restoringOverlayCardID = nil
                }
            }
        }
    }

    /// Release the one-card focus lock as soon as the intended card's real
    /// focus callback confirms restoration. Defer the unlock by one run-loop
    /// turn so the current focus transaction finishes with only that card
    /// eligible; unlocking inside the callback let tvOS jump to the first row
    /// in the six-row focus window (two rows above).
    private func completeOverlayFocusRestore(for cardKey: String) {
        guard focusWork.restoringOverlayCardID == cardKey else { return }
        let generation = overlayRestoreGeneration
        TVHomeDebugTrace.log("home.completeOverlayFocusRestore start cardKey=\(cardKey) gen=\(generation)")
        DispatchQueue.main.async {
            guard overlayRestoreGeneration == generation,
                  focusWork.restoringOverlayCardID == cardKey,
                  overlayRestoreCardID == cardKey else { return }

            TVHomeDebugTrace.log("home.completeOverlayFocusRestore done cardKey=\(cardKey)")
            focusWork.restoringOverlayCardID = nil
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) {
                overlayRestoreCardID = nil
                focusedCardID = cardKey
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
        if let pendingInitialFocusCardKey {
            return pendingInitialFocusCardKey
        }
        if let saved = store.lastFocusedCardID {
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

    /// Stable, small signature for progressive row publication. It lets the
    /// lazy viewport retry saved-focus preparation without comparing metadata
    /// arrays or rebuilding work for every card.
    private var initialFocusContentSignature: String {
        let sectionSignature = visibleSections.map { section in
            "\(section.id)\u{1}\(section.isLoadingPlaceholder ? 1 : 0)"
                + "\u{1}\(section.items.count)\u{1}\(section.collectionFolders.count)"
        }
        .joined(separator: "\u{1e}")
        return "\(store.hasLoaded)\u{1e}\(sectionSignature)"
    }

    /// Finds the saved card without assuming that section or card IDs contain
    /// no separators. The lazy vertical stack must know the distant section
    /// before its card can run the existing initial-focus callback.
    private func initialFocusLocation(
        in sections: [TVHomeSection]
    ) -> (sectionIndex: Int, sectionID: String, cardIndex: Int)? {
        guard let focusKey = initialFocusCardKey else { return nil }

        for (sectionIndex, section) in sections.enumerated() {
            let prefix = "\(section.id)\u{1}"
            guard focusKey.hasPrefix(prefix) else { continue }
            let cardID = String(focusKey.dropFirst(prefix.count))

            if let cardIndex = section.collectionFolders.firstIndex(where: { $0.id == cardID }) {
                return (sectionIndex, section.id, cardIndex)
            }
            if let cardIndex = section.items.firstIndex(where: { $0.id == cardID }) {
                return (sectionIndex, section.id, cardIndex)
            }
        }
        return nil
    }

    /// Seeds both vertical and horizontal restoration state before a distant
    /// saved card can request focus from a lazily mounted row.
    private func prepareInitialFocusViewport(
        for sections: [TVHomeSection],
        using proxy: ScrollViewProxy
    ) {
        guard !didPrepareInitialFocusViewport else { return }
        guard let location = initialFocusLocation(in: sections) else {
            // Keep a saved target alive while progressive loading has not yet
            // published its section. Once the final tree is known, fall back
            // safely to normal first-row focus if that card truly disappeared.
            if !store.hasLoaded {
                if pendingInitialFocusCardKey == nil {
                    pendingInitialFocusCardKey = store.lastFocusedCardID
                }
                return
            }
            pendingInitialFocusCardKey = nil
            didPrepareInitialFocusViewport = true
            store.lastFocusedCardID = nil
            return
        }

        didPrepareInitialFocusViewport = true
        focusedRowIndex = location.sectionIndex
        rowScrollStore.setIndex(location.cardIndex, for: location.sectionID)

        // Fresh first-row focus already has the correct viewport. Preserve its
        // existing first-load behavior and only move the lazy stack for a
        // distant saved section.
        guard location.sectionIndex > 0 else { return }
        DispatchQueue.main.async {
            guard !self.didRequestInitialCardFocus else { return }
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) {
                proxy.scrollTo(location.sectionID, anchor: .top)
            }
        }
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
        return section.collectionFolders.isEmpty
            ? estimatedCatalogRowHeight
            : estimatedCollectionRowHeight(for: section)
    }

    /// Captures return identity without publishing SwiftUI state. Publishing
    /// `overlayRestoreCardID` here invalidates the entire Home tree on the same
    /// frame that Details is trying to mount, which is why Search felt faster.
    private func navigateToDetailsFromHome(
        id: String,
        type: String,
        restoreCardID: String? = nil
    ) {
        focusWork.defersOverlayPreparation = true
        focusWork.pendingOverlayRestoreCardID = restoreCardID
            ?? focusedCardID
            ?? store.lastFocusedCardID
        onNavigateToDetails(id, type)
    }

    private var visibleSections: [TVHomeSection] {
        let resumeSection = TVHomeSection(
            id: TVHomeSection.continueWatchingId,
            title: L10n.string("home_continue_watching", fallback: "Continue Watching"),
            items: continueWatchingMetas
        )
        let upcomingSection = TVHomeSection(
            id: TVHomeSection.upcomingId,
            title: L10n.string("tvos_home_upcoming", fallback: "Upcoming"),
            items: upcomingMetas
        )
        let pinnedSections = (continueWatching.isEmpty ? [] : [resumeSection])
            + (upcomingMetas.isEmpty ? [] : [upcomingSection])
            + [localTitlesSection, jellyfinSection].compactMap { $0 }
        let allSections = pinnedSections + store.sections

        // The common path does not need to copy and filter every add-on row on
        // each focus update. Keep the original copy-on-write item arrays intact.
        guard hideUnreleased else { return allSections }

        let today = ContentReleasePolicy.todayIsoDay()
        return allSections.map { section in
            // Collection folder rows don't carry title posters; leave them intact.
            if !section.collectionFolders.isEmpty
                || section.id == TVHomeSection.localTitlesId
                || section.id == TVHomeSection.jellyfinId {
                return section
            }
            var copy = section
            copy.items = section.items.filter {
                !ContentReleasePolicy.isUnreleased($0, today: today)
            }
            return copy
        }
    }

    /// Held cards in the Continue Watching / Upcoming row open the resume menu; every other
    /// row keeps the generic title menu. A Continue Watching card whose entry has
    /// since gone (the row refreshed mid-press) falls back rather than doing
    /// nothing.
    private func longPressHandler(for sectionId: String) -> ((NuvioMeta) -> Void)? {
        guard (sectionId == TVHomeSection.continueWatchingId || sectionId == TVHomeSection.upcomingId),
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
    /// actually in the Continue Watching / Upcoming row. The same title can also appear in
    /// catalog rows (Popular etc.), where the hero should stay generic.
    private func heroContinueItem(for meta: NuvioMeta) -> ContinueWatchingItem? {
        guard visibleFocusedMeta != nil,
              (focusedSectionId == TVHomeSection.continueWatchingId || focusedSectionId == TVHomeSection.upcomingId) else { return nil }
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
            $0.id != TVHomeSection.continueWatchingId && $0.id != TVHomeSection.upcomingId && $0.collectionFolders.isEmpty
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
        (!item.isUpNextEntry || ContinueWatchingFeatureFlags.nextUpCardsEnabled)
            && isVisible(item.meta)
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
        guard identity.profileId != "none" && !identity.profileId.isEmpty else {
            isLoading = false
            return
        }
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
        guard identity.profileId != "none" && !identity.profileId.isEmpty else {
            isLoading = false
            return
        }
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
        guard identity.profileId != "none" && !identity.profileId.isEmpty else { return }
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
        didPrepareInitialFocusViewport = false
        pendingInitialFocusCardKey = nil
        shouldRestoreHomeFocus = false
        retainedFocusBindingCardID = nil
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
                  row.id != TVHomeSection.upcomingId,
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
        return sections
    }

    /// Re-resolves collection rows in place after a sync pull / local edit
    /// lands while Home is already loaded, without disturbing catalog rows.
    private func refreshCollectionSections(for identity: TVHomeContentIdentity) async {
        guard identity.profileId != "none" && !identity.profileId.isEmpty else { return }
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
        let delay = heroSettleNanoseconds
        TVHomeDebugTrace.log(
            "hero.schedule section=\(targetSectionId ?? "nil") meta=\(targetMetaId ?? "nil") "
                + "folder=\(targetFolderId ?? "nil") delayMs=\(delay / 1_000_000)"
        )

        focusWork.focusSettleTask = Task { @MainActor in
            let started = TVHomeDebugTrace.now()
            try? await Task.sleep(nanoseconds: delay)
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
                TVHomeDebugTrace.log(
                    "hero.publish folder=\(folder.id) elapsedMs=\(TVHomeDebugTrace.elapsedMilliseconds(since: started))"
                )
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

            TVHomeDebugTrace.log(
                "hero.publish section=\(targetSectionId) meta=\(settledMeta.id) "
                    + "enrich=\(settledMeta.needsHeroMetadataEnrichment) "
                    + "elapsedMs=\(TVHomeDebugTrace.elapsedMilliseconds(since: started))"
            )

            // Third-party catalog responses are often intentionally compact
            // and omit runtime/status and shelf artwork. Once focus settles,
            // ask for the full metadata record and fill the missing fields.
            guard settledMeta.needsHeroMetadataEnrichment else { return }
            await enrichSettledCatalogMeta(settledMeta, in: targetSectionId)
        }
    }

    /// Fetches (or reuses the cached) full `/meta` record for a catalog card
    /// focus has rested on and merges the missing fields into it. Debounced by
    /// `scheduleHeroSettle`, so rapid navigation never generates a request per
    /// card passed over. The merged record replaces `focusedMeta` (hero), the
    /// pending focus target, and the exact item inside
    /// `store.sections[sectionId].items` — the latter being what `PosterCard`
    /// renders, so the landscape overlay gains the title logo/backdrop.
    @MainActor
    private func enrichSettledCatalogMeta(_ settledMeta: NuvioMeta, in sectionId: String) async {
        let enrichmentKey = "\(settledMeta.type.lowercased())\u{1f}\(settledMeta.id)"
        let fullMeta: NuvioMeta
        if let cached = focusWork.enrichedHeroMetadata[enrichmentKey] {
            fullMeta = cached
        } else {
            guard let fetched = try? await repository.getMetadata(
                id: settledMeta.id,
                type: settledMeta.type
            ) else {
                return
            }
            // Cache even when focus has already moved on, so the next visit to
            // this card reuses the fetch instead of repeating it.
            focusWork.enrichedHeroMetadata[enrichmentKey] = fetched
            fullMeta = fetched
        }

        let merged = settledMeta.fillingMissingHeroMetadata(from: fullMeta)
        // Publish only while this card is still the settled focus target: a
        // stale record must never overwrite the hero mid-navigation.
        guard !Task.isCancelled,
              focusWork.pendingFocusedMeta?.id == settledMeta.id,
              focusWork.pendingSectionId == sectionId,
              focusWork.pendingFocusedFolder == nil else {
            return
        }
        focusedMeta = merged
        focusWork.pendingFocusedMeta = merged
        guard let sectionIndex = store.sections.firstIndex(where: { $0.id == sectionId }),
              let itemIndex = store.sections[sectionIndex].items.firstIndex(where: { $0.id == settledMeta.id }) else {
            return
        }
        if store.sections[sectionIndex].items[itemIndex] != merged {
            store.sections[sectionIndex].items[itemIndex] = merged
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
        if sectionId == TVHomeSection.upcomingId {
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
        // reveal those before making another network request. These records
        // skipped the TMDB enrichment the first 18 items went through, so pass
        // the batch through the same preparation so post-18 cards show the
        // same shelf artwork (logo/backdrop) as the head of the row.
        if !section.pendingItems.isEmpty {
            let batchCount = min(18, section.pendingItems.count)
            let batch = Array(section.pendingItems.prefix(batchCount))
            store.sections[sectionIndex].pendingItems.removeFirst(batchCount)
            store.sections[sectionIndex].isLoadingMore = true
            Task { @MainActor in
                defer {
                    if let latestIndex = store.sections.firstIndex(where: { $0.id == sectionId }) {
                        store.sections[latestIndex].isLoadingMore = false
                    }
                }
                let enrichedBatch = await TmdbDetailsService.localizedMetadata(for: batch)
                guard let latestIndex = store.sections.firstIndex(where: { $0.id == sectionId }) else {
                    return
                }
                let currentIds = Set(store.sections[latestIndex].items.map(\.id))
                store.sections[latestIndex].items.append(
                    contentsOf: enrichedBatch.filter { !currentIds.contains($0.id) }
                )
                store.sections[latestIndex].hasMore =
                    !store.sections[latestIndex].pendingItems.isEmpty
                    || (store.sections[latestIndex].contentType != nil && store.sections[latestIndex].catalogId != nil)
            }
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
        TVHomeDebugTrace.log(
            "backdrop.schedule card=\(cardKey) delayMs=\(delaySeconds * 1_000)"
        )
        focusWork.landscapeFocusTask = Task { @MainActor in
            let started = TVHomeDebugTrace.now()
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds) * 1_000_000_000)
            guard !Task.isCancelled,
                  focusWork.pendingLandscapeFocusedId == targetKey else {
                return
            }

            landscapeFocusedId = targetKey
            TVHomeDebugTrace.log(
                "backdrop.publish card=\(targetKey) elapsedMs=\(TVHomeDebugTrace.elapsedMilliseconds(since: started))"
            )
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

        if !focusWork.defersOverlayPreparation, landscapeFocusedId == cardKey {
            landscapeFocusedId = nil
        }
    }

    /// Publishes Continue Watching and its derived lookup data together. The
    /// row is updated from notifications and source refreshes, while Home can
    /// re-evaluate its body dozens of times during focus movement; keeping the
    /// metadata array and progress index out of those body computations is the
    /// important part of this helper.
    private func setContinueWatching(_ rawItems: [ContinueWatchingItem]) {
        rawContinueWatchingItems = rawItems
        let (items, upcoming): ([ContinueWatchingItem], [ContinueWatchingItem]) = {
            if continueWatchingSort == "Separate Upcoming Row" {
                let released = ContinueWatchingSortPolicy.sorted(rawItems, preference: continueWatchingSort)
                let unreleased = ContinueWatchingSortPolicy.upcomingItems(rawItems)
                return (released, unreleased)
            } else {
                return (ContinueWatchingSortPolicy.sorted(rawItems, preference: continueWatchingSort), [])
            }
        }()

        TVHomeDebugTrace.log(
            "cw.set incoming=\(rawItems.count) showing=\(items.count) upcoming=\(upcoming.count) "
                + "upNext=\(rawItems.filter(\.isUpNextEntry).count)"
        )
        let all = items + upcoming
        var byMetaId = Dictionary<String, ContinueWatchingItem>(
            minimumCapacity: all.count
        )
        var indexByMetaId = Dictionary<String, Int>(minimumCapacity: items.count)
        for (index, item) in items.enumerated() {
            if let existing = byMetaId[item.meta.id], existing.lastWatchedAt >= item.lastWatchedAt {
                continue
            }
            byMetaId[item.meta.id] = item
            indexByMetaId[item.meta.id] = index
        }
        for item in upcoming {
            if byMetaId[item.meta.id] == nil {
                byMetaId[item.meta.id] = item
            }
        }

        continueWatching = items
        // The full series episode guide remains on the source item for resume,
        // episode lookup, and playback. The row cards only need presentation
        // metadata; keeping hundreds of `videos` entries in every SwiftUI card
        // value makes repeated focus/layout passes carry unnecessary payload.
        continueWatchingMetas = items.map { $0.meta.persistenceSnapshot }
        upcomingItems = upcoming
        upcomingMetas = upcoming.map { $0.meta.persistenceSnapshot }
        continueWatchingByMetaId = byMetaId
        continueWatchingIndexByMetaId = indexByMetaId
        continueWatchingIDs = items.map(\.meta.id)
    }

    private func refreshContinueWatching() {
        guard !usesRemoteProgress else {
            if displayedProgressSource != selectedProgressSource {
                setContinueWatching([])
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
        setContinueWatching(visibleItems)
        displayedProgressSource = .nuvioSync
        #if DEBUG
        logRowWindow("after CW refresh (\(continueWatching.count) item(s), \(upcomingItems.count) upcoming)")
        #endif
    }

    #if DEBUG
    /// Reports which rows are focusable versus placeholders, and what the row
    /// window is centred on. Vertical navigation dying on Home means the centre
    /// disagrees with where focus actually is, and that is invisible otherwise.
    private func logRowWindow(_ reason: String) {
        let sections = visibleSections.filter(\.hasContent)
    }
    #endif

    /// Pages in more of the account's history as focus nears the end of the
    /// Continue Watching row, the same way a catalog row loads its next page.
    /// Everything is already in the local ledger, so this only costs metadata
    /// lookups for titles this device has not rendered before.
    private func loadMoreContinueWatchingIfNeeded(currentItem: NuvioMeta) {
        let continueIndex = continueWatchingIndexByMetaId[currentItem.id]
        TVHomeDebugTrace.log(
            "cw.approach id=\(currentItem.id) index=\(continueIndex.map(String.init) ?? "nil") "
                + "count=\(continueWatching.count) canMore=\(ContinueWatchingBuilder.canLoadMore) "
                + "loading=\(isLoadingMoreContinueWatching)"
        )
        guard !usesRemoteProgress,
              ContinueWatchingBuilder.canLoadMore,
              !isLoadingMoreContinueWatching,
              let index = continueIndex,
              index >= max(continueWatching.count - TVHomeRowPrefetchThreshold, 0) else {
            return
        }
        isLoadingMoreContinueWatching = true
        TVHomeDebugTrace.log("cw.approach loadNextPage start count=\(continueWatching.count)")
        Task { @MainActor in
            defer { isLoadingMoreContinueWatching = false }
            _ = await ContinueWatchingBuilder.loadNextPage()
            guard !usesRemoteProgress else { return }
            refreshContinueWatching()
            TVHomeDebugTrace.log("cw.approach loadNextPage end count=\(continueWatching.count)")
        }
    }

    private func scheduleContinueWatchingRefresh() {
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
        let isSimklRefresh = source == .simkl

        if isSimklRefresh {
            beginSimklHomeLoadingDiagnostic(generation: generation)
        } else {
            finishSimklHomeLoadingDiagnostic()
        }
        defer {
            if isSimklRefresh, generation == continueWatchingRefreshGeneration {
                finishSimklHomeLoadingDiagnostic()
            }
        }

        refreshContinueWatching()
        guard usesRemoteProgress else {
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
            return
        }
        guard generation == continueWatchingRefreshGeneration else {
            return
        }
        guard profileID == ContinueWatchingStore.activeProfileId else {
            return
        }
        guard source == selectedProgressSource, usesRemoteProgress else {
            return
        }
        guard let items else {
            return
        }
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
        setContinueWatching(visibleItems)
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

    private func beginSimklHomeLoadingDiagnostic(generation: Int) {
        simklLoadingTimeoutTask?.cancel()
        simklLoadingStartedAt = Date()
        simklLoadingDebugInfo = nil
        simklLoadingTimeoutTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled,
                  generation == continueWatchingRefreshGeneration,
                  selectedProgressSource == .simkl else { return }
            simklLoadingDebugInfo = makeSimklHomeLoadingDebugInfo()
        }
    }

    private func finishSimklHomeLoadingDiagnostic() {
        simklLoadingTimeoutTask?.cancel()
        simklLoadingTimeoutTask = nil
        simklLoadingStartedAt = nil
        simklLoadingDebugInfo = nil
    }

    private func makeSimklHomeLoadingDebugInfo() -> String {
        let profileStore = ProfileSettings.store(for: contentIdentity.profileId)
        let scope = contentIdentity.profileId.trimmingCharacters(in: .whitespacesAndNewlines)
        let authenticated = SimklRuntimeSession.authenticatedState(
            store: profileStore,
            profileScope: scope.isEmpty ? "default" : scope
        ) != nil
        let elapsed = simklLoadingStartedAt.map { Int(Date().timeIntervalSince($0)) } ?? 60

        return [
            "SIMKL DEBUG REPORT",
            "reason=Home Continue Watching did not finish after \(elapsed) seconds",
            "stage=Home Simkl progress refresh",
            "source=\(selectedProgressSource.rawValue)",
            "client_id_configured=\(SimklConfig.isConfigured(in: profileStore))",
            "authenticated=\(authenticated)",
            "home_catalog_loading=\(isLoading)",
            "home_sections=\(store.sections.count)",
            "profile_id=\(contentIdentity.profileId)",
            "app_version=\(SimklConfig.appVersion)",
            "os=\(ProcessInfo.processInfo.operatingSystemVersionString)",
            "next=possible Simkl/network timeout, expired credentials, or Home waiting on a provider response"
        ].joined(separator: "\n")
    }

    private func refreshWatchedTitles() {
        watchedTitleKeys = WatchedStore.visibleWholeTitleIdentityKeys()
    }

    @MainActor
    private func loadLocalTitlesSection() async {
        guard contentIdentity.profileId != "none" && !contentIdentity.profileId.isEmpty else {
            localTitlesSection = nil
            return
        }
        guard smbLocalRowEnabled else {
            localTitlesSection = nil
            return
        }
        let indexed = SMBLibraryIndex.shared.titles()
        guard !indexed.isEmpty else {
            localTitlesSection = nil
            return
        }
        var metasByContentId: [String: NuvioMeta] = [:]
        var iterator = indexed.makeIterator()
        let repository = self.repository
        await withTaskGroup(of: (String, NuvioMeta?).self) { group in
            func startNext() {
                guard let title = iterator.next() else { return }
                group.addTask { @MainActor in
                    (title.contentId, try? await repository.getMetadata(id: title.contentId, type: title.type))
                }
            }
            for _ in 0..<6 { startNext() }
            while let (contentId, meta) = await group.next() {
                if let meta { metasByContentId[contentId] = meta }
                startNext()
            }
        }
        let metas = indexed.compactMap { metasByContentId[$0.contentId] }
        localTitlesSection = metas.isEmpty ? nil : TVHomeSection(
            id: TVHomeSection.localTitlesId,
            title: L10n.string("home_local_titles", fallback: "Local titles"),
            items: metas
        )
    }

    @MainActor
    private func loadJellyfinSection() async {
        guard contentIdentity.profileId != "none" && !contentIdentity.profileId.isEmpty else {
            jellyfinSection = nil
            return
        }
        guard jellyfinLocalRowEnabled else {
            jellyfinSection = nil
            return
        }
        let metas = JellyfinLibraryIndex.shared.titles().compactMap {
            JellyfinLibraryIndex.shared.meta(forContentId: $0.contentId)
        }
        jellyfinSection = metas.isEmpty ? nil : TVHomeSection(
            id: TVHomeSection.jellyfinId,
            title: L10n.string("home_jellyfin_titles", fallback: "Jellyfin"),
            items: metas
        )
    }
}

struct TVHomeSection: Identifiable {
    static let continueWatchingId = "continue_watching"
    static let upcomingId = "upcoming"
    static let localTitlesId = "local_titles"
    static let jellyfinId = "jellyfin_titles"
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
    static let snapshotChangedNotification = Notification.Name("nuvio.tv.homeCatalogSnapshot.changed")

    static func catalogDisplayTitle(_ name: String, contentType: String, showType: Bool) -> String {
        guard showType else { return name }
        let normalized = contentType.lowercased().replacingOccurrences(of: "_", with: "-")
        let suffix: String
        switch normalized {
        case "movie": suffix = "Movies"
        case "series", "show", "tvshow", "tv-show": suffix = "TV Shows"
        case "anime": suffix = "Anime"
        case "channel", "live", "livetv", "live-tv", "iptv", "radio": suffix = "Channels"
        default: suffix = contentType.prefix(1).uppercased() + contentType.dropFirst()
        }
        let lower = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lower.hasSuffix(suffix.lowercased()), !(suffix == "TV Shows" && lower.hasSuffix("series")) else { return name }
        return "\(name) - \(suffix)"
    }

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

    static func disabledAddonIDs() -> Set<String> {
        guard let data = ProfileSettings.current.data(forKey: SettingsKey.homeCatalogDisabledAddonIDs),
              let ids = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(ids)
    }

    static func disabledAddonNames() -> Set<String> {
        guard let data = ProfileSettings.current.data(forKey: SettingsKey.homeCatalogDisabledAddonNames),
              let names = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(names)
    }

    static func normalizedAddonSourceName(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    static func setDisabledAddonSources(ids: Set<String>, names: Set<String>) {
        persist(ids, forKey: SettingsKey.homeCatalogDisabledAddonIDs)
        persist(
            Set(names.map(Self.normalizedAddonSourceName)),
            forKey: SettingsKey.homeCatalogDisabledAddonNames
        )
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
        let disabledAddons = disabledAddonIDs()
        let disabledAddonNames = disabledAddonNames()
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
            let isHiddenByLayout = previous.settingsKey.map { key in
                key.hasPrefix(TVHomeSection.collectionIdPrefix)
                    ? hiddenCollections.contains(
                        String(key.dropFirst(TVHomeSection.collectionIdPrefix.count))
                      )
                    : hiddenCatalogs.contains(key)
            } ?? false
            let isHiddenByAddon = previous.addonId.map(disabledAddons.contains) ?? false
                || previous.addonName.map {
                    disabledAddonNames.contains(normalizedAddonSourceName($0))
                } ?? false
            guard isHiddenByLayout || isHiddenByAddon else { continue }
            rows.insert(previous, at: min(index, rows.count))
        }

        writeSnapshotRows(rows)
    }

    /// Replaces one add-on's rows with the catalogs that actually returned
    /// content. Dynamic manifests rotate candidates, so merging would retain
    /// stale recommendations that no longer exist on Home.
    static func replaceSnapshotRows(
        forAddonID addonID: String,
        addonName: String,
        with additions: [SnapshotRow]
    ) {
        let current = snapshotRows()
        let normalizedName = normalizedAddonSourceName(addonName)
        func belongsToSource(_ row: SnapshotRow) -> Bool {
            if row.addonId == addonID { return true }
            guard row.addonId == nil, let rowName = row.addonName else { return false }
            return normalizedAddonSourceName(rowName) == normalizedName
        }

        let insertionIndex = current.firstIndex(where: belongsToSource) ?? current.count
        var rows = current.filter { !belongsToSource($0) }
        var seen = Set<String>()
        let uniqueAdditions = additions.filter { seen.insert($0.id).inserted }
        rows.insert(contentsOf: uniqueAdditions, at: min(insertionIndex, rows.count))
        guard rows != current else { return }
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
        NotificationCenter.default.post(name: snapshotChangedNotification, object: nil)
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

/// Keeps catalogs used only inside synced collection folders out of top-level
/// Home rows. Inputs are explicit so the matching rule remains deterministic.
enum CatalogHomeVisibilityResolver {
    struct Source {
        let addonIdentifier: String
        let contentType: String
        let catalogID: String
        let collectionID: String

        init(addonIdentifier: String, contentType: String, catalogID: String, collectionID: String = "") {
            self.addonIdentifier = addonIdentifier
            self.contentType = contentType
            self.catalogID = catalogID
            self.collectionID = collectionID
        }
    }

    static func shouldInclude(
        addonID: String,
        contentType: String,
        catalogID: String,
        collectionSources: [Source],
        manifestURL: URL,
        explicitHomeKeys: Set<String>
    ) -> Bool {
        let key = TVHomeCatalogOrder.catalogSettingsKey(
            addonId: addonID, contentType: contentType, catalogId: catalogID
        )
        let matchingSources = collectionSources.filter {
            matches($0.addonIdentifier, addonID: addonID, manifestURL: manifestURL)
        }
        guard !matchingSources.isEmpty else { return true }

        // An explicitly represented catalog remains eligible (the existing
        // disabled-key filter decides whether Home actually shows it).
        if explicitHomeKeys.contains(key) { return true }

        // A synced collection row makes the layout authoritative for that
        // collection-backed add-on only. Other add-ons' synced rows must not
        // suppress manually installed catalogs here.
        let hasMatchingCollectionKey = matchingSources.contains {
            !($0.collectionID.isEmpty)
                && explicitHomeKeys.contains("collection_\($0.collectionID)")
        }
        if hasMatchingCollectionKey { return false }
        // Without a matching synced row, retain manual-install behavior while
        // hiding catalogs used exactly as collection sources.
        return !matchingSources.contains {
            $0.contentType == contentType && $0.catalogID == catalogID
        }
    }

    private static func matches(_ raw: String, addonID: String, manifestURL: URL) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.caseInsensitiveCompare(addonID) == .orderedSame { return true }
        var candidates = [value]
        if value.lowercased().hasPrefix("addon:"),
           let separator = value.dropFirst("addon:".count).firstIndex(of: ":") {
            candidates.append(String(value[value.index(after: separator)...]))
            let embeddedID = String(value[value.index(value.startIndex, offsetBy: "addon:".count)..<separator])
            if embeddedID.caseInsensitiveCompare(addonID) == .orderedSame { return true }
        }
        let canonical = canonicalURL(manifestURL)
        return candidates.compactMap(URL.init(string:)).contains {
            canonicalURL($0) == canonical
        }
    }

    private static func canonicalURL(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        var path = components.percentEncodedPath
        if path.split(separator: "/").last?.lowercased() == "manifest.json" {
            path = droppingTrailingSlash(String(path.dropLast("manifest.json".count)))
        } else {
            path = droppingTrailingSlash(path)
        }
        components.percentEncodedPath = path
        return components.string ?? url.absoluteString
    }

    private static func droppingTrailingSlash(_ input: String) -> String {
        var value = input
        while value.count > 1 && value.hasSuffix("/") { value.removeLast() }
        return value == "/" ? "" : value
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
        let _ = TVHomeDebugTrace.log("hero.render meta=\(meta.id)")
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

extension TVHeroView: Equatable {
    static func == (lhs: TVHeroView, rhs: TVHeroView) -> Bool {
        lhs.meta.id == rhs.meta.id
            && lhs.meta.name == rhs.meta.name
            && lhs.meta.logoUrl == rhs.meta.logoUrl
            && lhs.meta.description == rhs.meta.description
            && lhs.meta.year == rhs.meta.year
            && lhs.meta.rating == rhs.meta.rating
            && lhs.meta.runtime == rhs.meta.runtime
            && lhs.meta.genres == rhs.meta.genres
            && lhs.continueItem?.meta.id == rhs.continueItem?.meta.id
            && lhs.continueItem?.episodeLabel == rhs.continueItem?.episodeLabel
            && lhs.continueItem?.remainingText == rhs.continueItem?.remainingText
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
        .onChange(of: isFocused) { _, focused in
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

/// A row whose catalog is still in flight: its real title over a lightweight
/// skeleton strip, sized exactly like `TVCatalogRow` so the row keeps its height
/// and the rows below it do not jump when the real cards arrive.
///
/// The Android app draws this same skeleton with a shimmer sweep; here each card
/// uses the app's existing glass loading treatment. Deliberately not focusable —
/// focus lands on the first row that has real titles, so the user is never parked
/// on a card that is about to become something else.
private struct TVLoadingCatalogRow: View {
    let title: String

    @AppStorage(SettingsKey.homeLayout) private var homeLayout = "Modern"
    @AppStorage(SettingsKey.posterLabels) private var posterLabels = false
    @AppStorage(SettingsKey.liquidGlassCards) private var liquidGlassCards = true

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
                        LoadingPosterCard(
                            width: cardWidth,
                            height: cardHeight,
                            isLiquidGlassEnabled: liquidGlassCards
                        )
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
    let horizontalEdgeInset: CGFloat
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
    var isRowFocused: Bool = false
    let onInitialFocusRequested: () -> Void
    let onFocus: (NuvioMeta) -> Void
    let onBlur: (NuvioMeta) -> Void
    let onApproachEnd: (NuvioMeta) -> Void
    let onSelect: (NuvioMeta) -> Void
    var onLongPress: ((NuvioMeta) -> Void)? = nil
    var onOpenDetails: ((NuvioMeta) -> Void)? = nil
    var onPlayContinueWatchingManually: ((ContinueWatchingItem) -> Void)? = nil
    var onStartContinueWatchingFromBeginning: ((ContinueWatchingItem) -> Void)? = nil
    var onRemoveFromContinueWatching: ((ContinueWatchingItem) -> Void)? = nil

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
        let raw = scrollIndex ?? initialScrollIndex
        guard !items.isEmpty else { return 0 }
        return min(max(raw, 0), items.count - 1)
    }

    /// Keep a complete visible page ahead plus four cards behind for fast
    /// reverse movement. This fills the row even when the focused Modern card
    /// expands to landscape, while retained row containers keep Up/Down smooth.
    private func materializedCardIndices(visibleCardCount: Int) -> [Int] {
        guard !items.isEmpty else { return [] }
        let focusIndex = effectiveScrollIndex
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

    private func isWatched(_ item: NuvioMeta) -> Bool? {
        let normalizedType = item.type.lowercased()
        let titleWatched = !watchedTitleKeys.isDisjoint(
            with: WatchedStore.catalogTitleIdentityKeys(for: item)
        )
        guard ["series", "tv", "show", "tvshow"].contains(normalizedType) else {
            return titleWatched
        }
        // A whole-series action writes a local aggregate marker plus episode
        // rows. Return the marker immediately, just like movie cards; when it
        // is absent, nil lets WatchedCheckmarkBadge resolve episode completion.
        return titleWatched ? true : nil
    }

    private var defaultFocusCardKey: String? {
        guard !items.isEmpty else { return nil }
        let idx = effectiveScrollIndex
        return "\(id)\u{1}\(items[idx].id)"
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
        .focusSection()
        .defaultFocusIfAvailable(externalFocus, defaultFocusCardKey)
    }

    // A definite-size clipping window for the cards. A GeometryReader imposes
    // its OWN frame size and never grows to fit its (very wide) child, so the
    // overflowing HStack can no longer blow out the parent width -- which was
    // what hid the row titles and the hero block. The cards still slide inside
    // the window via a manual offset; overflow is clipped.
    private var cardStrip: some View {
        GeometryReader { geo in
            let rowTraceEnabled = true
            let rowLayoutStarted = TVHomeDebugTrace.now()
            let stripWidth = max(1920, geo.size.width + horizontalEdgeInset * 2)
            let rowHomeLayout = homeLayout
            let rowPosterLabels = posterLabels
            let rowSmoothFocus = smoothFocus
            let rowFocusHighlighter = focusHighlighter
            let rowCardFocusAnimations = rowSmoothFocus && !suppressFocusAnimations
            let rowPosterWidth: CGFloat = rowHomeLayout == "Compact" ? 170 : 210
            let rowCardSpacing: CGFloat = rowHomeLayout == "Compact" ? 22 : 28
            let visibleCardCount = max(1, Int(ceil(stripWidth / (rowPosterWidth + rowCardSpacing))) + 1)
            let materializedIndices = materializedCardIndices(visibleCardCount: visibleCardCount)
            let guideEntries = materializedIndices.reduce(into: 0) { total, itemIndex in
                total += items[itemIndex].videos?.count ?? 0
            }
            let _ = traceRowLayout(
                enabled: rowTraceEnabled,
                rowID: id,
                itemCount: items.count,
                mountedCount: materializedIndices.count,
                guideEntries: guideEntries,
                index: effectiveScrollIndex
            )

            HStack(alignment: .top, spacing: rowCardSpacing) {
                ForEach(materializedIndices, id: \.self) { itemIndex in
                    let item = items[itemIndex]
                    let cardKey = "\(id)\u{1}\(item.id)"
                    let shouldRequestInitialFocus = cardKey == initialFocusCardKey
                    let progressItem = progressByItemId[item.id]
                    let handleFocus: (NuvioMeta) -> Void = { focused in
                        let focusStarted = TVHomeDebugTrace.now()
                        TVHomeDebugTrace.log(
                            "focus.begin row=\(id) index=\(itemIndex) items=\(items.count) "
                                + "mounted=\(materializedIndices.count) meta=\(focused.id)"
                        )
                        if effectiveScrollIndex != itemIndex {
                            let updateScrollPosition = {
                                scrollIndex = itemIndex
                                onScrollIndexChange(itemIndex)
                            }
                            if rowSmoothFocus && !suppressFocusAnimations {
                                withAnimation(TVHomeLayout.scrollAnimation) {
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
                        let approachStarted = TVHomeDebugTrace.now()
                        onApproachEnd(focused)
                        TVHomeDebugTrace.log(
                            "focus.approach row=\(id) index=\(itemIndex) "
                                + "elapsedMs=\(TVHomeDebugTrace.elapsedMilliseconds(since: approachStarted))"
                        )
                        let parentStarted = TVHomeDebugTrace.now()
                        onFocus(focused)
                        TVHomeDebugTrace.log(
                            "focus.end row=\(id) index=\(itemIndex) "
                                + "parentMs=\(TVHomeDebugTrace.elapsedMilliseconds(since: parentStarted)) "
                                + "totalMs=\(TVHomeDebugTrace.elapsedMilliseconds(since: focusStarted))"
                        )
                    }
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
                        showsWatchedBadge: id != TVHomeSection.continueWatchingId && id != TVHomeSection.upcomingId,
                        shouldRequestInitialFocus: shouldRequestInitialFocus,
                        onInitialFocusRequested: shouldRequestInitialFocus ? onInitialFocusRequested : nil,
                        onFocus: handleFocus,
                        onBlur: onBlur,
                        externalFocus: externalFocus,
                        externalFocusValue: cardKey,
                        onLongPress: onLongPress,
                        onOpenDetails: onOpenDetails != nil ? { onOpenDetails?(item) } : nil,
                        onPlayManually: ((id == TVHomeSection.continueWatchingId || id == TVHomeSection.upcomingId) && progressItem != nil) ? {
                            if let p = progressItem { onPlayContinueWatchingManually?(p) }
                        } : nil,
                        onStartFromBeginning: ((id == TVHomeSection.continueWatchingId || id == TVHomeSection.upcomingId) && progressItem != nil) ? {
                            if let p = progressItem { onStartContinueWatchingFromBeginning?(p) }
                        } : nil,
                        onRemoveFromContinueWatching: ((id == TVHomeSection.continueWatchingId || id == TVHomeSection.upcomingId) && progressItem != nil) ? {
                            if let p = progressItem { onRemoveFromContinueWatching?(p) }
                        } : nil,
                        layoutMode: rowHomeLayout,
                        showPosterLabels: rowPosterLabels,
                        smoothFocusAnimations: rowCardFocusAnimations,
                        focusHighlighterEnabled: rowFocusHighlighter,
                        retainFocusAppearance: retainFocusAppearanceForCardKey == cardKey,
                        allowsFocus: true,
                        isWatched: isWatched(item)
                    ) {
                        onSelect(item)
                    }
                    .disabled(
                        (restrictFocusToCardKey != nil && restrictFocusToCardKey != cardKey)
                            || (!isRowFocused && itemIndex != effectiveScrollIndex)
                    )
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
            .offset(
                x: horizontalEdgeInset + TVLayout.rowLeading
                    - CGFloat(effectiveScrollIndex) * (rowPosterWidth + rowCardSpacing)
            )
            .frame(
                width: stripWidth,
                height: stripHeight,
                alignment: .topLeading
            )
            .clipped()
            .offset(x: -horizontalEdgeInset)
            // `scrollIndex` is animated explicitly in the focus callback so
            // user navigation still springs while restoration can snap quietly.
            .animation(rowCardFocusAnimations ? TVHomeLayout.scrollAnimation : nil, value: landscapeFocusedId)
            .onAppear {
                guard rowTraceEnabled else { return }
                TVHomeDebugTrace.log(
                    "row.layout.appear row=\(id) ms=\(TVHomeDebugTrace.elapsedMilliseconds(since: rowLayoutStarted))"
                )
            }
        }
        .frame(height: stripHeight)
    }

    private func traceRowLayout(
        enabled: Bool,
        rowID: String,
        itemCount: Int,
        mountedCount: Int,
        guideEntries: Int,
        index: Int
    ) {
        TVHomeDebugTrace.log("row.layout row=\(rowID) items=\(itemCount) mounted=\(mountedCount) index=\(index)")
    }
}

// Keep row identity and horizontal state stable, while allowing the focused
// vertical window to swap lightweight shells for real poster cards.
extension TVCatalogRow: Equatable {
    static func == (lhs: TVCatalogRow, rhs: TVCatalogRow) -> Bool {
        let lhsTargetInRow = lhs.restrictFocusToCardKey?.hasPrefix("\(lhs.id)\u{1}") == true
        let rhsTargetInRow = rhs.restrictFocusToCardKey?.hasPrefix("\(rhs.id)\u{1}") == true
        let restrictEqual = (lhs.restrictFocusToCardKey != nil) == (rhs.restrictFocusToCardKey != nil)
            && (lhsTargetInRow == rhsTargetInRow)
            && (!lhsTargetInRow || lhs.restrictFocusToCardKey == rhs.restrictFocusToCardKey)

        let lhsRetainInRow = lhs.retainFocusAppearanceForCardKey?.hasPrefix("\(lhs.id)\u{1}") == true
        let rhsRetainInRow = rhs.retainFocusAppearanceForCardKey?.hasPrefix("\(rhs.id)\u{1}") == true
        let retainEqual = (lhsRetainInRow == rhsRetainInRow)
            && (!lhsRetainInRow || lhs.retainFocusAppearanceForCardKey == rhs.retainFocusAppearanceForCardKey)

        return lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.horizontalEdgeInset == rhs.horizontalEdgeInset
            && lhs.items == rhs.items
            && lhs.watchedTitleKeys == rhs.watchedTitleKeys
            && lhs.initialScrollIndex == rhs.initialScrollIndex
            && lhs.initialFocusCardKey == rhs.initialFocusCardKey
            && lhs.landscapeFocusedId == rhs.landscapeFocusedId
            && restrictEqual
            && retainEqual
            && lhs.suppressFocusAnimations == rhs.suppressFocusAnimations
            && lhs.isRowFocused == rhs.isRowFocused
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

    static func isWatched(_ item: NuvioMeta, watchedTitleKeys: Set<String>) -> Bool? {
        let type = item.type.lowercased()
        let titleWatched = !watchedTitleKeys.isDisjoint(
            with: WatchedStore.catalogTitleIdentityKeys(for: item)
        )
        guard ["series", "tv", "show", "tvshow"].contains(type) else {
            return titleWatched
        }
        return titleWatched ? true : nil
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
    @AppStorage(SettingsKey.cardCornerRadius) private var cardCornerRadiusSetting = AppCardStyle.defaultCornerRadiusRaw

    private var showsFocusedAppearance: Bool { isFocused || retainFocusAppearance }

    private var cardCornerRadius: CGFloat {
        AppCardStyle.cornerRadius(for: cardCornerRadiusSetting, fallback: 16)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
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
            .modifier(LiquidGlassSurface(cornerRadius: cardCornerRadius, prominent: showsFocusedAppearance))
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
        .onChange(of: isFocused) { _, focused in
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
            pendingItems.removeFirst(batchCount)
            // Same TMDB preparation the initial 18 Home items received, so
            // post-18 cards match their shelf artwork (logo/backdrop).
            isLoadingMore = true
            Task { @MainActor in
                defer { isLoadingMore = false }
                let enrichedBatch = await TmdbDetailsService.localizedMetadata(for: batch)
                let currentIDs = Set(items.map(\.id))
                items.append(contentsOf: enrichedBatch.filter { !currentIDs.contains($0.id) })
                hasMore = !pendingItems.isEmpty || (section.contentType != nil && section.catalogId != nil)
            }
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
    let horizontalEdgeInset: CGFloat
    let folders: [TVCollectionFolderItem]
    let initialScrollIndex: Int
    let onScrollIndexChange: (Int) -> Void
    let initialFocusCardKey: String?
    var externalFocus: FocusState<String?>.Binding? = nil
    var restrictFocusToCardKey: String? = nil
    var retainFocusAppearanceForCardKey: String? = nil
    var suppressFocusAnimations = false
    var isRowFocused = false
    let onInitialFocusRequested: () -> Void
    let onFocus: (TVCollectionFolderItem) -> Void
    let onSelect: (TVCollectionFolderItem) -> Void

    @State private var scrollIndex: Int?
    @AppStorage(SettingsKey.homeLayout) private var homeLayout = "Modern"
    @AppStorage(SettingsKey.posterLabels) private var posterLabels = false
    @AppStorage(SettingsKey.smoothFocus) private var smoothFocus = true
    @AppStorage(SettingsKey.focusHighlighter) private var focusHighlighter = false

    private var effectiveScrollIndex: Int {
        let raw = scrollIndex ?? initialScrollIndex
        guard !folders.isEmpty else { return 0 }
        return min(max(raw, 0), folders.count - 1)
    }

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

        let focusIndex = effectiveScrollIndex
        var lowerBound = max(0, focusIndex - 4)
        var upperBound = focusIndex
        let spacing = TVCollectionFolderCardLayout.rowSpacing(layoutMode: layoutMode)
        var coveredWidth: CGFloat = 0

        for index in focusIndex..<folders.count {
            coveredWidth += TVCollectionFolderCardLayout.cardWidth(
                shape: folders[index].tileShape,
                layoutMode: layoutMode
            ) + spacing
            upperBound = index
            if coveredWidth >= stripWidth { break }
        }

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

    private var defaultFocusFolderKey: String? {
        guard !folders.isEmpty else { return nil }
        let idx = effectiveScrollIndex
        return "\(id)\u{1}\(folders[idx].id)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.custom("Inter-Bold", size: 30))
                .foregroundColor(.white)
                .padding(.leading, TVLayout.rowLeading)
                .offset(y: 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .zIndex(2)

            cardStrip
                .zIndex(0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
        .defaultFocusIfAvailable(externalFocus, defaultFocusFolderKey)
    }

    private var cardStrip: some View {
        GeometryReader { geo in
            let stripWidth = max(1920, geo.size.width + horizontalEdgeInset * 2)
            let rowHomeLayout = homeLayout
            let rowPosterLabels = posterLabels
            let rowSmoothFocus = smoothFocus
            let rowFocusHighlighter = focusHighlighter
            let rowSpacing = TVCollectionFolderCardLayout.rowSpacing(layoutMode: rowHomeLayout)
            let scrollX = TVCollectionFolderCardLayout.scrollOffset(
                to: effectiveScrollIndex,
                folders: folders,
                layoutMode: rowHomeLayout
            )
            let materializedIndices = materializedCardIndices(
                stripWidth: stripWidth,
                layoutMode: rowHomeLayout
            )

            HStack(alignment: .top, spacing: rowSpacing) {
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
                            if effectiveScrollIndex != index {
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
                        allowsFocus: true,
                        onSelect: { onSelect(folder) }
                    )
                    .disabled(
                        (restrictFocusToCardKey != nil && restrictFocusToCardKey != cardKey)
                            || (!isRowFocused && index != effectiveScrollIndex)
                    )
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
            .offset(x: horizontalEdgeInset + TVLayout.rowLeading - scrollX)
            .frame(
                width: stripWidth,
                height: stripHeight,
                alignment: .topLeading
            )
            .clipped()
            .offset(x: -horizontalEdgeInset)
            .animation(
                rowSmoothFocus && !suppressFocusAnimations ? TVHomeLayout.scrollAnimation : nil,
                value: effectiveScrollIndex
            )
        }
        .frame(height: stripHeight)
    }
}

// Keep row identity and horizontal state stable, while allowing the focused
// vertical window to swap lightweight shells for real folder cards.
extension TVCollectionFolderRow: Equatable {
    static func == (lhs: TVCollectionFolderRow, rhs: TVCollectionFolderRow) -> Bool {
        let lhsRestrictInRow = lhs.restrictFocusToCardKey?.hasPrefix("\(lhs.id)\u{1}") == true
        let rhsRestrictInRow = rhs.restrictFocusToCardKey?.hasPrefix("\(rhs.id)\u{1}") == true
        let restrictEqual = (lhsRestrictInRow == rhsRestrictInRow)
            && (!lhsRestrictInRow || lhs.restrictFocusToCardKey == rhs.restrictFocusToCardKey)

        let lhsRetainInRow = lhs.retainFocusAppearanceForCardKey?.hasPrefix("\(lhs.id)\u{1}") == true
        let rhsRetainInRow = rhs.retainFocusAppearanceForCardKey?.hasPrefix("\(rhs.id)\u{1}") == true
        let retainEqual = (lhsRetainInRow == rhsRetainInRow)
            && (!lhsRetainInRow || lhs.retainFocusAppearanceForCardKey == rhs.retainFocusAppearanceForCardKey)

        return lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.horizontalEdgeInset == rhs.horizontalEdgeInset
            && lhs.folders == rhs.folders
            && lhs.initialScrollIndex == rhs.initialScrollIndex
            && lhs.initialFocusCardKey == rhs.initialFocusCardKey
            && restrictEqual
            && retainEqual
            && lhs.suppressFocusAnimations == rhs.suppressFocusAnimations
            && lhs.isRowFocused == rhs.isRowFocused
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
    var allowsFocus = true
    let onSelect: () -> Void

    @FocusState private var isFocused: Bool
    @State private var didRequestInitialFocus = false
    @AppStorage(SettingsKey.cardCornerRadius) private var cardCornerRadiusSetting = AppCardStyle.defaultCornerRadiusRaw

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

    private var cardCornerRadius: CGFloat {
        AppCardStyle.cornerRadius(for: cardCornerRadiusSetting, fallback: 16)
    }

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
            .focusable(allowsFocus)
            .focused($isFocused)
            .modifier(ExternalFocusBinding(binding: externalFocus, id: externalFocusValue ?? folder.id))
            .focusEffectDisabledIfAvailable()
            .onTapGesture(perform: onSelect)
            .onChange(of: isFocused) { _, focused in
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
    @FocusState private var isLoadingFocusActive: Bool
    @State private var lastFocusedItemID: String?
    @State private var focusRestoreGeneration = 0
    @State private var watchedTitleKeys: Set<String> = []
    @State private var cachedCollectionMetadata: [String: NuvioMeta] = [:]
    @State private var collectionEnrichmentTask: Task<Void, Never>?
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
        .onAppear {
            requestLoadingFocusIfNeeded()
        }
        .onDisappear {
            collectionEnrichmentTask?.cancel()
            collectionEnrichmentTask = nil
        }
        .task {
            refreshWatchedTitles()
            await load()
        }
        .onReceive(NotificationCenter.default.publisher(for: WatchedStore.changedNotification)) { _ in
            refreshWatchedTitles()
        }
        .onChange(of: focusedItemID) { _, newValue in
            if let newValue { lastFocusedItemID = newValue }
        }
        .onChange(of: isLoading) { _, loading in
            if loading {
                requestLoadingFocusIfNeeded()
            } else {
                isLoadingFocusActive = false
            }
        }
        .onChange(of: isEnabled) { _, enabled in
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
                        .overlay { loadingFocusAnchor }
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
                            .overlay { loadingFocusAnchor }
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
                                onFocus: enrichCollectionItemIfNeeded,
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

    /// Keep focus inside the full-screen collection while its network request
    /// is pending, so Menu reaches this view's `onExitCommand` instead of the
    /// Apple TV shell.
    private var loadingFocusAnchor: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .focusable(true)
            .focused($isLoadingFocusActive)
    }

    private func requestLoadingFocusIfNeeded() {
        guard isLoading else { return }
        DispatchQueue.main.async {
            guard isLoading else { return }
            isLoadingFocusActive = true
        }
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
                    CollectionFolderTabButton(
                        label: label,
                        isSelected: selectedTabIndex == index
                    ) {
                        selectedTabIndex = index
                    }
                }
            }
            .padding(.horizontal, 60)
            .padding(.vertical, 8)
        }
        .scrollClipDisabledIfAvailable()
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
                                onFocus: enrichCollectionItemIfNeeded,
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
        watchedTitleKeys = WatchedStore.visibleWholeTitleIdentityKeys()
    }

    private func isTitleWatched(_ meta: NuvioMeta) -> Bool? {
        let titleWatched = !watchedTitleKeys.isDisjoint(
            with: WatchedStore.catalogTitleIdentityKeys(for: meta)
        )
        guard !["series", "tv", "show", "tvshow"].contains(meta.type.lowercased()) else {
            return titleWatched ? true : nil
        }
        return titleWatched
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
                group.addTask { @MainActor [repository] in
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

    /// Collections use the same focus-driven catalog enrichment as Home. This
    /// intentionally goes through the repository rather than TMDB, so a
    /// source-provided `/meta` logo still appears when TMDB is disabled.
    private func enrichCollectionItemIfNeeded(_ item: NuvioMeta) {
        guard item.needsHeroMetadataEnrichment else { return }
        let key = "\(item.type.lowercased())\u{1f}\(item.id)"

        if let fullMeta = cachedCollectionMetadata[key] {
            applyCollectionMetadata(fullMeta, to: item.id)
            return
        }

        // Focus moves quickly while the user browses with the remote. Do not
        // start one metadata request per card passed over; wait for focus to
        // settle and cancel the previous pending request.
        collectionEnrichmentTask?.cancel()
        collectionEnrichmentTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled,
                  let fullMeta = try? await repository.refreshMetadata(
                id: item.id,
                type: item.type
            ), !Task.isCancelled else {
                return
            }
            cachedCollectionMetadata[key] = fullMeta
            applyCollectionMetadata(fullMeta, to: item.id)
        }
    }

    private func applyCollectionMetadata(_ fullMeta: NuvioMeta, to itemID: String) {
        for rowIndex in catalogRows.indices {
            guard let itemIndex = catalogRows[rowIndex].items.firstIndex(where: { $0.id == itemID }) else {
                continue
            }
            let compact = catalogRows[rowIndex].items[itemIndex]
            catalogRows[rowIndex].items[itemIndex] = compact.fillingMissingHeroMetadata(from: fullMeta)
        }
        if let itemIndex = items.firstIndex(where: { $0.id == itemID }) {
            items[itemIndex] = items[itemIndex].fillingMissingHeroMetadata(from: fullMeta)
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
    let onFocus: (NuvioMeta) -> Void
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
        .onChange(of: focusedPosterBackdropEnabled) { _, enabled in
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
                            onFocus(focused)
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
                        isWatched: isTitleWatched(item)
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
            .animation(rowSmoothFocus ? TVHomeLayout.scrollAnimation : nil, value: scrollIndex)
            .animation(rowSmoothFocus ? TVHomeLayout.scrollAnimation : nil, value: landscapeFocusedId)
        }
        .frame(height: stripHeight)
    }

    private func isTitleWatched(_ meta: NuvioMeta) -> Bool? {
        let titleWatched = !watchedTitleKeys.isDisjoint(
            with: WatchedStore.catalogTitleIdentityKeys(for: meta)
        )
        guard !["series", "tv", "show", "tvshow"].contains(meta.type.lowercased()) else {
            return titleWatched ? true : nil
        }
        return titleWatched
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

/// Pill tab button for CollectionFolderBrowseView (Grid view mode).
/// Displays a clear focus outline (theme accent color) when navigated to,
/// and highlights selected tabs.
private struct CollectionFolderTabButton: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    @FocusState private var isFocused: Bool
    @AppStorage(SettingsKey.smoothFocus) private var smoothFocus = true
    @AppStorage(SettingsKey.focusHighlighter) private var focusHighlighter = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(textColor)
                .padding(.horizontal, 22)
                .frame(height: 48)
                .background(
                    backgroundColor,
                    in: Capsule(style: .continuous)
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(
                            isFocused ? AppFocusOutline.color : .clear,
                            lineWidth: focusHighlighter ? AppFocusOutline.emphasizedWidth : AppFocusOutline.width
                        )
                )
                .shadow(
                    color: .black.opacity(isFocused ? 0.45 : 0.0),
                    radius: isFocused ? 12 : 0
                )
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($isFocused)
        .focusEffectDisabledIfAvailable()
        .scaleEffect(isFocused ? 1.08 : 1.0)
        .animation(smoothFocus ? .spring(response: 0.28, dampingFraction: 0.75) : .easeOut(duration: 0.12), value: isFocused)
        .animation(.easeOut(duration: 0.12), value: isSelected)
    }

    private var textColor: Color {
        if isFocused {
            return .black
        }
        return isSelected ? .black : .white.opacity(0.85)
    }

    private var backgroundColor: Color {
        if isFocused {
            return .white
        }
        return isSelected ? Color.white : Color.white.opacity(0.12)
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
    @AppStorage(SettingsKey.cardCornerRadius) private var cardCornerRadiusSetting = AppCardStyle.defaultCornerRadiusRaw
    @AppStorage(SettingsKey.liquidGlassCards) private var liquidGlassCards = true

    private var cardCornerRadius: CGFloat {
        AppCardStyle.cornerRadius(for: cardCornerRadiusSetting, fallback: 16)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                CachedPosterArtwork(
                    urlString: meta.posterUrl,
                    width: CollectionFolderGridMetrics.posterWidth,
                    height: CollectionFolderGridMetrics.posterHeight,
                    maximumWidth: CollectionFolderGridMetrics.posterWidth
                ) {
                    ZStack {
                        Rectangle().fill(Color.white.opacity(0.07))
                        Image(systemName: meta.type == "series" ? "tv" : "film")
                            .font(.system(size: 40))
                            .foregroundColor(.white.opacity(0.25))
                    }
                }
                .frame(
                    width: CollectionFolderGridMetrics.posterWidth,
                    height: CollectionFolderGridMetrics.posterHeight
                )
                .clipShape(shape)
                .modifier(
                    LiquidGlassCardModifier(
                        cornerRadius: cardCornerRadius,
                        isFocused: focused,
                        isEnabled: liquidGlassCards
                    )
                )
                .overlay(alignment: .topTrailing) {
                    if let isWatched {
                        if isWatched { WatchedCheckmarkIcon() }
                    } else {
                        WatchedCheckmarkBadge(meta: meta)
                    }
                }
                .overlay(
                    shape.stroke(
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
        .titleActionsContextMenu(
            meta: meta,
            onOpenDetails: action
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
        if raw.caseInsensitiveCompare("tbd") == .orderedSame || raw.caseInsensitiveCompare("tba") == .orderedSame {
            return "TBD"
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
    /// Keep the first catalog heading close to the hero description.
    static let heroBottomPadding: CGFloat = 20
    static let rowsTopPadding: CGFloat = 4
    /// Extra scroll room so the last row can reach the same fixed anchor as
    /// earlier rows instead of being clamped to the viewport bottom.
    static let finalRowScrollRunway: CGFloat = 24
    /// Focus breathing room above/below cards inside a strip.
    static let stripVerticalPadding: CGFloat = 24
    /// Section title line (~30pt) + VStack spacing under the title (~10pt) + slack.
    static let rowTitleBlock: CGFloat = 46

    /// Horizontal strip motion with no spring settling.
    static let scrollAnimation = Animation.easeOut(duration: 0.22)
    /// Keep successive remote presses from stacking long-running vertical
    /// transactions while retaining a visible native scroll transition.
    static let verticalScrollAnimation = Animation.easeOut(duration: 0.22)
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
