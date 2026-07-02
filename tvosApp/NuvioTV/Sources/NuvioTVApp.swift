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
    @State private var selectedTab: TVTab = .home
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
                    withAnimation(.easeInOut(duration: 0.28)) {
                        activeScreen = .profileSelection
                    }
                }
                .transition(.opacity)

            case .profileSelection:
                UserProfileView(viewModel: profileViewModel)
                    .onReceive(profileViewModel.$activeProfile) { activeProfile in
                        if activeProfile != nil {
                            withAnimation(.easeInOut(duration: 0.28)) {
                                activeScreen = .main
                            }
                        }
                    }

            case .main, .details, .player:
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
        .onAppear {
            syncManager.attach(authManager: authManager, profileViewModel: profileViewModel)
            guard !resolvedInitialScreen else { return }
            resolvedInitialScreen = true
            // Skip the login gate if a session was restored or the user has
            // previously chosen to continue without an account.
            if !authManager.shouldShowLoginGate {
                activeScreen = .profileSelection
            }
        }
        .onReceive(authManager.$authState) { state in
            syncManager.authStateChanged(state)
        }
        .onReceive(profileViewModel.$activeProfile) { profile in
            syncManager.activeProfileChanged(profile)
        }
    }

    /// Whether Details or Player is currently covering the tab view.
    private var isOverlayPresented: Bool {
        switch activeScreen {
        case .details, .player: return true
        default: return false
        }
    }

    /// Dismisses the current overlay to the same destination its own back action
    /// would (Player returns to Details for series/trailers, otherwise Home).
    /// Used only by the root Menu-button safety net; changing `activeScreen`
    /// tears the overlay down, so Player's `onDisappear` cleanup still runs.
    private func dismissOverlay() {
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
        default:
            break
        }
    }

    /// Routes a chosen stream either to an installed external player (per the
    /// External Player setting) or the built-in mpv player. Trailers always use
    /// the built-in player since they are YouTube-resolved. If the external app
    /// isn't installed / declines to open, playback falls back to the built-in
    /// player so the user is never left on a dead end.
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
                .opacity(isOverlayPresented ? 0 : 1)

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
        }
    }

    private var mainTabView: some View {
        TVMainTabView(
            selectedTab: $selectedTab,
            activeProfile: profileViewModel.activeProfile,
            searchViewModel: searchViewModel,
            libraryViewModel: libraryViewModel,
            homeStore: homeStore,
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
            onNavigateToDetails: { contentId, contentType in
                withAnimation(.easeInOut(duration: 0.28)) {
                    activeScreen = .details(id: contentId, type: contentType)
                }
            },
            onResumePlayback: { item in
                let streamUrl = item.streamUrl.trimmingCharacters(in: .whitespacesAndNewlines)
                if !streamUrl.isEmpty, let url = URL(string: streamUrl) {
                    presentPlayback(
                        url: url,
                        meta: item.meta,
                        subtitle: "",
                        externalSubtitles: [],
                        resumeFrom: item.resumePosition
                    )
                } else {
                    withAnimation(.easeInOut(duration: 0.28)) {
                        activeScreen = .details(id: item.meta.id, type: item.meta.type)
                    }
                }
            }
        )
    }

    private func detailsScreen(contentId: String, contentType: String) -> some View {
        DetailsScreen(
            id: contentId,
            type: contentType,
            repository: CinemetaCatalogRepository(),
            onPlayClick: { streamUrlString, meta, subtitle, externalSubtitles in
                if let url = URL(string: streamUrlString) {
                    let isTrailer = subtitle == PlaybackMarkers.trailerSubtitle
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

    @ViewBuilder
    private func playerScreen(
        url: URL,
        meta: NuvioMeta,
        subtitle: String,
        externalSubtitles: [NuvioSubtitle],
        resumeFrom: Double?
    ) -> some View {
        let isTrailer = subtitle == PlaybackMarkers.trailerSubtitle
        PlayerView(
            url: url,
            meta: meta,
            subtitle: subtitle,
            externalSubtitles: externalSubtitles,
            resumeFrom: resumeFrom,
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

private struct TVMainTabView: View {
    @Binding var selectedTab: TVTab
    let activeProfile: Profile?
    @ObservedObject var searchViewModel: SearchViewModel
    @ObservedObject var libraryViewModel: LibraryViewModel
    @ObservedObject var homeStore: TVHomeStore
    let onSwitchProfile: () -> Void
    let onNavigateToDetails: (String, String) -> Void
    let onResumePlayback: (ContinueWatchingItem) -> Void
    @AppStorage(SettingsKey.amoled) private var amoled = false
    @AppStorage(SettingsKey.bodyColor) private var bodyColor = SettingsBackground.charcoal.rawValue
    @AppStorage(SettingsKey.discoverLocation) private var discoverLocation = "Search"
    @AppStorage(SettingsKey.profileName) private var settingsProfileName = "Nuvio User"

    /// Name shown on the fallback profile tab (tvOS < 27), mirroring the
    /// sidebar header's display-name logic.
    private var profileTabTitle: String {
        let trimmed = settingsProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? (activeProfile?.name ?? "Nuvio User") : trimmed
    }

    var body: some View {
        // `tabViewSidebarHeader` is tvOS 27-only on tvOS, so the styled
        // avatar+name header only renders there. No public device ships tvOS 27
        // yet (as of mid-2026), so on every shipping device we fall back to the
        // profile tab below, whose label carries the profile name + avatar icon.
        if #available(tvOS 27.0, *) {
            tabs
                .tabViewStyle(.sidebarAdaptable)
                .tabViewSidebarHeader {
                    TVSidebarProfileHeader(profile: activeProfile, action: onSwitchProfile)
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
            // shows who's signed in instead of a generic "Profile" entry.
            if #unavailable(tvOS 27.0) {
                TVProfileTabView(profile: activeProfile, onSwitchProfile: onSwitchProfile)
                    .tabItem {
                        Label(profileTabTitle, systemImage: "person.crop.circle.fill")
                    }
                    .tag(TVTab.profile)
            }

            TVHomeView(
                store: homeStore,
                repository: CinemetaCatalogRepository(),
                onNavigateToDetails: onNavigateToDetails,
                onResumePlayback: onResumePlayback
            )
                .tabItem {
                    Label(TVTab.home.rawValue, systemImage: TVTab.home.symbol)
                }
                .tag(TVTab.home)

            SearchView(
                viewModel: searchViewModel,
                showDiscover: discoverLocation == "Search",
                onContentClick: onNavigateToDetails
            )
                .tabItem {
                    Label(TVTab.search.rawValue, systemImage: TVTab.search.symbol)
                }
                .tag(TVTab.search)

            LibraryView(viewModel: libraryViewModel, onContentClick: onNavigateToDetails)
                .tabItem {
                    Label(TVTab.library.rawValue, systemImage: TVTab.library.symbol)
                }
                .tag(TVTab.library)

            SettingsView()
                .tabItem {
                    Label(TVTab.settings.rawValue, systemImage: TVTab.settings.symbol)
                }
                .tag(TVTab.settings)
        }
        .background(Color.nuvioBackground(amoled: amoled, body: bodyColor).ignoresSafeArea())
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
        let trimmed = settingsProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? (profile?.name ?? "Nuvio User") : trimmed
    }
}

private struct TVSidebarAvatar: View {
    let profile: Profile?
    let isFocused: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(red: 1.0, green: 0.82, blue: 0.92))

            Text(initial)
                .font(.system(size: 20, weight: .heavy))
                .foregroundColor(Color(red: 0.18, green: 0.12, blue: 0.18))
        }
        .frame(width: 44, height: 44)
        .overlay(
            Circle()
                .stroke(Color.white.opacity(0.82), lineWidth: 2)
        )
        .scaleEffect(isFocused ? 1.12 : 1)
        .offset(y: isFocused ? -3 : 0)
        .shadow(color: .black.opacity(isFocused ? 0.32 : 0), radius: 12, x: 0, y: 8)
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: isFocused)
    }

    private var initial: String {
        guard let first = profile?.name.trimmingCharacters(in: .whitespacesAndNewlines).first else {
            return "N"
        }

        return String(first).uppercased()
    }
}

/// Profile screen surfaced as a tab on tvOS versions without the sidebar header
/// API (< 27), so the active profile stays visible and switchable on device.
private struct TVProfileTabView: View {
    let profile: Profile?
    let onSwitchProfile: () -> Void

    @AppStorage(SettingsKey.profileName) private var settingsProfileName = "Nuvio User"
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 30) {
            TVSidebarAvatar(profile: profile, isFocused: isFocused)
                .scaleEffect(2.4)
                .frame(height: 120)

            VStack(spacing: 8) {
                Text(displayName)
                    .font(.system(size: 40, weight: .bold))
                    .foregroundColor(.white)

                Text("Manage who's watching")
                    .font(.system(size: 22))
                    .foregroundColor(.white.opacity(0.6))
            }

            Button(action: onSwitchProfile) {
                Text("Change Profile")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 44)
                    .padding(.vertical, 18)
                    .background(
                        Capsule().fill(isFocused ? Color.white.opacity(0.22) : Color.white.opacity(0.10))
                    )
                    .overlay(
                        Capsule().strokeBorder(isFocused ? Color.white : Color.white.opacity(0.25), lineWidth: isFocused ? 3 : 1)
                    )
            }
            .buttonStyle(.plain)
            .focused($isFocused)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var displayName: String {
        let trimmed = settingsProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? (profile?.name ?? "Nuvio User") : trimmed
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

/// Collects each home row's top Y (in the rows' own coordinate space) so the
/// manual vertical offset can glide the focused row flush under the hero.
private struct HomeRowTopsKey: PreferenceKey {
    static var defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

struct TVHomeView: View {
    @ObservedObject var store: TVHomeStore
    let repository: CatalogRepository
    let onNavigateToDetails: (String, String) -> Void
    let onResumePlayback: (ContinueWatchingItem) -> Void

    @AppStorage(SettingsKey.amoled) private var amoled = false
    @AppStorage(SettingsKey.bodyColor) private var bodyColor = SettingsBackground.charcoal.rawValue
    @AppStorage(SettingsKey.heroEnabled) private var heroEnabled = true
    @AppStorage(SettingsKey.trailersEnabled) private var trailersEnabled = true
    @AppStorage(SettingsKey.trailerDelay) private var trailerDelay = 7
    @AppStorage(SettingsKey.fastNavigation) private var fastNavigation = false
    @AppStorage(SettingsKey.hideUnreleased) private var hideUnreleased = false
    @AppStorage(SettingsKey.smoothFocus) private var smoothFocus = true

    @State private var isLoading = true
    @State private var focusedMeta: NuvioMeta?
    @State private var pendingFocusedMeta: NuvioMeta?
    @State private var focusSettleTask: Task<Void, Never>?
    @State private var landscapeFocusedId: String?
    @State private var pendingLandscapeFocusedId: String?
    @State private var landscapeFocusTask: Task<Void, Never>?
    @State private var continueWatching: [ContinueWatchingItem] = []
    @State private var errorMessage: String?
    @State private var didRequestInitialCardFocus = false
    @State private var shouldRestoreHomeFocus = false
    @State private var focusedRowIndex = 0
    @State private var rowTops: [Int: CGFloat] = [:]
    @State private var verticalOffset: CGFloat = 0
    @FocusState private var isLoadingFocusActive: Bool
    @FocusState private var focusedCardID: String?

    var body: some View {
        ZStack(alignment: .topLeading) {
            // 1. Bottom Layer: Full Screen Crossfading Backdrop
            CrossfadingBackdrop(
                url: (visibleFocusedMeta?.backgroundUrl ?? visibleFocusedMeta?.posterUrl) ?? (visibleHero?.backgroundUrl ?? visibleHero?.posterUrl),
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
                } else if let errorMessage {
                    TVErrorView(message: errorMessage)
                } else {
                    // Header Hero Meta block (Static, outside ScrollView)
                    if heroEnabled, let heroMeta = visibleFocusedMeta ?? visibleHero {
                        TVHeroView(meta: heroMeta) {
                            onNavigateToDetails(heroMeta.id, heroMeta.type)
                        }
                    }
                    
                    // Only the rows scroll -- driven by a manual spring offset
                    // (the vertical analog of the horizontal card strip) so the
                    // focused row glides flush under the hero with the SAME feel
                    // and speed as horizontal paging. A GeometryReader imposes a
                    // definite window so the tall row stack is clipped rather than
                    // overflowing; the hero stays pinned (it's a sibling above) and
                    // the focus engine is untouched -- tvOS can focus an off-screen
                    // row and we simply follow it, exactly like the card strip.
                    GeometryReader { proxy in
                        VStack(spacing: 28) {
                            ForEach(Array(visibleSections.enumerated()), id: \.element.id) { index, section in
                                if !section.items.isEmpty {
                                    TVCatalogRow(
                                        id: section.id,
                                        title: section.title,
                                        items: section.items,
                                        progressByItemId: section.id == TVHomeSection.continueWatchingId ? continueWatchingByMetaId : [:],
                                        initialFocusCardKey: initialFocusCardKey,
                                        landscapeFocusedId: landscapeFocusedId,
                                        externalFocus: $focusedCardID,
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
                                            settleFocus(on: meta)
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
                                        }
                                    )
                                    .background(
                                        GeometryReader { rowGeo in
                                            Color.clear.preference(
                                                key: HomeRowTopsKey.self,
                                                value: [index: rowGeo.frame(in: .named("homeRows")).minY.rounded()]
                                            )
                                        }
                                    )
                                }
                            }
                        }
                        .padding(.top, 20)
                        .frame(width: proxy.size.width, alignment: .topLeading)
                        .coordinateSpace(name: "homeRows")
                        .offset(y: verticalOffset)
                        .animation(smoothFocus ? .spring(response: 0.4, dampingFraction: 0.95) : nil, value: verticalOffset)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .clipShape(VerticalEdgeClip())
                    .onPreferenceChange(HomeRowTopsKey.self) { newTops in
                        rowTops = newTops
                        // Keep the focused row anchored if measurements settle or
                        // sections load in -- recompute from the fresh values.
                        if let focusedTop = newTops[focusedRowIndex] {
                            let firstTop = newTops.values.min() ?? focusedTop
                            let target = -(focusedTop - firstTop)
                            if target != verticalOffset { verticalOffset = target }
                        }
                    }
                    // Treat the rows as a focus section so focus can jump in/out
                    // cleanly. The default focus is only armed after Home loses
                    // focus, so the first Menu press can still reach the sidebar,
                    // while returning from the sidebar restores the saved card.
                    .focusSection()
                    .defaultFocusIfAvailable($focusedCardID, shouldRestoreHomeFocus ? store.lastFocusedCardID : nil)
                }
            }
            .ignoresSafeArea(.container, edges: .top)
        }
        .task {
            await load()
        }
        .onAppear {
            refreshContinueWatching()
        }
        // Home stays mounted behind Details/Player, so `onAppear` no longer
        // fires on return. Refresh the Continue Watching row whenever the store
        // changes (progress saved during playback, item finished/removed).
        .onReceive(NotificationCenter.default.publisher(for: ContinueWatchingStore.changedNotification)) { _ in
            refreshContinueWatching()
        }
        .onDisappear {
            focusSettleTask?.cancel()
            landscapeFocusTask?.cancel()
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
            } else if store.lastFocusedCardID != nil {
                shouldRestoreHomeFocus = true
            }
        }
    }

    /// The loading spinner should only replace the catalog on a genuine first
    /// load. When returning from a card the sections are already cached in the
    /// store, so we render them straight away instead of flashing the spinner.
    private var showsLoading: Bool {
        isLoading && store.sections.isEmpty
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

    /// Vertical translation that lands the row at `index` where the first row
    /// sits (flush under the hero) -- the vertical analog of the card strip
    /// pinning the focused card under the row title. Returns the current offset
    /// when that row hasn't been measured yet, so we never jump to 0 mid-scroll.
    private func offsetForRow(_ index: Int) -> CGFloat {
        guard let focusedTop = rowTops[index] else { return verticalOffset }
        let firstTop = rowTops.values.min() ?? focusedTop
        return -(focusedTop - firstTop)
    }

    private var visibleSections: [TVHomeSection] {
        let resumeSection = TVHomeSection(
            id: TVHomeSection.continueWatchingId,
            title: "Continue Watching",
            items: continueWatching.map(\.meta)
        )
        let allSections = continueWatching.isEmpty ? store.sections : [resumeSection] + store.sections

        return allSections.map { section in
            TVHomeSection(id: section.id, title: section.title, items: section.items.filter(isVisible))
        }
    }

    private var continueWatchingByMetaId: [String: ContinueWatchingItem] {
        Dictionary(uniqueKeysWithValues: continueWatching.map { ($0.meta.id, $0) })
    }

    private var visibleHero: NuvioMeta? {
        guard let hero = store.hero, isVisible(hero) else { return visibleSections.first?.items.first }
        return hero
    }

    private var visibleFocusedMeta: NuvioMeta? {
        guard let focusedMeta, isVisible(focusedMeta) else { return nil }
        return focusedMeta
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
        // Returning from a card: the catalog is still cached in the store, so
        // skip the network round-trip. The saved card re-focuses itself via
        // `initialFocusCardKey`, which restores the row/scroll position too.
        if store.hasLoaded {
            isLoading = false
            refreshContinueWatching()
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            let catalogs = try await repository.getHomeCatalogs()
            var loadedSections: [TVHomeSection] = []

            for catalog in catalogs {
                var items: [NuvioMeta] = []
                for id in catalog.itemIds.prefix(18) {
                    if let meta = try? await repository.getMetadata(id: id, type: catalog.contentType ?? "movie") {
                        items.append(meta)
                    }
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

            store.sections = loadedSections
            store.hero = loadedSections.first?.items.first
            store.lastFocusedCardID = nil
            store.hasLoaded = true
            refreshContinueWatching()
            focusedMeta = loadedSections.first?.items.first
            pendingFocusedMeta = focusedMeta
            landscapeFocusedId = nil
            pendingLandscapeFocusedId = nil
            didRequestInitialCardFocus = false
            shouldRestoreHomeFocus = false
            isLoading = false
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    private func settleFocus(on meta: NuvioMeta) {
        pendingFocusedMeta = meta
        focusSettleTask?.cancel()

        let targetId = meta.id
        focusSettleTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: fastNavigation ? 60_000_000 : 140_000_000)
            guard !Task.isCancelled,
                  pendingFocusedMeta?.id == targetId,
                  focusedMeta?.id != targetId,
                  let settledMeta = pendingFocusedMeta else {
                return
            }

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
            pendingLandscapeFocusedId = nil
            landscapeFocusedId = nil
            landscapeFocusTask?.cancel()
            return
        }

        pendingLandscapeFocusedId = cardKey
        landscapeFocusedId = nil
        landscapeFocusTask?.cancel()

        let targetKey = cardKey
        let delaySeconds = max(1, trailerDelay)
        landscapeFocusTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds) * 1_000_000_000)
            guard !Task.isCancelled,
                  pendingLandscapeFocusedId == targetKey else {
                return
            }

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

    private func refreshContinueWatching() {
        continueWatching = ContinueWatchingStore.items().filter { isVisible($0.meta) }
    }
}

struct TVHomeSection: Identifiable {
    static let continueWatchingId = "continue_watching"

    let id: String
    let title: String
    var items: [NuvioMeta]
    var contentType: String? = nil
    var catalogId: String? = nil
    var nextSkip: Int? = nil
    var hasMore: Bool = false
    var isLoadingMore: Bool = false
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

            TVHeroMetaLine(meta: meta)

            if let description = meta.description {
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
    /// Composite key ("<sectionId>\u{1}<metaId>") of the card that should take
    /// focus on appear — the first card on a fresh load, or the card the user
    /// left on when returning from details.
    let initialFocusCardKey: String?
    let landscapeFocusedId: String?
    var externalFocus: FocusState<String?>.Binding? = nil
    let onInitialFocusRequested: () -> Void
    let onFocus: (NuvioMeta) -> Void
    let onBlur: (NuvioMeta) -> Void
    let onApproachEnd: (NuvioMeta) -> Void
    let onSelect: (NuvioMeta) -> Void

    // Index of the card whose leading edge is pinned under the title. Driven by
    // focus and intentionally NOT reset on blur, so the row keeps its position
    // when focus moves to another row and comes back (tvOS focus memory).
    @State private var scrollIndex: Int = 0
    @AppStorage(SettingsKey.homeLayout) private var homeLayout = "Modern"
    @AppStorage(SettingsKey.posterLabels) private var posterLabels = false
    @AppStorage(SettingsKey.smoothFocus) private var smoothFocus = true

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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.custom("Inter-Bold", size: 30))
                .foregroundColor(.white)
                .padding(.leading, TVLayout.rowLeading)

            cardStrip
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

            HStack(alignment: .bottom, spacing: rowSpacing) {
                ForEach(items) { item in
                    let cardKey = "\(id)\u{1}\(item.id)"
                    let shouldRequestInitialFocus = cardKey == initialFocusCardKey
                    let progressItem = progressByItemId[item.id]
                    PosterCard(
                        meta: item,
                        isLandscape: homeLayout == "Modern" && landscapeFocusedId == cardKey,
                        continueProgress: progressItem?.progress,
                        continueRemainingText: progressItem?.remainingText,
                        shouldRequestInitialFocus: shouldRequestInitialFocus,
                        onInitialFocusRequested: shouldRequestInitialFocus ? onInitialFocusRequested : nil,
                        onFocus: { focused in
                            if let index = items.firstIndex(where: { $0.id == focused.id }) {
                                scrollIndex = index
                            }
                            onApproachEnd(focused)
                            onFocus(focused)
                        },
                        onBlur: { blurred in
                            onBlur(blurred)
                        },
                        externalFocus: externalFocus,
                        externalFocusValue: cardKey
                    ) {
                        onSelect(item)
                    }
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
            .offset(x: edgeInset + TVLayout.rowLeading - CGFloat(scrollIndex) * step)
            .frame(width: stripWidth, height: stripHeight, alignment: .leading)
            .clipped()
            .offset(x: -edgeInset)
            .animation(smoothFocus ? .spring(response: 0.4, dampingFraction: 0.95) : nil, value: scrollIndex)
            .animation(smoothFocus ? .spring(response: 0.18, dampingFraction: 0.86) : nil, value: landscapeFocusedId)
        }
        .frame(height: stripHeight)
    }
}

private struct TVHeroMetaLine: View {
    let meta: NuvioMeta
    @AppStorage(SettingsKey.showFullDates) private var showFullDates = true

    var body: some View {
        let values = [
            meta.type.capitalized,
            meta.genres?.first,
            formattedRuntime,
            releaseDate,
            meta.rating.map { String(format: "%.1f IMDb", $0) }
        ].compactMap { $0 }.filter { !$0.isEmpty }

        Text(values.joined(separator: "  •  "))
            .font(.custom("Inter-SemiBold", size: 22))
            .foregroundColor(.white.opacity(0.66))
            .lineLimit(1)
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
