//
//  NuvioTVApp.swift
//  NuvioTV
//
//  Created by Claude Code
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
    case player(url: URL, meta: NuvioMeta, subtitle: String, externalSubtitles: [NuvioSubtitle], resumeFrom: Double?)
    case cloudLibrary
    /// Browse titles inside one collection folder (catalogs grouped under it).
    case collectionFolder(TVCollectionFolderItem, collectionTitle: String)
    /// All titles from a production company or network.
    case productionBrowse(MetaCompany)
}

private enum PlaybackOrigin {
    case main
    case details
    case cloudLibrary
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
    // Holds the who's-watching screen back until the post-sign-in profile pull
    // lands, so freshly imported profile names show instead of local stubs.
    @State private var awaitingPostLoginSync = false
    @State private var enterMainAfterPostLoginSync = false
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
    /// URL-less Continue Watching entries (for example synced progress or Next
    /// Up) resolve their stream in place instead of opening Details first.
    @State private var isResolvingContinueWatchingStream = false
    @State private var continueWatchingPlaybackTask: Task<Void, Never>?
    @State private var pendingDeepLinkURL: URL?
    /// Details title to restore when leaving a production company browse.
    @State private var productionBrowseReturn: (id: String, type: String)?
    @StateObject private var authManager = AuthManager()
    @StateObject private var profileViewModel = ProfileViewModel()
    @StateObject private var syncManager = NuvioSyncManager()
    @StateObject private var searchViewModel = SearchViewModel()
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
                            withAnimation(.easeInOut(duration: 0.28)) {
                                activeScreen = .main
                            }
                            resumePendingDeepLinkIfPossible()
                        }
                }

            case .main, .details, .player, .cloudLibrary, .collectionFolder, .productionBrowse:
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
                if authManager.isAuthenticated,
                   AuthConfig.isConfigured,
                   isUsingLocalGuestPlaceholder,
                   syncManager.isPullingAccountProfiles {
                    // A restored Keychain session can outlive missing/corrupt
                    // local profile data. Gate that startup pull exactly like a
                    // fresh login instead of auto-entering the local Guest.
                    awaitingPostLoginSync = true
                    enterMainAfterPostLoginSync = autoSelectLast
                    activeScreen = .profileSelection
                } else if autoSelectLast,
                          let activeProfile = profileViewModel.activeProfile,
                          !activeProfile.isPinProtected {
                    activeScreen = .main
                    resumePendingDeepLinkIfPossible()
                } else {
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
            if phase == .active {
                syncManager.refreshAccountFromForeground()
            }
        }
    }

    /// Whether Details, Player, or the card quick-actions menu is currently
    /// covering the tab view (drives `.disabled` and the Menu-button safety net).
    private var isUsingLocalGuestPlaceholder: Bool {
        guard let profile = profileViewModel.activeProfile else { return true }
        if profile.id == "guest" { return true }
        let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return profile.id == "1" && !profile.isAdmin && profile.avatarId.isEmpty
            && name == "nuvio guest"
    }

    private var isOverlayPresented: Bool {
        if isResolvingContinueWatchingStream { return true }
        if cardMenuMeta != nil { return true }
        return fullScreenOverlayPresented
    }

    /// Details/Player fully replace Home, so the tab view fades to black under
    /// them. The card quick-actions menu is deliberately excluded — it keeps Home
    /// visible behind its glass panel.
    private var fullScreenOverlayPresented: Bool {
        if isResolvingContinueWatchingStream { return true }
        switch activeScreen {
        case .details, .player, .cloudLibrary, .collectionFolder, .productionBrowse: return true
        default: return false
        }
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
            return
        }
        switch activeScreen {
        case .details:
            withAnimation(.easeInOut(duration: 0.24)) {
                activeScreen = .main
            }
        case let .player(_, meta, subtitle, _, _):
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
        default:
            break
        }
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
            activeScreen = .details(id: id, type: type)
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

    private static func seasonSortKey(_ season: Int) -> Int {
        season <= 0 ? Int.max : season
    }

    /// Starts a Continue Watching card immediately. Locally played entries use
    /// their last stream URL; synced and Next Up entries fetch and smart-select
    /// a stream in the background without opening Details first.
    private func resumePlayback(_ item: ContinueWatchingItem) {
        continueWatchingPlaybackTask?.cancel()
        continueWatchingPlaybackTask = nil
        isResolvingContinueWatchingStream = false

        let context = Self.episodeContext(for: item)
        playbackEpisodes = context.episodes
        playbackCurrentEpisode = context.current

        let streamUrl = item.streamUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if !streamUrl.isEmpty, let url = URL(string: streamUrl) {
            presentPlayback(
                url: url,
                meta: item.meta,
                subtitle: item.episodeSubtitle ?? "",
                externalSubtitles: [],
                resumeFrom: item.resumePosition
            )
            return
        }

        isResolvingContinueWatchingStream = true
        let profileId = profileViewModel.activeProfile?.id
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
                    resumeFrom: item.resumePosition
                )
            } else {
                // Keep the manual picker available when no add-on returns a
                // playable stream automatically.
                withAnimation(.easeInOut(duration: 0.28)) {
                    activeScreen = .details(id: item.meta.id, type: item.meta.type)
                }
            }
        }
    }

    private func presentPlayback(
        url: URL,
        meta: NuvioMeta,
        subtitle: String,
        externalSubtitles: [NuvioSubtitle],
        resumeFrom: Double?,
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
        if !isTrailer,
           let launchURL = player.launchURL(for: url, subtitleURLs: subtitleURLs),
           UIApplication.shared.canOpenURL(launchURL) {
            UIApplication.shared.open(launchURL, options: [:], completionHandler: nil)
            return
        }

        presentBuiltInPlayer(
            url: url,
            meta: meta,
            subtitle: subtitle,
            externalSubtitles: externalSubtitles,
            resumeFrom: resumeFrom,
            origin: origin
        )
    }

    private func presentBuiltInPlayer(
        url: URL,
        meta: NuvioMeta,
        subtitle: String,
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

            if case .player(let url, let meta, let subtitle, let externalSubtitles, let resumeFrom) = activeScreen {
                playerScreen(
                    url: url,
                    meta: meta,
                    subtitle: subtitle,
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

            if case .collectionFolder(let folder, let collectionTitle) = activeScreen {
                CollectionFolderBrowseView(
                    folder: folder,
                    collectionTitle: collectionTitle,
                    repository: CinemetaCatalogRepository(),
                    onSelect: { meta in
                        withAnimation(.easeInOut(duration: 0.28)) {
                            activeScreen = .details(id: meta.id, type: meta.type)
                        }
                    },
                    onBack: {
                        withAnimation(.easeInOut(duration: 0.24)) {
                            activeScreen = .main
                        }
                    }
                )
                .transition(.opacity)
                .zIndex(1)
            }

            if case .productionBrowse(let company) = activeScreen {
                ProductionBrowseView(
                    company: company,
                    onSelect: { title in
                        productionBrowseReturn = nil
                        withAnimation(.easeInOut(duration: 0.28)) {
                            activeScreen = .details(id: title.id, type: title.type)
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
                            activeScreen = .details(id: menuMeta.id, type: menuMeta.type)
                        }
                    },
                    onDismiss: {
                        withAnimation(.easeInOut(duration: 0.2)) { cardMenuMeta = nil }
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
            libraryViewModel: libraryViewModel,
            homeStore: homeStore,
            accountEmail: authManager.currentEmail,
            isAuthenticated: authManager.isAuthenticated,
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
                withAnimation(.easeInOut(duration: 0.28)) {
                    selectedTab = .home
                    profileViewModel.activeProfile = nil
                    activeScreen = .login
                }
            },
            onNavigateToDetails: { contentId, contentType in
                withAnimation(.easeInOut(duration: 0.28)) {
                    activeScreen = .details(id: contentId, type: contentType)
                }
            },
            onOpenCollectionFolder: { folder, collectionTitle in
                withAnimation(.easeInOut(duration: 0.28)) {
                    activeScreen = .collectionFolder(folder, collectionTitle: collectionTitle)
                }
            },
            onResumePlayback: { item in
                resumePlayback(item)
            },
            onLongPressCard: { meta in
                withAnimation(.easeInOut(duration: 0.2)) {
                    cardMenuMeta = meta
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
            onPlayClick: { streamUrlString, meta, subtitle, externalSubtitles, currentEpisode, episodes in
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
                        resumeFrom: isTrailer ? nil : ContinueWatchingStore.item(for: meta.id)?.resumePosition,
                        origin: .details
                    )
                }
            },
            onBack: {
                withAnimation(.easeInOut(duration: 0.24)) {
                    activeScreen = .main
                }
            },
            onOpenTitle: { contentId, contentType in
                withAnimation(.easeInOut(duration: 0.28)) {
                    activeScreen = .details(id: contentId, type: contentType)
                }
            },
            onOpenProduction: { company in
                productionBrowseReturn = (contentId, contentType)
                withAnimation(.easeInOut(duration: 0.28)) {
                    activeScreen = .productionBrowse(company)
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
                subtitleLine: subtitleLine,
                subtitles: candidate.subtitles,
                streamName: candidate.name,
                streamDescription: candidate.description,
                filename: candidate.filename
            )
        }
        return nil
    }

    /// All playable sources for the Sources side panel (ordered smart-best first).
    private static func fetchSources(
        contentId: String,
        type: String,
        profileId: String?
    ) async -> [NuvioStream] {
        let streams = await StreamsRepository.shared.collectStreams(type: type, videoId: contentId)
        let store = ProfileSettings.store(for: profileId)
        let quality = store.string(forKey: SettingsKey.smartStreamQuality) ?? "Highest"
        let matchSubtitles = store.object(forKey: SettingsKey.smartSubtitleMatching) as? Bool ?? true
        let languages = SubtitleLanguagePreferences.orderedFromDefaults(defaults: store)
        let debrid = DebridResolver(store: store)
        let cachedOnly = (store.object(forKey: SettingsKey.cachedOnlyStreams) as? Bool) ?? false
        let metaIdForTags = contentId.split(separator: ":").first.map(String.init) ?? contentId
        let preferredTags = LastStreamQualityStore.load(metaId: metaIdForTags, profileId: profileId)
        return rankedPlayableStreams(
            from: streams,
            qualityPreference: quality,
            subtitleLanguages: languages,
            shouldMatchSubtitles: matchSubtitles,
            includeDebrid: debrid.isEnabled,
            preferredTags: preferredTags,
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

        if stream.isDebridResolvable {
            guard case let .success(url, _, _)? = await debrid.resolvedURL(
                for: stream,
                season: season,
                episode: episode
            ) else { return nil }
            return PreparedNextStream(
                url: url,
                subtitleLine: subtitleLine,
                subtitles: stream.subtitles,
                streamName: stream.name,
                streamDescription: stream.description,
                filename: stream.filename
            )
        }

        guard let urlString = stream.url, let url = URL(string: urlString) else { return nil }
        return PreparedNextStream(
            url: url,
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
        externalSubtitles: [NuvioSubtitle],
        resumeFrom: Double?
    ) -> some View {
        let isTrailer = subtitle == PlaybackMarkers.trailerSubtitle
        let store = ProfileSettings.store(for: profileViewModel.activeProfile?.id)
        let autoPlayNext = store.object(forKey: SettingsKey.autoPlayNext) as? Bool ?? true
        PlayerView(
            url: url,
            meta: meta,
            subtitle: subtitle,
            externalSubtitles: externalSubtitles,
            resumeFrom: resumeFrom,
            episodes: isTrailer ? [] : playbackEpisodes,
            currentEpisode: isTrailer ? nil : playbackCurrentEpisode,
            autoPlayNextEnabled: autoPlayNext,
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
    @ObservedObject var libraryViewModel: LibraryViewModel
    @ObservedObject var homeStore: TVHomeStore
    let accountEmail: String?
    let isAuthenticated: Bool
    let onSwitchProfile: () -> Void
    let onChangeProfileAvatar: (String, String) -> Void
    let onChangeProfileName: (String, String) -> Void
    let onChangeProfilePin: (String, String?, String?) async -> Bool
    let onVerifyProfilePin: (String, String) async -> Bool
    let onSignIn: () -> Void
    let onSignOut: () -> Void
    let onNavigateToDetails: (String, String) -> Void
    let onOpenCollectionFolder: (TVCollectionFolderItem, String) -> Void
    let onResumePlayback: (ContinueWatchingItem) -> Void
    let onLongPressCard: (NuvioMeta) -> Void
    let onOpenCloudLibrary: () -> Void
    @AppStorage(SettingsKey.amoled) private var amoled = false
    @AppStorage(SettingsKey.bodyColor) private var bodyColor = SettingsBackground.charcoal.rawValue
    @AppStorage(SettingsKey.discoverLocation) private var discoverLocation = "Search"
    @AppStorage(SettingsKey.profileName) private var settingsProfileName = "Nuvio User"
    @StateObject private var profileTabAvatar = ProfileTabAvatarRenderer()

    private var displayedProfile: Profile? {
        if isAuthenticated { return activeProfile }
        return activeProfile?.id == "guest" ? activeProfile : nil
    }

    /// Name shown on the fallback profile tab (tvOS < 27), mirroring the
    /// sidebar header's display-name logic.
    private var profileTabTitle: String {
        guard let displayedProfile else { return "Nuvio Guest" }
        return ProfileDisplayName.resolve(profile: displayedProfile, settingsName: settingsProfileName)
    }

    var body: some View {
        if #available(tvOS 27.0, *) {
            tabs
                .tabViewStyle(.sidebarAdaptable)
                .tabViewSidebarHeader {
                    TVSidebarProfileHeader(
                        profile: displayedProfile,
                        action: onSwitchProfile
                    )
                }
        } else if #available(tvOS 18.0, *) {
            tabs
                .tabViewStyle(.sidebarAdaptable)
        } else {
            tabs
        }
    }

    private var tabs: some View {
        TabView(selection: $selectedTab) {
            // tvOS 27 surfaces the profile in the sidebar header; older tvOS has
            // no sidebar-header API, so expose the profile as a dedicated tab.
            // The tab label carries the profile name + avatar icon so the menu
            // shows who's signed in instead of a generic "Profile" entry. Its
            // content stays empty: selecting it goes straight to profile
            // switching, while editing now lives in Settings.
            if #unavailable(tvOS 27.0) {
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
            }

            TVHomeView(
                store: homeStore,
                repository: CinemetaCatalogRepository(),
                onNavigateToDetails: onNavigateToDetails,
                onOpenCollectionFolder: onOpenCollectionFolder,
                onResumePlayback: onResumePlayback,
                onLongPressCard: onLongPressCard
            )
                .id(activeProfile?.id ?? "none")
                .tabItem {
                    Label(TVTab.home.title, systemImage: TVTab.home.symbol)
                }
                .tag(TVTab.home)

            SearchView(
                viewModel: searchViewModel,
                showDiscover: discoverLocation == "Search",
                onContentClick: onNavigateToDetails,
                onLongPress: onLongPressCard
            )
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
    @ObservedObject var store: TVHomeStore
    let repository: CatalogRepository
    let onNavigateToDetails: (String, String) -> Void
    let onOpenCollectionFolder: (TVCollectionFolderItem, String) -> Void
    let onResumePlayback: (ContinueWatchingItem) -> Void
    var onLongPressCard: ((NuvioMeta) -> Void)? = nil

    @AppStorage(SettingsKey.amoled) private var amoled = false
    @AppStorage(SettingsKey.bodyColor) private var bodyColor = SettingsBackground.charcoal.rawValue
    @AppStorage(SettingsKey.heroEnabled) private var heroEnabled = true
    @AppStorage(SettingsKey.trailersEnabled) private var trailersEnabled = true
    @AppStorage(SettingsKey.trailerDelay) private var trailerDelay = 7
    @AppStorage(SettingsKey.fastNavigation) private var fastNavigation = false
    @AppStorage(SettingsKey.hideUnreleased) private var hideUnreleased = false
    @AppStorage(SettingsKey.smoothFocus) private var smoothFocus = true
    @AppStorage(SettingsKey.homeLayout) private var homeLayout = "Modern"
    @AppStorage(SettingsKey.posterLabels) private var posterLabels = false

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
    @State private var addonReloadTask: Task<Void, Never>?
    @State private var continueWatching: [ContinueWatchingItem] = []
    @State private var displayedProgressSource: TraktWatchProgressSource?
    @State private var continueWatchingRefreshGeneration = 0
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
    @Environment(\.isEnabled) private var isEnabled
    @State private var focusedRowIndex = 0
    /// Measured height per section id (collection vs catalog rows differ).
    @State private var measuredRowHeights: [String: CGFloat] = [:]
    @State private var verticalOffset: CGFloat = 0
    @FocusState private var isLoadingFocusActive: Bool
    @FocusState private var focusedCardID: String?

    var body: some View {
        ZStack(alignment: .topLeading) {
            HomeTabBarScrollState(rowIndex: focusedRowIndex)

            // 1. Bottom Layer: Full Screen Crossfading Backdrop
            // Collection folder heroes: top-trailing crop (Android TopEnd) so
            // portrait hero art isn't center-cropped with the subject too high.
            CrossfadingBackdrop(
                url: homeBackdropURL,
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
                    TVErrorView(message: errorMessage)
                } else {
                    // Header Hero Meta block (static, outside the rows). Folder
                    // focus swaps poster meta for emoji + folder title (browse-style).
                    if heroEnabled {
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
                        // Same cadence as the gap under the hero (see TVHeroView
                        // bottom padding + this top padding) so the first section
                        // title does not sit farther from the hero title than
                        // later section titles sit from the row above.
                        VStack(spacing: TVHomeLayout.sectionSpacing) {
                            ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                                if shouldMaterializeHomeRow(index, sectionId: section.id, total: sections.count) {
                                    if !section.collectionFolders.isEmpty {
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
                                            restrictFocusToCardKey: overlayRestoreCardID,
                                            onInitialFocusRequested: {
                                                didRequestInitialCardFocus = true
                                            },
                                            onFocus: { folder in
                                                if focusedRowIndex != index {
                                                    focusedRowIndex = index
                                                    verticalOffset = offsetForRow(index, in: sections)
                                                }
                                                // Row window + card focus update immediately; hero /
                                                // full-screen backdrop wait for settle so horizontal
                                                // paging does not thrash decode + layout each step.
                                                focusedSectionId = section.id
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
                                        restrictFocusToCardKey: overlayRestoreCardID,
                                        onInitialFocusRequested: {
                                            didRequestInitialCardFocus = true
                                        },
                                        onFocus: { meta in
                                            // Only re-anchor vertically when the
                                            // focused ROW changes -- horizontal
                                            // moves keep the offset rock-steady so
                                            // lower rows don't flicker at the clip.
                                            if focusedRowIndex != index {
                                                focusedRowIndex = index
                                                verticalOffset = offsetForRow(index, in: sections)
                                            }
                                            // Immediate: focus engine + row window.
                                            // Deferred: hero text + full-screen backdrop.
                                            focusedSectionId = section.id
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
                                                overlayRestoreCardID = "\(section.id)\u{1}\(meta.id)"
                                                onNavigateToDetails(meta.id, meta.type)
                                            }
                                        },
                                        onLongPress: onLongPressCard
                                    )
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
                        .animation(smoothFocus ? TVHomeLayout.scrollSpring : nil, value: verticalOffset)
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
        .task {
            await load()
            await ContinueWatchingStore.refreshMissingEpisodeDetails()
        }
        .task {
            await refreshContinueWatchingFromSelectedSource()
        }
        .onAppear {
            // Classic was never a distinct layout; collapse legacy values to Modern.
            if homeLayout == "Classic" { homeLayout = "Modern" }
            refreshContinueWatching()
            refreshWatchedTitles()
        }
        // Home stays mounted behind Details/Player, so `onAppear` no longer
        // fires on return. Refresh the Continue Watching row whenever the store
        // changes (progress saved during playback, item finished/removed).
        .onReceive(NotificationCenter.default.publisher(for: ContinueWatchingStore.changedNotification)) { _ in
            refreshContinueWatching()
        }
        .onReceive(NotificationCenter.default.publisher(for: TraktAuthStore.changedNotification)) { _ in
            Task { await refreshContinueWatchingFromSelectedSource() }
        }
        .onReceive(NotificationCenter.default.publisher(for: TraktSettingsStore.continueWatchingChangedNotification)) { _ in
            Task { await refreshContinueWatchingFromSelectedSource() }
        }
        .onReceive(NotificationCenter.default.publisher(for: WatchedStore.changedNotification)) { _ in
            refreshWatchedTitles()
        }
        // Collection rows arrive from the account sync, which usually lands
        // after Home has loaded — splice them in when the store updates.
        .onReceive(NotificationCenter.default.publisher(for: CollectionsStore.changedNotification)) { _ in
            Task { await refreshCollectionSections() }
        }
        // Settings → Home Catalogs reorder applies to the mounted Home live.
        .onReceive(NotificationCenter.default.publisher(for: TVHomeCatalogOrder.changedNotification)) { _ in
            let reordered = TVHomeCatalogOrder.apply(to: store.sections)
            if reordered.map(\.id) != store.sections.map(\.id) {
                store.sections = reordered
            }
        }
        // Add-on enable/order changes must replace the mounted catalog tree.
        // Persisting the setting alone is not enough because `TVHomeStore`
        // intentionally caches its sections while Home remains mounted.
        .onReceive(NotificationCenter.default.publisher(for: NuvioSyncManager.addonOrderChangedNotification)) { _ in
            addonReloadTask?.cancel()
            addonReloadTask = Task { @MainActor in
                await reloadHomeAfterCurrentLoad()
            }
        }
        // Account sync applies add-on and Home-catalog settings after the
        // initial Home load can already have cached its rows. Rebuild once the
        // remote profile data is fully available so Better Posters and other
        // synced catalogs appear without requiring an app relaunch.
        .onReceive(NotificationCenter.default.publisher(for: NuvioSyncManager.homeContentSyncedNotification)) { _ in
            addonReloadTask?.cancel()
            addonReloadTask = Task { @MainActor in
                await reloadHomeAfterCurrentLoad()
            }
        }
        .onDisappear {
            focusWork.cancelAll()
            addonReloadTask?.cancel()
            continueWatchingRefreshGeneration &+= 1
        }
        .onChange(of: isLoading) { loading in
            if loading {
                requestLoadingFocus()
            }
        }
        .onChange(of: focusedCardID) { newValue in
            if let newValue {
                store.lastFocusedCardID = newValue
                shouldRestoreHomeFocus = false
                // Restoration complete -- lift the focus restriction.
                if isEnabled, newValue == overlayRestoreCardID {
                    overlayRestoreCardID = nil
                }
            } else if store.lastFocusedCardID != nil {
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
            if !enabled {
                overlayRestoreGeneration &+= 1
                overlayRestoreCardID = focusedCardID ?? store.lastFocusedCardID
            } else if let target = overlayRestoreCardID {
                restoreOverlayFocus(to: target, generation: overlayRestoreGeneration)
            }
        }
    }

    /// Nudges focus back to `target` after an overlay dismissal, in case the
    /// engine parked focus outside the rows (hero, sidebar) while the tab view
    /// was still fading in. Two attempts because cards are unfocusable at
    /// near-zero opacity; the trailing clear lifts the card restriction even
    /// if the saved card no longer exists (e.g. Continue Watching reordered),
    /// so the rows can never be left permanently unfocusable.
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
        // Account progress is available before the add-on catalog requests
        // finish. Do not cover a ready Continue Watching row with the global
        // spinner while BetterPosters (or another large add-on) is loading.
        isLoading && store.sections.isEmpty && continueWatching.isEmpty
    }

    private var firstFocusableSectionId: String? {
        visibleSections.first(where: \.hasContent)?.id
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
        guard let section = visibleSections.first(where: \.hasContent) else { return nil }
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

    /// Collection folder row estimate — identical strip math to catalog rows
    /// (same image height, optional poster labels, strip padding, title block).
    private var estimatedCollectionRowHeight: CGFloat {
        let imageHeight: CGFloat = homeLayout == "Compact" ? 255 : 315
        let stripHeight = imageHeight + (posterLabels ? 48 : 0) + TVHomeLayout.stripVerticalPadding * 2
        return stripHeight + TVHomeLayout.rowTitleBlock
    }

    private func estimatedHeight(for section: TVHomeSection) -> CGFloat {
        if let measured = measuredRowHeights[section.id], measured > 0 {
            return measured
        }
        return section.collectionFolders.isEmpty ? estimatedCatalogRowHeight : estimatedCollectionRowHeight
    }

    /// Keep a small working set of Home rows mounted for the focus engine.
    ///
    /// ±1 is enough for a single step, but rapid reverse (up → down → up → down)
    /// demounts the next row before tvOS evaluates the next press, so that press
    /// is eaten and the user has to click again. ±2 keeps one extra row in each
    /// direction so the engine always has a live focus target after a direction
    /// change. Prefer the currently focused section id when it is known so the
    /// window tracks real focus even if `focusedRowIndex` lags by a frame.
    private func shouldMaterializeHomeRow(_ index: Int, sectionId: String, total: Int) -> Bool {
        guard total > 0 else { return false }

        let sections = visibleSections.filter(\.hasContent)
        let sectionFocusIndex = focusedSectionId.flatMap { id in
            sections.firstIndex(where: { $0.id == id })
        }
        let center = sectionFocusIndex ?? min(max(focusedRowIndex, 0), total - 1)
        let lower = max(0, center - 2)
        let upper = min(total - 1, center + 2)
        if (lower...upper).contains(index) { return true }

        // A restored focus target can be outside the initial row window.
        let rowPrefix = "\(sectionId)\u{1}"
        return initialFocusCardKey?.hasPrefix(rowPrefix) == true
            || overlayRestoreCardID?.hasPrefix(rowPrefix) == true
    }

    /// Vertical translation that lands the row at `index` flush under the hero.
    /// Sums actual/estimated heights of rows above — required because collection
    /// folder rows and catalog poster rows are not the same height.
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
        let allSections = continueWatching.isEmpty ? store.sections : [resumeSection] + store.sections

        // The common path does not need to copy and filter every add-on row on
        // each focus update. Keep the original copy-on-write item arrays intact.
        guard hideUnreleased else { return allSections }

        return allSections.map { section in
            // Collection folder rows don't carry title posters; leave them intact.
            if !section.collectionFolders.isEmpty { return section }
            var copy = section
            copy.items = section.items.filter(isVisible)
            return copy
        }
    }

    private var continueWatchingByMetaId: [String: ContinueWatchingItem] {
        Dictionary(uniqueKeysWithValues: continueWatching.map { ($0.meta.id, $0) })
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
        return !isUnreleased(meta)
    }

    private func isUnreleased(_ meta: NuvioMeta) -> Bool {
        let currentYear = Calendar.current.component(.year, from: Date())
        if let year = meta.year, year > currentYear {
            return true
        }
        if let releasedYear = leadingYear(from: meta.released), releasedYear > currentYear {
            return true
        }
        if let releaseInfoYear = leadingYear(from: meta.releaseInfo), releaseInfoYear > currentYear {
            return true
        }
        return false
    }

    private func leadingYear(from value: String?) -> Int? {
        guard let value else { return nil }
        let prefix = value.prefix(4)
        guard prefix.count == 4 else { return nil }
        return Int(prefix)
    }

    private func requestLoadingFocus() {
        DispatchQueue.main.async {
            isLoadingFocusActive = true
        }
    }

    @MainActor
    private func load() async {
        // Progress is local/account-synced state and does not depend on the
        // catalog network request below. Publish it first so Home is useful
        // even while a large add-on is still resolving its rows.
        refreshContinueWatching()
        refreshWatchedTitles()

        // Returning from a card: the catalog is still cached in the store, so
        // skip the network round-trip. The saved card re-focuses itself via
        // `initialFocusCardKey`, which restores the row/scroll position too.
        if store.hasLoaded {
            isLoading = false
            refreshContinueWatching()
            refreshWatchedTitles()
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            let catalogs = try await repository.getHomeCatalogs()
            var loadedSections: [TVHomeSection] = []

            for catalog in catalogs {
                let items: [NuvioMeta]
                let pendingItems: [NuvioMeta]
                let nextSkip: Int
                if let catalogItems = catalog.items {
                    items = Array(catalogItems.prefix(18))
                    pendingItems = Array(catalogItems.dropFirst(items.count))
                    // The add-on already returned these records, even though
                    // Home reveals them in smaller UI batches.
                    nextSkip = catalogItems.count
                } else {
                    var resolvedItems: [NuvioMeta] = []
                    for id in catalog.itemIds.prefix(18) {
                        if let meta = try? await repository.getMetadata(id: id, type: catalog.contentType ?? "movie") {
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
                        catalogGenre: catalog.catalogGenre,
                        pendingItems: pendingItems,
                        nextSkip: nextSkip,
                        hasMore: !items.isEmpty && (!pendingItems.isEmpty || canRequestMore)
                    )
                )
            }

            let collectionSections = await loadCollectionSections()
            let pinned = collectionSections.filter(\.isPinnedCollection)
            let unpinned = collectionSections.filter { !$0.isPinnedCollection }
            let composed = TVHomeCatalogOrder.apply(to: pinned + loadedSections + unpinned)
            TVHomeCatalogOrder.writeSnapshot(composed)
            store.sections = composed
            store.hero = store.sections.first?.items.first
            store.lastFocusedCardID = nil
            store.hasLoaded = true
            refreshContinueWatching()
            refreshWatchedTitles()
            focusedMeta = store.sections.first?.items.first
            focusedSectionId = nil
            focusedCollectionFolder = nil
            focusWork.pendingFocusedMeta = focusedMeta
            // Keep folder-hero state clear until a folder card is focused.
            landscapeFocusedId = nil
            focusWork.pendingLandscapeFocusedId = nil
            didRequestInitialCardFocus = false
            shouldRestoreHomeFocus = false
            isLoading = false
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    @MainActor
    private func reloadHomeAfterCurrentLoad() async {
        // Account sync often lands while the four base Cinemeta rows are still
        // loading. Wait for that request to publish, then run one replacement
        // load using the newly applied add-ons instead of dropping the event.
        while isLoading && !store.hasLoaded {
            do {
                try await Task.sleep(nanoseconds: 200_000_000)
            } catch {
                return
            }
        }
        guard !Task.isCancelled else { return }
        await reloadHomeForAddonChange()
    }

    @MainActor
    private func reloadHomeForAddonChange() async {
        guard !Task.isCancelled else { return }

        // Direct callers must not overlap the initial request. Notification
        // callers use `reloadHomeAfterCurrentLoad()` above and therefore queue.
        guard store.hasLoaded || !isLoading else { return }

        // Keep the last successful rows mounted while the replacement tree is
        // fetched. A slow/dead add-on must never blank Home or hide Continue
        // Watching; `load()` swaps in the new tree only after it completes.
        store.hasLoaded = false
        isLoading = true
        errorMessage = nil
        await load()
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
                    sources: folder.addonCatalogSources,
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
    private func refreshCollectionSections() async {
        guard store.hasLoaded else { return }
        let fresh = await loadCollectionSections()
        let catalogRows = store.sections.filter { !$0.isCollectionRow }
        let pinned = fresh.filter(\.isPinnedCollection)
        let unpinned = fresh.filter { !$0.isPinnedCollection }
        let merged = TVHomeCatalogOrder.apply(to: pinned + catalogRows + unpinned)
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
        fastNavigation ? 120_000_000 : 250_000_000
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
                      folder.id == targetFolderId else { return }
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
                  settledMeta.id == targetMetaId else { return }

            // Leaving a folder hero: clear only after settle so backdrop stays frozen.
            if focusedCollectionFolder != nil {
                focusedCollectionFolder = nil
            }
            if focusedMeta?.id != settledMeta.id {
                focusedMeta = settledMeta
            }
        }
    }

    @MainActor
    private func loadMoreSectionIfNeeded(sectionId: String, currentItem: NuvioMeta) {
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
        guard trailersEnabled else {
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
        let delaySeconds = max(1, trailerDelay)
        focusWork.landscapeFocusTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds) * 1_000_000_000)
            guard !Task.isCancelled,
                  focusWork.pendingLandscapeFocusedId == targetKey else {
                return
            }

            landscapeFocusedId = targetKey
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
        guard !usesTraktProgress else {
            if displayedProgressSource != .trakt {
                continueWatching = []
                displayedProgressSource = .trakt
            }
            return
        }
        continueWatching = ContinueWatchingStore.items().filter { isVisible($0.meta) }
        displayedProgressSource = .nuvioSync
    }

    @MainActor
    private func refreshContinueWatchingFromSelectedSource() async {
        continueWatchingRefreshGeneration &+= 1
        let generation = continueWatchingRefreshGeneration
        let profileID = ContinueWatchingStore.activeProfileId

        refreshContinueWatching()
        guard usesTraktProgress else { return }

        let items = await TraktProgressService.fetchContinueWatching(repository: repository)
        guard !Task.isCancelled,
              generation == continueWatchingRefreshGeneration,
              profileID == ContinueWatchingStore.activeProfileId,
              usesTraktProgress,
              let items else { return }
        continueWatching = items.filter { isVisible($0.meta) }
        displayedProgressSource = .trakt
    }

    private var selectedProgressSource: TraktWatchProgressSource {
        TraktSettingsStore.watchProgressSource
    }

    private var usesTraktProgress: Bool {
        selectedProgressSource == .trakt && TraktAuthStore.state.isAuthenticated
    }

    private func refreshWatchedTitles() {
        watchedTitleKeys = Set(
            WatchedStore.items()
                .filter { $0.season == nil && $0.episode == nil }
                .map { watchedTitleKey(for: $0.meta) }
        )
    }

    private func watchedTitleKey(for meta: NuvioMeta) -> String {
        "\(meta.type.lowercased())\u{1f}\(meta.id)"
    }
}

struct TVHomeSection: Identifiable {
    static let continueWatchingId = "continue_watching"
    /// Id prefix for rows built from account-synced collections.
    static let collectionIdPrefix = "collection_"

    let id: String
    let title: String
    var items: [NuvioMeta]
    var contentType: String? = nil
    var catalogId: String? = nil
    var addonId: String? = nil
    var catalogGenre: String? = nil
    /// Items already returned by the first add-on response but not mounted yet.
    var pendingItems: [NuvioMeta] = []
    var nextSkip: Int? = nil
    var hasMore: Bool = false
    var isLoadingMore: Bool = false
    /// Pinned collections render above the standard catalog rows.
    var isPinnedCollection: Bool = false
    /// Folder cards for a collection row (emoji / cover tiles). When non-empty,
    /// Home renders `TVCollectionFolderRow` with the same paging rhythm as
    /// catalog rows; catalogs stay grouped inside folders.
    var collectionFolders: [TVCollectionFolderItem] = []

    var isCollectionRow: Bool { id.hasPrefix(Self.collectionIdPrefix) }
    var hasContent: Bool { !items.isEmpty || !collectionFolders.isEmpty }
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
        return keys
    }

    static func save(_ keys: [String]) {
        guard let data = try? JSONEncoder().encode(keys) else { return }
        ProfileSettings.current.set(data, forKey: SettingsKey.homeCatalogOrder)
        NotificationCenter.default.post(name: changedNotification, object: nil)
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
            return keys
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
            if section.id.hasPrefix("addon_") {
                return String(section.id.dropFirst("addon_".count))
            }
            return section.id
        }
        let known = sections
            .filter { indexByKey[orderKey(for: $0)] != nil }
            .sorted {
                (indexByKey[orderKey(for: $0)] ?? 0) < (indexByKey[orderKey(for: $1)] ?? 0)
            }
        let unknown = sections.filter { indexByKey[orderKey(for: $0)] == nil }
        return known + unknown
    }

    /// Records the effective rows (id + title, in order) after a Home load.
    static func writeSnapshot(_ sections: [TVHomeSection]) {
        let rows = sections.map { ["id": $0.id, "title": $0.title] }
        guard let data = try? JSONSerialization.data(withJSONObject: rows) else { return }
        ProfileSettings.current.set(data, forKey: SettingsKey.homeCatalogTitles)
    }

    /// Keeps the Settings list's snapshot aligned after an in-list move so
    /// re-entering the pane shows the new order even before Home reloads.
    static func writeSnapshotRows(_ rows: [(id: String, title: String)]) {
        let payload = rows.map { ["id": $0.id, "title": $0.title] }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        ProfileSettings.current.set(data, forKey: SettingsKey.homeCatalogTitles)
    }

    /// Rows for the Settings reorder list, from the last Home snapshot.
    static func snapshotRows() -> [(id: String, title: String)] {
        guard let data = ProfileSettings.current.data(forKey: SettingsKey.homeCatalogTitles),
              let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: String]] else {
            return []
        }
        return rows.compactMap { row in
            guard let id = row["id"], let title = row["title"] else { return nil }
            return (id: id, title: title)
        }
    }
}

/// Holds the Home screen's browsing state outside `TVHomeView` so it survives
/// the details/player push (which tears the view down). Owned by `ContentView`;
/// lets returning from a card restore the cached catalog + the focused card
/// instead of reloading and jumping back to the top.
final class TVHomeStore: ObservableObject {
    @Published var sections: [TVHomeSection] = []
    @Published var hero: NuvioMeta?
    /// True once the catalog has loaded at least once, so `load()` can skip the
    /// network round-trip on return.
    @Published var hasLoaded = false
    /// Composite "<sectionId>\u{1}<metaId>" key of the last focused card.
    var lastFocusedCardID: String?

    func reset() {
        sections = []
        hero = nil
        hasLoaded = false
        lastFocusedCardID = nil
    }
}

private let TVHomeRowPrefetchThreshold = 6

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
        // Size to the logo's intrinsic aspect (capped at 440×114) instead of a
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
                .frame(maxWidth: 440, maxHeight: 114, alignment: .bottomLeading)
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
    let onInitialFocusRequested: () -> Void
    let onFocus: (NuvioMeta) -> Void
    let onBlur: (NuvioMeta) -> Void
    let onApproachEnd: (NuvioMeta) -> Void
    let onSelect: (NuvioMeta) -> Void
    var onLongPress: ((NuvioMeta) -> Void)? = nil

    // Index of the card whose leading edge is pinned under the title. Driven by
    // focus and intentionally NOT reset on blur, so the row keeps its position
    // when focus moves to another row and comes back (tvOS focus memory).
    @State private var scrollIndex: Int = 0
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

            HStack(alignment: .bottom, spacing: rowHomeLayout == "Compact" ? 22 : 28) {
                ForEach(items) { item in
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
                            if let index = items.firstIndex(where: { $0.id == focused.id }) {
                                if scrollIndex != index {
                                    scrollIndex = index
                                    onScrollIndexChange(index)
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
                        smoothFocusAnimations: rowSmoothFocus,
                        focusHighlighterEnabled: rowFocusHighlighter,
                        retainFocusAppearance: restrictFocusToCardKey == cardKey,
                        isWatched: isWatched(item)
                    ) {
                        onSelect(item)
                    }
                    .disabled(restrictFocusToCardKey != nil && restrictFocusToCardKey != cardKey)
                }
            }
            .padding(.vertical, TVHomeLayout.stripVerticalPadding)
            // Pin the focused card's leading edge directly under the title
            // (TVLayout.rowLeading) by translating the strip left scrollIndex steps.
            // The clipping window expands to the physical screen edge while the
            // card offset stays in the row's safe-area coordinate space.
            // tvOS overrides ScrollViewReader.scrollTo (no-op once a card is
            // already on-screen, which the focus engine guarantees), so we
            // position manually -- mirroring the Android TV BringIntoViewSpec.
            .offset(x: edgeInset + TVLayout.rowLeading - CGFloat(scrollIndex) * ((rowHomeLayout == "Compact" ? 170 : 210) + (rowHomeLayout == "Compact" ? 22 : 28)))
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
        case .landscape, .square:
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
        imageHeight + (posterLabels ? 48 : 0) + TVHomeLayout.stripVerticalPadding * 2
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

            HStack(alignment: .bottom, spacing: rowSpacing) {
                ForEach(Array(folders.enumerated()), id: \.element.id) { index, folder in
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
                        retainFocusAppearance: restrictFocusToCardKey == cardKey,
                        onSelect: { onSelect(folder) }
                    )
                    .disabled(restrictFocusToCardKey != nil && restrictFocusToCardKey != cardKey)
                }
            }
            .padding(.vertical, TVHomeLayout.stripVerticalPadding)
            .offset(x: edgeInset + TVLayout.rowLeading - scrollX)
            .frame(
                width: stripWidth,
                height: imageHeight
                    + (rowPosterLabels ? 48 : 0)
                    + TVHomeLayout.stripVerticalPadding * 2,
                alignment: .leading
            )
            .clipped()
            .offset(x: -edgeInset)
            .animation(rowSmoothFocus ? TVHomeLayout.scrollSpring : nil, value: scrollIndex)
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

    private var layoutWidth: CGFloat { cardWidth }

    /// Search-style labels use two lines (title + subtitle); reserve space.
    private var totalCardHeight: CGFloat {
        cardHeight + (showPosterLabels ? 48 : 0)
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
            .animation(
                smoothFocusAnimations ? .spring(response: 0.28, dampingFraction: 0.75) : nil,
                value: showFocus
            )
            .zIndex(showFocus ? 1 : 0)
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            artTile

            if showPosterLabels {
                VStack(alignment: .leading, spacing: 3) {
                    Text(displayTitle)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(showFocus ? .white : .white.opacity(0.78))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.white.opacity(0.45))
                        .lineLimit(1)
                }
                .frame(width: cardWidth, alignment: .leading)
            }
        }
        .frame(width: layoutWidth, height: totalCardHeight, alignment: .topLeading)
        .scaleEffect(showFocus ? 1.06 : 1.0)
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
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
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
            .modifier(CollectionFolderEmojiGlass(cornerRadius: cardCornerRadius, prominent: showFocus))

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

/// Liquid Glass surface for collection folder cards in emoji cover mode.
/// tvOS 26+ uses real `glassEffect`; older systems get frosted material.
private struct CollectionFolderEmojiGlass: ViewModifier {
    let cornerRadius: CGFloat
    var prominent: Bool = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(tvOS 26.0, *) {
            content
                .background(Color.white.opacity(prominent ? 0.14 : 0.08), in: shape)
                .glassEffect(.regular, in: shape)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .background(Color.white.opacity(prominent ? 0.12 : 0.06), in: shape)
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
    let source: NuvioCollectionCatalogSource
    var items: [NuvioMeta]
    var nextSkip: Int
    var hasMore: Bool
    var isLoadingMore: Bool = false
}

/// Full-screen folder browser. Honors collection `viewMode`:
/// - **Tabs** (`TABBED_GRID`): poster grid (optional source tabs + All).
/// - **Rows** / **Follow layout**: Home-style horizontal catalog rows per source.
struct CollectionFolderBrowseView: View {
    let folder: TVCollectionFolderItem
    let collectionTitle: String
    let repository: CatalogRepository
    let onSelect: (NuvioMeta) -> Void
    let onBack: () -> Void

    @State private var items: [NuvioMeta] = []
    @State private var catalogRows: [CollectionFolderCatalogRow] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var selectedTabIndex = 0
    @FocusState private var focusedItemID: String?
    @AppStorage(SettingsKey.amoled) private var amoled = false
    @AppStorage(SettingsKey.bodyColor) private var bodyColor = SettingsBackground.charcoal.rawValue
    @AppStorage(SettingsKey.homeLayout) private var homeLayout = "Modern"
    @AppStorage(SettingsKey.posterLabels) private var posterLabels = false

    private let pageSize = 40

    private var usesRows: Bool { folder.viewMode.usesCatalogRows }

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
        return items
    }

    private var columns: [GridItem] {
        [GridItem(
            .adaptive(minimum: CollectionFolderGridMetrics.posterWidth, maximum: CollectionFolderGridMetrics.posterWidth),
            spacing: CollectionFolderGridMetrics.posterGap,
            alignment: .top
        )]
    }

    var body: some View {
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
        .onExitCommand(perform: onBack)
        .task {
            await load()
        }
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
                                layoutMode: homeLayout,
                                showPosterLabels: posterLabels,
                                onApproachEnd: { item in
                                    loadMoreRowIfNeeded(rowId: row.id, currentItem: item)
                                },
                                onSelect: onSelect
                            )
                        }
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 60)
                }
                .focusSection()
            }
        }
    }

    private var gridContent: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: CollectionFolderGridMetrics.posterGap) {
                ForEach(displayedGridItems) { item in
                    CollectionFolderResultCard(
                        meta: item,
                        externalFocus: $focusedItemID
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
        .defaultFocusIfAvailable($focusedItemID, displayedGridItems.first?.id)
        .id(selectedTabIndex)
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        selectedTabIndex = 0

        let sources = folder.sources
        if sources.isEmpty {
            items = []
            catalogRows = []
            isLoading = false
            return
        }

        // Always load per-source so Rows mode (and Tabs without All) can split.
        var rows: [CollectionFolderCatalogRow] = []
        var all: [NuvioMeta] = []
        var seen = Set<String>()
        for source in sources {
            guard let page = try? await repository.browseCatalog(
                addonId: source.addonId,
                contentType: source.type,
                catalogId: source.catalogId,
                skip: 0,
                genre: source.genre
            ) else { continue }
            let batch = Array(page.items.prefix(pageSize))
            var sourceIds = Set<String>()
            let resolved = batch.filter { sourceIds.insert($0.id).inserted }
            rows.append(
                CollectionFolderCatalogRow(
                    id: Self.sourceKey(source),
                    title: Self.sourceLabel(source),
                    source: source,
                    items: resolved,
                    nextSkip: batch.count,
                    hasMore: page.hasMore && !batch.isEmpty
                )
            )
            for meta in resolved where seen.insert(meta.id).inserted {
                all.append(meta)
            }
        }
        catalogRows = rows.filter { !$0.items.isEmpty }
        items = all
        isLoading = false
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
                let page = try await repository.browseCatalog(
                    addonId: source.addonId,
                    contentType: source.type,
                    catalogId: source.catalogId,
                    skip: requestedSkip,
                    genre: source.genre
                )
                guard let latestIndex = catalogRows.firstIndex(where: { $0.id == rowId }) else { return }

                let batch = Array(page.items.prefix(pageSize))
                var existingRowIds = Set(catalogRows[latestIndex].items.map(\.id))
                let newItems = batch.filter { existingRowIds.insert($0.id).inserted }
                catalogRows[latestIndex].items.append(contentsOf: newItems)
                catalogRows[latestIndex].nextSkip = requestedSkip + batch.count
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

    private static func sourceKey(_ source: NuvioCollectionCatalogSource) -> String {
        "\(source.addonId)_\(source.type)_\(source.catalogId)_\(source.genre ?? "")"
    }

    private static func sourceLabel(_ source: NuvioCollectionCatalogSource) -> String {
        let type = source.type.capitalized
        let name = source.catalogId
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        if let genre = source.genre, !genre.isEmpty {
            return "\(name) (\(type)) · \(genre)"
        }
        return "\(name) (\(type))"
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
    let onApproachEnd: (NuvioMeta) -> Void
    let onSelect: (NuvioMeta) -> Void

    /// Stable row id so composite card keys stay unique across strips.
    private var rowId: String { id }

    @State private var scrollIndex: Int = 0
    @State private var landscapeFocusedId: String?
    @AppStorage(SettingsKey.smoothFocus) private var smoothFocus = true
    @AppStorage(SettingsKey.focusHighlighter) private var focusHighlighter = false

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
                            landscapeFocusedId = cardKey
                            onApproachEnd(focused)
                        },
                        onBlur: { blurred in
                            let key = "\(rowId)\u{1}\(blurred.id)"
                            if landscapeFocusedId == key {
                                landscapeFocusedId = nil
                            }
                        },
                        layoutMode: rowHomeLayout,
                        showPosterLabels: rowPosterLabels,
                        smoothFocusAnimations: rowSmoothFocus,
                        focusHighlighterEnabled: rowFocusHighlighter
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
}

/// Poster card chrome matching Search / Library grids (Tabs view mode).
private struct CollectionFolderResultCard: View {
    let meta: NuvioMeta
    var externalFocus: FocusState<String?>.Binding? = nil
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
                    WatchedCheckmarkBadge(metaId: meta.id, type: meta.type)
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
    var body: some View {
        VStack(spacing: 18) {
            ProgressView()
                .scaleEffect(1.4)
            Text("Loading catalog")
                .font(.system(size: 24, weight: .semibold))
                .foregroundColor(.white.opacity(0.62))
        }
        .frame(maxWidth: .infinity, minHeight: 620)
        .focusable(true)
    }
}

private struct TVErrorView: View {
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Catalog failed")
                .font(.largeTitle.bold())
            Text(message)
                .font(.title3)
                .foregroundColor(.white.opacity(0.68))
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
        guard datePart.count == 10,
              let date = isoDay.date(from: datePart) else {
            return raw
        }

        return display.string(from: date)
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
