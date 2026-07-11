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
}

enum TVTab: String, CaseIterable, Identifiable {
    case profile = "Profile"
    case home = "Home"
    case search = "Search"
    case library = "Library"
    case settings = "Settings"

    var id: String { rawValue }

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
    /// Title whose liquid-glass quick-actions menu is showing (long-press on a
    /// card). Presented as an overlay over the tab view, like Details/Player.
    @State private var cardMenuMeta: NuvioMeta?
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
                        }
                }

            case .main, .details, .player, .cloudLibrary:
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
                } else if autoSelectLast, profileViewModel.activeProfile != nil {
                    activeScreen = .main
                } else {
                    activeScreen = .profileSelection
                }
            }
        }
        .onReceive(authManager.$authState) { state in
            syncManager.authStateChanged(state)
        }
        .onReceive(syncManager.$isPullingAccountProfiles) { pulling in
            if !pulling, awaitingPostLoginSync {
                let shouldEnterMain = enterMainAfterPostLoginSync
                    && authManager.isAuthenticated
                    && syncManager.profileSyncError == nil
                    && profileViewModel.activeProfile?.id != "guest"
                withAnimation(.easeInOut(duration: 0.28)) {
                    awaitingPostLoginSync = false
                    enterMainAfterPostLoginSync = false
                    if shouldEnterMain {
                        activeScreen = .main
                    }
                }
            }
        }
        .onReceive(profileViewModel.$activeProfile) { profile in
            syncManager.activeProfileChanged(profile)
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
        if cardMenuMeta != nil { return true }
        return fullScreenOverlayPresented
    }

    /// Details/Player fully replace Home, so the tab view fades to black under
    /// them. The card quick-actions menu is deliberately excluded — it keeps Home
    /// visible behind its glass panel.
    private var fullScreenOverlayPresented: Bool {
        switch activeScreen {
        case .details, .player, .cloudLibrary: return true
        default: return false
        }
    }

    /// Dismisses the current overlay to the same destination its own back action
    /// would (Player returns to Details for series/trailers, otherwise Home).
    /// Used only by the root Menu-button safety net; changing `activeScreen`
    /// tears the overlay down, so Player's `onDisappear` cleanup still runs.
    private func dismissOverlay() {
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
            let isTrailer = subtitle == PlaybackMarkers.trailerSubtitle
            withAnimation(.easeInOut(duration: 0.24)) {
                activeScreen = (isTrailer || meta.isSeries)
                    ? .details(id: meta.id, type: meta.type)
                    : .main
            }
        case .cloudLibrary:
            withAnimation(.easeInOut(duration: 0.24)) {
                activeScreen = .main
            }
        default:
            break
        }
    }

    /// Handles `nuvio-tv://details?id=…&type=…` deep links (e.g. a Top Shelf card
    /// tapped on the Apple TV home screen), opening the matching Details screen.
    /// Ignored while the user is still on the login / profile gate.
    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "nuvio-tv", url.host == "details",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let id = components.queryItems?.first(where: { $0.name == "id" })?.value, !id.isEmpty else {
            return
        }
        let type = components.queryItems?.first(where: { $0.name == "type" })?.value ?? "movie"
        switch activeScreen {
        case .login, .profileSelection:
            return
        default:
            withAnimation(.easeInOut(duration: 0.28)) {
                activeScreen = .details(id: id, type: type)
            }
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
        let current = sorted.first { $0.season == item.season && $0.episode == item.episode }
        return (sorted, current)
    }

    private static func seasonSortKey(_ season: Int) -> Int {
        season <= 0 ? Int.max : season
    }

    private func presentPlayback(
        url: URL,
        meta: NuvioMeta,
        subtitle: String,
        externalSubtitles: [NuvioSubtitle],
        resumeFrom: Double?
    ) {
        let isTrailer = subtitle == PlaybackMarkers.trailerSubtitle
        let player = ExternalPlayer.from(
            ProfileSettings.store(for: profileViewModel.activeProfile?.id)
                .string(forKey: SettingsKey.externalPlayer)
        )

        // Hand off to the external app only when it is actually installed
        // (`canOpenURL` needs its scheme in LSApplicationQueriesSchemes); if it
        // isn't, fall through to the built-in player instead of a dead launch.
        if !isTrailer,
           let launchURL = player.launchURL(for: url),
           UIApplication.shared.canOpenURL(launchURL) {
            UIApplication.shared.open(launchURL, options: [:], completionHandler: nil)
            return
        }

        presentBuiltInPlayer(
            url: url,
            meta: meta,
            subtitle: subtitle,
            externalSubtitles: externalSubtitles,
            resumeFrom: resumeFrom
        )
    }

    private func presentBuiltInPlayer(
        url: URL,
        meta: NuvioMeta,
        subtitle: String,
        externalSubtitles: [NuvioSubtitle],
        resumeFrom: Double?
    ) {
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
            onResumePlayback: { item in
                let streamUrl = item.streamUrl.trimmingCharacters(in: .whitespacesAndNewlines)
                if !streamUrl.isEmpty, let url = URL(string: streamUrl) {
                    // Carry episode context so the player can offer the next
                    // episode when resuming straight from Home.
                    let context = Self.episodeContext(for: item)
                    playbackEpisodes = context.episodes
                    playbackCurrentEpisode = context.current
                    presentPlayback(
                        url: url,
                        meta: item.meta,
                        // Rebuild the episode line so the player header shows it
                        // and progress saves keep the episode identity.
                        subtitle: item.episodeSubtitle ?? "",
                        externalSubtitles: [],
                        resumeFrom: item.resumePosition
                    )
                } else {
                    withAnimation(.easeInOut(duration: 0.28)) {
                        activeScreen = .details(id: item.meta.id, type: item.meta.type)
                    }
                }
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
            onPlayClick: { streamUrlString, meta, subtitle, externalSubtitles, currentEpisode, episodes in
                if let url = URL(string: streamUrlString) {
                    let isTrailer = subtitle == PlaybackMarkers.trailerSubtitle
                    playbackEpisodes = episodes
                    playbackCurrentEpisode = currentEpisode
                    presentPlayback(
                        url: url,
                        meta: meta,
                        subtitle: subtitle,
                        externalSubtitles: externalSubtitles,
                        resumeFrom: isTrailer ? nil : ContinueWatchingStore.item(for: meta.id)?.resumePosition
                    )
                }
            },
            onBack: {
                withAnimation(.easeInOut(duration: 0.24)) {
                    activeScreen = .main
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
                presentPlayback(url: url, meta: meta, subtitle: "", externalSubtitles: [], resumeFrom: nil)
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
    /// and to reload a fresh link for the current title when one expires. A fresh
    /// fetch yields fresh (non-expired) URLs.
    private static func resolveStream(contentId: String, type: String, subtitleLine: String, profileId: String?) async -> PreparedNextStream? {
        let repository = CinemetaCatalogRepository()
        let streams = ((try? await repository.getStreams(id: contentId, type: type)) ?? [])
            .filter { $0.addonName != "Nuvio Sample" }   // ignore the placeholder fallback
        guard !streams.isEmpty else { return nil }

        let store = ProfileSettings.store(for: profileId)
        let quality = store.string(forKey: SettingsKey.smartStreamQuality) ?? "Highest"
        let matchSubtitles = store.object(forKey: SettingsKey.smartSubtitleMatching) as? Bool ?? true
        let languages = SubtitleLanguagePreferences.orderedFromDefaults(defaults: store)

        let debrid = DebridResolver(store: store)
        let best = SmartPlaybackSelector.bestStream(
            from: streams,
            qualityPreference: quality,
            subtitleLanguages: languages,
            shouldMatchSubtitles: matchSubtitles,
            includeDebrid: debrid.isEnabled
        ) ?? SmartPlaybackSelector.playableStreams(from: streams, includeDebrid: debrid.isEnabled).first

        guard let best else { return nil }

        // Torrent-only streams (no direct URL) go through the debrid provider,
        // which returns a cached, directly-playable link. Direct streams pass
        // through untouched.
        if best.isDebridResolvable {
            let (season, episode) = Self.seasonEpisode(fromContentId: contentId)
            guard case let .success(url, _, _)? = await debrid.resolvedURL(for: best, season: season, episode: episode) else {
                return nil
            }
            return PreparedNextStream(url: url, subtitleLine: subtitleLine, subtitles: best.subtitles)
        }

        guard let urlString = best.url, let url = URL(string: urlString) else { return nil }
        return PreparedNextStream(url: url, subtitleLine: subtitleLine, subtitles: best.subtitles)
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
            reloadCurrentStream: isTrailer ? nil : {
                let profileId = profileViewModel.activeProfile?.id
                if let episode = playbackCurrentEpisode {
                    return await Self.resolveNextEpisodeStream(episode: episode, profileId: profileId)
                }
                return await Self.resolveStream(contentId: meta.id, type: meta.type, subtitleLine: subtitle, profileId: profileId)
            },
            onFinished: isTrailer ? {
                withAnimation(.easeInOut(duration: 0.24)) {
                    activeScreen = .details(id: meta.id, type: meta.type)
                }
            } : nil
        ) {
            withAnimation(.easeInOut(duration: 0.24)) {
                if isTrailer {
                    activeScreen = .details(id: meta.id, type: meta.type)
                } else {
                    activeScreen = meta.isSeries ? .details(id: meta.id, type: meta.type) : .main
                }
            }
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
private struct CrossfadingBackdrop: View {
    let url: String?
    let placeholder: Color

    @State private var image: UIImage?
    @State private var loadedURL: String?
    @State private var outgoingImage: UIImage?
    @State private var outgoingOpacity = 0.0
    @State private var imageOpacity = 1.0

    var body: some View {
        ZStack {
            placeholder
            if let outgoingImage {
                Image(uiImage: outgoingImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .opacity(outgoingOpacity)
            }
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .opacity(imageOpacity)
                    .id(loadedURL)
            }
        }
        .task(id: url) {
            guard let url, url != loadedURL, let imageURL = URL(string: url) else {
                outgoingImage = nil
                outgoingOpacity = 0
                return
            }
            guard let loaded = await BackdropImageCache.shared.image(for: imageURL) else { return }
            guard loaded.size.width > loaded.size.height else { return }
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
    let onSignIn: () -> Void
    let onSignOut: () -> Void
    let onNavigateToDetails: (String, String) -> Void
    let onResumePlayback: (ContinueWatchingItem) -> Void
    let onLongPressCard: (NuvioMeta) -> Void
    let onOpenCloudLibrary: () -> Void
    @AppStorage(SettingsKey.amoled) private var amoled = false
    @AppStorage(SettingsKey.bodyColor) private var bodyColor = SettingsBackground.charcoal.rawValue
    @AppStorage(SettingsKey.discoverLocation) private var discoverLocation = "Search"
    @AppStorage(SettingsKey.profileName) private var settingsProfileName = "Nuvio User"
    @StateObject private var profileTabAvatar = ProfileTabAvatarRenderer()

    /// Name shown on the fallback profile tab (tvOS < 27), mirroring the
    /// sidebar header's display-name logic.
    private var profileTabTitle: String {
        guard isAuthenticated else { return "Nuvio Guest" }
        return ProfileDisplayName.resolve(profile: activeProfile, settingsName: settingsProfileName)
    }

    var body: some View {
        if #available(tvOS 18.0, *) {
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
            // shows who's signed in instead of a generic "Profile" entry.
            if #unavailable(tvOS 27.0) {
                TVProfileTabView(
                    profile: isAuthenticated ? activeProfile : nil,
                    onSwitchProfile: onSwitchProfile,
                    onChangeAvatar: onChangeProfileAvatar
                )
                    .tabItem {
                        Label {
                            Text(profileTabTitle)
                        } icon: {
                            if let avatar = profileTabAvatar.image {
                                Image(uiImage: avatar).renderingMode(.original)
                            } else {
                                Image(systemName: ProfileAvatarCatalog.symbolName(for: activeProfile?.avatarId))
                            }
                        }
                    }
                    .tag(TVTab.profile)
            }

            TVHomeView(
                store: homeStore,
                repository: CinemetaCatalogRepository(),
                onNavigateToDetails: onNavigateToDetails,
                onResumePlayback: onResumePlayback,
                onLongPressCard: onLongPressCard
            )
                .tabItem {
                    Label(TVTab.home.rawValue, systemImage: TVTab.home.symbol)
                }
                .tag(TVTab.home)

            SearchView(
                viewModel: searchViewModel,
                showDiscover: discoverLocation == "Search",
                onContentClick: onNavigateToDetails,
                onLongPress: onLongPressCard
            )
                .tabItem {
                    Label(TVTab.search.rawValue, systemImage: TVTab.search.symbol)
                }
                .tag(TVTab.search)

            LibraryView(viewModel: libraryViewModel, onContentClick: onNavigateToDetails, onLongPress: onLongPressCard, onOpenCloudLibrary: onOpenCloudLibrary)
                .tabItem {
                    Label(TVTab.library.rawValue, systemImage: TVTab.library.symbol)
                }
                .tag(TVTab.library)

            SettingsView(
                activeProfile: isAuthenticated ? activeProfile : nil,
                accountEmail: accountEmail,
                isAuthenticated: isAuthenticated,
                onSignIn: onSignIn,
                onSignOut: onSignOut
            )
                .tabItem {
                    Label(TVTab.settings.rawValue, systemImage: TVTab.settings.symbol)
                }
                .tag(TVTab.settings)
        }
        .background(Color.nuvioBackground(amoled: amoled, body: bodyColor).ignoresSafeArea())
        .onAppear {
            AvatarCatalogStore.shared.loadIfNeeded()
            profileTabAvatar.refresh(avatarId: activeProfile?.avatarId)
        }
        .onChange(of: activeProfile?.avatarId) { newValue in
            profileTabAvatar.refresh(avatarId: newValue)
        }
        // Re-attempt once the catalog finishes loading, since the first refresh
        // can't resolve the avatar image before then.
        .onReceive(AvatarCatalogStore.shared.$items) { _ in
            profileTabAvatar.refresh(avatarId: activeProfile?.avatarId)
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

/// Profile screen surfaced as a tab on tvOS versions without the sidebar header
/// API (< 27), so the active profile stays visible and switchable on device.
private struct TVProfileTabView: View {
    let profile: Profile?
    let onSwitchProfile: () -> Void
    let onChangeAvatar: (String, String) -> Void

    @AppStorage(SettingsKey.profileName) private var settingsProfileName = "Nuvio User"
    @State private var showingAvatarPicker = false
    @FocusState private var focusedControl: TVProfileTabFocus?

    var body: some View {
        VStack(spacing: 30) {
            ProfileAvatarView(
                avatarId: profile?.avatarId ?? ProfileAvatarCatalog.defaultId,
                size: 124,
                isFocused: focusedControl == .avatar
            )
            .scaleEffect(focusedControl == .avatar ? 1.1 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.82), value: focusedControl)

            VStack(spacing: 8) {
                Text(displayName)
                    .font(.system(size: 40, weight: .bold))
                    .foregroundColor(.white)

                Text("Manage who's watching")
                    .font(.system(size: 22))
                    .foregroundColor(.white.opacity(0.6))
            }

            HStack(spacing: 18) {
                TVProfileActionButton(
                    title: "Change Avatar",
                    systemImage: "person.crop.circle",
                    isFocused: focusedControl == .avatar
                ) {
                    showingAvatarPicker = true
                }
                .focused($focusedControl, equals: .avatar)
                .disabled(profile == nil)

                TVProfileActionButton(
                    title: "Switch Profile",
                    systemImage: "person.2.fill",
                    isFocused: focusedControl == .profile
                ) {
                    onSwitchProfile()
                }
                .focused($focusedControl, equals: .profile)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showingAvatarPicker) {
            ProfileAvatarPickerSheet(
                isPresented: $showingAvatarPicker,
                title: displayName,
                selectedAvatarId: profile?.avatarId ?? ProfileAvatarCatalog.defaultId
            ) { avatarId in
                guard let profileId = profile?.id else { return }
                onChangeAvatar(profileId, avatarId)
            }
        }
    }

    private var displayName: String {
        ProfileDisplayName.resolve(profile: profile, settingsName: settingsProfileName)
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

private enum TVProfileTabFocus: Hashable {
    case avatar
    case profile
}

private struct TVProfileActionButton: View {
    let title: String
    let systemImage: String
    let isFocused: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 24, weight: .semibold))
                .foregroundColor(isFocused ? .black : .white)
                .lineLimit(1)
                .padding(.horizontal, 34)
                .padding(.vertical, 18)
                .frame(minWidth: 230)
                .loginGlassCapsule(highlighted: isFocused)
                .contentShape(Capsule())
                .scaleEffect(isFocused ? 1.03 : 1)
        }
        .buttonStyle(PosterCardButtonStyle())
        .focusEffectDisabledIfAvailable()
        .animation(.easeOut(duration: 0.12), value: isFocused)
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

/// Measures one materialized Home row. Every catalog row has the same height,
/// so a single value is enough to preserve the full stack's geometry while
/// distant rows are represented by cheap placeholders.
private struct HomeRowHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private final class TVHomeFocusWork {
    var pendingFocusedMeta: NuvioMeta?
    var focusSettleTask: Task<Void, Never>?
    var pendingLandscapeFocusedId: String?
    var landscapeFocusTask: Task<Void, Never>?

    func cancelAll() {
        focusSettleTask?.cancel()
        landscapeFocusTask?.cancel()
        focusSettleTask = nil
        landscapeFocusTask = nil
        pendingFocusedMeta = nil
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

struct TVHomeView: View {
    @ObservedObject var store: TVHomeStore
    let repository: CatalogRepository
    let onNavigateToDetails: (String, String) -> Void
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
    /// Row the settled focus lives in; the hero only shows Continue Watching
    /// context (episode line, time left) for cards focused in that row.
    @State private var focusedSectionId: String?
    @State private var landscapeFocusedId: String?
    @State private var focusWork = TVHomeFocusWork()
    @State private var rowScrollStore = TVHomeRowScrollStore()
    @State private var addonReloadTask: Task<Void, Never>?
    @State private var continueWatching: [ContinueWatchingItem] = []
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
    @State private var measuredRowHeight: CGFloat?
    @State private var verticalOffset: CGFloat = 0
    @FocusState private var isLoadingFocusActive: Bool
    @FocusState private var focusedCardID: String?

    var body: some View {
        ZStack(alignment: .topLeading) {
            // 1. Bottom Layer: Full Screen Crossfading Backdrop
            CrossfadingBackdrop(
                url: homeBackdropURL,
                placeholder: Color.nuvioBackground(amoled: amoled, body: bodyColor)
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
                    // Header Hero Meta block (Static, outside ScrollView)
                    if heroEnabled, let heroMeta = visibleFocusedMeta ?? visibleHero {
                        TVHeroView(meta: heroMeta, continueItem: heroContinueItem(for: heroMeta)) {
                            onNavigateToDetails(heroMeta.id, heroMeta.type)
                        }
                    }
                    
                    // Only a small window around the focused row is materialized.
                    // Add-ons can contribute many catalogs (BetterPosters adds 13),
                    // and eagerly mounting every poster in every row makes each
                    // focus update rebuild hundreds of SwiftUI nodes. Fixed-height
                    // placeholders preserve the stack geometry and manual paging
                    // while the focused row plus its neighbours stay focusable.
                    GeometryReader { proxy in
                        let sections = visibleSections.filter { !$0.items.isEmpty }
                        VStack(spacing: 28) {
                            ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                                if shouldMaterializeHomeRow(index, sectionId: section.id, total: sections.count) {
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
                                                verticalOffset = offsetForRow(index)
                                            }
                                            settleFocus(on: meta, in: section.id)
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
                                                onNavigateToDetails(meta.id, meta.type)
                                            }
                                        },
                                        onLongPress: onLongPressCard
                                    )
                                    .background(
                                        GeometryReader { rowGeo in
                                            Color.clear.preference(
                                                key: HomeRowHeightKey.self,
                                                value: rowGeo.size.height.rounded()
                                            )
                                        }
                                    )
                                } else {
                                    Color.clear
                                        .frame(height: resolvedHomeRowHeight)
                                        .accessibilityHidden(true)
                                }
                            }
                        }
                        .padding(.top, 20)
                        .frame(width: proxy.size.width, alignment: .topLeading)
                        .offset(y: verticalOffset)
                        .animation(smoothFocus ? .spring(response: 0.4, dampingFraction: 0.95) : nil, value: verticalOffset)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .clipShape(VerticalEdgeClip())
                    .onPreferenceChange(HomeRowHeightKey.self) { newHeight in
                        guard newHeight > 0,
                              abs(newHeight - (measuredRowHeight ?? 0)) > 0.5 else { return }
                        measuredRowHeight = newHeight
                        let target = offsetForRow(focusedRowIndex, rowHeight: newHeight)
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
        .onAppear {
            refreshContinueWatching()
            refreshWatchedTitles()
        }
        // Home stays mounted behind Details/Player, so `onAppear` no longer
        // fires on return. Refresh the Continue Watching row whenever the store
        // changes (progress saved during playback, item finished/removed).
        .onReceive(NotificationCenter.default.publisher(for: ContinueWatchingStore.changedNotification)) { _ in
            refreshContinueWatching()
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
        visibleSections.first(where: { !$0.items.isEmpty })?.id
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
        guard let sectionId = firstFocusableSectionId,
              let first = visibleSections.first(where: { $0.id == sectionId })?.items.first else {
            return nil
        }
        return "\(sectionId)\u{1}\(first.id)"
    }

    private var estimatedHomeRowHeight: CGFloat {
        let imageHeight: CGFloat = homeLayout == "Compact" ? 255 : 315
        let stripHeight = imageHeight + (posterLabels ? 48 : 0) + 56
        // One 30pt Inter title line plus the row's 10pt internal spacing.
        return stripHeight + 46
    }

    private var resolvedHomeRowHeight: CGFloat {
        measuredRowHeight ?? estimatedHomeRowHeight
    }

    /// Keep only the focused row and its immediate neighbours. The next row is
    /// already mounted for the focus engine, and the window advances in the
    /// same transaction as focus, matching a TV lazy list's working set.
    private func shouldMaterializeHomeRow(_ index: Int, sectionId: String, total: Int) -> Bool {
        guard total > 0 else { return false }
        let lower = max(0, focusedRowIndex - 1)
        let upper = min(total - 1, focusedRowIndex + 1)
        if (lower...upper).contains(index) { return true }

        // A restored focus target can be outside the initial row window.
        let prefix = "\(sectionId)\u{1}"
        return initialFocusCardKey?.hasPrefix(prefix) == true
            || overlayRestoreCardID?.hasPrefix(prefix) == true
    }

    /// Vertical translation that lands the row at `index` where the first row
    /// sits (flush under the hero). Placeholder and real rows share one height,
    /// so this is constant-time and does not require per-frame geometry merging.
    private func offsetForRow(_ index: Int) -> CGFloat {
        offsetForRow(index, rowHeight: resolvedHomeRowHeight)
    }

    private func offsetForRow(_ index: Int, rowHeight: CGFloat) -> CGFloat {
        -CGFloat(index) * (rowHeight + 28)
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
            TVHomeSection(id: section.id, title: section.title, items: section.items.filter(isVisible))
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
        preferredBackdropURL(for: visibleFocusedMeta) ?? preferredBackdropURL(for: visibleHero)
    }

    private func preferredBackdropURL(for meta: NuvioMeta?) -> String? {
        guard let background = meta?.backgroundUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
              !background.isEmpty,
              background != meta?.posterUrl else {
            return nil
        }
        return background
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
                if let catalogItems = catalog.items {
                    items = Array(catalogItems.prefix(18))
                } else {
                    var resolvedItems: [NuvioMeta] = []
                    for id in catalog.itemIds.prefix(18) {
                        if let meta = try? await repository.getMetadata(id: id, type: catalog.contentType ?? "movie") {
                            resolvedItems.append(meta)
                        }
                    }
                    items = resolvedItems
                }

                loadedSections.append(
                    TVHomeSection(
                        id: catalog.id,
                        title: catalog.name,
                        items: items,
                        contentType: catalog.contentType,
                        catalogId: catalog.catalogId,
                        nextSkip: items.count,
                        hasMore: catalog.contentType != nil && catalog.catalogId != nil && !items.isEmpty
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
            focusWork.pendingFocusedMeta = focusedMeta
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

    /// Builds one Home row per synced collection folder, resolving each
    /// folder's add-on catalog sources into items. Folders whose sources are
    /// all unresolvable (TMDB/Trakt-only, unknown add-ons) are skipped.
    private func loadCollectionSections() async -> [TVHomeSection] {
        var sections: [TVHomeSection] = []
        for collection in CollectionsStore.collections() {
            for folder in collection.folders {
                let sources = folder.addonCatalogSources
                guard !sources.isEmpty else { continue }
                let items = await repository.getCollectionFolderItems(sources: sources, limit: 18)
                guard !items.isEmpty else { continue }
                let title = collection.title.caseInsensitiveCompare(folder.title) == .orderedSame
                    ? collection.title
                    : "\(collection.title) • \(folder.title)"
                sections.append(
                    TVHomeSection(
                        id: "\(TVHomeSection.collectionIdPrefix)\(collection.id)_\(folder.id)",
                        title: title,
                        items: items,
                        isPinnedCollection: collection.pinToTop
                    )
                )
            }
        }
        return sections
    }

    /// Re-resolves collection rows in place after a sync pull lands while
    /// Home is already loaded, without disturbing the catalog rows or focus.
    private func refreshCollectionSections() async {
        guard store.hasLoaded else { return }
        let fresh = await loadCollectionSections()
        let catalogRows = store.sections.filter { !$0.isCollectionRow }
        let pinned = fresh.filter(\.isPinnedCollection)
        let unpinned = fresh.filter { !$0.isPinnedCollection }
        let merged = TVHomeCatalogOrder.apply(to: pinned + catalogRows + unpinned)
        TVHomeCatalogOrder.writeSnapshot(merged)
        // Only publish when the row set actually changed; rebuilding the
        // section list disturbs tvOS focus.
        let currentIds = store.sections.map(\.id)
        if merged.map(\.id) != currentIds {
            store.sections = merged
        }
    }

    private func settleFocus(on meta: NuvioMeta, in sectionId: String) {
        focusWork.pendingFocusedMeta = meta
        focusWork.focusSettleTask?.cancel()

        let targetId = meta.id
        focusWork.focusSettleTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: fastNavigation ? 60_000_000 : 140_000_000)
            guard !Task.isCancelled,
                  focusWork.pendingFocusedMeta?.id == targetId,
                  let settledMeta = focusWork.pendingFocusedMeta else {
                return
            }

            // Same card, possibly reached in a different row: still update the
            // row so the hero's Continue Watching context follows the focus.
            focusedSectionId = sectionId
            guard focusedMeta?.id != targetId else { return }
            focusedMeta = settledMeta
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
        store.sections[sectionIndex].isLoadingMore = true

        Task { @MainActor in
            do {
                let page = try await repository.browseCatalog(
                    contentType: contentType,
                    catalogId: catalogId,
                    skip: requestedSkip,
                    genre: nil
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
        continueWatching = ContinueWatchingStore.items().filter { isVisible($0.meta) }
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
    /// Id prefix for rows built from account-synced collection folders.
    static let collectionIdPrefix = "collection_"

    let id: String
    let title: String
    var items: [NuvioMeta]
    var contentType: String? = nil
    var catalogId: String? = nil
    var nextSkip: Int? = nil
    var hasMore: Bool = false
    var isLoadingMore: Bool = false
    /// Pinned collections render above the standard catalog rows.
    var isPinnedCollection: Bool = false

    var isCollectionRow: Bool { id.hasPrefix(Self.collectionIdPrefix) }
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
    static func apply(to sections: [TVHomeSection]) -> [TVHomeSection] {
        let order = savedOrder()
        guard !order.isEmpty else { return sections }
        var indexByKey: [String: Int] = [:]
        for (index, key) in order.enumerated() where indexByKey[key] == nil {
            indexByKey[key] = index
        }
        let known = sections
            .filter { indexByKey[$0.id] != nil }
            .sorted { (indexByKey[$0.id] ?? 0) < (indexByKey[$1.id] ?? 0) }
        let unknown = sections.filter { indexByKey[$0.id] == nil }
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
        .padding(.bottom, 20)
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

    var body: some View {
        ZStack(alignment: .leading) {
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
            } else {
                Text(title)
                    .font(.custom("Inter-Bold", size: 54))
                    .lineLimit(2)
            }
        }
        .frame(width: 440, height: 114, alignment: .leading)
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
        return imageHeight + (posterLabels ? 48 : 0) + 56
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
            Text(title)
                .font(.custom("Inter-Bold", size: 30))
                .foregroundColor(.white)
                .padding(.leading, TVLayout.rowLeading)

            cardStrip
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
                        isWatched: isWatched(item)
                    ) {
                        onSelect(item)
                    }
                    .disabled(restrictFocusToCardKey != nil && restrictFocusToCardKey != cardKey)
                }
            }
            .padding(.vertical, 28)
            // Pin the focused card's leading edge directly under the title
            // (TVLayout.rowLeading) by translating the strip left scrollIndex steps.
            // The clipping window expands to the physical screen edge while the
            // card offset stays in the row's safe-area coordinate space.
            // tvOS overrides ScrollViewReader.scrollTo (no-op once a card is
            // already on-screen, which the focus engine guarantees), so we
            // position manually -- mirroring the Android TV BringIntoViewSpec.
            .offset(x: edgeInset + TVLayout.rowLeading - CGFloat(scrollIndex) * ((rowHomeLayout == "Compact" ? 170 : 210) + (rowHomeLayout == "Compact" ? 22 : 28)))
            .frame(width: stripWidth, height: (rowHomeLayout == "Compact" ? 255 : 315) + (rowPosterLabels ? 48 : 0) + 56, alignment: .leading)
            .clipped()
            .offset(x: -edgeInset)
            .animation(rowSmoothFocus ? .spring(response: 0.4, dampingFraction: 0.95) : nil, value: scrollIndex)
            .animation(rowSmoothFocus ? .spring(response: 0.18, dampingFraction: 0.86) : nil, value: landscapeFocusedId)
        }
        .frame(height: stripHeight)
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

        VStack(alignment: .leading, spacing: 10) {
            Text(primaryValues.joined(separator: "  •  "))
                .font(.custom("Inter-SemiBold", size: 22))
                .foregroundColor(.white.opacity(0.66))
                .lineLimit(1)

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

    private var formattedRuntime: String? {
        Self.formatRuntime(meta.runtime)
    }

    private var releaseDate: String? {
        if showFullDates, let released = meta.released, !released.isEmpty {
            return NuvioDateDisplay.formattedDate(released)
        }
        return meta.year.map(String.init)
    }

    private static func formatRuntime(_ runtime: String?) -> String? {
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

        guard let totalMinutes else {
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
