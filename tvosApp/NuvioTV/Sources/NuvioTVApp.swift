//
//  NuvioTVApp.swift
//  NuvioTV
//
//  Main SwiftUI app entry point with Master view coordinator
//

import SwiftUI
import Combine
import Foundation
import UIKit
import ImageIO
import OSLog
#if canImport(AetherEngine)
import AetherEngine
#endif

@main
struct NuvioTVApp: App {
    init() {
        let totalRam = ProcessInfo.processInfo.physicalMemory
        let isLegacyDevice = totalRam <= 2_500_000_000 // <= 2.5 GB (Apple TV HD)
        let memCapacity = isLegacyDevice ? (12 * 1024 * 1024) : (32 * 1024 * 1024)
        let diskCapacity = isLegacyDevice ? (60 * 1024 * 1024) : (150 * 1024 * 1024)
        URLCache.shared.memoryCapacity = memCapacity
        URLCache.shared.diskCapacity = diskCapacity
        let payloadMigrationKey = "nuvio.tv.migrations.largePayloadPreferences.v1"
        if !UserDefaults.standard.bool(forKey: payloadMigrationKey),
           HomeCatalogPayloadStore.migrateAllKnownPreferences() {
            LargePayloadStore.purgeAllKnownPreferences()
            UserDefaults.standard.set(true, forKey: SettingsKey.smoothFocus)
            UserDefaults.standard.set(true, forKey: payloadMigrationKey)
        }

        #if canImport(AetherEngine)
        // Schedule AetherEngine prewarming on its required main actor before
        // player appearance.
        Task(priority: .utility) { @MainActor in
            _ = try? AetherEngine()
        }
        #endif
    }

    /// Injected here rather than in ContentView's long modifier chain.
    @StateObject private var atvloadlyService = AtvloadlyService()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(atvloadlyService)
        }
    }
}

/// Temporary Home performance tracing. Enabled by default in DEBUG so console
/// output shows main-thread stalls, or via `-TVHomeDebugTrace` argument.
enum TVHomeDebugTrace {
    static var enabled = false
    private static let logger = Logger(
        subsystem: "com.pyksel.nuviotvos",
        category: "TVTrace"
    )

    struct Breadcrumb: Sendable {
        let timestamp: UInt64
        let message: String
        let isMainThread: Bool
    }

    private static var breadcrumbLock = os_unfair_lock_s()
    private static var breadcrumbs: [Breadcrumb] = []
    private static let maxBreadcrumbs = 40

    static func now() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    static func elapsedMilliseconds(since start: UInt64) -> String {
        String(format: "%.1f", Double(now() - start) / 1_000_000)
    }

    static func breadcrumb(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        let text = message()
        let isMain = Thread.isMainThread
        let item = Breadcrumb(timestamp: now(), message: text, isMainThread: isMain)
        os_unfair_lock_lock(&breadcrumbLock)
        breadcrumbs.append(item)
        if breadcrumbs.count > maxBreadcrumbs {
            breadcrumbs.removeFirst(breadcrumbs.count - maxBreadcrumbs)
        }
        os_unfair_lock_unlock(&breadcrumbLock)
    }

    static func recentBreadcrumbs(count: Int = 15) -> [String] {
        os_unfair_lock_lock(&breadcrumbLock)
        let copy = breadcrumbs
        os_unfair_lock_unlock(&breadcrumbLock)
        let current = now()
        return copy.suffix(count).map { b in
            let ageMs = String(format: "%.1f", Double(current - b.timestamp) / 1_000_000)
            let thread = b.isMainThread ? "Main" : "BG"
            return "[\(ageMs)ms ago][\(thread)] \(b.message)"
        }
    }

    static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        let text = message()
        breadcrumb(text)
        print("[TVTrace] \(text)")
        logger.notice("\(text, privacy: .public)")
    }

    @discardableResult
    static func measure<T>(_ label: @autoclosure () -> String, thresholdMs: Double = 15.0, block: () throws -> T) rethrows -> T {
        guard enabled else { return try block() }
        let text = label()
        breadcrumb("\(text) begin")
        let start = now()
        defer {
            let elapsedMs = Double(now() - start) / 1_000_000
            breadcrumb("\(text) end (\(String(format: "%.1f", elapsedMs))ms)")
            if elapsedMs >= thresholdMs {
                log("⚠️ [SLOW_OP] \(text) took \(String(format: "%.1f", elapsedMs))ms (threshold \(thresholdMs)ms)")
            }
        }
        return try block()
    }

    @discardableResult
    static func measureAsync<T>(_ label: @autoclosure () -> String, thresholdMs: Double = 20.0, block: () async throws -> T) async rethrows -> T {
        guard enabled else { return try await block() }
        let text = label()
        breadcrumb("\(text) begin")
        let start = now()
        defer {
            let elapsedMs = Double(now() - start) / 1_000_000
            breadcrumb("\(text) end (\(String(format: "%.1f", elapsedMs))ms)")
            if elapsedMs >= thresholdMs {
                log("⚠️ [SLOW_OP_ASYNC] \(text) took \(String(format: "%.1f", elapsedMs))ms")
            }
        }
        return try await block()
    }

    // MARK: - Main Thread Stall Watchdog
    private static var isWatchdogRunning = false
    private static let watchdogQueue = DispatchQueue(label: "com.nuvio.stallWatchdog", qos: .userInteractive)
    private static var watchdogTimer: DispatchSourceTimer?
    private static var pingDispatchedTime: UInt64 = 0
    private static var isPingInFlight = false
    private static var isStallActive = false
    private static var stallStartTime: UInt64 = 0
    private static var heartbeatTicks: UInt64 = 0

    static func startWatchdogIfNeeded() {
        guard enabled else { return }
        watchdogQueue.sync {
            guard !isWatchdogRunning else { return }
            isWatchdogRunning = true

            #if canImport(UIKit)
            NotificationCenter.default.addObserver(
                forName: UIApplication.didReceiveMemoryWarningNotification,
                object: nil,
                queue: nil
            ) { _ in
                let report = TVMemoryDiagnostic.detailedReport(label: "SYSTEM_MEMORY_WARNING")
                print("[TVTrace] ⚠️🚨 \(report)")
                logger.fault("⚠️🚨 [SYSTEM_MEMORY_WARNING] Low memory warning received from OS!\n\(report, privacy: .public)")
            }
            #endif

            let timer = DispatchSource.makeTimerSource(queue: watchdogQueue)
            timer.schedule(deadline: .now() + .milliseconds(500), repeating: .milliseconds(25))
            timer.setEventHandler {
                let current = now()
                heartbeatTicks &+= 1

                // Every ~5 seconds (200 * 25ms = 5000ms), log periodic RAM heartbeat breadcrumb
                if heartbeatTicks % 200 == 0 {
                    let pulse = TVMemoryDiagnostic.summaryPulse()
                    breadcrumb("[RAM] \(pulse)")
                }

                if isPingInFlight {
                    let elapsedMs = Double(current - pingDispatchedTime) / 1_000_000
                    if elapsedMs >= 250.0 {
                        if !isStallActive {
                            isStallActive = true
                            stallStartTime = pingDispatchedTime
                            let memReport = TVMemoryDiagnostic.detailedReport(label: "MAIN_THREAD_STALL_START")
                            let crumbs = recentBreadcrumbs(count: 12)
                            var lines = [
                                "🚨🚨🚨 [MAIN_THREAD_STALL_START] Main thread frozen for \(String(format: "%.1f", elapsedMs))ms!",
                                memReport,
                                "🚨 Recent breadcrumbs leading up to freeze:"
                            ]
                            for (idx, crumb) in crumbs.enumerated() {
                                lines.append("  (\(idx + 1)) \(crumb)")
                            }
                            let fullText = lines.map { "[TVTrace] \($0)" }.joined(separator: "\n")
                            print(fullText)
                            logger.fault("🚨 [MAIN_THREAD_STALL_START] Main thread frozen for \(String(format: "%.1f", elapsedMs))ms!\n\(memReport, privacy: .public)")
                        }
                    }
                } else {
                    isPingInFlight = true
                    pingDispatchedTime = current
                    DispatchQueue.main.async {
                        let mainNow = now()
                        watchdogQueue.async {
                            if isStallActive {
                                let totalStallMs = Double(mainNow - stallStartTime) / 1_000_000
                                let memPulse = TVMemoryDiagnostic.summaryPulse()
                                let message = "✅ [MAIN_THREAD_STALL_RESOLVED] Main thread UNBLOCKED after \(String(format: "%.1f", totalStallMs))ms total freeze! [\(memPulse)]"
                                print("[TVTrace] \(message)")
                                logger.notice("\(message, privacy: .public)")
                                isStallActive = false
                            }
                            isPingInFlight = false
                        }
                    }
                }
            }
            watchdogTimer = timer
            timer.resume()
            print("[TVTrace] Main thread watchdog started (interval: 25ms, threshold: 250ms)")
            logger.notice("Main thread watchdog started (interval: 25ms, threshold: 250ms)")
        }
    }
}

enum TVScreen: Equatable, CustomStringConvertible {
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

    var description: String {
        switch self {
        case .login: return "login"
        case .profileSelection: return "profileSelection"
        case .main: return "main"
        case let .details(id, type): return "details(\(id), \(type))"
        case let .player(_, meta, _, _, _, _): return "player(\(meta.id), \(meta.name))"
        case .cloudLibrary: return "cloudLibrary"
        case let .collectionFolder(folder, title): return "collectionFolder(\(folder.id), \(title))"
        case let .productionBrowse(company): return "productionBrowse(\(company.name))"
        case let .personBrowse(person): return "personBrowse(\(person.name))"
        }
    }

    var isPlayer: Bool {
        if case .player = self { return true }
        return false
    }
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

enum TVTab: Hashable, Identifiable, CaseIterable {
    case profile, home, party, search, library, calendar, settings
    case collection(CollectionHomeID)

    static var allCases: [Self] {
        var tabs: [Self] = [.profile, .home]
        if WatchPartyConfiguration.isEnabled { tabs.append(.party) }
        tabs += [.search, .library]
        if isCalendarEnabled { tabs.append(.calendar) }
        tabs.append(.settings)
        return tabs
    }

    /// Settings → Appearance → Sidebar → Calendar (on unless turned off).
    static var isCalendarEnabled: Bool {
        ProfileSettings.current.object(forKey: SettingsKey.showCalendarTab) as? Bool ?? true
    }
    var id: String { rawValue }
    var rawValue: String {
        switch self {
        case .profile: return "Profile"
        case .home: return "Home"
        case .search: return "Search"
        case .library: return "Library"
        case .calendar: return "Calendar"
        case .settings: return "Settings"
        case .party: return "Watch Party"
        case .collection(let id): return "Collection:\(id.key)"
        }
    }
    var title: String {
        switch self {
        case .profile: return L10n.string("settings_profiles", fallback: "Profile")
        case .home: return L10n.string("nav_home", fallback: "Home")
        case .search: return L10n.string("nav_search", fallback: "Search")
        case .library: return L10n.string("nav_library", fallback: "Library")
        case .calendar: return L10n.string("nav_calendar", fallback: "Calendar")
        case .settings: return L10n.string("nav_settings", fallback: "Settings")
        case .party: return "Watch Party"
        case .collection: return L10n.string("tmdb_collections_title", fallback: "Collections")
        }
    }
    var symbol: String {
        switch self {
        case .profile: return "person.crop.circle"
        case .home: return "house"
        case .search: return "magnifyingglass"
        case .library: return "rectangle.stack"
        case .calendar: return "calendar"
        case .settings: return "gearshape"
        case .party: return "person.2.fill"
        case .collection: return "rectangle.stack.fill"
        }
    }
}

/// Main content view - entry point for the app with screen routing
struct DetailsNavigationEntry {
    let id: String
    let type: String
    let libraryWatchedContext: LibraryWatchedContext?
}

@MainActor
struct DetailsNavigationContextTransition {
    let backStackEntry: DetailsNavigationEntry
    let activeLibraryWatchedContext: LibraryWatchedContext?

    static func pushingCurrentDetails(
        id: String,
        type: String,
        libraryWatchedContext: LibraryWatchedContext?
    ) -> DetailsNavigationContextTransition {
        DetailsNavigationContextTransition(
            backStackEntry: DetailsNavigationEntry(
                id: id,
                type: type,
                libraryWatchedContext: libraryWatchedContext
            ),
            activeLibraryWatchedContext: nil
        )
    }

    static func openingRelatedTitle(
        from entry: DetailsNavigationEntry
    ) -> DetailsNavigationContextTransition {
        DetailsNavigationContextTransition(
            backStackEntry: entry,
            activeLibraryWatchedContext: nil
        )
    }

    static func restoring(_ entry: DetailsNavigationEntry) -> LibraryWatchedContext? {
        entry.libraryWatchedContext
    }

    static func playbackContext(
        origin: PlaybackOrigin,
        currentLibraryWatchedContext: LibraryWatchedContext?
    ) -> LibraryWatchedContext? {
        switch origin {
        case .details: return currentLibraryWatchedContext
        case .main, .cloudLibrary: return nil
        }
    }
}

struct ContentView: View {
    private struct PartyDetailsDestination {
        let screen: TVScreen
        let tab: TVTab
        let backStack: [DetailsNavigationEntry]
        let returnDestination: DetailsReturnDestination
        let collectionContext: CollectionPlaybackContext?
        let libraryWatchedContext: LibraryWatchedContext?
    }

    private struct PartyDetailsOrigin {
        let context: WatchPartyPlaybackContext
        let media: WatchPartyMedia
        let destination: PartyDetailsDestination
    }

    @Environment(\.scenePhase) private var scenePhase
    @State private var activeScreen: TVScreen = .login
    @State private var playbackPartyID: UUID?
    @State private var playerSurfaceID = UUID()
    @State private var creatingParty = false
    @State private var choosingPartySource = false
    @State private var partyLaunchTask: Task<Void, Never>?
    @State private var partyLaunchID = UUID()
    @State private var partyDetailsOrigin: PartyDetailsOrigin?
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
    @State private var profileGateLiftTask: Task<Void, Never>?
    @State private var profileGateStartedAt: Date?
    @State private var profileGateGeneration: UInt = 0
    @State private var profileGateReadinessIdentity: TVHomeContentIdentity?
    @State private var profileGateReadiness: TVProfileGateReadiness = .waiting(hasFocusableContent: false, targetSignature: nil)
    /// Every switch shows the cover for at least this long, even when the new
    /// profile's rows are already cached and come back instantly. A cover that
    /// appears only sometimes reads as a stutter; a switch that always takes the
    /// same short beat reads as the app doing something deliberate — which is
    /// how the Android client behaves, and why its switches feel settled.
    private static let profileGateMinimumDuration: TimeInterval = 1.2
    /// Watchdog for maximum profile loading time (capped at 3.0 seconds).
    private static let profileGateTimeout: TimeInterval = 3.0
    @State private var selectedTab: TVTab = .home
    /// Series context for the current playback, captured at play time so the
    /// player can offer/auto-play the next episode. Empty for movies/trailers.
    @State private var playbackEpisodes: [NuvioVideo] = []
    @State private var partySourceNavigationRevision: UInt = 0
    @State private var playbackCurrentEpisode: NuvioVideo?
    @State private var playbackIsActionPlaybackSession = false
    @State private var playbackOrigin: PlaybackOrigin = .main
    @State private var playbackLibraryWatchedContext: LibraryWatchedContext?
    @State private var playbackFilename: String?
    @State private var playbackSourceID: String?
    @State private var playbackVideoSize: Int64?
    @State private var playbackVideoHash: String?
    @State private var playbackCacheFileIdentity: PlaybackCacheFileIdentity?
    @State private var playbackStartupBenchmarkToken: UUID?
    @State private var continueWatchingStartupBenchmarkToken: UUID?
    @State private var playbackDidStart = false
    @State private var playbackCollectionContext: CollectionPlaybackContext?
    @State private var detailsCollectionContext: CollectionPlaybackContext?
    @State private var detailsLibraryWatchedContext: LibraryWatchedContext?
    @State private var reopenStreamPickerOnDetails = false
    @State private var reopenStreamPickerEpisode: NuvioVideo?
    @State private var reopenStreamPickerResumePosition: Double?
    /// Episode to select when Details opens from the calendar.
    @State private var detailsFocusEpisode: DetailsEpisodeFocus?
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
    @State private var continueWatchingLoadingMessage: String = L10n.string("player_searching_sources", fallback: "Searching sources…")
    @State private var continueWatchingPlaybackTask: Task<Void, Never>?
    @State private var pendingDeepLinkURL: URL?
    /// Details title to restore when leaving a production company browse.
    @State private var productionBrowseReturn: DetailsNavigationEntry?
    /// Details title to restore when leaving a person browse.
    @State private var personBrowseReturn: DetailsNavigationEntry?
    /// Titles to walk back through when Details opened Details ("More like
    /// this"). Empty means the current Details is the root of its chain and back
    /// belongs to its recorded return destination.
    @State private var detailsBackStack: [DetailsNavigationEntry] = []
    @State private var nextDetailsPlaybackRequestID: UInt = 0
    @State private var pendingDetailsPlaybackRequestID: UInt?
    @State private var presentedAppNoticeDetails: AppNotice?
    @State private var appNoticeFocusRequestGeneration: UInt = 0
    /// Where the root Details screen should return. This is normally Home, but
    /// a title opened from a collection must return to that collection.
    @State private var detailsReturnDestination: DetailsReturnDestination = .main
    /// Bumped only after the Details view has actually left the hierarchy.
    /// Home uses this lifecycle signal to request focus at the first moment
    /// tvOS can accept it, instead of guessing with delayed timers.
    @State private var detailsDidDisappearGeneration: UInt = 0
    @StateObject private var authManager = AuthManager()
    @StateObject private var watchPartyOwner = WatchPartyAppOwner()
    @StateObject private var profileViewModel = ProfileViewModel()
    @StateObject private var syncManager = NuvioSyncManager()
    // Both search screens are backed by their own view model. Only the one
    // picked by `SettingsKey.searchStyle` is rendered, but both are held here
    // so switching styles doesn't tear down and refetch the other's state.
    // They share the same recent-search storage key.
    @StateObject private var searchViewModel = SearchViewModel()
    @StateObject private var netflixSearchViewModel = NetflixSearchViewModel()
    @StateObject private var libraryViewModel = LibraryViewModel()
    @StateObject private var releaseUpdateService = ReleaseUpdateService()
    @EnvironmentObject private var atvloadlyService: AtvloadlyService
    @StateObject private var announcementService = AnnouncementService()
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

            // The adaptive tab sidebar is briefly expanded while its first
            // focus pass runs. Keep the full container covered while Home
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
                // Cover Home immediately, even inside the animated profile
                // transition; fade only when its focus handoff is complete.
                .transition(.asymmetric(insertion: .identity, removal: .opacity))
                .zIndex(999)
            }

            if let notice = visibleAppNotice {
                AppNoticeBanner(
                    notice: notice,
                    currentVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0",
                    accentColor: AppFocusOutline.color,
                    focusRequestGeneration: appNoticeFocusRequestGeneration,
                    isDetailsPresented: presentedAppNoticeDetails != nil,
                    onShowDetails: { presentedAppNoticeDetails = notice },
                    onDismiss: { dismissAppNotice(notice) },
                    onSkip: { skipAppNotice(notice) },
                    installAction: atvloadlyInstallAction(for: notice)
                )
                .id(notice.id)
                .padding(.trailing, 52)
                .padding(.bottom, 42)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(10)
            }

            AtvloadlyNoticeCountdownDriver(release: atvloadlyNoticeRelease)
        }
        // Resolve every @AppStorage in the app against the active profile's
        // settings suite, so each profile keeps its own theme, layout, playback
        // preferences, etc. Falls back to the shared store before a profile is picked.
        .defaultAppStorage(ProfileSettings.store(for: profileViewModel.activeProfile?.id))
        .environmentObject(releaseUpdateService)
        .environmentObject(announcementService)
        // Apply selected app language (locale + L10n catalog) and refresh UI on change.
        .appliesAppLocale()
        .onChange(of: profileViewModel.activeProfile?.id) { _, _ in
            AppLocaleManager.shared.reloadFromProfileStore()
        }
        // Backing out of the switch must not leave the cover behind.
        .onChange(of: isOnProfileSelection) { _, isSelecting in
            if isSelecting, isPreparingProfile {
                liftProfileGate()
            }
        }
        .onChange(of: selectedTab) { _, tab in
            partySourceNavigationRevision &+= 1
            if isPreparingProfile, tab != .home {
                liftProfileGate(generation: profileGateGeneration)
            }
        }
        .onChange(of: activeScreen) { oldScreen, newScreen in
            TVHomeDebugTrace.log("app.activeScreen changed from \(oldScreen) to \(newScreen)")
            if oldScreen.isPlayer, !newScreen.isPlayer,
               let transitionID = watchPartyOwner.incomingMediaTransition?.id {
                watchPartyOwner.cancelIncomingMediaTransition(transitionID)
            }
            if oldScreen != newScreen, !newScreen.isPlayer, partyLaunchTask != nil {
                partyLaunchID = UUID(); partyLaunchTask?.cancel(); partyLaunchTask = nil
            }
        }
        .onChange(of: visibleAppNotice?.id) { _, noticeID in
            if noticeID != nil { appNoticeFocusRequestGeneration &+= 1 }
        }
        .overlay {
            if partyLaunchTask != nil {
                VStack(spacing: 24) {
                    ProgressView("Preparing Watch Party…")
                    Button("Cancel") {
                        partyLaunchID = UUID(); partyLaunchTask?.cancel(); partyLaunchTask = nil
                        creatingParty = false; choosingPartySource = false
                        selectedTab = .party; activeScreen = .main
                    }
                }
                .padding(50)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
            }
        }
        .background(Color.black.ignoresSafeArea())
        // Safety net for the Menu button while an overlay is up. During the
        // overlay's insert animation focus is briefly in limbo (the tab view is
        // disabled, the overlay hasn't taken focus yet); a Menu press then finds
        // no `.onExitCommand` handler and tvOS quits the app. This root handler
        // catches those stray presses and dismisses the overlay instead. When
        // focus is settled inside Details/Player their own handler fires first,
        // so this only kicks in for the in-between frames.
        .onExitCommand(perform: visibleAppNotice != nil
            ? dismissVisibleAppNotice
            : (isOverlayPresented ? dismissOverlay : nil))
        .sheet(item: $presentedAppNoticeDetails, onDismiss: {
            appNoticeFocusRequestGeneration &+= 1
        }) {
            AppNoticeDetailsSheet(notice: $0)
        }
        .onChange(of: watchPartyOwner.presentation?.id) { old, new in
            if old == nil, let new, activeScreen.isPlayer, playbackPartyID == nil {
                // InSight adopted the already-playing PlayerViewModel. Keep its view identity stable.
                playbackPartyID = new
            }
            if let old, old == playbackPartyID, new == nil {
                playbackPartyID = nil
                let keepPlayer = watchPartyOwner.consumePreservePlayerAfterRoomExit()
                if activeScreen.isPlayer, !keepPlayer {
                    activeScreen = .main; selectedTab = WatchPartyConfiguration.isEnabled ? .party : .home
                }
            }
        }
        .onChange(of: watchPartyOwner.incomingMediaTransition?.id) { _, transitionID in
            handleIncomingMediaTransitionChange(transitionID)
        }
        .onReceive(authManager.contextWillChange.merge(with: profileViewModel.contextWillChange)) { _ in
            partyDetailsOrigin = nil
            partyLaunchID = UUID()
            partyLaunchTask?.cancel(); partyLaunchTask = nil
            creatingParty = false; choosingPartySource = false
        }
        .onOpenURL(perform: handleDeepLink)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            watchPartyOwner.suspendForInactivity()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            watchPartyOwner.resumeAfterForeground()
        }
        .onAppear {
            Task { await releaseUpdateService.checkIfNeeded() }
            Task { await announcementService.checkIfNeeded() }
            if WatchPartyConfiguration.isEnabled {
                watchPartyOwner.attach(authManager: authManager, profiles: profileViewModel)
            }
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
                let autoSelectLast = (UserDefaults.standard.object(
                    forKey: SettingsKey.profileAutoSelectLast
                ) as? Bool) ?? (ProfileSettings.current.object(
                    forKey: SettingsKey.profileAutoSelectLast
                ) as? Bool) ?? true
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
        .onReceive(authManager.$authState.receive(on: RunLoop.main)) { state in
            syncManager.authStateChanged(state)
            if state == .signedOut, profileViewModel.activeProfile?.id != "guest" {
                profileViewModel.resetForSignedOut()
            }
        }
        .onReceive(syncManager.$isPullingAccountProfiles.receive(on: RunLoop.main)) { pulling in
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
        .onReceive(profileViewModel.$activeProfile.receive(on: RunLoop.main)) { profile in
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
                watchPartyOwner.suspendForInactivity()
                backgroundedAt = Date()
                syncManager.flushPendingPushes()
            case .active:
                if backgroundedAt != nil {
                    releaseUpdateService.beginForegroundSession()
                    announcementService.beginForegroundSession()
                }
                Task { await releaseUpdateService.checkIfNeeded() }
                Task { await announcementService.checkIfNeeded() }
                syncManager.refreshAccountIfIdle()
                presentProfileSelectionAfterBackgroundIfNeeded()
                watchPartyOwner.resumeAfterForeground()
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

        let autoSelectLast = (UserDefaults.standard.object(
            forKey: SettingsKey.profileAutoSelectLast
        ) as? Bool) ?? (ProfileSettings.current.object(
            forKey: SettingsKey.profileAutoSelectLast
        ) as? Bool) ?? true
        let requireSelectionOnEveryReturn = (UserDefaults.standard.object(
            forKey: SettingsKey.profileRequireSelectionAfterBackground
        ) as? Bool) ?? (ProfileSettings.current.object(
            forKey: SettingsKey.profileRequireSelectionAfterBackground
        ) as? Bool) ?? false
        let shouldRequireSelection: Bool
        if requireSelectionOnEveryReturn {
            shouldRequireSelection = true
        } else {
            let hasExceededGracePeriod = Date().timeIntervalSince(backgroundedAt)
                >= Self.profileSelectionBackgroundGracePeriod
            if autoSelectLast && profileViewModel.activeProfile?.isPinProtected == false {
                shouldRequireSelection = false
            } else {
                shouldRequireSelection = hasExceededGracePeriod || !autoSelectLast
            }
        }
        guard shouldRequireSelection else { return }

        // Revoke transient Party work before a privacy gate, even if the selected ID stays equal.
        watchPartyOwner.invalidateContext()

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

    private var selectedAppNotice: AppNotice? {
        AppNotice.select(
            release: releaseUpdateService.latestRelease,
            releaseIsAvailable: releaseUpdateService.shouldShowNotice,
            announcementsEnabled: announcementService.isEnabled,
            activeAnnouncements: announcementService.activeAnnouncements,
            skippedAnnouncementIDs: announcementService.skippedAnnouncementIDs,
            dismissedAnnouncementIDs: announcementService.dismissedAnnouncementIDs
        )
    }

    private var visibleAppNotice: AppNotice? {
        guard resolvedInitialScreen,
              activeScreen == .main,
              !isPreparingProfile,
              !isOverlayPresented,
              partyLaunchTask == nil,
              selectedTab == .home else {
            return nil
        }
        return selectedAppNotice
    }

    private func dismissVisibleAppNotice() {
        guard let visibleAppNotice else { return }
        dismissAppNotice(visibleAppNotice)
    }

    /// The release notice while it is on screen with nothing over it (Home,
    /// nothing playing): the only time an automatic atvloadly install may
    /// count down.
    private var atvloadlyNoticeRelease: ReleaseUpdateMetadata? {
        guard scenePhase == .active, presentedAppNoticeDetails == nil,
              case .release(let release)? = visibleAppNotice else { return nil }
        return release
    }

    private func atvloadlyInstallAction(for notice: AppNotice) -> AppNoticeInstallAction? {
        guard atvloadlyService.isEnabled, case .release(let release) = notice else { return nil }
        return AppNoticeInstallAction(
            title: L10n.string("atvloadly_install", fallback: "Install"),
            message: atvloadlyService.noticeMessage(for: release),
            isCountingDown: atvloadlyService.isCountingDown,
            perform: { Task { await atvloadlyService.install(release: release) } },
            cancelCountdown: { atvloadlyService.cancelCountdown() }
        )
    }

    private func dismissAppNotice(_ notice: AppNotice) {
        switch notice {
        case .release(let release):
            atvloadlyService.noticeDismissed(tag: release.tagName)
            releaseUpdateService.dismissNotice(tag: release.tagName)
        case .announcement(let announcement):
            announcementService.dismiss(id: announcement.id)
        }
    }

    private func skipAppNotice(_ notice: AppNotice) {
        switch notice {
        case .release(let release):
            atvloadlyService.noticeDismissed(tag: release.tagName)
            releaseUpdateService.skipCurrentVersion(tag: release.tagName)
        case .announcement(let announcement):
            announcementService.skip(id: announcement.id)
        }
    }

    /// Full-screen overlays already hide Home with alpha zero. Propagating
    /// `.disabled` through that hidden tree changes `isEnabled` for every
    /// resident card and forces the shelves to lay themselves out again while
    /// Details is entering. Keep the environment lock for visible menus, where
    /// Home still needs to stay on screen but must not receive focus.
    private var shouldDisableHomeContent: Bool {
        visibleAppNotice != nil
            || presentedAppNoticeDetails != nil
            || (isOverlayPresented && !fullScreenOverlayPresented)
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
            PlaybackStartupTiming.cancel(token: continueWatchingStartupBenchmarkToken)
            continueWatchingStartupBenchmarkToken = nil
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
                    detailsLibraryWatchedContext = DetailsNavigationContextTransition.restoring(ret)
                } else {
                    activeScreen = .main
                    detailsLibraryWatchedContext = nil
                }
                productionBrowseReturn = nil
            }
        case .personBrowse:
            withAnimation(.easeInOut(duration: 0.24)) {
                if let ret = personBrowseReturn {
                    activeScreen = .details(id: ret.id, type: ret.type)
                    detailsLibraryWatchedContext = DetailsNavigationContextTransition.restoring(ret)
                } else {
                    activeScreen = .main
                    detailsLibraryWatchedContext = nil
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
        pendingDetailsPlaybackRequestID = nil
        TVHomeDebugTrace.log(
            "details.leave backStackRemaining=\(detailsBackStack.count) returnDest=\(detailsReturnDestination)"
        )
        withAnimation(.easeInOut(duration: 0.24)) {
            if let previous = detailsBackStack.popLast() {
                activeScreen = .details(id: previous.id, type: previous.type)
                detailsLibraryWatchedContext = DetailsNavigationContextTransition.restoring(previous)
            } else {
                switch detailsReturnDestination {
                case .main:
                    activeScreen = .main
                case let .collectionFolder(folder, collectionTitle):
                    activeScreen = .collectionFolder(folder, collectionTitle: collectionTitle)
                }
                detailsReturnDestination = .main
                detailsLibraryWatchedContext = nil
            }
        }
    }

    /// Opens Details as a fresh navigation (Home, search, a card menu, a deep
    /// link). Any "More like this" chain belongs to the flow being left, so the
    /// back stack starts empty and back from here returns to Home.
    private func openDetailsRoot(
        id: String,
        type: String,
        returnDestination: DetailsReturnDestination = .main,
        startPlayback: Bool = false,
        collectionContext: CollectionPlaybackContext? = nil,
        focusEpisode: DetailsEpisodeFocus? = nil,
        libraryWatchedContext: LibraryWatchedContext? = nil
    ) {
        TVHomeDebugTrace.log(
            "details.open.root id=\(id) type=\(type) returnDest=\(returnDestination)"
        )
        detailsBackStack.removeAll()
        detailsCollectionContext = collectionContext
        detailsFocusEpisode = focusEpisode
        detailsLibraryWatchedContext = libraryWatchedContext
        detailsReturnDestination = returnDestination
        if startPlayback {
            nextDetailsPlaybackRequestID &+= 1
            pendingDetailsPlaybackRequestID = nextDetailsPlaybackRequestID
            reopenStreamPickerOnDetails = false
            reopenStreamPickerEpisode = nil
            reopenStreamPickerResumePosition = nil
        } else {
            pendingDetailsPlaybackRequestID = nil
        }
        activeScreen = .details(id: id, type: type)
    }

    private func collectionContext(
        id: String, type: String, folder: TVCollectionFolderItem? = nil,
        resuming: Bool = false
    ) -> CollectionPlaybackContext {
        CollectionPlaybackContext(
            profileID: profileViewModel.activeProfile?.id ?? "none",
            contentID: id, type: type,
            origin: folder.flatMap { CollectionOriginPresentation.service(folder: $0)?.reference },
            preservesStoredOrigin: resuming
        )
    }

    private var selectedCollectionFolder: TVCollectionFolderItem? {
        guard case .collection(let id) = selectedTab,
              id.profileID == profileViewModel.activeProfile?.id else { return nil }
        return CollectionHomeDestination.configured(profileID: id.profileID)
            .first { $0.id == id }?.folder
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

        if progress > 0, let context = session.collectionContext {
            CollectionPlaybackOriginStore.recordStarted(
                meta: session.meta, context: context,
                activeProfileID: profileID
            )
        }

        if RemoteTrackingState.isProgressSourceAuthenticated {
            // Keep the provider-backed path aligned with built-in playback:
            // optimistic local state plus one pause/stop report. A zero
            // fraction is an Infuse close-before-play signal, not playback.
            let completionFraction = TraktSettingsStore.watchProgressSource == .mdblist
                ? MdbListProgressService.completionPercent / 100
                : WatchProgressLedger.completionFraction
            if progress > 0 {
                let reportDuration = duration ?? 100
                let reportPosition = duration.map { $0 * progress } ?? (100 * progress)
                let action: TraktScrobbleAction = progress >= completionFraction
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
            if progress >= completionFraction {
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
            let position = duration * progress
            if position >= WatchProgressLedger.minimumTrackableSeconds {
                ContinueWatchingDismissStore.clear(contentId: session.meta.id)
            }
            ContinueWatchingStore.save(
                meta: session.meta,
                streamUrl: session.sourceURL,
                position: position,
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

    private var currentHomeContentIdentity: TVHomeContentIdentity {
        TVHomeContentIdentity(
            profileId: profileViewModel.activeProfile?.id ?? "none",
            catalogRevision: syncManager.homeCatalogRevision
        )
    }

    /// Covers Home while the picked profile's stores are re-pointed and its rows
    /// rebuilt, so the user waits once instead of watching Home assemble itself.
    ///
    /// Empty or failed loads get a bounded escape. Populated content waits for
    /// Home's native focus acknowledgement, even after the deadline.
    private func beginProfileGate() {
        profileGateTask?.cancel()
        profileGateLiftTask?.cancel()
        profileGateGeneration &+= 1
        profileGateReadinessIdentity = nil
        profileGateReadiness = .waiting(hasFocusableContent: false, targetSignature: nil)
        isPreparingProfile = true
        profileGateStartedAt = Date()
        let generation = profileGateGeneration
        TVHomeDebugTrace.log("profileGate.begin gen=\(generation) timeout=\(Self.profileGateTimeout)s minDuration=\(Self.profileGateMinimumDuration)s")
        profileGateTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.profileGateTimeout * 1_000_000_000))
            guard !Task.isCancelled,
                  isPreparingProfile,
                  generation == profileGateGeneration else {
                TVHomeDebugTrace.log("profileGate.watchdog cancelled or superseded gen=\(generation) currentGen=\(profileGateGeneration)")
                return
            }
            TVHomeDebugTrace.log("⚠️ profileGate.watchdog FIRED after \(Self.profileGateTimeout)s timeout! Force lifting gate for gen=\(generation)")
            liftProfileGate(generation: generation)
        }
    }

    private func profileGateReadinessChanged(
        _ identity: TVHomeContentIdentity,
        _ generation: UInt,
        _ readiness: TVProfileGateReadiness
    ) {
        TVHomeDebugTrace.log("profileGate.readinessChanged identity=\(identity.profileId):\(identity.catalogRevision) gen=\(generation) curGen=\(profileGateGeneration) readiness=\(readiness)")
        guard isPreparingProfile,
              generation == profileGateGeneration,
              identity == currentHomeContentIdentity else { return }
        profileGateReadinessIdentity = identity
        profileGateReadiness = readiness
        switch readiness {
        case .ready, .empty, .overlay:
            scheduleProfileGateLift(for: identity, generation: generation)
        case .waiting:
            profileGateLiftTask?.cancel()
            profileGateLiftTask = nil
        }
    }

    private func scheduleProfileGateLift(for identity: TVHomeContentIdentity, generation: UInt) {
        guard isPreparingProfile else { return }
        let elapsed = Date().timeIntervalSince(profileGateStartedAt ?? Date())
        let remaining = max(0, Self.profileGateMinimumDuration - elapsed)
        TVHomeDebugTrace.log("profileGate.scheduleLift gen=\(generation) elapsed=\(String(format: "%.2f", elapsed))s remaining=\(String(format: "%.2f", remaining))s readiness=\(profileGateReadiness)")
        profileGateLiftTask?.cancel()
        profileGateLiftTask = Task { @MainActor in
            if remaining > 0 {
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            }
            guard !Task.isCancelled,
                  isPreparingProfile,
                  generation == profileGateGeneration,
                  identity == currentHomeContentIdentity,
                  profileGateReadinessIdentity == identity else {
                TVHomeDebugTrace.log("profileGate.liftTask cancelled or mismatched gen=\(generation)")
                return
            }
            switch profileGateReadiness {
            case .ready, .empty, .overlay:
                break
            case .waiting:
                TVHomeDebugTrace.log("profileGate.liftTask aborted: readiness still waiting gen=\(generation)")
                return
            }
            TVHomeDebugTrace.log("profileGate.liftTask executing normal lift for gen=\(generation)")
            liftProfileGate(generation: generation)
        }
    }

    /// Used when the user backs out or the scoped deadline reaches an empty load.
    private func liftProfileGate(generation: UInt? = nil) {
        if let generation, generation != profileGateGeneration {
            TVHomeDebugTrace.log("profileGate.lift ignored mismatched gen=\(generation) currentGen=\(profileGateGeneration)")
            return
        }
        TVHomeDebugTrace.log("profileGate.lift executing (isPreparingProfile was \(isPreparingProfile), gen=\(generation.map { String($0) } ?? "nil"))")
        profileGateTask?.cancel()
        profileGateTask = nil
        profileGateLiftTask?.cancel()
        profileGateLiftTask = nil
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
        return ContinueWatchingStore.item(for: meta)?.resumePosition
            ?? ContinueWatchingStore.item(for: meta.id)?.resumePosition
            ?? ContinueWatchingStore.resumePosition(for: meta, season: nil, episode: nil)
    }

    private static func seasonSortKey(_ season: Int) -> Int {
        season <= 0 ? Int.max : season
    }

    /// Starts a Continue Watching card. Normal resume uses Details' picker when
    /// Smart Playback is off; with Smart Playback on, locally played entries use
    /// their last stream URL and synced/Next Up entries smart-select in place.
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

        let profileId = profileViewModel.activeProfile?.id
        let profileStore = ProfileSettings.store(for: profileId)
        let smartStreamSelection = profileStore.bool(forKey: SettingsKey.smartStreamSelection)
        let reuseLastLink = profileStore.bool(forKey: SettingsKey.reuseLastLink)

        // Normal resume must let the viewer choose a source when Smart Playback
        // and Reuse Last Link are both disabled.
        // Start from beginning deliberately keeps its existing
        // direct/resolve path so it still starts at zero.
        if !startFromBeginning, !smartStreamSelection, !reuseLastLink {
            playContinueWatchingManually(item)
            return
        }

        let context = Self.episodeContext(for: item)
        let provenance = collectionContext(id: item.meta.id, type: item.meta.type, resuming: true)
        playbackEpisodes = context.episodes
        playbackCurrentEpisode = context.current

        let storedStream = item.isUpNextEntry
            ? nil
            : LastPlaybackStreamStore.load(
                metaId: item.meta.id,
                season: item.season,
                episode: item.episode,
                meta: item.meta,
                profileId: profileId
            )
        let streamURL = storedStream?.url ?? ""
        let httpHeaders = storedStream?.httpHeaders ?? [:]
        if !streamURL.isEmpty, let url = URL(string: streamURL) {
            presentPlayback(
                url: url,
                meta: item.meta,
                subtitle: item.episodeSubtitle ?? "",
                externalSubtitles: [],
                resumeFrom: startFromBeginning ? nil : Self.resumePosition(for: item),
                httpHeaders: httpHeaders,
                collectionContext: provenance
            )
            return
        }

        // If no cached stream is available and Auto Select Stream is off, open manual picker
        if !startFromBeginning, !smartStreamSelection {
            playContinueWatchingManually(item)
            return
        }

        resolvingContinueWatchingItem = item
        continueWatchingLoadingMessage = L10n.string("player_searching_sources", fallback: "Searching sources…")
        let startupToken = PlaybackStartupTiming.start(title: item.meta.name)
        continueWatchingStartupBenchmarkToken = startupToken
        isResolvingContinueWatchingStream = true
        continueWatchingPlaybackTask = Task {
            let prepared: PreparedNextStream?
            if let episode = context.current {
                prepared = await Self.resolveNextEpisodeStream(
                    episode: episode,
                    seriesMeta: item.meta,
                    profileId: profileId,
                    startupToken: startupToken
                )
            } else if let episode = Self.manualPlaybackEpisode(for: item) {
                prepared = await Self.resolveNextEpisodeStream(
                    episode: episode,
                    seriesMeta: item.meta,
                    profileId: profileId,
                    startupToken: startupToken
                )
            } else {
                prepared = await Self.resolveStream(
                    contentId: item.meta.id,
                    type: item.meta.type,
                    subtitleLine: item.episodeSubtitle ?? "",
                    profileId: profileId,
                    startupToken: startupToken
                )
            }

            guard !Task.isCancelled,
                  PlaybackStartupTiming.isActive(token: startupToken) else {
                PlaybackStartupTiming.cancel(token: startupToken)
                if continueWatchingStartupBenchmarkToken == startupToken {
                    continueWatchingStartupBenchmarkToken = nil
                }
                return
            }

            if let prepared {
                continueWatchingLoadingMessage = L10n.string("player_loading_building", fallback: "Building player…")
                continueWatchingPlaybackTask = nil
                presentPlayback(
                    url: prepared.url,
                    meta: item.meta,
                    subtitle: prepared.subtitleLine,
                    externalSubtitles: prepared.subtitles,
                    resumeFrom: startFromBeginning ? nil : Self.resumePosition(for: item),
                    httpHeaders: prepared.httpHeaders,
                    filename: prepared.filename,
                    videoSize: prepared.videoSize,
                    videoHash: prepared.videoHash,
                    startupBenchmarkToken: startupToken,
                    sourceID: prepared.sourceID,
                    collectionContext: provenance
                )
                if continueWatchingStartupBenchmarkToken == startupToken {
                    continueWatchingStartupBenchmarkToken = nil
                }
                isResolvingContinueWatchingStream = false
                resolvingContinueWatchingItem = nil
            } else {
                continueWatchingPlaybackTask = nil
                PlaybackStartupTiming.cancel(token: startupToken)
                if continueWatchingStartupBenchmarkToken == startupToken {
                    continueWatchingStartupBenchmarkToken = nil
                }
                // Keep the manual picker available when no add-on returns a
                // playable stream automatically.
                withAnimation(.easeInOut(duration: 0.28)) {
                    isResolvingContinueWatchingStream = false
                    resolvingContinueWatchingItem = nil
                    reopenStreamPickerOnDetails = true
                    reopenStreamPickerEpisode = context.current ?? Self.manualPlaybackEpisode(for: item)
                    reopenStreamPickerResumePosition = startFromBeginning ? nil : Self.resumePosition(for: item)
                    openDetailsRoot(id: item.meta.id, type: item.meta.type, collectionContext: provenance)
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
            reopenStreamPickerResumePosition = Self.resumePosition(for: item)
            openDetailsRoot(
                id: item.meta.id, type: item.meta.type,
                collectionContext: collectionContext(id: item.meta.id, type: item.meta.type, resuming: true)
            )
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
        print("[ContinueWatching][Home] removeFromContinueWatching called: metaId=\(item.meta.id), S\(item.season.map(String.init) ?? "nil")E\(item.episode.map(String.init) ?? "nil")")
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
        Task { @MainActor in await MdbListProgressService.removePlayback(for: item) }
        Task { @MainActor in await WeTrakrProgressService.removePlayback(for: item) }

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
        customPlayer: ExternalPlayer? = nil,
        cacheFileIdentity: PlaybackCacheFileIdentity? = nil,
        filename: String? = nil,
        videoSize: Int64? = nil,
        videoHash: String? = nil,
        startupBenchmarkToken: UUID? = nil,
        sourceID: String? = nil,
        collectionContext: CollectionPlaybackContext? = nil,
        isActionPlaybackSession: Bool = false
    ) {
        // Usenet streams arrive as nuvio-usenet:// URLs: start the local
        // engine first, then play its 127.0.0.1 URL like any other stream.
        if let usenet = UsenetStreamSpec(url: url) {
            Task { @MainActor in
                do {
                    let localURL = try await UsenetEngineManager.shared.startStream(usenet)
                    presentPlayback(
                        url: localURL, meta: meta, subtitle: subtitle, externalSubtitles: externalSubtitles,
                        resumeFrom: resumeFrom, httpHeaders: httpHeaders, origin: origin, customPlayer: customPlayer,
                        cacheFileIdentity: cacheFileIdentity, filename: filename, videoSize: videoSize,
                        videoHash: videoHash, startupBenchmarkToken: startupBenchmarkToken, sourceID: sourceID,
                        collectionContext: collectionContext, isActionPlaybackSession: isActionPlaybackSession
                    )
                } catch {
                    PlaybackStartupTiming.cancel(token: startupBenchmarkToken)
                    usenetLog.error("usenet: playback not started: \(error.localizedDescription, privacy: .public)")
                }
            }
            return
        }
        playbackIsActionPlaybackSession = isActionPlaybackSession
        // The calendar episode focus applies to the first open only.
        detailsFocusEpisode = nil
        let isTrailer = subtitle == PlaybackMarkers.trailerSubtitle
        let isStandalonePlaybackSession = isTrailer || isActionPlaybackSession
        if !isStandalonePlaybackSession && (creatingParty || choosingPartySource) {
            launchPartyPlayback(url: url, meta: meta, subtitle: subtitle, httpHeaders: httpHeaders,
                externalSubtitles: externalSubtitles, cacheFileIdentity: cacheFileIdentity,
                filename: filename, videoSize: videoSize, videoHash: videoHash,
                startupBenchmarkToken: startupBenchmarkToken, sourceID: sourceID)
            return
        }
        if watchPartyOwner.presentation != nil {
            watchPartyOwner.finishPlayback()
            playbackPartyID = nil
        }
        let provenance = collectionContext ?? self.collectionContext(id: meta.id, type: meta.type)
        let store = ProfileSettings.store(for: profileViewModel.activeProfile?.id)
        let defaultPlayer = ExternalPlayer.from(store.string(forKey: SettingsKey.externalPlayer))
        let player = customPlayer ?? defaultPlayer
        let forwardSubtitles = (store.object(forKey: SettingsKey.externalPlayerForwardSubtitles) as? Bool) ?? true
        // Put the best complete (non-forced) preferred-language subtitle first: players
        // that read only the first `sub=` then get the full dialogue track, not a forced one.
        let subtitleURLs = forwardSubtitles
            ? SubtitleLanguagePreferences.bestCompleteFirst(
                externalSubtitles,
                preferredLanguages: SubtitleLanguagePreferences.orderedFromDefaults(defaults: store)
              ).compactMap { URL(string: $0.url) }
            : []

        let numbers: (season: Int, episode: Int)?
        if isActionPlaybackSession {
            numbers = nil
        } else if let current = playbackCurrentEpisode, current.season > 0, current.episode > 0 {
            numbers = (current.season, current.episode)
        } else if let parsed = Self.episodeNumbers(fromSubtitle: subtitle) {
            numbers = parsed
        } else {
            let parsed = Self.seasonEpisode(fromContentId: url.deletingPathExtension().lastPathComponent)
            numbers = parsed.season.flatMap { season in
                parsed.episode.map { (season: season, episode: $0) }
            }
        }

        let externalSession: ExternalPlaybackSession?
        let successCallback: URL?
        let errorCallback: URL?
        // Infuse, SenPlayer, and Native Player all take x-callback-url success/error
        // URLs and return here so we can report watch progress to continue-watching/Trakt.
        if !isActionPlaybackSession && (player == .infuse || player == .senplayer || player == .nativePlayer) {
            let id = UUID().uuidString
            let profileID = profileViewModel.activeProfile?.id ?? WatchedStore.activeProfileId
            externalSession = ExternalPlaybackSession(
                id: id,
                meta: meta.persistenceSnapshot,
                sourceURL: url.absoluteString,
                season: meta.isSeries ? numbers?.season : nil,
                episode: meta.isSeries ? numbers?.episode : nil,
                duration: Self.runtimeSeconds(meta.runtime),
                profileID: profileID,
                collectionContext: provenance
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
        let mediaFilename = filename ?? ExternalPlayer.mediaFilename(
            meta: meta,
            season: meta.isSeries ? numbers?.season : nil,
            episode: meta.isSeries ? numbers?.episode : nil,
            episodeTitle: isActionPlaybackSession ? nil : (playbackCurrentEpisode?.title ?? (meta.isSeries ? subtitle : nil))
        )

        if !isStandalonePlaybackSession,
           url.scheme?.lowercased() != "smb",
           let launchURL = player.launchURL(
               for: url,
               filename: mediaFilename,
               subtitleURLs: subtitleURLs,
               position: resumeFrom,
               title: meta.name,
               successURL: successCallback,
               errorURL: errorCallback
           ),
           UIApplication.shared.canOpenURL(launchURL) {
            PlaybackStartupTiming.cancel(token: startupBenchmarkToken)
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
            resumeFrom: isActionPlaybackSession ? nil : resumeFrom,
            origin: origin,
            cacheFileIdentity: cacheFileIdentity,
            filename: filename,
            videoSize: videoSize,
            videoHash: videoHash,
            startupBenchmarkToken: startupBenchmarkToken,
            sourceID: sourceID,
            collectionContext: provenance
        )
    }

    /// Host from Details without starting a stream. The server owns room-code
    /// generation; membership and uncertain outcomes stay in WatchPartyService.
    private func createWatchPartyFromDetails(meta: NuvioMeta, episode: NuvioVideo?) {
        guard WatchPartyConfiguration.isEnabled, case .details = activeScreen else { return }
        guard let service = watchPartyOwner.service, partyLaunchTask == nil else { return }
        guard authManager.isAuthenticated, !authManager.sessionNeedsReauthentication,
              profileViewModel.activeProfile != nil else {
            selectedTab = .party
            activeScreen = .main
            return
        }
        if service.session?.party != nil {
            selectedTab = .party
            activeScreen = .main
            return
        }
        guard !service.busy, !service.membershipOutcomeUncertain else {
            watchPartyOwner.message = "Check your previous room request before creating another."
            selectedTab = .party
            activeScreen = .main
            return
        }
        let media: WatchPartyMedia
        do {
            media = try WatchPartyLaunchPolicy.mediaForDetails(meta, episode: episode)
        } catch {
            watchPartyOwner.message = "Choose a valid movie or a specific episode to host a room."
            return
        }
        watchPartyOwner.message = nil
        let destination = PartyDetailsDestination(
            screen: activeScreen, tab: selectedTab, backStack: detailsBackStack,
            returnDestination: detailsReturnDestination, collectionContext: detailsCollectionContext,
            libraryWatchedContext: detailsLibraryWatchedContext
        )
        let detailsGeneration = detailsDidDisappearGeneration
        partyDetailsOrigin = nil
        let mark = UUID()
        partyLaunchID = mark
        partyLaunchTask = Task { @MainActor in
            defer { if partyLaunchID == mark { partyLaunchTask = nil } }
            do {
                try await service.create(media: media, playback: nil)
                guard !Task.isCancelled, partyLaunchID == mark,
                      watchPartyOwner.service === service,
                      activeScreen == destination.screen,
                      detailsDidDisappearGeneration == detailsGeneration else { return }
                rememberPartyDetailsOrigin(destination, media: media, service: service)
                creatingParty = false
                choosingPartySource = false
                partyLaunchTask = nil
                selectedTab = .party
                activeScreen = .main
            } catch {
                guard !Task.isCancelled, partyLaunchID == mark,
                      watchPartyOwner.service === service,
                      activeScreen == destination.screen,
                      detailsDidDisappearGeneration == detailsGeneration else { return }
                rememberPartyDetailsOrigin(destination, media: media, service: service)
                watchPartyOwner.message = "Watch Party could not create the room. Check the room status before retrying."
                partyLaunchTask = nil
                selectedTab = .party
                activeScreen = .main
            }
        }
    }

    private func rememberPartyDetailsOrigin(_ destination: PartyDetailsDestination,
                                            media: WatchPartyMedia, service: WatchPartyService) {
        guard watchPartyOwner.service === service,
              let context = service.session?.playbackContext,
              service.isCurrent(context.request), context.mediaKey == media.key else { return }
        partyDetailsOrigin = PartyDetailsOrigin(context: context, media: media, destination: destination)
    }

    private var partyDetailsBackdrop: WatchPartyMedia? {
        guard let origin = partyDetailsOrigin, let service = watchPartyOwner.service,
              service.isCurrent(origin.context.request),
              let current = service.session?.playbackContext,
              WatchPartyDetailsPresentationPolicy.sameMembership(origin.context, current) else { return nil }
        return origin.media
    }

    private func didExitWatchPartyRoom(_ context: WatchPartyPlaybackContext) {
        guard let origin = partyDetailsOrigin,
              WatchPartyDetailsPresentationPolicy.sameMembership(origin.context, context) else { return }
        partyDetailsOrigin = nil
        guard let service = watchPartyOwner.service, service.isCurrent(context.request),
              service.session?.party == nil, activeScreen == .main, selectedTab == .party else { return }
        creatingParty = false; choosingPartySource = false
        pendingDetailsPlaybackRequestID = nil
        reopenStreamPickerOnDetails = false
        reopenStreamPickerResumePosition = nil
        reopenStreamPickerEpisode = nil
        detailsBackStack = origin.destination.backStack
        detailsReturnDestination = origin.destination.returnDestination
        detailsCollectionContext = origin.destination.collectionContext
        detailsLibraryWatchedContext = origin.destination.libraryWatchedContext
        selectedTab = origin.destination.tab
        withAnimation(.easeInOut(duration: 0.24)) {
            activeScreen = origin.destination.screen
        }
    }

    private func launchPartyPlayback(
        url: URL, meta: NuvioMeta, subtitle: String, httpHeaders: [String: String],
        externalSubtitles: [NuvioSubtitle], cacheFileIdentity: PlaybackCacheFileIdentity?,
        filename: String?, videoSize: Int64?, videoHash: String?,
        startupBenchmarkToken: UUID?, sourceID: String?
    ) {
        guard let service = watchPartyOwner.service else { return }
        let createsRoom = creatingParty
        let roomMedia = service.session?.party?.media
        let episode = meta.isSeries ? playbackCurrentEpisode : nil
        // Keep validation inside the launch task so its existing catch path
        // releases startup timing and any resolved torrent on failure.
        let mediaResult = Result {
            try WatchPartyLaunchPolicy.mediaForPlayback(
                meta, episode: episode, room: roomMedia
            )
        }
        partyLaunchTask?.cancel()
        let mark = UUID()
        partyLaunchID = mark
        partyLaunchTask = Task { @MainActor in
            defer { if partyLaunchID == mark { partyLaunchTask = nil } }
            do {
                let media = try mediaResult.get()
                try WatchPartyLaunchPolicy.validate(media)
                if createsRoom { try await service.create(media: media) }
                try Task.checkCancellation()
                guard partyLaunchID == mark, watchPartyOwner.service === service,
                      let current = service.session?.party?.media else { throw WatchPartyPlaybackRuntimeError.staleContext }
                try WatchPartyLaunchPolicy.validateSelection(media, room: current)
                let presentation = try watchPartyOwner.preparePlayback(media: current)
                creatingParty = false; choosingPartySource = false
                presentBuiltInPlayer(url: url, meta: meta, subtitle: subtitle, httpHeaders: httpHeaders,
                    externalSubtitles: externalSubtitles, resumeFrom: nil, origin: .main,
                    cacheFileIdentity: cacheFileIdentity, filename: filename, videoSize: videoSize,
                    videoHash: videoHash, startupBenchmarkToken: startupBenchmarkToken,
                    sourceID: sourceID, party: presentation)
            } catch {
                PlaybackStartupTiming.cancel(token: startupBenchmarkToken)
                if PictureInPictureManager.shared.activeCoordinator?.torrentStreamSourceURL != url {
                    await TorrentEngineManager.shared.stopActiveStream(for: url)
                    await UsenetEngineManager.shared.stopActiveStream(for: url)
                }
                guard partyLaunchID == mark, !Task.isCancelled else { return }
                watchPartyOwner.message = error is WatchPartyLaunchError
                    ? "That title or episode doesn't match the room. Choose the matching entry; you can use any source."
                    : "Watch Party could not start. Check the room status and choose your source again."
                selectedTab = .party; activeScreen = .main
            }
        }
    }

    @MainActor
    private func changeWatchPartyEpisode(
        _ episode: NuvioVideo,
        prepared: PreparedNextStream,
        sourceViewModel: PlayerViewModel,
        expectedPresentationID: UUID,
        expectedSurfaceID: UUID,
        meta: NuvioMeta
    ) async -> Bool {
        guard activeScreen.isPlayer, playerSurfaceID == expectedSurfaceID,
              playbackPartyID == expectedPresentationID,
              let presentation = watchPartyOwner.presentation,
              presentation.id == expectedPresentationID,
              presentation.mount.isCurrent,
              presentation.mount.viewModel === sourceViewModel,
              let service = watchPartyOwner.service,
              let room = service.session,
              room.connection == .ready,
              room.playbackContext == presentation.context,
              room.party?.hostMemberID == room.memberID else { return false }

        let startupToken = sourceViewModel.startupBenchmarkToken
        var nextStartupToken: UUID?
        do {
            let media = try WatchPartyLaunchPolicy.mediaForPlayback(
                meta, episode: episode, room: room.party?.media
            )
            try await watchPartyOwner.updateRoomMedia(media)
            try Task.checkCancellation()
            guard watchPartyOwner.service === service, service.session === room,
                  room.connection == .ready, room.party?.media.key == media.key,
                  activeScreen.isPlayer, playerSurfaceID == expectedSurfaceID else {
                throw WatchPartyPlaybackRuntimeError.staleContext
            }

            playbackCurrentEpisode = episode
            PlaybackStartupTiming.cancel(token: startupToken)
            nextStartupToken = PlaybackStartupTiming.start(title: meta.name)
            let nextPresentation = try watchPartyOwner.preparePlayback(media: media)
            presentBuiltInPlayer(
                url: prepared.url,
                meta: meta,
                subtitle: prepared.subtitleLine,
                httpHeaders: prepared.httpHeaders,
                externalSubtitles: prepared.subtitles,
                resumeFrom: nil,
                origin: playbackOrigin,
                cacheFileIdentity: prepared.cacheFileIdentity,
                filename: prepared.filename,
                videoSize: prepared.videoSize,
                videoHash: prepared.videoHash,
                startupBenchmarkToken: nextStartupToken,
                sourceID: prepared.sourceID,
                party: nextPresentation
            )
            return true
        } catch {
            PlaybackStartupTiming.cancel(token: startupToken)
            PlaybackStartupTiming.cancel(token: nextStartupToken)
            guard activeScreen.isPlayer, playerSurfaceID == expectedSurfaceID,
                  playbackPartyID == expectedPresentationID else { return false }
            if watchPartyOwner.presentation?.id == expectedPresentationID {
                watchPartyOwner.message = "Couldn't change the Watch Party episode. Try again."
            } else {
                playbackPartyID = nil
                selectedTab = .party
                activeScreen = .main
            }
            return false
        }
    }

    @MainActor
    private func handleIncomingMediaTransitionChange(_ transitionID: UUID?) {
        guard let transitionID,
              let transition = watchPartyOwner.incomingMediaTransition,
              transition.id == transitionID else { return }
        guard case let .player(_, meta, _, _, _, _) = activeScreen else {
            watchPartyOwner.cancelIncomingMediaTransition(transitionID)
            return
        }
        let expectedSurfaceID = playerSurfaceID
        Task { @MainActor in
            await handleIncomingWatchPartyMediaTransition(
                transition, expectedSurfaceID: expectedSurfaceID, meta: meta
            )
        }
    }

    @MainActor
    private func completeIncomingWatchPartyEpisode(
        transitionID: UUID,
        context: WatchPartyPlaybackContext,
        media: WatchPartyMedia,
        episode: NuvioVideo,
        prepared: PreparedNextStream,
        startupToken: UUID,
        expectedSurfaceID: UUID,
        meta: NuvioMeta
    ) async -> Bool {
        guard activeScreen.isPlayer, playerSurfaceID == expectedSurfaceID,
              watchPartyOwner.isCurrentIncomingMediaTransition(transitionID, context: context),
              let service = watchPartyOwner.service,
              let room = service.session,
              room.connection == .ready,
              room.playbackContext == context,
              room.party?.media.key == media.key,
              context.mediaKey == media.key else { return false }

        do {
            let presentation = try watchPartyOwner.preparePlayback(media: media)
            playbackCurrentEpisode = episode
            presentBuiltInPlayer(
                url: prepared.url,
                meta: meta,
                subtitle: prepared.subtitleLine,
                httpHeaders: prepared.httpHeaders,
                externalSubtitles: prepared.subtitles,
                resumeFrom: nil,
                origin: playbackOrigin,
                cacheFileIdentity: prepared.cacheFileIdentity,
                filename: prepared.filename,
                videoSize: prepared.videoSize,
                videoHash: prepared.videoHash,
                startupBenchmarkToken: startupToken,
                sourceID: prepared.sourceID,
                party: presentation
            )
            watchPartyOwner.completeIncomingMediaTransition(transitionID, context: context)
            return true
        } catch {
            PlaybackStartupTiming.cancel(token: startupToken)
            return false
        }
    }

    @MainActor
    private func handleIncomingWatchPartyMediaTransition(
        _ transition: WatchPartyAppOwner.IncomingMediaTransition,
        expectedSurfaceID: UUID,
        meta: NuvioMeta
    ) async {
        let id = transition.id
        let context = transition.context
        let viewModel = transition.viewModel
        guard activeScreen.isPlayer, playerSurfaceID == expectedSurfaceID,
              watchPartyOwner.isCurrentIncomingMediaTransition(id, context: context) else {
            watchPartyOwner.cancelIncomingMediaTransition(id)
            return
        }
        guard let plan = transition.plan,
              let service = watchPartyOwner.service,
              let room = service.session else {
            if !watchPartyOwner.showWatchPartyAfterIncomingMediaTransition(id) {
                selectedTab = .party
                activeScreen = .main
            }
            return
        }

        let isCurrent: @MainActor () -> Bool = {
            activeScreen.isPlayer && playerSurfaceID == expectedSurfaceID
                && watchPartyOwner.isCurrentIncomingMediaTransition(id, context: context)
        }
        let waitUntilReady: @MainActor () async -> Bool = {
            let deadline = Date().addingTimeInterval(20)
            while service.session === room, room.connection != .ready {
                guard !Task.isCancelled, isCurrent(),
                      Date() < deadline else { return false }
                do { try await Task.sleep(nanoseconds: 100_000_000) }
                catch { return false }
            }
            return !Task.isCancelled && isCurrent()
        }
        let resolved = await viewModel.resolveIncomingWatchPartyEpisode(
            plan, media: transition.media, context: context,
            transitionID: id, isCurrent: isCurrent,
            waitUntilReady: waitUntilReady
        )
        guard watchPartyOwner.incomingMediaTransition?.id == id else { return }
        guard activeScreen.isPlayer, playerSurfaceID == expectedSurfaceID else {
            watchPartyOwner.cancelIncomingMediaTransition(id)
            return
        }
        if !resolved {
            if !watchPartyOwner.showWatchPartyAfterIncomingMediaTransition(id) {
                selectedTab = .party
                activeScreen = .main
            }
        }
    }

    private func watchPartyMedia(
        for meta: NuvioMeta,
        episode: NuvioVideo? = nil,
        matchingRoom: WatchPartyMedia? = nil
    ) -> WatchPartyMedia {
        let identifiers = [meta.id, meta.imdbId].compactMap { $0 }
        let metaID = matchingRoom.flatMap { identifiers.contains($0.metaID) ? $0.metaID : nil }
            ?? meta.imdbId ?? meta.id
        let mediaType = meta.isSeries ? "series" : "movie"
        return WatchPartyMedia(
            type: mediaType,
            metaID: metaID,
            metaType: mediaType,
            videoID: episode?.id,
            season: episode?.season,
            episode: episode?.episode,
            title: meta.name,
            episodeTitle: episode?.title,
            description: meta.description,
            poster: meta.posterUrl,
            background: meta.backgroundUrl,
            logo: meta.logoUrl
        )
    }

    private func createWatchPartyRoom(media: WatchPartyMedia) {
        guard WatchPartyConfiguration.isEnabled else {
            creatingParty = false
            return
        }
        guard creatingParty, partyLaunchTask == nil else { return }
        guard let service = watchPartyOwner.service else {
            creatingParty = false
            watchPartyOwner.message = "Watch Party is unavailable on this server."
            selectedTab = .party; activeScreen = .main
            return
        }

        let mark = UUID()
        partyLaunchID = mark
        partyLaunchTask = Task { @MainActor in
            defer { if partyLaunchID == mark { partyLaunchTask = nil } }
            do {
                try WatchPartyLaunchPolicy.validate(media)
                try await service.create(media: media)
                try Task.checkCancellation()
                guard partyLaunchID == mark, watchPartyOwner.service === service,
                      let roomMedia = service.session?.party?.media else {
                    throw WatchPartyPlaybackRuntimeError.staleContext
                }
                try WatchPartyLaunchPolicy.validateSelection(media, room: roomMedia)

                creatingParty = false
                choosingPartySource = false
                watchPartyOwner.message = nil
                partyLaunchTask = nil
                selectedTab = .party
                activeScreen = .main
            } catch {
                guard partyLaunchID == mark, !Task.isCancelled else { return }
                creatingParty = false
                choosingPartySource = false
                watchPartyOwner.message = error is WatchPartyLaunchError
                    ? "That title or episode isn't supported for a Watch Party."
                    : "Watch Party could not be created. Check the room status and try again."
                partyLaunchTask = nil
                selectedTab = .party
                activeScreen = .main
            }
        }
    }

    private func chooseWatchPartySharedSource(_ stream: WatchPartyStream) {
        guard WatchPartyConfiguration.isEnabled, activeScreen == .main, selectedTab == .party,
              partyLaunchTask == nil, let service = watchPartyOwner.service,
              !service.busy, let room = service.session,
              let context = room.playbackContext, let media = room.party?.media,
              let memberID = room.memberID, let hostID = room.party?.hostMemberID,
              memberID != hostID, service.isCurrent(context.request) else { return }
        let selection: WatchPartySharedStreamSelection
        do { selection = try room.selectSharedStream(stream) }
        catch {
            watchPartyOwner.message = "The shared source changed or is unavailable. Ask the host to share again, or choose your own source."
            return
        }
        watchPartyOwner.message = nil
        let mark = UUID()
        let navigationRevision = partySourceNavigationRevision
        partyLaunchID = mark
        partyLaunchTask = Task { @MainActor in
            defer { if partyLaunchID == mark { partyLaunchTask = nil } }
            // Revalidate the accepted membership and exact source revision after metadata loading.
            // There is no source-URL probe, automatic playback, resend or persistence here.
            let isCurrent = {
                !Task.isCancelled && partyLaunchID == mark && activeScreen == .main
                    && partySourceNavigationRevision == navigationRevision
                    && selectedTab == .party && watchPartyOwner.service === service
                    && service.session === room && service.isCurrent(context.request)
                    && room.playbackContext == context
                    && room.isCurrentSharedStreamSelection(selection)
            }
            do {
                let target = try await WatchPartySharedPlaybackResolver.resolve(
                    stream: selection.candidate.metadata, room: media, isCurrent: isCurrent,
                    loadMetadata: { id, type in
                        try await CinemetaCatalogRepository().getMetadata(id: id, type: type)
                    }
                )
                guard isCurrent() else { return }
                let presentation = try watchPartyOwner.preparePlayback(media: media)
                presentation.mount.viewModel.markWatchPartySharedSource()
                creatingParty = false; choosingPartySource = false
                playbackIsActionPlaybackSession = false
                playbackEpisodes = target.meta.isSeries ? (target.meta.videos ?? []) : []
                playbackCurrentEpisode = target.episode
                reopenStreamPickerOnDetails = false
                reopenStreamPickerEpisode = nil
                reopenStreamPickerResumePosition = nil
                pendingDetailsPlaybackRequestID = nil
                let subtitle = target.episode.map { "S\($0.season) · E\($0.episode) · \($0.title)" } ?? ""
                presentBuiltInPlayer(
                    url: target.url, meta: target.meta, subtitle: subtitle,
                    httpHeaders: target.stream.headers, externalSubtitles: [], resumeFrom: nil,
                    origin: .main, filename: target.stream.filename, videoSize: target.stream.videoSize,
                    party: presentation
                )
            } catch {
                guard isCurrent() else { return }
                if error as? WatchPartySharedPlaybackError == .unsupportedResponseHeaders {
                    watchPartyOwner.message = "This shared source needs unsupported response headers. Choose your own source."
                } else if error as? WatchPartySharedPlaybackError == .missingEpisode {
                    watchPartyOwner.message = "The room's exact episode is unavailable in your catalog. Choose your own source."
                } else {
                    watchPartyOwner.message = "The shared source could not be prepared for this title or episode. Ask the host to share again, or choose your own source."
                }
            }
        }
    }

    private func presentBuiltInPlayer(
        url: URL,
        meta: NuvioMeta,
        subtitle: String,
        httpHeaders: [String: String],
        externalSubtitles: [NuvioSubtitle],
        resumeFrom: Double?,
        origin: PlaybackOrigin,
        cacheFileIdentity: PlaybackCacheFileIdentity? = nil,
        filename: String? = nil,
        videoSize: Int64? = nil,
        videoHash: String? = nil,
        startupBenchmarkToken: UUID? = nil,
        sourceID: String? = nil,
        collectionContext: CollectionPlaybackContext? = nil,
        party: WatchPartyAppOwner.Presentation? = nil
    ) {
        if party == nil {
            partyLaunchID = UUID()
            partyLaunchTask?.cancel(); partyLaunchTask = nil
            watchPartyOwner.finishPlayback()
        }
        playbackPartyID = party?.id
        if let party, PictureInPictureManager.shared.activeCoordinator !== party.mount.viewModel.sessionCoordinator {
            PictureInPictureManager.shared.invalidateSession()
        }
        if PictureInPictureManager.shared.isPictureInPictureActive,
           PictureInPictureManager.shared.activeContext?.url != url {
            PictureInPictureManager.shared.invalidateSession()
        }
        playbackOrigin = origin
        playbackCollectionContext = collectionContext
        playbackLibraryWatchedContext = DetailsNavigationContextTransition.playbackContext(
            origin: origin,
            currentLibraryWatchedContext: detailsLibraryWatchedContext
        )
        if origin == .main {
            // Direct Continue Watching playback can return to Details for a
            // series, without calling openDetailsRoot first.
            detailsCollectionContext = collectionContext
        }
        playbackFilename = filename
        playbackSourceID = sourceID
        playbackVideoSize = videoSize
        playbackVideoHash = videoHash
        playbackCacheFileIdentity = cacheFileIdentity
        playbackStartupBenchmarkToken = startupBenchmarkToken
        playbackDidStart = false
        playerSurfaceID = UUID()
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
        PictureInPictureManager.shared.onDidLoseWatchPartyPiP = { coordinator in
            guard watchPartyOwner.owns(coordinator),
                  !activeScreen.isPlayer || UIApplication.shared.applicationState != .active else { return }
            watchPartyOwner.finishPlayback()
        }
        PictureInPictureManager.shared.onRestoreUI = { [self] context, completion in
            if watchPartyOwner.owns(PictureInPictureManager.shared.activeCoordinator) {
                guard let restored = watchPartyOwner.restorePlayback(for: PictureInPictureManager.shared.activeCoordinator) else {
                    completion(false)
                    watchPartyOwner.finishPlayback()
                    return
                }
                playbackPartyID = restored.id
            } else {
                guard PictureInPictureManager.shared.activeCoordinator?.aetherController?.isWatchPartyControlled != true else {
                    completion(false)
                    return
                }
                playbackPartyID = nil
            }
            withAnimation(.easeInOut(duration: 0.24)) {
                self.playbackIsActionPlaybackSession = false
                self.playerSurfaceID = UUID()
                self.playbackOrigin = context.playbackOrigin
                self.playbackCollectionContext = self.collectionContext(
                    id: context.meta.id, type: context.meta.type, resuming: true
                )
                self.playbackFilename = context.filename
                self.playbackSourceID = context.sourceID
                self.playbackVideoSize = context.videoSize
                self.playbackVideoHash = context.videoHash
                self.playbackCacheFileIdentity = context.cacheFileIdentity
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
            if watchPartyOwner.owns(PictureInPictureManager.shared.activeCoordinator) {
                watchPartyOwner.finishPlayback()
                return
            }
            if let coordinator = PictureInPictureManager.shared.activeCoordinator {
                PlaybackWakeLock.release(ownerID: coordinator.wakeLockOwnerID)
            }
            let sourceURL = PictureInPictureManager.shared.activeCoordinator?.torrentStreamSourceURL
            Task {
                guard let sourceURL else { return }
                await TorrentEngineManager.shared.stopActiveStream(for: sourceURL)
                await UsenetEngineManager.shared.stopActiveStream(for: sourceURL)
            }
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
                    resumeFrom: resumeFrom,
                    startupBenchmarkToken: playbackStartupBenchmarkToken
                )
                .transition(.opacity)
                .onDisappear {
                    detailsDidDisappearGeneration &+= 1
                }
                .zIndex(2)
            }

            let showCloudLibrary = {
                if case .cloudLibrary = activeScreen { return true }
                if activeScreen.isPlayer, playbackOrigin == .cloudLibrary { return true }
                return false
            }()

            if showCloudLibrary {
                cloudLibraryScreen()
                    .disabled(activeScreen.isPlayer)
                    .transition(.opacity)
                    .onDisappear {
                        detailsDidDisappearGeneration &+= 1
                    }
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
                        CinemetaCatalogRepository.cacheCatalogMetadata(meta)
                        withAnimation(.easeInOut(duration: 0.28)) {
                            openDetailsRoot(
                                id: meta.id,
                                type: meta.type,
                                returnDestination: .collectionFolder(
                                    folder,
                                    collectionTitle: collectionTitle
                                ),
                                collectionContext: self.collectionContext(id: meta.id, type: meta.type, folder: folder)
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
                .onDisappear {
                    detailsDidDisappearGeneration &+= 1
                }
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
                                let transition = DetailsNavigationContextTransition.openingRelatedTitle(from: ret)
                                detailsBackStack.append(transition.backStackEntry)
                                detailsLibraryWatchedContext = transition.activeLibraryWatchedContext
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
                                detailsLibraryWatchedContext = DetailsNavigationContextTransition.restoring(ret)
                            } else {
                                activeScreen = .main
                                detailsLibraryWatchedContext = nil
                            }
                            productionBrowseReturn = nil
                        }
                    }
                )
                .transition(.opacity)
                .onDisappear {
                    detailsDidDisappearGeneration &+= 1
                }
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
                                let transition = DetailsNavigationContextTransition.openingRelatedTitle(from: ret)
                                detailsBackStack.append(transition.backStackEntry)
                                detailsLibraryWatchedContext = transition.activeLibraryWatchedContext
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
                                detailsLibraryWatchedContext = DetailsNavigationContextTransition.restoring(ret)
                            } else {
                                activeScreen = .main
                                detailsLibraryWatchedContext = nil
                            }
                            personBrowseReturn = nil
                        }
                    }
                )
                .transition(.opacity)
                .onDisappear {
                    detailsDidDisappearGeneration &+= 1
                }
                .zIndex(1)
            }

            if isResolvingContinueWatchingStream, let item = resolvingContinueWatchingItem {
                PlayerLoadingOverlay(
                    backdropUrl: item.meta.backgroundUrl ?? item.meta.posterUrl,
                    logoUrl: item.meta.logoUrl,
                    title: item.meta.name,
                    message: continueWatchingLoadingMessage,
                    onDismiss: {
                        dismissOverlay()
                    }
                )
                .transition(.opacity)
                .onDisappear {
                    detailsDidDisappearGeneration &+= 1
                }
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
            isFullScreenOverlayPresented: fullScreenOverlayPresented,
            detailsDidDisappearGeneration: detailsDidDisappearGeneration,
            accountEmail: authManager.currentEmail,
            isAuthenticated: authManager.isAuthenticated,
            sessionNeedsReauthentication: authManager.sessionNeedsReauthentication,
            isProfileFocusPending: isPreparingProfile,
            profileGateGeneration: profileGateGeneration,
            onProfileGateReadinessChange: profileGateReadinessChanged,
            authManager: authManager,
            syncManager: syncManager,
            watchPartyOwner: watchPartyOwner,
            partyDetailsMedia: partyDetailsBackdrop,
            onPartyRoomExited: didExitWatchPartyRoom,
            onCreateParty: {
                partyDetailsOrigin = nil
                creatingParty = true; choosingPartySource = false
                reopenStreamPickerOnDetails = false
                reopenStreamPickerEpisode = nil
                reopenStreamPickerResumePosition = nil
                selectedTab = .search
            },
            onChoosePartySource: { media in
                // Honor upstream beta gating. Never detach the current player
                // for a stale or unauthorized Watch Party selection.
                guard WatchPartyConfiguration.isEnabled,
                      let room = watchPartyOwner.service?.session,
                      room.connection == .ready, room.membershipExit == nil,
                      let currentMedia = room.party?.media,
                      (try? WatchPartyLaunchPolicy.validateSelection(media, room: currentMedia)) != nil else {
                    watchPartyOwner.message = "The room or episode changed. Review the current room before choosing a source."
                    return
                }
                creatingParty = false; choosingPartySource = true
                watchPartyOwner.finishPlayback()
                reopenStreamPickerOnDetails = true
                if let season = media.season, let episode = media.episode {
                    reopenStreamPickerEpisode = NuvioVideo(
                        id: media.videoID ?? "\(media.metaID):\(season):\(episode)",
                        title: media.episodeTitle.flatMap { $0.isEmpty ? nil : $0 } ?? "Episode \(episode)",
                        season: season,
                        episode: episode
                    )
                } else {
                    reopenStreamPickerEpisode = nil
                }
                openDetailsRoot(id: media.metaID, type: media.metaType)
            },
            onChoosePartySharedSource: chooseWatchPartySharedSource,
            partyIsChoosing: creatingParty || choosingPartySource,
            onCancelPartySelection: {
                creatingParty = false; choosingPartySource = false
                partyLaunchID = UUID(); partyLaunchTask?.cancel(); partyLaunchTask = nil
            },
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
                    openDetailsRoot(
                        id: contentId, type: contentType,
                        collectionContext: collectionContext(id: contentId, type: contentType, folder: selectedCollectionFolder)
                    )
                }
            },
            onNavigateToLibraryDetails: { contentId, contentType, watchedContext in
                withAnimation(.easeInOut(duration: 0.28)) {
                    openDetailsRoot(
                        id: contentId,
                        type: contentType,
                        libraryWatchedContext: watchedContext
                    )
                }
            },
            onPlayTitle: { contentId, contentType in
                withAnimation(.easeInOut(duration: 0.28)) {
                    openDetailsRoot(
                        id: contentId, type: contentType, startPlayback: true,
                        collectionContext: collectionContext(id: contentId, type: contentType, folder: selectedCollectionFolder)
                    )
                }
            },
            onRequestAccountRefresh: { force in
                if force {
                    syncManager.forcePull()
                } else {
                    syncManager.refreshAccountIfIdle()
                }
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
            onNavigateToContinueWatchingDetails: { id, type in
                withAnimation(.easeInOut(duration: 0.28)) {
                    openDetailsRoot(
                        id: id, type: type,
                        collectionContext: collectionContext(id: id, type: type, resuming: true)
                    )
                }
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
                    origin: .cloudLibrary,
                    filename: meta.name
                )
            },
            onOpenCalendarEntry: { entry in
                openCalendarEntry(entry)
            }
        )
    }

    /// Opens a calendar entry: a movie's details, or a series' details with
    /// the entry's episode selected.
    private func openCalendarEntry(_ entry: CalendarEntry) {
        let type = entry.itemType.isEmpty ? (entry.kind == .series ? "series" : "movie") : entry.itemType
        let focus = entry.seasonNumber.flatMap { season in
            entry.episodeNumber.map {
                DetailsEpisodeFocus(metaID: entry.itemId, season: season, episode: $0, airDate: entry.date)
            }
        }
        withAnimation(.easeInOut(duration: 0.28)) {
            openDetailsRoot(id: entry.itemId, type: type, focusEpisode: focus)
        }
    }

    private func detailsScreen(contentId: String, contentType: String) -> some View {
        let provenance = detailsCollectionContext
        return DetailsScreen(
            id: contentId,
            type: contentType,
            libraryWatchedContext: detailsLibraryWatchedContext,
            repository: CinemetaCatalogRepository(),
            initialPlaybackRequestID: pendingDetailsPlaybackRequestID,
            onInitialPlaybackRequestConsumed: { requestID in
                guard pendingDetailsPlaybackRequestID == requestID else { return }
                pendingDetailsPlaybackRequestID = nil
            },
            initiallyPresentStreamPicker: reopenStreamPickerOnDetails,
            initialStreamPickerEpisode: reopenStreamPickerEpisode,
            initialStreamPickerResumePosition: reopenStreamPickerResumePosition,
            initialFocusEpisode: detailsFocusEpisode.flatMap { $0.metaID == contentId ? $0 : nil },
            onInitialStreamPickerPresented: {
                reopenStreamPickerOnDetails = false
                reopenStreamPickerEpisode = nil
                reopenStreamPickerResumePosition = nil
                reopenStreamPickerResumePosition = nil
            },
            onWatchPartyMovieReady: { meta in
                guard creatingParty, !meta.isSeries else { return }
                createWatchPartyRoom(media: watchPartyMedia(for: meta))
            },
            creatingWatchPartyRoom: creatingParty,
            onWatchPartyMediaSelected: { meta, episode in
                guard creatingParty else { return }
                createWatchPartyRoom(media: watchPartyMedia(for: meta, episode: episode))
            },
            onPlayClick: { streamUrlString, httpHeaders, meta, subtitle, externalSubtitles, currentEpisode, episodes, player, cacheFileIdentity, filename, videoSize, videoHash, resumeFrom, startupToken, sourceID, isActionPlaybackSession in
                if let url = URL(string: streamUrlString) {
                    let isTrailer = subtitle == PlaybackMarkers.trailerSubtitle
                    reopenStreamPickerOnDetails = false
        reopenStreamPickerResumePosition = nil
                    reopenStreamPickerEpisode = nil
                    reopenStreamPickerResumePosition = nil
                    playbackEpisodes = episodes
                    playbackCurrentEpisode = currentEpisode
                    presentPlayback(
                        url: url,
                        meta: meta,
                        subtitle: subtitle,
                        externalSubtitles: externalSubtitles,
                        resumeFrom: isActionPlaybackSession ? nil : (isTrailer ? resumeFrom : (resumeFrom ?? Self.resumePosition(for: meta, episode: currentEpisode))),
                        httpHeaders: httpHeaders,
                        origin: .details,
                        customPlayer: player,
                        cacheFileIdentity: cacheFileIdentity,
                        filename: filename,
                        videoSize: videoSize,
                        videoHash: videoHash,
                        startupBenchmarkToken: startupToken,
                        sourceID: sourceID,
                        collectionContext: provenance,
                        isActionPlaybackSession: isActionPlaybackSession
                    )
                } else {
                    PlaybackStartupTiming.cancel(token: startupToken)
                }
            },
            onBack: { leaveDetails() },
            onCreateWatchParty: WatchPartyConfiguration.isEnabled ? { meta, episode in
                createWatchPartyFromDetails(meta: meta, episode: episode)
            } : nil,
            onOpenTitle: { nextId, nextType in
                let transition = DetailsNavigationContextTransition.pushingCurrentDetails(
                    id: contentId,
                    type: contentType,
                    libraryWatchedContext: detailsLibraryWatchedContext
                )
                detailsBackStack.append(transition.backStackEntry)
                detailsLibraryWatchedContext = transition.activeLibraryWatchedContext
                withAnimation(.easeInOut(duration: 0.28)) {
                    activeScreen = .details(id: nextId, type: nextType)
                }
            },
            onOpenProduction: { company in
                productionBrowseReturn = DetailsNavigationEntry(
                    id: contentId,
                    type: contentType,
                    libraryWatchedContext: detailsLibraryWatchedContext
                )
                withAnimation(.easeInOut(duration: 0.28)) {
                    activeScreen = .productionBrowse(company)
                }
            },
            onOpenPerson: { person in
                personBrowseReturn = DetailsNavigationEntry(
                    id: contentId,
                    type: contentType,
                    libraryWatchedContext: detailsLibraryWatchedContext
                )
                withAnimation(.easeInOut(duration: 0.28)) {
                    activeScreen = .personBrowse(person)
                }
            }
        )
    }

    private func cloudLibraryScreen() -> some View {
        let activeProfileId = profileViewModel.activeProfile?.id
        return CloudLibraryView(
            store: ProfileSettings.store(for: activeProfileId),
            onPlay: { [weak profileViewModel] url, meta in
                guard activeScreen == .cloudLibrary,
                      profileViewModel?.activeProfile?.id == activeProfileId else {
                    return
                }
                playbackEpisodes = []
                playbackCurrentEpisode = nil
                presentPlayback(
                    url: url,
                    meta: meta,
                    subtitle: "",
                    externalSubtitles: [],
                    resumeFrom: nil,
                    origin: .cloudLibrary,
                    filename: meta.name
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
    private static func resolveNextEpisodeStream(
        episode: NuvioVideo,
        seriesMeta: NuvioMeta,
        profileId: String?,
        startupToken: UUID? = nil
    ) async -> PreparedNextStream? {
        let streamId = seriesMeta.canonicalEpisodeStreamId(for: episode)
        return await resolveStream(
            contentId: streamId,
            type: "series",
            subtitleLine: "S\(episode.season) · E\(episode.episode) · \(episode.title)",
            profileId: profileId,
            seriesMetaId: seriesMeta.id,
            startupToken: startupToken
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
        excludingURLs: Set<String> = [],
        seriesMetaId: String? = nil,
        forceRefresh: Bool = false,
        startupToken: UUID? = nil
    ) async -> PreparedNextStream? {
        let streams = await StreamsRepository.shared.collectStreams(
            type: type,
            videoId: contentId,
            forceRefresh: forceRefresh || !excludingURLs.isEmpty
        )
        guard !streams.isEmpty else { return nil }

        let store = ProfileSettings.store(for: profileId)
        let quality = store.string(forKey: SettingsKey.smartStreamQuality) ?? "Highest"
        let matchSubtitles = store.object(forKey: SettingsKey.smartSubtitleMatching) as? Bool ?? true
        let languages = SubtitleLanguagePreferences.orderedFromDefaults(defaults: store)
        let cachedOnlyPreference = (store.object(forKey: SettingsKey.cachedOnlyStreams) as? Bool) ?? false
        let cachedOnly = SmartPlaybackSelector.effectiveCachedOnly(
            cachedOnlyPreference,
            contentType: type
        )
        // Prefer the exact series meta id when resolving an episode stream.
        let resolvedSeriesId = seriesMetaId ?? StreamQualityTags.seriesId(fromContentId: contentId)
        let metaIdForTags = resolvedSeriesId.isEmpty ? contentId : resolvedSeriesId
        let preferredTags = LastStreamQualityStore.load(metaId: metaIdForTags, profileId: profileId)
            ?? LastStreamQualityStore.load(metaId: contentId, profileId: profileId)

        let debrid = DebridResolver(store: store)
        let useTopResult = (store.object(forKey: SettingsKey.smartStreamUseTopResult) as? Bool) ?? false
        let preserveAddonOrder = (store.object(forKey: SettingsKey.preserveAddonStreamOrder) as? Bool) ?? false
        let preferBingeGroup = (store.object(forKey: SettingsKey.streamAutoPlayPreferBingeGroup) as? Bool) ?? true
        let reuseBingeGroup = (store.object(forKey: SettingsKey.streamAutoPlayReuseBingeGroup) as? Bool) ?? true
        let sortRaw = store.string(forKey: SettingsKey.streamSortOption)
        let sortOption = sortRaw.flatMap(StreamSortOption.init(rawValueOrSync:)) ?? .quality

        let ranked: [NuvioStream]
        let includeDebridOrTorrent = debrid.isEnabled || TorrentSettings.isEnabled()
        if useTopResult || preserveAddonOrder {
            let playable = SmartPlaybackSelector.playableStreams(
                from: streams,
                includeDebrid: includeDebridOrTorrent,
                cachedOnly: cachedOnly,
                preserveAddonStreams: preserveAddonOrder
            ).filter { !$0.isNotPlayable }
            let sortedPlayable = StreamPickerListBuilder.sorted(playable, by: sortOption, preserveAddonStreams: preserveAddonOrder)
            // Prioritize preferred binge group or release fingerprint before taking top result
            if (preferBingeGroup || reuseBingeGroup), let preferredTags, preferredTags.bingeGroup != nil || preferredTags.releaseFingerprint != nil {
                let matching = sortedPlayable.first { candidate in
                    let tags = StreamQualityTags.parse(stream: candidate)
                    if let pbg = preferredTags.bingeGroup, let sbg = tags.bingeGroup,
                       pbg.compare(sbg, options: .caseInsensitive) == .orderedSame {
                        return true
                    }
                    if let pfp = preferredTags.releaseFingerprint, let sfp = tags.releaseFingerprint,
                       pfp.compare(sfp, options: .caseInsensitive) == .orderedSame {
                        return true
                    }
                    return false
                }
                if let matching {
                    ranked = [matching] + sortedPlayable.filter { $0.id != matching.id }
                } else {
                    ranked = sortedPlayable
                }
            } else {
                ranked = sortedPlayable
            }
        } else {
            ranked = Self.rankedPlayableStreams(
                from: streams,
                qualityPreference: quality,
                subtitleLanguages: languages,
                shouldMatchSubtitles: matchSubtitles,
                includeDebrid: includeDebridOrTorrent,
                preferredTags: preferredTags,
                cachedOnly: cachedOnly
            )
        }
        guard !ranked.isEmpty else { return nil }

        let (season, episode) = Self.seasonEpisode(fromContentId: contentId)
        for candidate in ranked {
            // Direct URL already known-bad this session.
            if let urlString = candidate.directURL?.trimmingCharacters(in: .whitespacesAndNewlines),
               !urlString.isEmpty,
               excludingURLs.contains(urlString)
                || UsenetEngineManager.isExcluded(sourceURL: urlString, excludedPlaybackURLs: excludingURLs) {
                continue
            }

            if candidate.isDebridResolvable {
                PlaybackStartupTiming.markSourcePicked(stream: candidate, token: startupToken)
                var resolvedURL: URL? = nil
                var resolvedFilename = candidate.filename
                var resolvedVideoSize = candidate.videoSize
                var providerName = debrid.selectedKind.rawValue
                if debrid.isEnabled {
                    let result = await debrid.resolvedURL(
                        for: candidate,
                        season: season,
                        episode: episode
                    )
                    if case let .success(url, filename, videoSize)? = result {
                        resolvedURL = url
                        resolvedFilename = filename ?? candidate.filename
                        resolvedVideoSize = videoSize ?? candidate.videoSize
                    } else if case .rateLimited? = result {
                        print("[NuvioTVApp] Debrid provider \(providerName) rate-limited (HTTP 429); halting candidate sweep.")
                        break
                    }
                }
                if resolvedURL == nil, TorrentSettings.isEnabled(), let infoHash = candidate.effectiveInfoHash, !infoHash.isEmpty {
                    do {
                        resolvedURL = try await TorrentEngineManager.shared.startStream(
                            infoHash: infoHash,
                            fileIdx: candidate.effectiveFileIdx,
                            trackers: candidate.sources,
                            filename: candidate.filename
                        )
                        providerName = "P2P Torrent"
                    } catch {
                        print("[NuvioTVApp] Next episode torrent stream error: \(error)")
                    }
                }
                guard let url = resolvedURL else { continue }
                if excludingURLs.contains(url.absoluteString) { continue }
                PlaybackStartupTiming.markDebridResolved(token: startupToken)
                LastStreamQualityStore.save(
                    metaId: metaIdForTags,
                    stream: candidate,
                    profileId: profileId
                )
                BingeGroupStore.save(
                    seriesId: metaIdForTags,
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
                    filename: resolvedFilename,
                    addonName: candidate.addonName,
                    videoSize: resolvedVideoSize,
                    videoHash: candidate.videoHash,
                    provider: providerName,
                    bingeGroup: candidate.bingeGroup ?? StreamQualityTags.syntheticBingeGroup(for: candidate),
                    trickplayURL: candidate.trickplayURL,
                    sourceID: candidate.id
                )
            }

            guard let urlString = candidate.directURL, let rawURL = URL(string: urlString),
                  let url = await Self.playableURL(for: rawURL) else { continue }
            PlaybackStartupTiming.markSourcePicked(stream: candidate, token: startupToken)
            LastStreamQualityStore.save(
                metaId: metaIdForTags,
                stream: candidate,
                profileId: profileId
            )
            BingeGroupStore.save(
                seriesId: metaIdForTags,
                stream: candidate,
                profileId: profileId
            )
            return PreparedNextStream(
                url: url,
                cacheFileIdentity: PlaybackCacheFileIdentity(infoHash: candidate.effectiveInfoHash, fileIndex: candidate.effectiveFileIdx),
                httpHeaders: candidate.httpHeaders ?? [:],
                subtitleLine: subtitleLine,
                subtitles: candidate.subtitles,
                streamName: candidate.name,
                streamDescription: candidate.description,
                filename: candidate.filename,
                addonName: candidate.addonName,
                videoSize: candidate.videoSize,
                videoHash: candidate.videoHash,
                provider: "Direct",
                bingeGroup: candidate.bingeGroup ?? StreamQualityTags.syntheticBingeGroup(for: candidate),
                trickplayURL: candidate.trickplayURL,
                sourceID: candidate.id
            )
        }
        return nil
    }

    /// Filters and orders sources exactly like the Details stream picker. This
    /// is applied to every progressive discovery update so the player can show
    /// the first usable source without waiting for every add-on.
    private static func displayedPlaybackSources(
        profileId: String?,
        type: String,
        streams: [NuvioStream]
    ) -> [NuvioStream] {
        let store = ProfileSettings.store(for: profileId)
        let debrid = DebridResolver(store: store)
        let cachedOnlyPreference = (store.object(forKey: SettingsKey.cachedOnlyStreams) as? Bool) ?? false
        let cachedOnly = SmartPlaybackSelector.effectiveCachedOnly(
            cachedOnlyPreference,
            contentType: type
        )
        let preserveAddonOrder = (store.object(forKey: SettingsKey.preserveAddonStreamOrder) as? Bool) ?? false
        let sortRaw = store.string(forKey: SettingsKey.streamSortOption)
        let sortOption = sortRaw.flatMap(StreamSortOption.init(rawValueOrSync:)) ?? .quality
        return StreamPickerListBuilder.displayedStreams(
            streams: streams,
            groups: [],
            selectedAddonId: nil,
            sortOption: sortOption,
            includeDebrid: debrid.isEnabled || TorrentSettings.isEnabled(),
            cachedOnly: cachedOnly,
            preserveAddonStreams: preserveAddonOrder
        )
    }

    /// Source discovery used by the in-player picker. Subtitle decoration is
    /// still completed by the shared discovery job for smart playback, but it
    /// is unrelated to selecting a stream and must not block this panel.
    private static func playbackSourcesProgressively(
        contentId: String,
        type: String,
        profileId: String?
    ) -> AsyncStream<[NuvioStream]> {
        let repository = CinemetaCatalogRepository()
        let updates = repository.streamsProgressively(
            id: contentId,
            type: type,
            finishAfterStreamResults: true
        )
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                for await streams in updates {
                    guard !Task.isCancelled else { break }
                    continuation.yield(
                        Self.displayedPlaybackSources(
                            profileId: profileId,
                            type: type,
                            streams: streams
                        )
                    )
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// A Usenet stream URL becomes the on-device engine's local URL (nil when
    /// it can't start); every other URL is returned unchanged.
    private static func playableURL(for url: URL) async -> URL? {
        guard let spec = UsenetStreamSpec(url: url) else { return url }
        do {
            return try await UsenetEngineManager.shared.startStream(spec)
        } catch {
            usenetLog.error("usenet: source not started: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Resolves one user-picked source (direct URL or debrid) for mid-playback switch.
    private static func resolveChosenStream(
        _ stream: NuvioStream,
        contentId: String,
        subtitleLine: String,
        seriesMetaId: String? = nil,
        profileId: String?,
        startupToken: UUID? = nil
    ) async -> PreparedNextStream? {
        guard stream.unavailabilityReason == nil else { return nil }
        PlaybackStartupTiming.markSourcePicked(stream: stream, token: startupToken)
        let store = ProfileSettings.store(for: profileId)
        let debrid = DebridResolver(store: store)
        let (season, episode) = seasonEpisode(fromContentId: contentId)
        let metaIdForTags = seriesMetaId ?? StreamQualityTags.seriesId(fromContentId: contentId)
        let bingeGroup = stream.bingeGroup ?? StreamQualityTags.syntheticBingeGroup(for: stream)

        if stream.isDebridResolvable {
            var resolvedURL: URL? = nil
            var resolvedFilename = stream.filename
            var resolvedVideoSize = stream.videoSize
            var providerName = debrid.selectedKind.rawValue
            if debrid.isEnabled {
                let result = await debrid.resolvedURL(
                    for: stream,
                    season: season,
                    episode: episode
                )
                if case let .success(url, filename, videoSize)? = result {
                    resolvedURL = url
                    resolvedFilename = filename ?? stream.filename
                    resolvedVideoSize = videoSize ?? stream.videoSize
                } else if case .rateLimited? = result {
                    print("[NuvioTVApp] Debrid provider \(providerName) rate-limited (HTTP 429) for stream.")
                    return nil
                }
            }
            if resolvedURL == nil, TorrentSettings.isEnabled(), let infoHash = stream.effectiveInfoHash, !infoHash.isEmpty {
                do {
                    resolvedURL = try await TorrentEngineManager.shared.startStream(
                        infoHash: infoHash,
                        fileIdx: stream.effectiveFileIdx,
                        trackers: stream.sources,
                        filename: stream.filename
                    )
                    providerName = "P2P Torrent"
                } catch {
                    print("[NuvioTVApp] Chosen torrent stream error: \(error)")
                }
            }
            guard let url = resolvedURL else { return nil }
            PlaybackStartupTiming.markDebridResolved(token: startupToken)
            LastStreamQualityStore.save(
                metaId: metaIdForTags,
                stream: stream,
                profileId: profileId
            )
            BingeGroupStore.save(
                seriesId: metaIdForTags,
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
                filename: resolvedFilename,
                addonName: stream.addonName,
                videoSize: resolvedVideoSize,
                videoHash: stream.videoHash,
                provider: providerName,
                bingeGroup: bingeGroup,
                trickplayURL: stream.trickplayURL,
                sourceID: stream.id
            )
        }

        guard let urlString = stream.directURL, let rawURL = URL(string: urlString),
              let url = await playableURL(for: rawURL) else { return nil }
        LastStreamQualityStore.save(
            metaId: metaIdForTags,
            stream: stream,
            profileId: profileId
        )
        BingeGroupStore.save(
            seriesId: metaIdForTags,
            stream: stream,
            profileId: profileId
        )
        return PreparedNextStream(
            url: url,
            cacheFileIdentity: PlaybackCacheFileIdentity(infoHash: stream.effectiveInfoHash, fileIndex: stream.effectiveFileIdx),
            httpHeaders: stream.httpHeaders ?? [:],
            subtitleLine: subtitleLine,
            subtitles: stream.subtitles,
            streamName: stream.name,
            streamDescription: stream.description,
            filename: stream.filename,
            addonName: stream.addonName,
            videoSize: stream.videoSize,
            videoHash: stream.videoHash,
            provider: "Direct",
            bingeGroup: bingeGroup,
            trickplayURL: stream.trickplayURL,
            sourceID: stream.id
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
        resumeFrom: Double?,
        startupBenchmarkToken: UUID?
    ) -> some View {
        let isTrailer = subtitle == PlaybackMarkers.trailerSubtitle
        let isActionPlaybackSession = playbackIsActionPlaybackSession
        let isStandalonePlaybackSession = isTrailer || isActionPlaybackSession
        let store = ProfileSettings.store(for: profileViewModel.activeProfile?.id)
        let autoPlayNext = store.object(forKey: SettingsKey.autoPlayNext) as? Bool ?? true
        let autoPlayNextCountdown = store.object(forKey: SettingsKey.autoPlayNextCountdown) as? Int ?? 10
        let provenance = playbackCollectionContext
        let surfaceIdentity = playerSurfaceID
        let party = playbackPartyID.flatMap { id in
            watchPartyOwner.presentation.flatMap { $0.id == id && $0.mount.isCurrent ? $0.mount : nil }
        }
        let partyRoom = party == nil ? nil : watchPartyOwner.service?.session
        let partyIsHost = party == nil
            || (partyRoom?.memberID != nil && partyRoom?.party?.hostMemberID == partyRoom?.memberID)
        let incomingMediaCompletion: WatchPartyIncomingEpisodePlan.Completion? = {
            guard party != nil else { return nil }
            return { transitionID, context, media, episode, prepared, startupToken in
                await self.completeIncomingWatchPartyEpisode(
                    transitionID: transitionID, context: context, media: media,
                    episode: episode, prepared: prepared, startupToken: startupToken,
                    expectedSurfaceID: surfaceIdentity, meta: meta
                )
            }
        }()
        let hostEpisodeResolved: (@MainActor (NuvioVideo, PreparedNextStream) async -> Bool)? = {
            guard party != nil, partyIsHost else { return nil }
            return { episode, prepared in
                guard let party, let expectedID = playbackPartyID else { return false }
                return await self.changeWatchPartyEpisode(
                    episode, prepared: prepared, sourceViewModel: party.viewModel,
                    expectedPresentationID: expectedID, expectedSurfaceID: surfaceIdentity, meta: meta
                )
            }
        }()
        let watchPartySourceChanged: (@MainActor () async -> Void)? = {
            guard party != nil else { return nil }
            return {
                guard let room = watchPartyOwner.service?.session,
                      let roomParty = room.party,
                      roomParty.hostMemberID == room.memberID else { return }
                _ = try? await room.stopSharingStream()
            }
        }()
        if playbackPartyID == nil || party != nil {
        PlayerView(
            url: url,
            meta: meta,
            subtitle: subtitle,
            httpHeaders: httpHeaders,
            externalSubtitles: externalSubtitles,
            resumeFrom: resumeFrom,
            isActionPlaybackSession: isActionPlaybackSession,
            playbackOrigin: playbackOrigin,
            filename: isStandalonePlaybackSession ? nil : playbackFilename,
            videoSize: isStandalonePlaybackSession ? nil : playbackVideoSize,
            videoHash: isStandalonePlaybackSession ? nil : playbackVideoHash,
            cacheFileIdentity: isStandalonePlaybackSession ? nil : playbackCacheFileIdentity,
            sourceID: isStandalonePlaybackSession ? nil : playbackSourceID,
            episodes: isStandalonePlaybackSession ? [] : playbackEpisodes,
            currentEpisode: isStandalonePlaybackSession ? nil : playbackCurrentEpisode,
            initialStartupBenchmarkToken: startupBenchmarkToken,
            autoPlayNextEnabled: party == nil && autoPlayNext,
            autoPlayNextCountdownSeconds: autoPlayNextCountdown,
            allowsManualEpisodeSelection: party == nil || partyIsHost,
            resolveNextStream: (isStandalonePlaybackSession || !meta.isSeries) ? nil : { episode, startupToken in
                await Self.resolveNextEpisodeStream(
                    episode: episode,
                    seriesMeta: meta,
                    profileId: profileViewModel.activeProfile?.id,
                    startupToken: startupToken
                )
            },
            reloadCurrentStream: (isStandalonePlaybackSession || party != nil) ? nil : { currentEpisode, excludedURLs in
                let profileId = profileViewModel.activeProfile?.id
                let excluded = Set(excludedURLs)
                if let episode = currentEpisode {
                    let streamId = meta.canonicalEpisodeStreamId(for: episode)
                    return await Self.resolveStream(
                        contentId: streamId,
                        type: "series",
                        subtitleLine: "S\(episode.season) · E\(episode.episode) · \(episode.title)",
                        profileId: profileId,
                        excludingURLs: excluded,
                        seriesMetaId: meta.id,
                        forceRefresh: true,
                        startupToken: nil
                    )
                }
                return await Self.resolveStream(
                    contentId: meta.id,
                    type: meta.type,
                    subtitleLine: subtitle,
                    profileId: profileId,
                    excludingURLs: excluded,
                    seriesMetaId: meta.isSeries ? meta.id : nil,
                    forceRefresh: true,
                    startupToken: nil
                )
            },
            fetchPlaybackSources: isStandalonePlaybackSession ? nil : { contentId, type in
                Self.playbackSourcesProgressively(
                    contentId: contentId,
                    type: type,
                    profileId: profileViewModel.activeProfile?.id
                )
            },
            resolvePlaybackStream: isStandalonePlaybackSession ? nil : { stream, contentId, subtitleLine, startupToken in
                await Self.resolveChosenStream(
                    stream,
                    contentId: contentId,
                    subtitleLine: subtitleLine,
                    seriesMetaId: meta.isSeries ? meta.id : nil,
                    profileId: profileViewModel.activeProfile?.id,
                    startupToken: startupToken
                )
            },
            onWatchPartyIncomingMediaResolved: incomingMediaCompletion,
            onWatchPartyEpisodeResolved: hostEpisodeResolved,
            onWatchPartySourceChanged: watchPartySourceChanged,
            onRequestSources: (isStandalonePlaybackSession || party != nil) ? nil : {
                withAnimation(.easeInOut(duration: 0.28)) {
                    reopenStreamPickerOnDetails = true
                    reopenStreamPickerEpisode = playbackCurrentEpisode
                    openDetailsRoot(
                        id: meta.id,
                        type: meta.type,
                        collectionContext: provenance,
                        libraryWatchedContext: playbackLibraryWatchedContext
                    )
                }
            },
            onFinished: isActionPlaybackSession ? {
                dismissPlayer(meta: meta, subtitle: subtitle)
            } : (isTrailer ? {
                withAnimation(.easeInOut(duration: 0.24)) {
                    activeScreen = .details(id: meta.id, type: meta.type)
                }
            } : nil),
            onPlaybackStarted: {
                playbackDidStart = true
                if !isStandalonePlaybackSession, let provenance,
                   ProfileSettings.activeProfileID == provenance.profileID {
                    CollectionPlaybackOriginStore.recordStarted(
                        meta: meta, context: provenance,
                        activeProfileID: profileViewModel.activeProfile?.id
                    )
                }
            },
            onPlayRecommendation: (isStandalonePlaybackSession || party != nil) ? nil : { recMeta, playManually in
                dismissPlayer(meta: meta, subtitle: subtitle)
                playRecommendedTitle(meta: recMeta, playManually: playManually)
            },
            onOpenRecommendationDetails: (isStandalonePlaybackSession || party != nil) ? nil : { recMeta in
                dismissPlayer(meta: meta, subtitle: subtitle)
                withAnimation(.easeInOut(duration: 0.28)) {
                    openDetailsRoot(id: recMeta.id, type: recMeta.type)
                }
            },
            partyPlayback: party,
            partyPlaybackIdentity: playbackPartyID,
            watchPartyOwner: watchPartyOwner,
            isCurrentPlayerSurface: {
                self.activeScreen.isPlayer
                    && self.playerSurfaceID == surfaceIdentity
                    && UIApplication.shared.applicationState == .active
            },
            onOpenWatchPartyLobby: {
                guard WatchPartyConfiguration.isEnabled, party == nil else { return }
                selectedTab = .party
                activeScreen = .main
            },
            onBack: { dismissPlayer(meta: meta, subtitle: subtitle) }
        )
        .id(playerSurfaceID.uuidString)
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
                    httpHeaders: prepared.httpHeaders,
                    filename: prepared.filename,
                    videoSize: prepared.videoSize,
                    videoHash: prepared.videoHash,
                    sourceID: prepared.sourceID
                )
            } else {
                withAnimation(.easeInOut(duration: 0.28)) {
                    openDetailsRoot(id: meta.id, type: meta.type)
                }
            }
        }
    }

    private func dismissPlayer(meta: NuvioMeta, subtitle: String) {
        if playbackPartyID != nil {
            let pip = PictureInPictureManager.shared
            let keepsPiP = watchPartyOwner.owns(pip.activeCoordinator)
                && (pip.isPictureInPictureActive || pip.isRestoringUIInProgress)
            if !keepsPiP { watchPartyOwner.finishPlayback(); playbackPartyID = nil }
            selectedTab = WatchPartyConfiguration.isEnabled ? .party : .home
            activeScreen = .main
            return
        }
        let isTrailer = subtitle == PlaybackMarkers.trailerSubtitle
        let isActionPlaybackSession = playbackIsActionPlaybackSession
        withAnimation(.easeInOut(duration: 0.24)) {
            switch playbackOrigin {
            case .details:
                // A stream that never reached playback should return to the
                // exact decision point so another source is one click away.
                reopenStreamPickerOnDetails = isActionPlaybackSession || (!playbackDidStart && !isTrailer)
                reopenStreamPickerEpisode = reopenStreamPickerOnDetails ? playbackCurrentEpisode : nil
                activeScreen = .details(id: meta.id, type: meta.type)
            case .cloudLibrary:
                detailsLibraryWatchedContext = nil
                activeScreen = .cloudLibrary
            case .main:
                detailsLibraryWatchedContext = nil
                activeScreen = (isTrailer || isActionPlaybackSession || meta.isSeries)
                    ? .details(id: meta.id, type: meta.type)
                    : .main
            }
            playbackLibraryWatchedContext = nil
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

            Text(L10n.string("account_sync_loading", fallback: "Syncing your account"))
                .font(.custom("Inter-Bold", size: 44))
                .foregroundColor(.white)

            Text(L10n.string(
                "account_sync_loading_subtitle",
                fallback: "Hang tight while we import your profiles and watch history."
            ))
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
        // Read the displayed state outside the GeometryReader so the body
        // depends on it. Reads that only happen inside the reader's content
        // closure did not re-render when a load finished, so the new image
        // only appeared on the next focus change (one title late).
        let currentImage = image
        let currentOutgoingImage = outgoingImage
        let currentImageOpacity = imageOpacity
        let currentOutgoingOpacity = outgoingOpacity
        let currentLoadedURL = loadedURL
        return GeometryReader { proxy in
            ZStack {
                placeholder
                if let currentOutgoingImage {
                    backdropImage(currentOutgoingImage, size: proxy.size)
                        .opacity(currentOutgoingOpacity)
                }
                if let currentImage {
                    backdropImage(currentImage, size: proxy.size)
                        .opacity(currentImageOpacity)
                        .id(currentLoadedURL)
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
/// A lock-protected class rather than an actor, so a view can read an image
/// that is already decoded synchronously when it is created (rating icons are
/// then drawn on the first frame instead of popping in after an actor hop).
final class BackdropImageCache: @unchecked Sendable {
    static let shared = BackdropImageCache()
    private static let tracker = NSCacheMemoryTracker(
        maxCost: {
            let gib = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
            if gib > 3.5 {
                return 96 * 1024 * 1024 // 96 MB (Apple TV 4K Gen 2/3)
            } else if gib > 2.5 {
                return 64 * 1024 * 1024 // 64 MB (Apple TV 4K Gen 1)
            } else {
                return 40 * 1024 * 1024 // 40 MB (Apple TV HD)
            }
        }()
    )

    static func telemetryMetrics() -> (count: Int, totalBytes: Int, maxCost: Int) {
        tracker.metrics()
    }

    private let cache = NSCache<NSString, UIImage>()
    private let lock = NSLock()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    init() {
        cache.totalCostLimit = Self.tracker.maxCost
        cache.delegate = Self.tracker
        #if canImport(UIKit)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { _ in
            BackdropImageCache.shared.purge()
        }
        #endif
    }

    private static let maxPixelSize: CGFloat = 1920.0

    func purge() {
        cache.removeAllObjects()
        Self.tracker.reset()
    }

    /// The decoded image when it is already in memory. Never downloads.
    func cachedImage(for url: URL) -> UIImage? {
        cache.object(forKey: url.absoluteString as NSString)
    }

    /// `minimumBytes` rejects error pages posing as artwork; small rating
    /// icons pass 0. Non-HTTP responses (`data:` icon URLs) are accepted.
    func image(
        for url: URL,
        priority: TaskPriority = .userInitiated,
        minimumBytes: Int = 512
    ) async -> UIImage? {
        let key = url.absoluteString
        if let cached = cache.object(forKey: key as NSString) { return cached }
        let pixelSize = Self.maxPixelSize
        let task: Task<UIImage?, Never> = lock.withLock {
            if let pending = inFlight[key] { return pending }
            let task = Task.detached(priority: priority) { [weak self] () -> UIImage? in
                var decoded: UIImage?
                if let (data, response) = try? await URLSession.shared.data(from: url) {
                    let statusOK = (response as? HTTPURLResponse).map { (200...299).contains($0.statusCode) } ?? true
                    if statusOK, data.count > minimumBytes {
                        decoded = downsampleBackdropImage(data: data, maxPixelSize: pixelSize)
                    }
                }
                // Store before leaving the in-flight list, so a caller arriving
                // in between finds the image instead of downloading it again.
                self?.finishLoad(key: key, image: decoded)
                return decoded
            }
            inFlight[key] = task
            return task
        }
        return await task.value
    }

    private func finishLoad(key: String, image: UIImage?) {
        if let image {
            let cost = image.decodedByteCost
            cache.setObject(image, forKey: key as NSString, cost: cost)
            Self.tracker.recordInsertion(cost: cost)
        }
        lock.withLock { inFlight[key] = nil }
    }
}

private func downsampleBackdropImage(data: Data, maxPixelSize: CGFloat) -> UIImage? {
    TVHomeDebugTrace.measure("backdrop.downsampleBackdropImage dataBytes=\(data.count)", thresholdMs: 150.0) {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else {
            return nil
        }
        guard CGImageSourceGetCount(source) > 0,
              CGImageSourceGetType(source) != nil else {
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
            TVHomeDebugTrace.log("backdrop.downsample failed for dataBytes=\(data.count) maxPixelSize=\(Int(ceil(maxPixelSize)))")
            return nil
        }
        return UIImage(cgImage: image)
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

private struct TVMainTabView: View {
    @Binding var selectedTab: TVTab
    let activeProfile: Profile?
    @ObservedObject var searchViewModel: SearchViewModel
    @ObservedObject var netflixSearchViewModel: NetflixSearchViewModel
    @ObservedObject var libraryViewModel: LibraryViewModel
    @ObservedObject var homeStore: TVHomeStore
    let homeCatalogRevision: UInt
    let homeCollectionsRevision: UInt
    let isFullScreenOverlayPresented: Bool
    let detailsDidDisappearGeneration: UInt
    let accountEmail: String?
    let isAuthenticated: Bool
    let sessionNeedsReauthentication: Bool
    let isProfileFocusPending: Bool
    let profileGateGeneration: UInt
    let onProfileGateReadinessChange: (TVHomeContentIdentity, UInt, TVProfileGateReadiness) -> Void
    let authManager: AuthManager
    let syncManager: NuvioSyncManager
    @ObservedObject var watchPartyOwner: WatchPartyAppOwner
    var partyDetailsMedia: WatchPartyMedia? = nil
    var onPartyRoomExited: (WatchPartyPlaybackContext) -> Void = { _ in }
    let onCreateParty: () -> Void
    let onChoosePartySource: (WatchPartyMedia) -> Void
    var onChoosePartySharedSource: (WatchPartyStream) -> Void = { _ in }
    let partyIsChoosing: Bool
    let onCancelPartySelection: () -> Void
    let onSwitchProfile: () -> Void
    let onChangeProfileAvatar: (String, String) -> Void
    let onChangeProfileName: (String, String) -> Void
    let onChangeProfilePin: (String, String?, String?) async -> Bool
    let onVerifyProfilePin: (String, String) async -> Bool
    let onSignIn: () -> Void
    let onSignOut: () -> Void
    let onNavigateToDetails: (String, String) -> Void
    var onNavigateToLibraryDetails: ((String, String, LibraryWatchedContext) -> Void)? = nil
    let onPlayTitle: (String, String) -> Void
    let onRequestAccountRefresh: (Bool) -> Void
    let onOpenCollectionFolder: (TVCollectionFolderItem, String) -> Void
    let onResumePlayback: (ContinueWatchingItem) -> Void
    var onNavigateToContinueWatchingDetails: ((String, String) -> Void)? = nil
    var onPlayContinueWatchingManually: ((ContinueWatchingItem) -> Void)? = nil
    var onStartContinueWatchingFromBeginning: ((ContinueWatchingItem) -> Void)? = nil
    var onRemoveFromContinueWatching: ((ContinueWatchingItem) -> Void)? = nil
    let onLongPressCard: (NuvioMeta) -> Void
    /// Long press on a Continue Watching card, which gets its own resume-centric
    /// menu instead of the generic title actions.
    let onLongPressContinueWatching: (ContinueWatchingItem) -> Void
    let onOpenCloudLibrary: () -> Void
    let onPlayCloudFile: (URL, NuvioMeta) -> Void
    var onOpenCalendarEntry: ((CalendarEntry) -> Void)? = nil
    @AppStorage(SettingsKey.amoled) private var amoled = false
    @AppStorage(SettingsKey.bodyColor) private var bodyColor = SettingsBackground.charcoal.rawValue
    @AppStorage(SettingsKey.discoverLocation) private var discoverLocation = "Search"
    @AppStorage(SettingsKey.showCalendarTab) private var showCalendarTab = true
    @AppStorage(SettingsKey.searchStyle) private var searchStyle = "Netflix"
    @AppStorage("nuvio.keyboard.detectedLayout") private var detectedKeyboardMode: TVOSKeyboardLayoutMode = .linear
    @AppStorage(SettingsKey.profileName) private var settingsProfileName = "Nuvio User"
    @State private var collectionDestinations: [CollectionHomeDestination] = []
    @State private var directCollectionDestinations: [CollectionHomeDestination] = []
    @State private var genreCollectionDestinations: [CollectionHomeDestination] = []
    @StateObject private var collectionSidebarArtwork = CollectionSidebarArtwork()
    @StateObject private var profileTabAvatar = ProfileTabAvatarRenderer()
    @State private var showingReauthSheet = false

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
        Group {
            if #available(tvOS 18.0, *) {
                tabs
                    .tabViewStyle(.sidebarAdaptable)
            } else {
                tabs
            }
        }
        .onChange(of: showCalendarTab) { _, isShown in
            if !isShown, selectedTab == .calendar { selectedTab = .home }
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
        } else if searchStyle == "Grid" {
            NativeSearchView(
                viewModel: searchViewModel,
                showDiscover: discoverLocation == "Search",
                forcedLayoutMode: .grid,
                isFullScreenOverlayPresented: isFullScreenOverlayPresented,
                detailsDidDisappearGeneration: detailsDidDisappearGeneration,
                onContentClick: onNavigateToDetails,
                onLongPress: onLongPressCard
            )
        } else if searchStyle == "Native" {
            NativeSearchView(
                viewModel: searchViewModel,
                showDiscover: discoverLocation == "Search",
                forcedLayoutMode: detectedKeyboardMode == .grid ? .grid : .linear,
                isFullScreenOverlayPresented: isFullScreenOverlayPresented,
                detailsDidDisappearGeneration: detailsDidDisappearGeneration,
                onContentClick: onNavigateToDetails,
                onLongPress: onLongPressCard
            )
        } else {
            NetflixSearchView(
                viewModel: netflixSearchViewModel,
                showDiscover: discoverLocation == "Search",
                isFullScreenOverlayPresented: isFullScreenOverlayPresented,
                detailsDidDisappearGeneration: detailsDidDisappearGeneration,
                onContentClick: onNavigateToDetails,
                onLongPress: onLongPressCard
            )
        }
    }

    private func collectionTabTitle(_ destination: CollectionHomeDestination) -> String {
        let duplicates = collectionDestinations.filter {
            $0.sidebarTitle.caseInsensitiveCompare(destination.sidebarTitle) == .orderedSame
        }.count
        return duplicates > 1
            ? "\(destination.sidebarTitle) • \(destination.collectionTitle)"
            : destination.sidebarTitle
    }

    private func refreshCollectionDestinations() {
        collectionDestinations = CollectionHomeDestination.configured(
            profileID: activeProfile?.id ?? "none"
        )
        directCollectionDestinations = collectionDestinations.filter { !$0.isGenreDestination }
        genreCollectionDestinations = collectionDestinations.filter(\.isGenreDestination)
        if case .collection(let id) = selectedTab,
           !collectionDestinations.contains(where: { $0.id == id }) {
            selectedTab = .home
        }
    }

    private var profileTabLabel: some View {
        Label {
            Text(profileTabTitle)
        } icon: {
            if sessionNeedsReauthentication {
                Image(systemName: "person.crop.circle.badge.exclamationmark")
            } else if let avatar = profileTabAvatar.image {
                Image(uiImage: avatar).renderingMode(.original)
            } else {
                Image(systemName: ProfileAvatarCatalog.symbolName(for: displayedProfile?.avatarId))
            }
        }
    }

    private var homeTabContent: some View {
        TVHomeView(
            store: homeStore,
            repository: CinemetaCatalogRepository(),
            isActive: selectedTab == .home,
            isFullScreenOverlayPresented: isFullScreenOverlayPresented,
            detailsDidDisappearGeneration: detailsDidDisappearGeneration,
            isProfileFocusPending: isProfileFocusPending,
            profileGateGeneration: profileGateGeneration,
            onProfileGateReadinessChange: onProfileGateReadinessChange,
            contentIdentity: TVHomeContentIdentity(
                profileId: activeProfile?.id ?? "none",
                catalogRevision: homeCatalogRevision
            ),
            collectionsRevision: homeCollectionsRevision,
            sessionNeedsReauthentication: sessionNeedsReauthentication,
            onNavigateToDetails: onNavigateToDetails,
            onPlayTitle: onPlayTitle,
            onOpenCollectionFolder: onOpenCollectionFolder,
            onResumePlayback: onResumePlayback,
            onNavigateToContinueWatchingDetails: onNavigateToContinueWatchingDetails,
            onPlayContinueWatchingManually: onPlayContinueWatchingManually,
            onStartContinueWatchingFromBeginning: onStartContinueWatchingFromBeginning,
            onRemoveFromContinueWatching: onRemoveFromContinueWatching,
            onLongPressCard: onLongPressCard,
            onLongPressContinueWatching: onLongPressContinueWatching,
            onRequestAccountRefresh: onRequestAccountRefresh,
            onRequestReauth: { showingReauthSheet = true },
            onOpenCalendarEntry: onOpenCalendarEntry
        )
            .id(activeProfile?.id ?? "none")
    }

    private var libraryTabContent: some View {
        LibraryView(
            viewModel: libraryViewModel,
            store: ProfileSettings.store(for: activeProfile?.id),
            onContentClick: onNavigateToDetails,
            onLibraryContentClick: { contentId, contentType, watchedContext in
                if let onNavigateToLibraryDetails {
                    onNavigateToLibraryDetails(contentId, contentType, watchedContext)
                } else {
                    withAnimation(.easeInOut(duration: 0.28)) {
                        onNavigateToDetails(contentId, contentType)
                    }
                }
            },
            onLongPress: onLongPressCard,
            onOpenCloudLibrary: onOpenCloudLibrary,
            onPlayCloudFile: onPlayCloudFile
        )
            .id(activeProfile?.id ?? "none")
    }

    private var calendarTabContent: some View {
        CalendarView(
            onOpenEntry: { entry in onOpenCalendarEntry?(entry) },
            onOpenSettings: { selectedTab = .settings }
        )
            .id(activeProfile?.id ?? "none")
    }

    private var settingsTabContent: some View {
        SettingsView(
            activeProfile: displayedProfile,
            accountEmail: accountEmail,
            isAuthenticated: isAuthenticated,
            sessionNeedsReauthentication: sessionNeedsReauthentication,
            onChangeProfileName: onChangeProfileName,
            onChangeProfileAvatar: onChangeProfileAvatar,
            onChangeProfilePin: onChangeProfilePin,
            onVerifyProfilePin: onVerifyProfilePin,
            onSignIn: {
                if sessionNeedsReauthentication {
                    showingReauthSheet = true
                } else {
                    onSignIn()
                }
            },
            onSignOut: onSignOut
        )
    }

    private func collectionTabContent(_ destination: CollectionHomeDestination) -> some View {
        CollectionHomeTab(
            destination: destination,
            catalogRevision: homeCatalogRevision,
            isActive: selectedTab == .collection(destination.id),
            isFullScreenOverlayPresented: isFullScreenOverlayPresented,
            detailsDidDisappearGeneration: detailsDidDisappearGeneration,
            collectionArtwork: collectionSidebarArtwork.images[destination.id],
            onNavigateToDetails: onNavigateToDetails,
            onPlayTitle: onPlayTitle,
            onLongPressCard: onLongPressCard
        )
        .id(destination.revision)
    }

    private func collectionTabLabel(_ destination: CollectionHomeDestination) -> some View {
        Label {
            Text(collectionTabTitle(destination))
        } icon: {
            if let image = collectionSidebarArtwork.images[destination.id] {
                Image(uiImage: image).renderingMode(.original)
            } else {
                Image(systemName: "rectangle.stack")
            }
        }
    }

    private var settingsTabLabel: some View {
        Label(
            TVTab.settings.title,
            systemImage: sessionNeedsReauthentication ? "exclamationmark.circle" : TVTab.settings.symbol
        )
    }

    // Compatibility shell for systems predating native tab sections.
    private var standardTabs: some View {
        TabView(selection: $selectedTab) {
            Color.clear.tabItem { profileTabLabel }.tag(TVTab.profile)
            homeTabContent
                .tabItem { Label(TVTab.home.title, systemImage: TVTab.home.symbol) }
                .tag(TVTab.home)
            if WatchPartyConfiguration.isEnabled {
                partyTabContent
                    .tabItem { Label(TVTab.party.title, systemImage: TVTab.party.symbol) }
                    .tag(TVTab.party)
            }
            searchTab
                .tabItem { Label(TVTab.search.title, systemImage: TVTab.search.symbol) }
                .tag(TVTab.search)
            libraryTabContent
                .tabItem { Label(TVTab.library.title, systemImage: TVTab.library.symbol) }
                .tag(TVTab.library)
            if showCalendarTab {
                calendarTabContent
                    .tabItem { Label(TVTab.calendar.title, systemImage: TVTab.calendar.symbol) }
                    .tag(TVTab.calendar)
            }
            settingsTabContent.tabItem { settingsTabLabel }.tag(TVTab.settings)
        }
    }

    @ViewBuilder
    private var partyTabContent: some View {
        if let service = watchPartyOwner.service {
            WatchPartyLobbyView(owner: watchPartyOwner, service: service,
                onChooseSharedSource: onChoosePartySharedSource,
                onReturnToPlayer: { PictureInPictureManager.shared.restoreFullscreenFromApp() },
                canUseAccount: isAuthenticated && !sessionNeedsReauthentication && activeProfile != nil,
                isChoosing: partyIsChoosing, onCreate: onCreateParty,
                onChooseSource: onChoosePartySource, onCancelSelection: onCancelPartySelection,
                onOpenProfile: {
                    if !isAuthenticated || sessionNeedsReauthentication {
                        onSignIn()
                    } else {
                        onSwitchProfile()
                    }
                },
                detailsMedia: partyDetailsMedia, onRoomExited: onPartyRoomExited)
        } else {
            Text("Sign in and choose a profile to use Watch Party.")
        }
    }

    @available(tvOS 18.0, *)
    private var groupedCollectionTabs: some View {
        TabView(selection: $selectedTab) {
            if #unavailable(tvOS 27.0) {
                Tab(value: TVTab.profile) { Color.clear } label: { profileTabLabel }
            }
            Tab(TVTab.home.title, systemImage: TVTab.home.symbol, value: TVTab.home) {
                homeTabContent
            }
            if WatchPartyConfiguration.isEnabled {
                Tab(TVTab.party.title, systemImage: TVTab.party.symbol, value: TVTab.party) {
                    partyTabContent
                }
            }
            Tab(TVTab.search.title, systemImage: TVTab.search.symbol, value: TVTab.search) {
                searchTab
            }
            Tab(TVTab.library.title, systemImage: TVTab.library.symbol, value: TVTab.library) {
                libraryTabContent
            }
            if showCalendarTab {
                Tab(TVTab.calendar.title, systemImage: TVTab.calendar.symbol, value: TVTab.calendar) {
                    calendarTabContent
                }
            }
            Tab(value: TVTab.settings) { settingsTabContent } label: { settingsTabLabel }
            if !directCollectionDestinations.isEmpty {
                TabSection {
                    ForEach(directCollectionDestinations) { destination in
                        Tab(value: TVTab.collection(destination.id)) {
                            collectionTabContent(destination)
                        } label: {
                            collectionTabLabel(destination)
                        }
                    }
                } header: {
                    Text(L10n.string("tmdb_collections_title", fallback: "Collections"))
                }
            }
            if !genreCollectionDestinations.isEmpty {
                if #available(tvOS 27.0, *) {
                    // tvOS supports the automatic policy, but not an explicit
                    // collapsed default. Keep the system's native behavior;
                    // header interaction still needs verification on Apple TV.
                    genreTabSection.defaultSectionExpansion(.automatic)
                } else {
                    // Earlier systems retain a usable, expanded native section.
                    genreTabSection
                }
            }
        }
    }

    @available(tvOS 18.0, *)
    private var genreTabSection: some TabContent<TVTab> {
        TabSection {
            ForEach(genreCollectionDestinations) { destination in
                Tab(value: TVTab.collection(destination.id)) {
                    collectionTabContent(destination)
                } label: {
                    collectionTabLabel(destination)
                }
            }
        } header: {
            Label(L10n.string("sidebar_genres_title", fallback: "Genres"), systemImage: "square.grid.2x2.fill")
        }
    }

    @ViewBuilder
    private var tabShell: some View {
        if #available(tvOS 27.0, *) {
            groupedCollectionTabs
                .tabViewSidebarHeader {
                    TVSidebarProfileHeader(profile: displayedProfile) {
                        guard !isProfileFocusPending else { return }
                        if selectedTab == .settings { syncManager.flushPendingPushes() }
                        onSwitchProfile()
                    }
                    .disabled(isProfileFocusPending)
                }
        } else if #available(tvOS 18.0, *) {
            groupedCollectionTabs
        } else {
            standardTabs
        }
    }

    private var tabs: some View {
        tabShell
        .background(Color.nuvioBackground(amoled: amoled, body: bodyColor).ignoresSafeArea())
        .sheet(isPresented: $showingReauthSheet) {
            ReauthSheet(auth: authManager) {
                syncManager.beginPostLoginSync()
            }
        }
        .onAppear {
            TVHomeDebugTrace.startWatchdogIfNeeded()
            refreshCollectionDestinations()
            AvatarCatalogStore.shared.loadIfNeeded()
            profileTabAvatar.refresh(avatarId: displayedProfile?.avatarId)
            if sessionNeedsReauthentication {
                showingReauthSheet = true
            }
        }
        .onChange(of: sessionNeedsReauthentication) { _, needsReauth in
            if needsReauth {
                showingReauthSheet = true
            }
        }
        .onChange(of: activeProfile?.id) { _, _ in refreshCollectionDestinations() }
        .task(id: collectionDestinations.map(\.revision)) {
            await collectionSidebarArtwork.load(collectionDestinations)
        }
        .onChange(of: homeCollectionsRevision) { _, _ in refreshCollectionDestinations() }
        .onReceive(NotificationCenter.default.publisher(for: CollectionsStore.changedNotification).receive(on: RunLoop.main)) { _ in
            refreshCollectionDestinations()
        }
        .onReceive(NotificationCenter.default.publisher(for: CollectionSidebarPreferences.changedNotification).receive(on: RunLoop.main)) { _ in
            refreshCollectionDestinations()
        }
        .onChange(of: displayedProfile?.avatarId) { _, newValue in
            profileTabAvatar.refresh(avatarId: newValue)
        }
        .onChange(of: selectedTab) { oldTab, tab in
            TVHomeDebugTrace.log("app.selectedTab changed from \(oldTab.rawValue) to \(tab.rawValue)")
            if oldTab == .settings {
                syncManager.flushPendingPushes()
            }
            if tab == .profile {
                if isProfileFocusPending {
                    TVHomeDebugTrace.log("app.selectedTab reset from Profile to Home because isProfileFocusPending is true")
                    selectedTab = .home
                    return
                }
                onSwitchProfile()
            }
        }
        // Re-attempt once the catalog finishes loading, since the first refresh
        // can't resolve the avatar image before then.
        .onReceive(AvatarCatalogStore.shared.$items.receive(on: RunLoop.main)) { _ in
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
        Button(action: action) {
            headerContent
        }
        .buttonStyle(PosterCardButtonStyle())
        .scaleEffect(isFocused ? 1.05 : 1.0, anchor: .leading)
        .animation(.spring(response: 0.28, dampingFraction: 0.78), value: isFocused)
        .focused($isFocused)
        .focusEffectDisabled()
    }

    private var headerContent: some View {
        HStack(spacing: 12) {
            TVSidebarAvatar(profile: profile, isFocused: isFocused)

            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                if isFocused {
                    Text(L10n.string("profile_change", fallback: "Change Profile"))
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.white.opacity(0.72))
                        .lineLimit(1)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }

            Spacer(minLength: 8)

            TVSidebarClock()
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(.white.opacity(0.68))
                .fixedSize(horizontal: true, vertical: false)
                .opacity(isFocused ? 0 : 1)
                .animation(isFocused ? .easeOut(duration: 0.12) : .easeInOut(duration: 0.25), value: isFocused)
                .accessibilityHidden(isFocused)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
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
            size: 54,
            isFocused: isFocused,
            showsFocusOutline: false
        )
        .scaleEffect(isFocused ? 1.15 : 1)
        .offset(y: isFocused ? -2 : 0)
        .shadow(color: .black.opacity(isFocused ? 0.42 : 0), radius: isFocused ? 16 : 0, x: 0, y: isFocused ? 8 : 0)
        .animation(.spring(response: 0.28, dampingFraction: 0.78), value: isFocused)
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
    struct VisibleSectionsSignature: Equatable {
        let cwVisible: Bool
        let cwCount: Int
        let cwFirstId: String?
        let upCount: Int
        let upFirstId: String?
        let localCount: Int
        let jellyfinCount: Int
        let storeRevision: UInt
        let hideUnreleased: Bool
        let cwLandscape: Bool
        let landscapePosters: Bool
        let calendarToday: [NuvioMeta]
    }
    struct CachedVisibleSections {
        let signature: VisibleSectionsSignature
        let sections: [TVHomeSection]
    }
    var cachedVisibleSections: CachedVisibleSections?
    var defersOverlayPreparation = false
    var pendingOverlayRestoreCardID: String?
    /// Remains set until the restored card's actual focus callback runs. The
    /// shared FocusState can be updated before that callback, so it cannot be
    /// used as the restore-in-progress marker by itself.
    var restoringOverlayCardID: String?
    var acknowledgedNativeOverlayFocusCardID: String?
    var restoreReleaseTask: Task<Void, Never>?
    var pendingFocusedMeta: NuvioMeta?
    var pendingFocusedFolder: TVCollectionFolderItem?
    var pendingSectionId: String?
    var focusSettleTask: Task<Void, Never>?
    var heroEnrichmentTask: Task<Void, Never>?
    var enrichedHeroMetadata: [String: NuvioMeta] = [:]
    var pendingLandscapeFocusedId: String?
    var landscapeFocusTask: Task<Void, Never>?
    var lastFocusTransitionTime: Double = 0
    var fastScrollSettleTask: Task<Void, Never>?
    /// Deferred fallback for the one direction the outer vertical ScrollView
    /// can consume before the previous lazy row is materialized.
    var upwardFocusTask: Task<Void, Never>?
    var focusedRowIndex: Int = 0

    func cancelAll() {
        cachedVisibleSections = nil
        restoreReleaseTask?.cancel()
        focusSettleTask?.cancel()
        heroEnrichmentTask?.cancel()
        landscapeFocusTask?.cancel()
        fastScrollSettleTask?.cancel()
        upwardFocusTask?.cancel()
        restoreReleaseTask = nil
        focusSettleTask = nil
        heroEnrichmentTask = nil
        landscapeFocusTask = nil
        fastScrollSettleTask = nil
        upwardFocusTask = nil
        pendingFocusedMeta = nil
        pendingFocusedFolder = nil
        pendingSectionId = nil
        pendingLandscapeFocusedId = nil
        defersOverlayPreparation = false
        pendingOverlayRestoreCardID = nil
        restoringOverlayCardID = nil
        acknowledgedNativeOverlayFocusCardID = nil
        lastFocusTransitionTime = 0
        focusedRowIndex = 0
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

#if os(tvOS)
struct TVScrollViewFocusConfigurator: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        DispatchQueue.main.async { [weak view] in
            guard let view, let scrollView = findScrollView(from: view) else { return }
            configure(scrollView)
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        DispatchQueue.main.async { [weak uiView] in
            guard let uiView, let scrollView = findScrollView(from: uiView) else { return }
            configure(scrollView)
        }
    }

    private func configure(_ scrollView: UIScrollView) {
        // Home owns the hero/row spacing and scrolls each row to an explicit top anchor.
        // Keep automatic safe-area adjustments and UIKit focus auto-scroll from shifting it during focus updates.
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.bounces = false
        scrollView.alwaysBounceVertical = false
        scrollView.alwaysBounceHorizontal = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.isScrollEnabled = false
    }

    private func findScrollView(from view: UIView) -> UIScrollView? {
        var current: UIView? = view
        while let c = current {
            if let sv = c as? UIScrollView {
                return sv
            }
            current = c.superview
        }
        return nil
    }
}
#endif

private enum TVHomeProfileFocusTarget: Equatable {
    case card(key: String, sectionID: String, sectionIndex: Int)
    case gridHero

    var signature: String {
        switch self {
        case .card(let key, let sectionID, let sectionIndex):
            return "card|\(sectionID)|\(sectionIndex)|\(key)"
        case .gridHero:
            return "gridHero"
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
    let isFullScreenOverlayPresented: Bool
    let detailsDidDisappearGeneration: UInt
    /// True while a freshly picked profile is being prepared. Keeps Home's own
    /// focus handoff coordinated with the root profile cover.
    var isProfileFocusPending: Bool = false
    var profileGateGeneration: UInt = 0
    var onProfileGateReadinessChange: (TVHomeContentIdentity, UInt, TVProfileGateReadiness) -> Void = { _, _, _ in }
    let contentIdentity: TVHomeContentIdentity
    let collectionsRevision: UInt
    var sessionNeedsReauthentication: Bool = false
    let onNavigateToDetails: (String, String) -> Void
    let onPlayTitle: (String, String) -> Void
    let onOpenCollectionFolder: (TVCollectionFolderItem, String) -> Void
    let onResumePlayback: (ContinueWatchingItem) -> Void
    var collectionHome: CollectionHomeModel? = nil
    var onNavigateToContinueWatchingDetails: ((String, String) -> Void)? = nil
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
    var onRequestAccountRefresh: (Bool) -> Void = { _ in }
    var onRequestReauth: () -> Void = {}
    /// Opens a card of the Today row on its episode.
    var onOpenCalendarEntry: ((CalendarEntry) -> Void)? = nil

    @AppStorage(SettingsKey.amoled) private var amoled = false
    @AppStorage(SettingsKey.bodyColor) private var bodyColor = SettingsBackground.charcoal.rawValue
    @AppStorage(SettingsKey.homeCalendarToday) private var homeCalendarToday = true
    @AppStorage(SettingsKey.heroEnabled) private var heroEnabled = true
    @AppStorage(SettingsKey.fullscreenHeroBackdrop) private var fullscreenHeroBackdrop = true
    @AppStorage(SettingsKey.focusedPosterBackdropEnabled) private var focusedPosterBackdropEnabled = true
    @AppStorage(SettingsKey.focusedPosterBackdropDelay) private var focusedPosterBackdropDelay = 3
    @AppStorage(SettingsKey.fastNavigation) private var fastNavigation = false
    @AppStorage(SettingsKey.hideUnreleased) private var hideUnreleased = false
    @AppStorage(SettingsKey.continueWatchingVisible) private var continueWatchingVisible = true
    @AppStorage(SettingsKey.continueWatchingSort) private var continueWatchingSort = "Default"
    @AppStorage(SettingsKey.upNextFromFurthestEpisode) private var upNextFromFurthestEpisode = true
    @AppStorage(SettingsKey.showUnairedNextUp) private var showUnairedNextUp = true
    @AppStorage(SettingsKey.smoothFocus) private var smoothFocus = true
    @AppStorage(SettingsKey.homeLayout) private var homeLayout = "Modern"
    @AppStorage(SettingsKey.gridRows) private var gridRows = TVHomeGridLayout.defaultRows
    @AppStorage(SettingsKey.heroCatalogs) private var heroCatalogsData = Data()
    @AppStorage(SettingsKey.posterLabels) private var posterLabels = false
    @AppStorage(SettingsKey.catalogAddonNames) private var catalogAddonNames = true
    @AppStorage(SettingsKey.landscapePosters) private var landscapePosters = false
    @AppStorage(SettingsKey.continueWatchingLandscape) private var continueWatchingLandscape = false
    @AppStorage(SettingsKey.tmdbEnabled) private var tmdbEnabled = false
    @AppStorage(SettingsKey.tmdbLanguage) private var tmdbLanguage = "en"
    @AppStorage(SettingsKey.tmdbFollowAppLanguage) private var tmdbFollowAppLanguage = true
    @AppStorage(SettingsKey.tmdbUseArtwork) private var tmdbUseArtwork = true
    @AppStorage(SettingsKey.tmdbUseBasicInfo) private var tmdbUseBasicInfo = true
    @AppStorage(SettingsKey.tmdbApplyToHome) private var tmdbApplyToHome = false
    @AppStorage(SettingsKey.smbLocalRowEnabled) private var smbLocalRowEnabled = true
    @AppStorage(SettingsKey.jellyfinLocalRowEnabled) private var jellyfinLocalRowEnabled = true
    @AppStorage(SettingsKey.catalogAutoRefreshInterval) private var catalogAutoRefreshInterval = "30 Minutes"
    @Environment(\.scenePhase) private var scenePhase

    @State private var isBannerDismissed = false

    @State private var localTitlesSection: TVHomeSection?
    @State private var jellyfinSections: [TVHomeSection] = []
    @State private var isLoading = true
    @State private var profileGateFailedLoadIdentity: TVHomeContentIdentity?
    @State private var focusedMeta: NuvioMeta?
    /// Collection folder currently focused on Home. When set, the hero shows
    /// emoji + folder title instead of title poster meta/description.
    @State private var focusedCollectionFolder: TVCollectionFolderItem?
    /// Row the settled focus lives in; the hero only shows Continue Watching
    /// context (episode line, time left) for cards focused in that row.
    @State private var focusedSectionId: String?
    @State private var landscapeFocusedId: String?
    @State private var lastAccountRefreshRequestedAt: Date?
    @State private var focusWork = TVHomeFocusWork()
    @State private var rowScrollStore = TVHomeRowScrollStore()
    @State private var homeReloadTask: Task<Void, Never>?
    /// Add-on/catalog settings the last completed load actually read.
    @State private var lastLoadedInputSignature: String?
    @State private var rawContinueWatchingItems: [ContinueWatchingItem] = []
    @State private var appliedContinueWatchingSort: String?
    @State private var continueWatching: [ContinueWatchingItem] = []
    @State private var upcomingItems: [ContinueWatchingItem] = []
    @State private var calendarToday = CalendarHomeToday()
    /// Derived once when Continue Watching changes. Recomputing these from the
    /// entire history inside `body` made every focus update scale with the
    /// number of loaded progress items.
    @State private var continueWatchingMetas: [NuvioMeta] = []
    @State private var upcomingMetas: [NuvioMeta] = []
    @State private var continueWatchingByMetaId: [String: ContinueWatchingItem] = [:]
    @State private var continueWatchingOrigins: [String: CollectionOriginPresentation] = [:]
    @State private var continueWatchingIndexByMetaId: [String: Int] = [:]
    @State private var continueWatchingIDs: [String] = []
    @State private var displayedProgressSource: TraktWatchProgressSource?
    @State private var continueWatchingRefreshGeneration = 0
    @State private var continueWatchingRefreshTask: Task<Void, Never>?
    @State private var traktWatchedHistorySyncTask: Task<Void, Never>?
    @State private var pendingContinueWatchingRefreshAfterOverlay = false
    @State private var lastContinueWatchingRefreshedAt: Date = .distantPast
    @State private var pendingContinueWatchingDebounceTask: Task<Void, Never>?
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
    @State private var preparedFocusLayout: String?
    @State private var pendingInitialFocusCardKey: String?
    /// Card to actively re-focus once the Details/Player overlay dismisses.
    /// Captured when the tab view gets disabled (overlay up), consumed when it
    /// is re-enabled. See `restoreOverlayFocus`.
    @State private var overlayRestoreCardID: String?
    /// Increments for every overlay presentation. Delayed focus callbacks from
    /// an older Details/Player return must never clear the next return's focus
    /// lock when the user opens the same card twice in quick succession.
    @State private var overlayRestoreGeneration = 0
    @Environment(\.isEnabled) private var isEnabled
    @State private var focusedRowIndex: Int = 0
    @State private var browsingSection: TVHomeSection?
    @State private var gridHeroIndex = 0
    @State private var didRequestInitialGridHeroFocus = false
    /// The Grid hero owns its own focus state, so `focusedCardID` goes nil while
    /// it is focused. Home still holds focus then, and arming the focus restore
    /// there would let `defaultFocus` reclaim focus the moment Menu tries to
    /// hand it to the sidebar.
    @State private var isGridHeroFocused = false
    @State private var nativeProfileFocusedCardKey: String?
    @State private var didNativeFocusGridHero = false
    @State private var gridHeroFocusRequestGeneration = 0
    /// Suppress the one focus/layout animation caused by returning to Home from
    /// another tab. Normal left/right focus animations remain enabled.
    @State private var suppressReturnFocusAnimations = false
    @State private var returnFocusAnimationGeneration = 0
    /// Fast-scroll tracking (matching Android DpadFastScrollModifier):
    /// suppresses intermediate card focus oscillations during continuous remote holding or rapid swiping.
    @State private var isFastScrolling = false
    @State private var scrollToTopGeneration = 0
    @State private var targetScrollToTopSectionId: String?

    private var activeFocusRestrictionCardID: String? {
        overlayRestoreCardID
    }

    private var tmdbHomeSettingsKey: String {
        "\(tmdbEnabled)|\(tmdbLanguage)|\(tmdbFollowAppLanguage)|\(TmdbDetailsService.preferredLanguage)|\(tmdbUseArtwork)|\(tmdbUseBasicInfo)|\(tmdbApplyToHome)"
    }
    @FocusState private var isLoadingFocusActive: Bool
    @FocusState private var focusedCardID: String?

    // Split out of `body` so the Swift 26.6 type-checker doesn't have to solve the
    // ZStack content plus all ~24 lifecycle modifiers as one expression (it times
    // out: "unable to type-check in reasonable time"). Behavior is identical: same
    // views, same modifiers, same order, just a `some View` boundary in the middle.
    @ViewBuilder private var homeBodyFirstHalf: some View {
        ZStack(alignment: .topLeading) {
            // Keep TVHomeView mounted in TabView across tab switches so that
            // tab transitions are instantaneous (0ms) and focus/scroll state is preserved.
            // 1. Bottom Layer: Crossfading Backdrop
            // When fullscreenHeroBackdrop is true: full bleed backdrop across entire screen.
            // When fullscreenHeroBackdrop is false: contained top-right hero art with soft dissolve masks.
            let backdropColor = Color.nuvioBackground(amoled: amoled, body: bodyColor)
            GeometryReader { proxy in
                if fullscreenHeroBackdrop {
                    CrossfadingBackdrop(
                        url: showsLoading || homeLayout == "Grid View" ? nil : homeBackdropURL,
                        placeholder: backdropColor,
                        alignment: focusedCollectionFolder != nil ? .topTrailing : .center
                    )
                    .equatable()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
                } else {
                    let backdropWidth = proxy.size.width * 0.65
                    let backdropHeight: CGFloat = homeLayout == "Compact" ? 440 : 560
                    ZStack(alignment: .topTrailing) {
                        backdropColor
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                        CrossfadingBackdrop(
                            url: showsLoading || homeLayout == "Grid View" ? nil : homeBackdropURL,
                            placeholder: backdropColor,
                            alignment: .topTrailing
                        )
                        .equatable()
                        .frame(width: backdropWidth, height: backdropHeight, alignment: .topTrailing)
                        .mask(
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0),
                                    .init(color: .black.opacity(0.30), location: 0.28),
                                    .init(color: .black, location: 0.65)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .mask(
                            LinearGradient(
                                stops: [
                                    .init(color: .black, location: 0),
                                    .init(color: .black, location: 0.48),
                                    .init(color: .black.opacity(0.40), location: 0.78),
                                    .init(color: .clear, location: 1.0)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .clipped()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
            }
            .ignoresSafeArea()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            // 2. Gradients overlay for backdrop blending and readability (Fullscreen mode)
            if fullscreenHeroBackdrop {
                GeometryReader { proxy in
                    LinearGradient(
                        stops: [
                            .init(color: backdropColor.opacity(0.96), location: 0),
                            .init(color: backdropColor.opacity(0.85), location: 0.22),
                            .init(color: backdropColor.opacity(0.52), location: 0.46),
                            .init(color: backdropColor.opacity(0.14), location: 0.76),
                            .init(color: .clear, location: 1)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: proxy.size.width * 0.58, height: proxy.size.height)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
            }

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
                } else if let errorMessage, profileGateStartupFocusTarget == nil {
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
                                .equatable()
                        } else if let heroMeta = visibleFocusedMeta ?? visibleHero {
                            TVHeroView(
                                meta: heroMeta,
                                continueItem: heroContinueItem(for: heroMeta)
                            ) {
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
                        let sections = visibleSections
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
                            // Keep row shells mounted for native tvOS Up/Down focus.
                            // The focused row ±2 window limits real card/artwork work.
                            ScrollViewReader { verticalScrollProxy in
                                ScrollView(.vertical, showsIndicators: false) {
                                    VStack(alignment: .leading, spacing: TVHomeLayout.sectionSpacing) {
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
                                            let isNearFocusedRow = abs(index - focusedRowIndex) <= 2
                                            if isNearFocusedRow {
                                                homeSectionRow(
                                                    index: index,
                                                    section: section,
                                                    horizontalEdgeInset: horizontalEdgeInset,
                                                    verticalScrollProxy: verticalScrollProxy
                                                )
                                            } else {
                                                Color.clear
                                                    .frame(
                                                        height: estimatedHeight(for: section),
                                                        alignment: .topLeading
                                                    )
                                                    .id(section.id)
                                                    .accessibilityHidden(true)
                                            }
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.top, TVHomeLayout.rowsTopPadding)
                                    .padding(.bottom, 80)
                                    #if os(tvOS)
                                    // Place the configurator inside the scroll content so its
                                    // ancestor is the UIScrollView that owns the row offset.
                                    .background(TVScrollViewFocusConfigurator())
                                    #endif
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
                                    .onChange(of: isActive) { _, active in
                                        if active {
                                            prepareInitialFocusViewport(
                                                for: sections,
                                                using: verticalScrollProxy
                                            )
                                        }
                                    }
                                    .task(id: profileGateFocusRequestSignature) {
                                        await maintainProfileGateFocus(
                                            for: sections,
                                            using: verticalScrollProxy
                                        )
                                    }
                                    .onChange(of: scrollToTopGeneration) { _, _ in
                                        let animation = (isFastScrolling || fastNavigation)
                                            ? TVHomeLayout.fastVerticalScrollAnimation
                                            : TVHomeLayout.verticalScrollAnimation
                                        withAnimation(animation) {
                                            let targetId = targetScrollToTopSectionId ?? firstFocusableSectionId
                                            if let targetId {
                                                verticalScrollProxy.scrollTo(targetId, anchor: .top)
                                            }
                                        }
                                    }
                                    .onChange(of: overlayRestoreGeneration) { _, generation in
                                        guard let target = overlayRestoreCardID,
                                              isActive,
                                              !isFullScreenOverlayPresented,
                                              let sectionID = visibleSections
                                                .filter({ target.hasPrefix("\($0.id)\u{1}") })
                                                .max(by: { $0.id.count < $1.id.count })?.id
                                        else { return }
                                        var transaction = Transaction(animation: nil)
                                        transaction.disablesAnimations = true
                                        withTransaction(transaction) {
                                            verticalScrollProxy.scrollTo(sectionID, anchor: .top)
                                        }
                                        DispatchQueue.main.async {
                                            guard overlayRestoreGeneration == generation,
                                                  isActive,
                                                  !isFullScreenOverlayPresented,
                                                  visibleSections.contains(where: { $0.id == sectionID })
                                            else { return }
                                            var asyncTransaction = Transaction(animation: nil)
                                            asyncTransaction.disablesAnimations = true
                                            withTransaction(asyncTransaction) {
                                                verticalScrollProxy.scrollTo(sectionID, anchor: .top)
                                            }
                                        }
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
                    .focusSection()
                    .defaultFocusIfAvailable($focusedCardID, initialDefaultFocusCardID)
                }
            }
            // Ignore the bottom safe-area inset too, so the scrolling rows window
            // runs to the screen's bottom edge instead of stopping short and
            // leaving a black bar below the lowest visible row.
            .ignoresSafeArea(.container, edges: [.top, .bottom])

            if let report = simklLoadingDebugInfo, !report.isEmpty {
                SimklHomeLoadingDebugReport(report: report)
                    .frame(maxWidth: 920)
                    .padding(.horizontal, 48)
                    .padding(.top, 48)
                    .zIndex(20)
                    .allowsHitTesting(false)
            }
        }
        .task(id: "\(contentIdentity.profileId):\(contentIdentity.catalogRevision):\(tmdbHomeSettingsKey):\(collectionHome == nil || isActive)") {
            guard collectionHome == nil || isActive else { return }
            focusWork.heroEnrichmentTask?.cancel()
            focusWork.enrichedHeroMetadata.removeAll()
            let isLoaded = store.isLoaded(for: contentIdentity)
            let inputsChanged = repository.homeCatalogInputSignature != lastLoadedInputSignature
            await loadWithAutomaticRetry(for: contentIdentity, forceReload: !isLoaded || inputsChanged)
            if !isLoaded, collectionHome == nil {
                // Add-on metadata providers are configured by the time Home has
                // loaded, so this is the pass that recovers titles an earlier sync
                // could not resolve. Mirrors the phone's
                // `retryMetadataResolutionWhenAddonMetaProvidersReady`.
                ContinueWatchingBuilder.scheduleRebuild(reason: "home loaded")
                await ContinueWatchingStore.refreshMissingEpisodeDetails()
            }
        }
        .task(id: "\(contentIdentity.profileId):\(collectionsRevision)") {
            await refreshCollectionSections(for: contentIdentity)
        }
        .task(id: "\(contentIdentity.profileId):smbLocalTitles:\(smbLocalRowEnabled)") {
            await loadLocalTitlesSection()
        }
        .onReceive(NotificationCenter.default.publisher(for: SMBLibraryIndex.changedNotification).receive(on: RunLoop.main)) { _ in
            guard isActive && !isFullScreenOverlayPresented else { return }
            Task { await loadLocalTitlesSection() }
        }
        .task(id: "\(contentIdentity.profileId):jellyfinTitles:\(jellyfinLocalRowEnabled)") {
            await loadJellyfinSection()
        }
        .onReceive(NotificationCenter.default.publisher(for: JellyfinLibraryIndex.changedNotification).receive(on: RunLoop.main)) { _ in
            guard isActive && !isFullScreenOverlayPresented else { return }
            Task { await loadJellyfinSection() }
        }
        .modifier(CalendarTodayHomeFeed(
            enabled: homeCalendarToday && collectionHome == nil,
            homeReady: store.hasLoaded,
            isActive: isActive && !isFullScreenOverlayPresented,
            row: $calendarToday
        ))
        .onAppear {
            TVHomeDebugTrace.startWatchdogIfNeeded()
            reportProfileGateReadiness()
            // A TabView may recreate Home instead of keeping it mounted. Arm
            // before its saved focus is restored so the first layout pass is
            // already non-animated.
            if isActive {
                if let lastFocused = store.lastFocusedCardID {
                    armReturnFocusAnimationSuppression()
                    pendingInitialFocusCardKey = lastFocused
                    didRequestInitialCardFocus = false
                    didPrepareInitialFocusViewport = false
                    restoreFocusState(for: lastFocused)
                    if focusedCardID != lastFocused {
                        focusedCardID = lastFocused
                    }
                } else if focusedCardID == nil, let defaultFocus = initialDefaultFocusCardID {
                    focusedCardID = defaultFocus
                }
            }
            // Classic was never a distinct layout; collapse legacy values to Modern.
            if homeLayout == "Classic" { homeLayout = "Modern" }
            refreshContinueWatching()
            refreshWatchedTitles()
            scheduleContinueWatchingRefresh()
            scheduleTraktWatchedHistorySync()
        }
        // Home stays mounted behind Details/Player, so `onAppear` no longer
        // fires on return. Refresh the Continue Watching row whenever the store
        // changes (progress saved during playback, item finished/removed).
        .onReceive(NotificationCenter.default.publisher(for: ContinueWatchingStore.changedNotification)
            .debounce(for: .milliseconds(30), scheduler: RunLoop.main)) { _ in
            guard collectionHome == nil else { return }
            guard isActive else { return }
            if isFullScreenOverlayPresented {
                pendingContinueWatchingRefreshAfterOverlay = true
                return
            }
            refreshContinueWatching()
        }
        // A removal has to leave the row immediately, including under Trakt/Simkl
        // where the displayed list belongs to the provider and only changes on
        // the next fetch.
        .onReceive(NotificationCenter.default.publisher(for: ContinueWatchingDismissStore.changedNotification).receive(on: RunLoop.main)) { _ in
            guard collectionHome == nil else { return }
            guard isActive && !isFullScreenOverlayPresented else { return }
            let all = continueWatching + upcomingItems
            let remaining = all.filter { !ContinueWatchingDismissStore.isDismissed($0) }
            if remaining.count != all.count {
                setContinueWatching(remaining)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: CollectionPlaybackOriginStore.changedNotification)
            .merge(with: NotificationCenter.default.publisher(for: CollectionsStore.changedNotification))
            .receive(on: RunLoop.main)) { _ in
            guard collectionHome == nil else { return }
            refreshContinueWatchingOrigins(rawContinueWatchingItems)
        }
        .onReceive(NotificationCenter.default.publisher(for: TraktAuthStore.changedNotification).receive(on: RunLoop.main)) { _ in
            guard isActive && !isFullScreenOverlayPresented else { return }
            scheduleContinueWatchingRefresh()
            scheduleTraktWatchedHistorySync()
        }
        .onReceive(NotificationCenter.default.publisher(for: TraktSettingsStore.continueWatchingChangedNotification).receive(on: RunLoop.main)) { _ in
            guard collectionHome == nil else { return }
            guard isActive else { return }
            if isFullScreenOverlayPresented {
                pendingContinueWatchingRefreshAfterOverlay = true
                return
            }
            scheduleContinueWatchingRefresh()
            scheduleTraktWatchedHistorySync()
        }
        // TabView can keep Home mounted while Settings is selected, so returning
        // to Home does not reliably produce another onAppear.
        .onChange(of: isActive) { oldActive, active in
            TVHomeDebugTrace.log(
                "home.isActive changed from \(oldActive) to \(active) "
                    + "(focusedCardID=\(focusedCardID ?? "nil"), "
                    + "storeLastFocused=\(store.lastFocusedCardID ?? "nil"), "
                    + "pendingInitial=\(pendingInitialFocusCardKey ?? "nil"), "
                    + "suppressAnimations=\(suppressReturnFocusAnimations))"
            )
            if active {
                // A tab switch can also toggle the environment's `isEnabled`.
                // That is not an overlay dismissal, so discard any focus lock
                // accidentally captured while Home was becoming inactive.
                if overlayRestoreCardID != nil {
                    overlayRestoreGeneration &+= 1
                    overlayRestoreCardID = nil
                    focusWork.acknowledgedNativeOverlayFocusCardID = nil
                }
                // Usually armed while leaving Home. Re-arm here as a fallback
                // for TabView implementations that recreate the selected tab.
                if !suppressReturnFocusAnimations {
                    armReturnFocusAnimationSuppression()
                }
                if let lastFocused = store.lastFocusedCardID {
                    pendingInitialFocusCardKey = lastFocused
                    didRequestInitialCardFocus = false
                    didPrepareInitialFocusViewport = false
                    restoreFocusState(for: lastFocused)
                    if focusedCardID != lastFocused {
                        focusedCardID = lastFocused
                    }
                }
                if focusedCardID != nil {
                    releaseReturnFocusAnimationSuppression()
                } else {
                    // Fallback release: returning from Settings finds focusedCardID == nil
                    // because the view tree was unmounted. Ensure animation suppression and
                    // pending focus target are guaranteed to release within 0.5s even if focus
                    // restoration takes an unexpected path or lands on a different card.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        guard self.isActive else { return }
                        if let pending = self.pendingInitialFocusCardKey {
                            TVHomeDebugTrace.log("home.isActive fallback timer clearing pendingInitialFocusCardKey=\(pending)")
                            self.pendingInitialFocusCardKey = nil
                        }
                        if self.suppressReturnFocusAnimations {
                            TVHomeDebugTrace.log("home.isActive fallback timer releasing animation suppression")
                            self.releaseReturnFocusAnimationSuppression()
                        }
                    }
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
                collectionHome?.cancel()
                // Details and Player leave Home selected; a real tab change
                // must never carry their one-card restoration lock back Home.
                overlayRestoreGeneration &+= 1
                overlayRestoreCardID = nil
                focusWork.acknowledgedNativeOverlayFocusCardID = nil
                // Screen-scoped work cancellation.
                continueWatchingRefreshTask?.cancel()
                continueWatchingRefreshTask = nil
                pendingContinueWatchingDebounceTask?.cancel()
                pendingContinueWatchingDebounceTask = nil
                continueWatchingRefreshGeneration &+= 1
            }
        }
    }

    @ViewBuilder private var homeBodySecondHalf: some View {
        homeBodyFirstHalf
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
            guard collectionHome == nil else { return }
            // Local Next Up cards are derived from the episode guide, so the
            // preference must rebuild that row rather than merely re-sort the
            // already materialized cards. Remote rows need a fresh fetch because
            // previously hidden upcoming cards are no longer in view state.
            if usesRemoteProgress {
                scheduleContinueWatchingRefresh()
            } else {
                ContinueWatchingBuilder.scheduleRebuild(reason: "unaired preference changed", delayMs: 0)
            }
        }
        .onChange(of: upNextFromFurthestEpisode) { _, _ in
            guard collectionHome == nil else { return }
            if usesRemoteProgress {
                scheduleContinueWatchingRefresh()
            } else {
                ContinueWatchingBuilder.scheduleRebuild(reason: "up next episode preference changed", delayMs: 0)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: WatchedStore.changedNotification).receive(on: RunLoop.main)) { _ in
            if collectionHome != nil {
                refreshWatchedTitles()
                return
            }
            guard isActive else { return }
            if isFullScreenOverlayPresented {
                pendingContinueWatchingRefreshAfterOverlay = true
                return
            }
            refreshWatchedTitles()
            // A watched mark can be the only history left for a completed
            // series. Rebuild the local row so a newly aired episode can seed a
            // fresh "Airs Today" card even after the old row was retired.
            if collectionHome == nil, !usesRemoteProgress {
                ContinueWatchingBuilder.scheduleRebuild(reason: "watched state changed")
            }
        }
        // Settings → Home Catalogs reorder applies to the mounted Home live.
        .onReceive(NotificationCenter.default.publisher(for: TVHomeCatalogOrder.changedNotification).receive(on: RunLoop.main)) { _ in
            if collectionHome != nil {
                guard isActive, !isFullScreenOverlayPresented else { return }
                homeReloadTask?.cancel()
                let identity = contentIdentity
                homeReloadTask = Task { @MainActor in await load(for: identity, forceReload: true) }
                return
            }
            guard isActive && !isFullScreenOverlayPresented else { return }
            let reordered = homeOrderedSections(store.sections)
            if reordered.map(\.id) != store.sections.map(\.id) {
                store.sections = reordered
            }
            if repository.homeCatalogInputSignature != lastLoadedInputSignature {
                homeReloadTask?.cancel()
                let identity = contentIdentity
                homeReloadTask = Task { @MainActor in
                    await load(for: identity, forceReload: true)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: SimklAuthStore.changedNotification).receive(on: RunLoop.main)) { _ in
            guard isActive && !isFullScreenOverlayPresented else { return }
            scheduleContinueWatchingRefresh()
            if repository.homeCatalogInputSignature != lastLoadedInputSignature {
                homeReloadTask?.cancel()
                let identity = contentIdentity
                homeReloadTask = Task { @MainActor in
                    await load(for: identity, forceReload: true)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: MdbListAuthStore.changedNotification).receive(on: RunLoop.main)) { _ in
            guard isActive && !isFullScreenOverlayPresented else { return }
            scheduleContinueWatchingRefresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: TraktSettingsStore.libraryChangedNotification).receive(on: RunLoop.main)) { _ in
            guard isActive && !isFullScreenOverlayPresented else { return }
            if SimklSettingsStore.isPlanToWatchHomeCatalogsEnabled {
                homeReloadTask?.cancel()
                let identity = contentIdentity
                homeReloadTask = Task { @MainActor in
                    await load(for: identity, forceReload: true)
                }
            }
        }
        // Individual revision changes can arrive while the initial physical-
        // device load is still in flight. Once account sync confirms that all
        // Home inputs have landed, queue one replacement load from that final
        // add-on and catalog-settings snapshot.
        .onReceive(NotificationCenter.default.publisher(for: NuvioSyncManager.homeContentSyncedNotification).receive(on: RunLoop.main)) { _ in
            TVHomeDebugTrace.log("home.received homeContentSyncedNotification isActive=\(isActive) overlayPresented=\(isFullScreenOverlayPresented)")
            guard isActive && !isFullScreenOverlayPresented else { return }
            homeReloadTask?.cancel()
            let identity = contentIdentity
            homeReloadTask = Task { @MainActor in
                await reloadHomeAfterSyncedInputs(for: identity)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AppCacheManager.didClearCacheNotification).receive(on: RunLoop.main)) { _ in
            store.reset()
            lastLoadedInputSignature = ""
            homeReloadTask?.cancel()
            guard isActive && !isFullScreenOverlayPresented else { return }
            let identity = contentIdentity
            homeReloadTask = Task { @MainActor in
                await load(for: identity, forceReload: true)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: TVHomeCatalogOrder.forceRefreshNotification).receive(on: RunLoop.main)) { _ in
            guard isActive && !isFullScreenOverlayPresented else { return }
            homeReloadTask?.cancel()
            let identity = contentIdentity
            homeReloadTask = Task { @MainActor in
                await load(for: identity, forceReload: true)
            }
        }
        .onDisappear {
            focusWork.cancelAll()
            collectionHome?.cancel()
            // The profile-focus retry is owned by a `.task(id:)` and cancels
            // automatically when this Home view leaves the hierarchy.
            homeReloadTask?.cancel()
            continueWatchingRefreshTask?.cancel()
            continueWatchingRefreshTask = nil
            traktWatchedHistorySyncTask?.cancel()
            traktWatchedHistorySyncTask = nil
            finishSimklHomeLoadingDiagnostic()
            continueWatchingRefreshGeneration &+= 1
        }
    }

    var body: some View {
        let _ = TVHomeDebugTrace.breadcrumb("home.body.render active=\(isActive) row=\(focusedRowIndex)")
        homeBodySecondHalf
        .onChange(of: isLoading) { _, loading in
            TVHomeDebugTrace.log("home.onChange(isLoading) loading=\(loading) showsLoading=\(showsLoading)")
            if loading && showsLoading {
                requestLoadingFocus()
            } else if !loading || !showsLoading {
                isLoadingFocusActive = false
            }
        }
        .onChange(of: profileGateReadiness) { _, _ in
            reportProfileGateReadiness()
        }
        .onChange(of: isProfileFocusPending) { _, switching in
            nativeProfileFocusedCardKey = nil
            didNativeFocusGridHero = false
            if switching { reportProfileGateReadiness() }
        }
        .onChange(of: profileGateGeneration) { _, _ in
            nativeProfileFocusedCardKey = nil
            didNativeFocusGridHero = false
            reportProfileGateReadiness()
        }
        .onChange(of: contentIdentity) { _, _ in
            nativeProfileFocusedCardKey = nil
            didNativeFocusGridHero = false
            reportProfileGateReadiness()
        }
        .onChange(of: isFullScreenOverlayPresented) { oldVal, isPresented in
            if oldVal && !isPresented && isActive {
                checkAndTriggerAutoRefresh()
                if pendingContinueWatchingRefreshAfterOverlay {
                    pendingContinueWatchingRefreshAfterOverlay = false
                    if usesRemoteProgress {
                        scheduleContinueWatchingRefresh()
                        scheduleTraktWatchedHistorySync()
                    } else {
                        ContinueWatchingBuilder.scheduleRebuild(reason: "full-screen overlay dismissed")
                        refreshContinueWatching()
                        refreshWatchedTitles()
                    }
                }
            }
        }
        .onChange(of: isActive) { oldVal, active in
            if !oldVal && active && !isFullScreenOverlayPresented {
                checkAndTriggerAutoRefresh()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                checkAndTriggerAutoRefresh()
                if isActive && !isFullScreenOverlayPresented {
                    if usesRemoteProgress {
                        scheduleContinueWatchingRefresh()
                        scheduleTraktWatchedHistorySync()
                    } else {
                        refreshContinueWatching()
                    }
                }
            }
        }
        .onChange(of: focusedPosterBackdropEnabled) { _, enabled in
            guard !enabled else { return }
            focusWork.pendingLandscapeFocusedId = nil
            focusWork.landscapeFocusTask?.cancel()
            landscapeFocusedId = nil
        }
        .onChange(of: focusedCardID) { oldValue, newValue in
            TVHomeDebugTrace.measure("home.focusedCardID.onChange") {
                TVHomeDebugTrace.log(
                    "home.focusedCardID changed from \(oldValue ?? "nil") to \(newValue ?? "nil") "
                        + "pendingInitial=\(pendingInitialFocusCardKey ?? "nil") "
                        + "suppressAnimations=\(suppressReturnFocusAnimations) "
                        + "lastFocused=\(store.lastFocusedCardID ?? "nil") "
                        + "didPrepareViewport=\(didPrepareInitialFocusViewport)"
                )
                if newValue == nil {
                    // A FocusState assignment can request focus, but only a
                    // native card callback below can acknowledge it.
                    nativeProfileFocusedCardKey = nil
                }
                if let newValue {
                    if let pending = pendingInitialFocusCardKey {
                        if pending == newValue {
                            TVHomeDebugTrace.log("home.focusedCardID matched pendingInitialFocusCardKey=\(pending)")
                            self.pendingInitialFocusCardKey = nil
                            self.suppressReturnFocusAnimations = false
                        } else {
                            // While waiting for pending initial focus target, ignore transient focus
                            // events during layout/viewport scroll passes.
                            TVHomeDebugTrace.log("home.focusedCardID ignoring transient focus on \(newValue) while waiting for \(pending)")
                            return
                        }
                    } else if !didPrepareInitialFocusViewport,
                              let saved = store.lastFocusedCardID,
                              saved != newValue
                    {
                        pendingInitialFocusCardKey = saved
                        return
                    }
                    store.lastFocusedCardID = newValue
                    if isActive {
                        releaseReturnFocusAnimationSuppression()
                    }
                    if isEnabled, let target = overlayRestoreCardID, newValue == target {
                        focusWork.acknowledgedNativeOverlayFocusCardID = target
                        completeOverlayFocusRestore(for: target)
                    }
                }
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
            guard !isFullScreenOverlayPresented, isActive else { return }
            if pendingContinueWatchingRefreshAfterOverlay {
                pendingContinueWatchingRefreshAfterOverlay = false
                if usesRemoteProgress {
                    scheduleContinueWatchingRefresh()
                    scheduleTraktWatchedHistorySync()
                } else {
                    refreshContinueWatching()
                    refreshWatchedTitles()
                }
            }
            let savedTarget = overlayRestoreCardID
                ?? focusWork.pendingOverlayRestoreCardID
                ?? store.lastFocusedCardID
            guard let rawTarget = savedTarget,
                  let target = validRestoreTarget(rawTarget) else { return }
            TVHomeDebugTrace.log(
                "home.details.disappeared generation=\(generation) restoring target=\(target)"
            )
            restoreFocusState(for: target)
            // Re-acquire the one-card lock instead of assigning focus directly.
            // On the first frames after Details fades out, the row has not
            // re-rendered with its restriction yet, so a bare assignment lets
            // the focus engine settle on a neighbouring card — and the restore
            // then confirms that neighbour. Details, the card menu, and the
            // player all return through this one locked path.
            armReturnFocusAnimationSuppression()
            overlayRestoreGeneration &+= 1
            overlayRestoreCardID = target
            restoreOverlayFocus(to: target, generation: overlayRestoreGeneration)
        }
        .onChange(of: focusRows) { _, _ in
            retargetMissingFocusIfNeeded()
        }
        .fullScreenCover(item: $browsingSection) { section in
            TVHomeCatalogBrowseView(
                section: section,
                repository: repository,
                watchedTitleKeys: watchedTitleKeys,
                collectionSource: collectionHome?.source(for: section.id),
                collectionProfileID: collectionHome?.destination.id.profileID,
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
        .onExitCommand(perform: canHandleExitCommand ? handleBackCommand : nil)
    }

    /// - Parameter heroBleed: Horizontal safe-area inset this grid sits inside.
    ///   The scroll view gives it back so the hero backdrop runs to the physical
    ///   screen edges; every row below re-applies it so the posters keep the
    ///   gutter the rest of Home uses.
    @ViewBuilder
    private func homeGrid(sections: [TVHomeSection], heroBleed: CGFloat) -> some View {
        let heroItems = heroEnabled ? gridHeroItems : []
        ScrollViewReader { verticalScrollProxy in
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

                    if heroEnabled && !heroItems.isEmpty {
                        TVGridHeroSlideshowView(
                            items: heroItems,
                            isPlaybackAllowed: isActive
                                && isEnabled
                                && !isFullScreenOverlayPresented
                                && browsingSection == nil
                                && !isProfileFocusPending,
                            repository: repository,
                            profileID: contentIdentity.profileId,
                            catalogRevision: contentIdentity.catalogRevision,
                            selectedIndex: $gridHeroIndex,
                            focusRequestGeneration: gridHeroFocusRequestGeneration,
                            shouldRequestInitialFocus: store.lastFocusedCardID == nil
                                && !didRequestInitialCardFocus
                                && !didRequestInitialGridHeroFocus,
                            onInitialFocusRequested: {
                                didRequestInitialGridHeroFocus = true
                                didRequestInitialCardFocus = true
                            },
                            onPlay: { selectedMeta in
                                playTitleFromHome(id: selectedMeta.id, type: selectedMeta.type)
                            },
                            backdropBleed: heroBleed,
                            onFocusChange: { isFocused in
                                isGridHeroFocused = isFocused
                                if isFocused {
                                    focusedCardID = nil
                                    focusedSectionId = nil
                                    let animation = (isFastScrolling || fastNavigation)
                                        ? TVHomeLayout.fastVerticalScrollAnimation
                                        : TVHomeLayout.verticalScrollAnimation
                                    withAnimation(animation) {
                                        verticalScrollProxy.scrollTo("home-grid-hero-top", anchor: .top)
                                    }
                                }
                                let wasHeroFocused = didNativeFocusGridHero
                                didNativeFocusGridHero = isProfileFocusPending && isFocused
                                if isProfileFocusPending && didNativeFocusGridHero != wasHeroFocused {
                                    TVHomeDebugTrace.log("home.profileGate.nativeGridHeroFocus isFocused=\(didNativeFocusGridHero)")
                                    reportProfileGateReadiness()
                                }
                            }
                        ) { selectedMeta in
                            navigateToDetailsFromHome(id: selectedMeta.id, type: selectedMeta.type)
                        }
                        .id("home-grid-hero-top")
                    }

                    ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                        if !section.collectionFolders.isEmpty {
                            TVCollectionFolderRow(
                                id: section.id,
                                title: section.title,
                                showsSectionTitle: true,
                                horizontalEdgeInset: heroBleed,
                                folders: section.collectionFolders,
                                initialScrollIndex: rowScrollStore.index(for: section.id),
                                onScrollIndexChange: { rowScrollStore.setIndex($0, for: section.id) },
                                initialFocusCardKey: initialFocusCardKey,
                                externalFocus: $focusedCardID,
                                restrictFocusToCardKey: activeFocusRestrictionCardID,
                                retainFocusAppearanceForCardKey: activeFocusRestrictionCardID,
                                suppressFocusAnimations: suppressReturnFocusAnimations,
                                onInitialFocusRequested: { didRequestInitialCardFocus = true },
                                onFocus: { folder in
                                    recordFocusTransition()
                                    let cardKey = TVHomeCardIdentity.folderKey(rowID: section.id, folder: folder)
                                    acknowledgeNativeProfileCardFocus(cardKey)
                                    acknowledgeNativeOverlayFocusRestore(for: cardKey)
                                    focusedRowIndex = index
                                    focusedSectionId = section.id
                                    focusedCardID = cardKey
                                    settleFolderFocus(folder, in: section.id)
                                },
                                onBlur: { folder in
                                    clearNativeProfileCardFocus(
                                        TVHomeCardIdentity.folderKey(rowID: section.id, folder: folder)
                                    )
                                },
                                onSelect: { folder in
                                    openCollectionFolderFromHome(
                                        folder: folder,
                                        sectionTitle: section.title,
                                        restoreCardID: TVHomeCardIdentity.folderKey(rowID: section.id, folder: folder)
                                    )
                                }
                            )
                            .id(section.id)
                        } else if section.id == TVHomeSection.continueWatchingId || section.id == TVHomeSection.upcomingId
                                    || section.id == TVHomeSection.calendarTodayId {
                            let isCalendarToday = section.id == TVHomeSection.calendarTodayId
                            TVCatalogRow(
                                id: section.id,
                                customPosterScreen: isCalendarToday ? .home : .continueWatching,
                                title: section.title,
                                addonName: section.addonName,
                                showAddonName: catalogAddonNames,
                                showsSectionTitle: true,
                                horizontalEdgeInset: heroBleed,
                                items: section.items,
                                progressByItemId: isCalendarToday ? [:] : continueWatchingByMetaId,
                                calendarLabelsByItemId: isCalendarToday ? calendarToday.labels : [:],
                                collectionOriginsByItemId: collectionHome == nil && section.id == TVHomeSection.continueWatchingId
                                    ? continueWatchingOrigins : [:],
                                watchedTitleKeys: watchedTitleKeys,
                                initialScrollIndex: rowScrollStore.index(for: section.id),
                                onScrollIndexChange: { rowScrollStore.setIndex($0, for: section.id) },
                                initialFocusCardKey: initialFocusCardKey,
                                landscapeFocusedId: nil,
                                explicitTileShape: effectiveTileShape(for: section),
                                externalFocus: $focusedCardID,
                                restrictFocusToCardKey: activeFocusRestrictionCardID,
                                retainFocusAppearanceForCardKey: activeFocusRestrictionCardID,
                                suppressFocusAnimations: suppressReturnFocusAnimations,
                                onInitialFocusRequested: { didRequestInitialCardFocus = true },
                                onFocus: { meta in
                                    recordFocusTransition()
                                    let cardKey = TVHomeCardIdentity.key(rowID: section.id, item: meta)
                                    acknowledgeNativeProfileCardFocus(cardKey)
                                    acknowledgeNativeOverlayFocusRestore(for: cardKey)
                                    focusedRowIndex = index
                                    focusedSectionId = section.id
                                    focusedCardID = cardKey
                                    settleCatalogFocus(on: meta, in: section.id)
                                },
                                onBlur: { meta in
                                    clearNativeProfileCardFocus(TVHomeCardIdentity.key(rowID: section.id, item: meta))
                                },
                                onApproachEnd: { _ in },
                                onSelect: { meta in
                                    let cardKey = TVHomeCardIdentity.key(rowID: section.id, item: meta)
                                    if isCalendarToday {
                                        openCalendarTodayCard(meta, restoreCardID: cardKey)
                                    } else if let item = continueWatchingByMetaId[meta.id] {
                                        if item.isUpNextEntry && !item.hasAired && !item.isAiringToday {
                                            navigateToDetailsFromHome(
                                                id: meta.id,
                                                type: meta.type,
                                                restoreCardID: cardKey
                                            )
                                        } else {
                                            prepareForOverlayPresentation(restoreCardID: cardKey)
                                            onResumePlayback(item)
                                        }
                                    } else {
                                        navigateToDetailsFromHome(
                                            id: meta.id,
                                            type: meta.type,
                                            restoreCardID: cardKey
                                        )
                                    }
                                },
                                onLongPress: longPressHandler(for: section.id),
                                onOpenDetails: { meta in
                                    let cardKey = TVHomeCardIdentity.key(rowID: section.id, item: meta)
                                    navigateToDetailsFromHome(
                                        id: meta.id,
                                        type: meta.type,
                                        restoreCardID: cardKey,
                                        preserveCollectionOrigin: section.id == TVHomeSection.continueWatchingId
                                    )
                                },
                                onPlayContinueWatchingManually: { item in
                                    let cardKey = TVHomeCardIdentity.key(rowID: section.id, item: item.meta)
                                    prepareForOverlayPresentation(restoreCardID: cardKey)
                                    onPlayContinueWatchingManually?(item)
                                },
                                onStartContinueWatchingFromBeginning: { item in
                                    let cardKey = TVHomeCardIdentity.key(rowID: section.id, item: item.meta)
                                    prepareForOverlayPresentation(restoreCardID: cardKey)
                                    onStartContinueWatchingFromBeginning?(item)
                                },
                                onRemoveFromContinueWatching: onRemoveFromContinueWatching,
                                onRefreshCatalog: { refreshHomeSection(sectionId: section.id) }
                            )
                            .id(section.id)
                        } else {
                            TVHomeCatalogGridSection(
                                section: section,
                                customPosterScreen: collectionHome == nil ? .home : .collections,
                                watchedTitleKeys: watchedTitleKeys,
                                initialFocusCardKey: initialFocusCardKey,
                                externalFocus: $focusedCardID,
                                restrictFocusToCardKey: activeFocusRestrictionCardID,
                                showAddonName: catalogAddonNames,
                                onInitialFocusRequested: { didRequestInitialCardFocus = true },
                                onFocus: { meta in
                                    let cardKey = TVHomeCardIdentity.key(rowID: section.id, item: meta)
                                    acknowledgeNativeProfileCardFocus(cardKey)
                                    acknowledgeNativeOverlayFocusRestore(for: cardKey)
                                    focusedRowIndex = index
                                    focusedSectionId = section.id
                                    focusedCardID = cardKey
                                    settleCatalogFocus(on: meta, in: section.id)
                                },
                                onBlur: { meta in
                                    clearNativeProfileCardFocus(TVHomeCardIdentity.key(rowID: section.id, item: meta))
                                },
                                onSelect: { meta in
                                    navigateToDetailsFromHome(
                                        id: meta.id,
                                        type: meta.type,
                                        restoreCardID: TVHomeCardIdentity.key(rowID: section.id, item: meta)
                                    )
                                },
                                onLongPress: onLongPressCard,
                                onRefreshCatalog: { refreshHomeSection(sectionId: section.id) },
                                onSeeAllFocus: {
                                    let cardKey = "\(section.id)\u{1}\(TVHomeGridLayout.seeAllID)"
                                    acknowledgeNativeProfileCardFocus(cardKey)
                                    focusedRowIndex = index
                                    focusedSectionId = section.id
                                    focusedCardID = cardKey
                                },
                                onSeeAll: { browsingSection = section }
                            )
                            .id(section.id)
                        }
                    }
                }
                // The poster grids have a narrower intrinsic width than the screen.
                // Without this, LazyVStack proposes that width to the hero too,
                // leaving an empty strip along the trailing edge.
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(
                    .top,
                    heroEnabled && !heroItems.isEmpty ? 0 : TVHomeLayout.rowsTopPadding
                )
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
                .onChange(of: isActive) { _, active in
                    if active {
                        prepareInitialFocusViewport(
                            for: sections,
                            using: verticalScrollProxy
                        )
                    }
                }
                .onChange(of: isGridHeroFocused) { wasFocused, isFocused in
                    if isFocused {
                        let animation = (isFastScrolling || fastNavigation)
                            ? TVHomeLayout.fastVerticalScrollAnimation
                            : TVHomeLayout.verticalScrollAnimation
                        withAnimation(animation) {
                            verticalScrollProxy.scrollTo("home-grid-hero-top", anchor: .top)
                        }
                    }
                }
                .task(id: profileGateFocusRequestSignature) {
                    await maintainProfileGateFocus(
                        for: sections,
                        using: verticalScrollProxy
                    )
                }
                .onChange(of: scrollToTopGeneration) { _, _ in
                    let animation = (isFastScrolling || fastNavigation)
                        ? TVHomeLayout.fastVerticalScrollAnimation
                        : TVHomeLayout.verticalScrollAnimation
                    withAnimation(animation) {
                        if heroEnabled && !heroItems.isEmpty && isGridHeroFocused {
                            verticalScrollProxy.scrollTo("home-grid-hero-top", anchor: .top)
                        } else if let targetId = targetScrollToTopSectionId ?? firstFocusableSectionId {
                            verticalScrollProxy.scrollTo(targetId, anchor: .top)
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
            // Lets the hero's backdrop paint past this scroll view's bounds. Only
            // clipping is relaxed — widening the scroll view itself would push its
            // leading edge under the collapsed sidebar, and the focus engine reads
            // that geometry when deciding where a left press should land.
            .scrollClipDisabledIfAvailable()
        }
    }

    private var focusRows: [TVHomeFocusRow] {
        visibleSections.map { section in
            let keys: [String]
            if section.isLoadingPlaceholder {
                keys = (0..<12).map {
                    TVHomeCardIdentity.placeholderKey(rowID: section.id, index: $0)
                }
            } else if !section.collectionFolders.isEmpty {
                keys = section.collectionFolders.map {
                    TVHomeCardIdentity.folderKey(rowID: section.id, folder: $0)
                }
            } else if homeLayout == "Grid View",
                      section.id != TVHomeSection.continueWatchingId,
                      section.id != TVHomeSection.upcomingId,
                      section.id != TVHomeSection.calendarTodayId {
                keys = section.items.prefix(TVHomeGridLayout.previewItemCount(rows: gridRows)).map {
                    TVHomeCardIdentity.key(rowID: section.id, item: $0)
                } + ["\(section.id)\u{1}\(TVHomeGridLayout.seeAllID)"]
            } else {
                keys = section.items.map { TVHomeCardIdentity.key(rowID: section.id, item: $0) }
            }
            return TVHomeFocusRow(id: section.id, keys: keys)
        }
    }

    private func validRestoreTarget(_ saved: String) -> String? {
        let rows = focusRows
        let row = rows.filter { saved.hasPrefix("\($0.id)\u{1}") }
            .max { $0.id.count < $1.id.count }
        return TVHomeFocusRestoration.target(
            saved: saved, rows: rows,
            preferredIndex: row.map { rowScrollStore.index(for: $0.id) } ?? 0
        )
    }

    /// Refresh saved destinations while an overlay owns focus, but request
    /// focus only after Home becomes active and the overlay has disappeared.
    private func retargetMissingFocusIfNeeded() {
        guard store.hasLoaded || !store.sections.isEmpty else { return }
        let pending = focusWork.pendingOverlayRestoreCardID
        guard let saved = pending ?? overlayRestoreCardID ?? store.lastFocusedCardID else { return }
        let target = validRestoreTarget(saved)
        guard target != saved else { return }

        store.lastFocusedCardID = target
        if pending != nil { focusWork.pendingOverlayRestoreCardID = target }
        if pendingInitialFocusCardKey != nil { pendingInitialFocusCardKey = target }
        guard isActive, isEnabled, !isFullScreenOverlayPresented,
              !focusWork.defersOverlayPreparation else { return }
        overlayRestoreGeneration &+= 1
        let wasRestoring = overlayRestoreCardID != nil
        overlayRestoreCardID = nil
        focusWork.restoringOverlayCardID = nil
        focusWork.acknowledgedNativeOverlayFocusCardID = nil
        guard let target else {
            focusedCardID = nil
            return
        }
        if wasRestoring {
            overlayRestoreCardID = target
            restoreOverlayFocus(to: target, generation: overlayRestoreGeneration)
        } else {
            focusedCardID = target
        }
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
            focusWork.acknowledgedNativeOverlayFocusCardID = nil
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
            // A locked restore may already be running for this return (the
            // Details onDisappear signal can arrive first); prefer the card it
            // resolved over a possibly stale pending target.
            let target = (overlayRestoreCardID ?? focusWork.pendingOverlayRestoreCardID ?? store.lastFocusedCardID)
                .flatMap(validRestoreTarget)
            focusWork.defersOverlayPreparation = false
            focusWork.pendingOverlayRestoreCardID = nil
            guard let target else {
                overlayRestoreGeneration &+= 1
                overlayRestoreCardID = nil
                focusWork.restoringOverlayCardID = nil
                focusWork.acknowledgedNativeOverlayFocusCardID = nil
                TVHomeDebugTrace.log("home.overlay.dismissal defersPrep with nil target")
                return
            }

            // Build the restriction only on return. Details may still be
            // finishing its opacity transition, so use the short retry window
            // instead of relying on a single onDisappear callback ordering.
            restoreFocusState(for: target)
            armReturnFocusAnimationSuppression()
            overlayRestoreGeneration &+= 1
            TVHomeDebugTrace.log("home.overlay.dismissal restoring to target=\(target) gen=\(overlayRestoreGeneration)")
            overlayRestoreCardID = target
            restoreOverlayFocus(
                to: target,
                generation: overlayRestoreGeneration
            )
        } else if let saved = overlayRestoreCardID ?? store.lastFocusedCardID {
            guard let target = validRestoreTarget(saved) else {
                overlayRestoreCardID = nil
                focusWork.restoringOverlayCardID = nil
                focusWork.acknowledgedNativeOverlayFocusCardID = nil
                return
            }
            restoreFocusState(for: target)
            overlayRestoreCardID = target
            TVHomeDebugTrace.log("home.overlay.dismissal fallback restoring to target=\(target) gen=\(overlayRestoreGeneration)")
            restoreOverlayFocus(to: target, generation: overlayRestoreGeneration)
        }
    }

    private func restoreFocusState(for rawTarget: String) {
        guard let target = validRestoreTarget(rawTarget) ?? (rawTarget.isEmpty ? nil : rawTarget) else { return }
        for (sectionIndex, section) in visibleSections.enumerated() {
            let prefix = "\(section.id)\u{1}"
            guard target.hasPrefix(prefix) else { continue }

            focusedRowIndex = sectionIndex
            focusedSectionId = section.id

            if !section.collectionFolders.isEmpty {
                if let folderIndex = section.collectionFolders.firstIndex(where: {
                    TVHomeCardIdentity.folderKey(rowID: section.id, folder: $0) == target
                }) {
                    let folder = section.collectionFolders[folderIndex]
                    focusedCollectionFolder = folder
                    focusedMeta = nil
                    focusWork.pendingFocusedFolder = folder
                    focusWork.pendingFocusedMeta = nil
                    rowScrollStore.setIndex(folderIndex, for: section.id)
                    return
                }
            } else if !section.items.isEmpty {
                if let itemIndex = section.items.firstIndex(where: {
                    TVHomeCardIdentity.key(rowID: section.id, item: $0) == target
                }) {
                    let item = section.items[itemIndex]
                    let settledMeta = collectionHome?.preparedHero(for: item) ?? item
                    focusedMeta = settledMeta
                    focusedCollectionFolder = nil
                    focusWork.pendingFocusedMeta = settledMeta
                    focusWork.pendingFocusedFolder = nil
                    rowScrollStore.setIndex(itemIndex, for: section.id)
                    if settledMeta.needsHeroMetadataEnrichment {
                        enrichSettledCatalogMeta(settledMeta, in: section.id)
                    }
                    scheduleLandscapeFocus(cardKey: target)
                    return
                }
            }
        }
    }

    private func restoreOverlayFocus(
        to target: String,
        generation: Int
    ) {
        TVHomeDebugTrace.log("home.restoreOverlayFocus begin target=\(target) gen=\(generation)")
        restoreFocusState(for: target)
        focusWork.restoringOverlayCardID = target
        focusWork.acknowledgedNativeOverlayFocusCardID = nil

        focusedCardID = target
        // Home and the outgoing overlay can overlap briefly during the opacity
        // transition. Retry after the target modifier is mounted instead of
        // depending on a single lifecycle callback ordering.
        for delay in [0.06, 0.18, 0.35] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                if overlayRestoreGeneration == generation, overlayRestoreCardID == target {
                    TVHomeDebugTrace.log("home.restoreOverlayFocus fire target=\(target) delay=\(delay)")
                    focusedCardID = target
                }
            }
        }

        // Safety fallback if the lifecycle callback is lost. Normally the
        // target card's focus callback clears the lock much earlier. While the
        // lock is still held this is the only eligible card, so re-assert it
        // rather than only filling a nil focus — a neighbouring card that won
        // the first frame would otherwise be left holding focus.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            if overlayRestoreGeneration == generation,
               overlayRestoreCardID == target {
                TVHomeDebugTrace.log("home.restoreOverlayFocus safety cleanup target=\(target)")
                if focusedCardID != target {
                    var transaction = Transaction()
                    transaction.animation = nil
                    withTransaction(transaction) {
                        focusedCardID = target
                    }
                }
                overlayRestoreCardID = nil
                focusWork.restoringOverlayCardID = nil
                focusWork.acknowledgedNativeOverlayFocusCardID = nil
            }
        }
    }

    /// Records confirmation from a real card focus callback. Catalog rows
    /// synchronize their horizontal index before calling this closure, so a
    /// matching acknowledgement can safely release the one-card lock.
    private func acknowledgeNativeOverlayFocusRestore(for cardKey: String) {
        guard focusWork.restoringOverlayCardID == cardKey,
              overlayRestoreCardID == cardKey else { return }
        focusWork.acknowledgedNativeOverlayFocusCardID = cardKey
        // A programmatic FocusState request may already contain the target,
        // in which case assigning it again will not emit another onChange.
        if focusedCardID == cardKey {
            completeOverlayFocusRestore(for: cardKey)
        }
    }

    /// Release the one-card focus lock as soon as the intended card's real
    /// focus callback confirms restoration. Defer the unlock by one run-loop
    /// turn so the current focus transaction finishes with only that card
    /// eligible; unlocking inside the callback let tvOS jump to the first row
    /// in the six-row focus window (two rows above).
    private func completeOverlayFocusRestore(for cardKey: String) {
        // Only the card this restore is waiting for may complete it. A
        // neighbouring card can report native focus while the return
        // transition is still settling; accepting it used to commit that
        // neighbour as the restored focus and cancel the retries that would
        // have re-asserted the real target.
        guard TVHomeOverlayFocusRestore.canComplete(
            cardKey,
            restoringCardID: focusWork.restoringOverlayCardID,
            lockedCardID: overlayRestoreCardID,
            acknowledgedNativeCardID: focusWork.acknowledgedNativeOverlayFocusCardID
        ) else { return }
        focusWork.restoringOverlayCardID = nil
        let generation = overlayRestoreGeneration
        TVHomeDebugTrace.log("home.completeOverlayFocusRestore start cardKey=\(cardKey) gen=\(generation)")
        DispatchQueue.main.async {
            guard overlayRestoreGeneration == generation else { return }

            TVHomeDebugTrace.log("home.completeOverlayFocusRestore done cardKey=\(cardKey)")
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) {
                overlayRestoreCardID = nil
                focusedCardID = cardKey
                focusWork.acknowledgedNativeOverlayFocusCardID = nil
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
        return isLoading
            && store.sections.isEmpty
            && continueWatching.isEmpty
            && profileGateStartupFocusTarget == nil
    }

    private var initialDefaultFocusCardID: String? {
        if let raw = store.lastFocusedCardID ?? focusWork.pendingOverlayRestoreCardID,
           let valid = validRestoreTarget(raw) {
            return valid
        }
        return store.lastFocusedCardID ?? focusWork.pendingOverlayRestoreCardID ?? profileGateStartupFocusTargetCardKey
    }

    private var profileGateStartupFocusTargetCardKey: String? {
        if case .card(let key, _, _) = profileGateStartupFocusTarget {
            return key
        }
        return nil
    }

    private var profileGateStartupFocusTarget: TVHomeProfileFocusTarget? {
        if homeLayout == "Grid View", heroEnabled, !gridHeroItems.isEmpty {
            return .gridHero
        }
        for (index, section) in visibleSections.enumerated() {
            guard section.hasContent, !section.isLoadingPlaceholder else { continue }
            if let folder = section.collectionFolders.first {
                return .card(
                    key: TVHomeCardIdentity.folderKey(rowID: section.id, folder: folder),
                    sectionID: section.id,
                    sectionIndex: index
                )
            }
            if let item = section.items.first {
                return .card(
                    key: TVHomeCardIdentity.key(rowID: section.id, item: item),
                    sectionID: section.id,
                    sectionIndex: index
                )
            }
        }
        return nil
    }

    private var profileGateReadiness: TVProfileGateReadiness {
        guard isProfileFocusPending else {
            return .waiting(hasFocusableContent: false, targetSignature: nil)
        }
        if isFullScreenOverlayPresented { return .overlay }
        let target = profileGateStartupFocusTarget
        if let target {
            return .ready(
                targetSignature: target.signature,
                storeLoaded: store.isLoaded(for: contentIdentity)
            )
        }
        let loadSettled = store.isLoaded(for: contentIdentity)
            || profileGateFailedLoadIdentity == contentIdentity
        guard loadSettled else {
            return .waiting(
                hasFocusableContent: false,
                targetSignature: nil
            )
        }
        return .empty
    }

    private var profileGateFocusRequestSignature: String {
        "\(isProfileFocusPending)|\(isActive)|\(profileGateGeneration)|\(contentIdentity.profileId)|"
            + "\(contentIdentity.catalogRevision)|\(store.isLoaded(for: contentIdentity))|"
            + "\(profileGateFailedLoadIdentity == contentIdentity)|\(isLoading)|"
            + "\(profileGateStartupFocusTarget?.signature ?? "none")|\(isFullScreenOverlayPresented)"
    }

    private func reportProfileGateReadiness() {
        guard isProfileFocusPending else { return }
        TVHomeDebugTrace.log("home.reportProfileGateReadiness identity=\(contentIdentity.profileId):\(contentIdentity.catalogRevision) gen=\(profileGateGeneration) readiness=\(profileGateReadiness)")
        onProfileGateReadinessChange(contentIdentity, profileGateGeneration, profileGateReadiness)
    }

    private func acknowledgeNativeProfileCardFocus(_ cardKey: String) {
        guard isProfileFocusPending else { return }
        didNativeFocusGridHero = false
        nativeProfileFocusedCardKey = cardKey
        TVHomeDebugTrace.log("home.profileGate.nativeCardFocus key=\(cardKey) target=\(profileGateStartupFocusTarget?.signature ?? "none")")
        reportProfileGateReadiness()
    }

    private func clearNativeProfileCardFocus(_ cardKey: String) {
        guard nativeProfileFocusedCardKey == cardKey else { return }
        nativeProfileFocusedCardKey = nil
        TVHomeDebugTrace.log("home.profileGate.nativeCardBlur key=\(cardKey)")
        reportProfileGateReadiness()
    }

    private func hasNativeProfileFocus(for target: TVHomeProfileFocusTarget) -> Bool {
        switch target {
        case .card(let key, _, _):
            return nativeProfileFocusedCardKey == key
        case .gridHero:
            return didNativeFocusGridHero
        }
    }

    private func maintainProfileGateFocus(
        for sections: [TVHomeSection],
        using proxy: ScrollViewProxy
    ) async {
        guard isProfileFocusPending,
              isActive,
              !isFullScreenOverlayPresented,
              let target = profileGateStartupFocusTarget else {
            TVHomeDebugTrace.log(
                "home.maintainProfileGateFocus skip isProfileFocusPending=\(isProfileFocusPending) "
                    + "isActive=\(isActive) overlayPresented=\(isFullScreenOverlayPresented) "
                    + "target=\(profileGateStartupFocusTarget?.signature ?? "nil")"
            )
            return
        }
        let identity = contentIdentity
        let gateGeneration = profileGateGeneration
        TVHomeDebugTrace.log("home.maintainProfileGateFocus start identity=\(identity.profileId):\(identity.catalogRevision) gen=\(gateGeneration) target=\(target.signature)")
        await Task.yield()
        var attempt = 0
        while !Task.isCancelled {
            guard !Task.isCancelled,
                  isProfileFocusPending,
                  isActive,
                  contentIdentity == identity,
                  profileGateGeneration == gateGeneration,
                  !isFullScreenOverlayPresented,
                  profileGateStartupFocusTarget == target else {
                TVHomeDebugTrace.log("home.maintainProfileGateFocus loop end attempt=\(attempt) pending=\(isProfileFocusPending) active=\(isActive) targetMatch=\(profileGateStartupFocusTarget == target)")
                return
            }
            if hasNativeProfileFocus(for: target) {
                TVHomeDebugTrace.log("home.maintainProfileGateFocus target acknowledged attempt=\(attempt) target=\(target.signature)")
                try? await Task.sleep(nanoseconds: 600_000_000)
                continue
            }

            switch target {
            case .gridHero:
                TVHomeDebugTrace.log("home.maintainProfileGateFocus setting gridHero focus attempt=\(attempt)")
                var transaction = Transaction()
                transaction.animation = nil
                withTransaction(transaction) {
                    proxy.scrollTo("home-grid-hero-top", anchor: .top)
                }
                gridHeroFocusRequestGeneration &+= 1
            case .card(let key, let sectionID, let sectionIndex):
                guard sections.contains(where: { $0.id == sectionID }) else {
                    TVHomeDebugTrace.log("home.maintainProfileGateFocus sectionID=\(sectionID) not in sections attempt=\(attempt)")
                    return
                }
                TVHomeDebugTrace.log("home.maintainProfileGateFocus setting focus to cardKey=\(key) sectionID=\(sectionID) row=\(sectionIndex) attempt=\(attempt)")
                // Drop any progressive first-focus lock; this final target must
                // be free to acknowledge through its real row callback.
                pendingInitialFocusCardKey = nil
                focusedRowIndex = sectionIndex
                focusedSectionId = sectionID
                rowScrollStore.setIndex(0, for: sectionID)
                if focusedCardID != key {
                    var transaction = Transaction()
                    transaction.animation = nil
                    withTransaction(transaction) {
                        proxy.scrollTo(sectionID, anchor: .top)
                        focusedCardID = key
                    }
                }
            }

            let retryDelay: UInt64 = attempt < 8 ? 150_000_000 : 600_000_000
            attempt += 1
            try? await Task.sleep(nanoseconds: retryDelay)
        }
    }

    // MARK: - Back Navigation (Two-Step Exit Command)

    private var currentBackAction: TVHomeBackAction {
        let hasHero = (homeLayout == "Grid View" && heroEnabled && !gridHeroItems.isEmpty)

        let currentSection: TVHomeSection? = {
            if let focusedCardID,
               let matched = visibleSections.first(where: { focusedCardID.hasPrefix("\($0.id)\u{1}") }) {
                return matched
            }
            if let focusedSectionId {
                return visibleSections.first(where: { $0.id == focusedSectionId })
            }
            return nil
        }()

        let currentRowFirstCardKey: String? = {
            guard let currentSection else { return nil }
            if let folder = currentSection.collectionFolders.first {
                return TVHomeCardIdentity.folderKey(rowID: currentSection.id, folder: folder)
            }
            if let item = currentSection.items.first {
                return TVHomeCardIdentity.key(rowID: currentSection.id, item: item)
            }
            return nil
        }()

        let currentRowScrollIndex: Int = {
            guard let currentSection else { return 0 }
            return rowScrollStore.index(for: currentSection.id)
        }()

        let continueWatchingSection = visibleSections.first(where: {
            $0.id == TVHomeSection.continueWatchingId && $0.hasContent && !$0.isLoadingPlaceholder
        })
        let topSection = continueWatchingSection ?? visibleSections.first(where: {
            $0.hasContent && !$0.isLoadingPlaceholder
        })

        let topTargetCardKey: String? = {
            guard let topSection else { return nil }
            let savedIndex = rowScrollStore.index(for: topSection.id)
            if !topSection.collectionFolders.isEmpty {
                let clamped = min(max(savedIndex, 0), topSection.collectionFolders.count - 1)
                return TVHomeCardIdentity.folderKey(rowID: topSection.id, folder: topSection.collectionFolders[clamped])
            }
            if !topSection.items.isEmpty {
                let clamped = min(max(savedIndex, 0), topSection.items.count - 1)
                return TVHomeCardIdentity.key(rowID: topSection.id, item: topSection.items[clamped])
            }
            return nil
        }()

        return TVHomeBackNavigation.determineAction(
            focusedCardID: focusedCardID,
            currentSectionID: currentSection?.id,
            currentRowFirstCardKey: currentRowFirstCardKey,
            currentRowScrollIndex: currentRowScrollIndex,
            isGridHeroFocused: isGridHeroFocused,
            hasGridHero: hasHero,
            continueWatchingOrTopSectionID: topSection?.id,
            continueWatchingOrTopTargetCardKey: topTargetCardKey
        )
    }

    /// Two-step Back toggle:
    /// 1. First press returns to the beginning (index 0) of the current catalog row without affecting vertical scroll.
    /// 2. Second press moves to Continue Watching (or top row) preserving its horizontal scroll position.
    /// 3. Once at the beginning of Continue Watching / Top (or on Grid Hero), Back is not consumed, allowing
    ///    the enclosing TabView to reveal the sidebar.
    private var canHandleExitCommand: Bool {
        guard isActive,
              isEnabled,
              !isFullScreenOverlayPresented,
              overlayRestoreCardID == nil,
              focusWork.restoringOverlayCardID == nil,
              !showsLoading,
              browsingSection == nil
        else { return false }

        return currentBackAction != .exitToSidebar
    }

    private func handleBackCommand() {
        let action = currentBackAction
        TVHomeDebugTrace.log("home.handleBackCommand action=\(action)")
        switch action {
        case .returnToRowBeginning(let sectionID, let cardKey):
            returnFocusToRowBeginning(sectionID: sectionID, cardKey: cardKey)
        case .moveToContinueWatchingOrTop(let sectionID, let cardKey):
            moveFocusToContinueWatchingOrTop(sectionID: sectionID, cardKey: cardKey)
        case .focusGridHero:
            focusGridHeroSlideshow()
        case .exitToSidebar:
            break
        }
    }

    private func scrollHomeToTop() {
        handleBackCommand()
    }

    private func returnFocusToRowBeginning(sectionID: String, cardKey: String) {
        TVHomeDebugTrace.log("home.returnFocusToRowBeginning section=\(sectionID) cardKey=\(cardKey)")
        focusWork.upwardFocusTask?.cancel()
        focusWork.landscapeFocusTask?.cancel()
        focusWork.pendingLandscapeFocusedId = nil
        landscapeFocusedId = nil
        pendingInitialFocusCardKey = nil

        armReturnFocusAnimationSuppression()
        store.lastFocusedCardID = cardKey
        rowScrollStore.setIndex(0, for: sectionID)

        overlayRestoreGeneration &+= 1
        overlayRestoreCardID = cardKey
        restoreOverlayFocus(to: cardKey, generation: overlayRestoreGeneration)

        guard let section = visibleSections.first(where: { $0.id == sectionID }) else { return }
        if let folder = section.collectionFolders.first {
            settleFolderFocus(folder, in: sectionID)
        } else if let meta = section.items.first {
            settleCatalogFocus(on: meta, in: sectionID)
            scheduleLandscapeFocus(cardKey: cardKey)
        }
    }

    private func moveFocusToContinueWatchingOrTop(sectionID: String, cardKey: String) {
        TVHomeDebugTrace.log("home.moveFocusToContinueWatchingOrTop section=\(sectionID) cardKey=\(cardKey)")
        focusWork.upwardFocusTask?.cancel()
        focusWork.landscapeFocusTask?.cancel()
        focusWork.pendingLandscapeFocusedId = nil
        landscapeFocusedId = nil
        pendingInitialFocusCardKey = nil

        armReturnFocusAnimationSuppression()
        targetScrollToTopSectionId = sectionID
        scrollToTopGeneration &+= 1

        if let rowIndex = visibleSections.firstIndex(where: { $0.id == sectionID }) {
            focusedRowIndex = rowIndex
        } else {
            focusedRowIndex = 0
        }
        focusedSectionId = sectionID

        store.lastFocusedCardID = cardKey
        overlayRestoreGeneration &+= 1
        overlayRestoreCardID = cardKey
        restoreOverlayFocus(to: cardKey, generation: overlayRestoreGeneration)

        // Preserve horizontal scroll: do NOT reset rowScrollStore index to 0
        guard let section = visibleSections.first(where: { $0.id == sectionID }) else { return }
        let savedIndex = rowScrollStore.index(for: sectionID)
        if !section.collectionFolders.isEmpty {
            let folderIndex = min(max(savedIndex, 0), section.collectionFolders.count - 1)
            let folder = section.collectionFolders[folderIndex]
            settleFolderFocus(folder, in: sectionID)
        } else if !section.items.isEmpty {
            let itemIndex = min(max(savedIndex, 0), section.items.count - 1)
            let item = section.items[itemIndex]
            settleCatalogFocus(on: item, in: sectionID)
            scheduleLandscapeFocus(cardKey: cardKey)
        }
    }

    private func focusGridHeroSlideshow() {
        TVHomeDebugTrace.log("home.focusGridHeroSlideshow")
        focusWork.upwardFocusTask?.cancel()
        focusWork.landscapeFocusTask?.cancel()
        focusWork.pendingLandscapeFocusedId = nil
        landscapeFocusedId = nil
        pendingInitialFocusCardKey = nil

        targetScrollToTopSectionId = nil
        focusedRowIndex = 0
        focusedSectionId = nil
        focusedCardID = nil
        store.lastFocusedCardID = nil
        gridHeroIndex = 0
        isGridHeroFocused = true
        gridHeroFocusRequestGeneration &+= 1
        scrollToTopGeneration &+= 1
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
            return TVHomeCardIdentity.folderKey(rowID: section.id, folder: folder)
        }
        guard let first = section.items.first else { return nil }
        return TVHomeCardIdentity.key(rowID: section.id, item: first)
    }

    /// The vertical ScrollView can consume a single Up command while its
    /// previous lazy row is still outside the viewport. Defer the fallback
    /// briefly so native focus gets first chance to handle the command; if the
    /// focused card is unchanged, move to the previous row exactly once.
    private func scheduleUpwardFocusFallback(
        from rowIndex: Int,
        sectionID: String,
        expectedCardKey: String?,
        using proxy: ScrollViewProxy
    ) {
        guard rowIndex > 0,
              isActive,
              !isFullScreenOverlayPresented,
              focusWork.restoringOverlayCardID == nil
        else { return }

        focusWork.upwardFocusTask?.cancel()
        focusWork.upwardFocusTask = Task { @MainActor in
            defer { self.focusWork.upwardFocusTask = nil }
            await Task.yield()
            guard !Task.isCancelled,
                  self.isActive,
                  !self.isFullScreenOverlayPresented,
                  self.focusWork.restoringOverlayCardID == nil,
                  self.focusedSectionId == sectionID,
                  expectedCardKey == nil || self.focusedCardID == expectedCardKey
            else { return }

            self.moveFocusToPreviousHomeRow(from: rowIndex, using: proxy)
        }
    }

    private func moveFocusToPreviousHomeRow(from rowIndex: Int, using proxy: ScrollViewProxy) {
        guard isActive,
              !isFullScreenOverlayPresented,
              focusWork.restoringOverlayCardID == nil
        else { return }

        let sections = visibleSections
        let previousIndex = rowIndex - 1
        guard sections.indices.contains(previousIndex) else { return }
        let previousSection = sections[previousIndex]
        let savedIndex = rowScrollStore.index(for: previousSection.id)

        let targetCardKey: String?
        if !previousSection.collectionFolders.isEmpty {
            let folderIndex = min(max(savedIndex, 0), previousSection.collectionFolders.count - 1)
            let folder = previousSection.collectionFolders[folderIndex]
            targetCardKey = TVHomeCardIdentity.folderKey(
                rowID: previousSection.id,
                folder: folder
            )
            settleFolderFocus(folder, in: previousSection.id)
        } else if !previousSection.items.isEmpty {
            let itemIndex = min(max(savedIndex, 0), previousSection.items.count - 1)
            let item = previousSection.items[itemIndex]
            let cardKey = TVHomeCardIdentity.key(
                rowID: previousSection.id,
                item: item
            )
            targetCardKey = cardKey
            settleCatalogFocus(on: item, in: previousSection.id)
            scheduleLandscapeFocus(cardKey: cardKey)
        } else {
            targetCardKey = nil
        }

        focusedSectionId = previousSection.id
        focusedRowIndex = previousIndex
        recordFocusTransition()

        let animation = (isFastScrolling || fastNavigation)
            ? TVHomeLayout.fastVerticalScrollAnimation
            : TVHomeLayout.verticalScrollAnimation
        withAnimation(animation) {
            proxy.scrollTo(previousSection.id, anchor: .top)
        }

        if let targetCardKey {
            store.lastFocusedCardID = targetCardKey
            focusedCardID = targetCardKey
        }
    }

    @ViewBuilder
    private func homeSectionRow(
        index: Int,
        section: TVHomeSection,
        horizontalEdgeInset: CGFloat,
        verticalScrollProxy: ScrollViewProxy
    ) -> some View {
        if section.isLoadingPlaceholder {
            TVLoadingCatalogRow(
                id: section.id,
                title: section.title,
                tileShape: effectiveTileShape(for: section),
                requestsFocus: false,
                addonName: section.addonName,
                showAddonName: catalogAddonNames,
                horizontalEdgeInset: horizontalEdgeInset,
                initialScrollIndex: rowScrollStore.index(for: section.id),
                onScrollIndexChange: { newIndex in
                    rowScrollStore.setIndex(newIndex, for: section.id)
                },
                externalFocus: $focusedCardID,
                onFocus: { placeholderIndex in
                    focusWork.upwardFocusTask?.cancel()
                    recordFocusTransition()
                    let changedRow = focusedSectionId != section.id || focusedRowIndex != index
                    TVHomeDebugTrace.log(
                        "🎯 [PLACEHOLDER_ROW_FOCUS] section=\(section.id) targetRow=\(index) currentRow=\(focusedRowIndex) changedRow=\(changedRow) isFastScrolling=\(isFastScrolling)"
                    )
                    focusedSectionId = section.id
                    if changedRow {
                        focusedRowIndex = index
                        let animation = (isFastScrolling || fastNavigation)
                            ? TVHomeLayout.fastVerticalScrollAnimation
                            : TVHomeLayout.verticalScrollAnimation
                        TVHomeDebugTrace.log("🚀 [SCROLL_TO] section=\(section.id) anchor=top anim=\(isFastScrolling || fastNavigation ? "FAST" : "NORMAL")")
                        withAnimation(animation) {
                            verticalScrollProxy.scrollTo(section.id, anchor: .top)
                        }
                    } else {
                        var transaction = Transaction(animation: nil)
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            verticalScrollProxy.scrollTo(section.id, anchor: .top)
                        }
                    }
                    let cardKey = TVHomeCardIdentity.placeholderKey(rowID: section.id, index: placeholderIndex)
                    focusedCardID = cardKey
                    store.lastFocusedCardID = cardKey
                },
            )
            .equatable()
            .frame(
                height: estimatedHeight(for: section),
                alignment: .topLeading
            )
            .id(section.id)
        } else if !section.collectionFolders.isEmpty {
            TVCollectionFolderRow(
                id: section.id,
                title: section.title,
                showsSectionTitle: true,
                horizontalEdgeInset: horizontalEdgeInset,
                folders: section.collectionFolders,
                initialScrollIndex: rowScrollStore.index(for: section.id),
                onScrollIndexChange: { newIndex in
                    rowScrollStore.setIndex(newIndex, for: section.id)
                },
                initialFocusCardKey: initialFocusCardKey,
                externalFocus: $focusedCardID,
                restrictFocusToCardKey: activeFocusRestrictionCardID,
                retainFocusAppearanceForCardKey: activeFocusRestrictionCardID,
                suppressFocusAnimations: suppressReturnFocusAnimations,
                onInitialFocusRequested: {
                    didRequestInitialCardFocus = true
                },
                onFocus: { folder in
                    focusWork.upwardFocusTask?.cancel()
                    recordFocusTransition()
                    let cardKey = TVHomeCardIdentity.folderKey(rowID: section.id, folder: folder)
                    acknowledgeNativeProfileCardFocus(cardKey)
                    if let pending = pendingInitialFocusCardKey, pending != cardKey {
                        TVHomeDebugTrace.log(
                            "home.focus ignoring transient focus on folder \(cardKey) while pending=\(pending)"
                        )
                        return
                    }
                    acknowledgeNativeOverlayFocusRestore(for: cardKey)
                    let changedRow = focusedSectionId != section.id || focusedRowIndex != index
                    TVHomeDebugTrace.log(
                        "🎯 [FOLDER_ROW_FOCUS] section=\(section.id) targetRow=\(index) currentRow=\(focusedRowIndex) changedRow=\(changedRow) isFastScrolling=\(isFastScrolling)"
                    )
                    focusedSectionId = section.id
                    if changedRow {
                        focusedRowIndex = index
                        if suppressReturnFocusAnimations || pendingInitialFocusCardKey != nil {
                            var transaction = Transaction(animation: nil)
                            transaction.disablesAnimations = true
                            withTransaction(transaction) {
                                verticalScrollProxy.scrollTo(section.id, anchor: .top)
                            }
                        } else {
                            let animation = (isFastScrolling || fastNavigation)
                                ? TVHomeLayout.fastVerticalScrollAnimation
                                : TVHomeLayout.verticalScrollAnimation
                            TVHomeDebugTrace.log("🚀 [SCROLL_TO] section=\(section.id) anchor=top anim=\(isFastScrolling || fastNavigation ? "FAST" : "NORMAL")")
                            withAnimation(animation) {
                                verticalScrollProxy.scrollTo(section.id, anchor: .top)
                            }
                        }
                    } else {
                        var transaction = Transaction(animation: nil)
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            verticalScrollProxy.scrollTo(section.id, anchor: .top)
                        }
                    }
                    focusedCardID = cardKey
                    settleFolderFocus(folder, in: section.id)
                },
                onBlur: { folder in
                    clearNativeProfileCardFocus(
                        TVHomeCardIdentity.folderKey(rowID: section.id, folder: folder)
                    )
                },
                onSelect: { folder in
                    openCollectionFolderFromHome(
                        folder: folder,
                        sectionTitle: section.title,
                        restoreCardID: TVHomeCardIdentity.folderKey(rowID: section.id, folder: folder)
                    )
                },
            )
            .equatable()
            .frame(
                height: estimatedHeight(for: section),
                alignment: .topLeading
            )
            .id(section.id)
        } else {
            TVCatalogRow(
                id: section.id,
                customPosterScreen: collectionHome == nil ? .home : .collections,
                title: section.title,
                addonName: section.addonName,
                showAddonName: catalogAddonNames,
                showsSectionTitle: true,
                horizontalEdgeInset: horizontalEdgeInset,
                items: section.items,
                progressByItemId: (section.id == TVHomeSection.continueWatchingId || section.id == TVHomeSection.upcomingId)
                    ? continueWatchingByMetaId : [:],
                calendarLabelsByItemId: section.id == TVHomeSection.calendarTodayId ? calendarToday.labels : [:],
                collectionOriginsByItemId: collectionHome == nil && section.id == TVHomeSection.continueWatchingId
                    ? continueWatchingOrigins : [:],
                watchedTitleKeys: watchedTitleKeys,
                initialScrollIndex: rowScrollStore.index(for: section.id),
                onScrollIndexChange: { newIndex in
                    rowScrollStore.setIndex(newIndex, for: section.id)
                },
                            initialFocusCardKey: initialFocusCardKey,
                            landscapeFocusedId: landscapeFocusedId(for: section.id),
                            explicitTileShape: effectiveTileShape(for: section),
                            externalFocus: $focusedCardID,
                            restrictFocusToCardKey: activeFocusRestrictionCardID,
                            retainFocusAppearanceForCardKey: activeFocusRestrictionCardID,
                suppressFocusAnimations: suppressReturnFocusAnimations,
                onInitialFocusRequested: {
                    didRequestInitialCardFocus = true
                },
                onFocus: { meta in
                    focusWork.upwardFocusTask?.cancel()
                    recordFocusTransition()
                    let focusStarted = TVHomeDebugTrace.now()
                    let cardKey = TVHomeCardIdentity.key(rowID: section.id, item: meta)
                    acknowledgeNativeProfileCardFocus(cardKey)
                    if let pending = pendingInitialFocusCardKey, pending != cardKey {
                        TVHomeDebugTrace.log(
                            "home.focus ignoring transient focus on \(cardKey) while pending=\(pending)"
                        )
                        return
                    }
                    acknowledgeNativeOverlayFocusRestore(for: cardKey)
                    let changedRow = focusedSectionId != section.id || focusedRowIndex != index
                    TVHomeDebugTrace.log(
                        "home.focus.begin section=\(section.id) meta=\(meta.id) changedRow=\(changedRow) fromRow=\(focusedRowIndex) toRow=\(index)"
                    )
                    focusedSectionId = section.id
                    if changedRow {
                        focusedRowIndex = index
                        if suppressReturnFocusAnimations || pendingInitialFocusCardKey != nil {
                            var transaction = Transaction(animation: nil)
                            transaction.disablesAnimations = true
                            withTransaction(transaction) {
                                verticalScrollProxy.scrollTo(section.id, anchor: .top)
                            }
                        } else {
                            let animation = (isFastScrolling || fastNavigation)
                                ? TVHomeLayout.fastVerticalScrollAnimation
                                : TVHomeLayout.verticalScrollAnimation
                            TVHomeDebugTrace.log(
                                "🚀 [SCROLL_TO] section=\(section.id) anchor=top fromRow=\(focusedRowIndex) toRow=\(index) anim=\(isFastScrolling || fastNavigation ? "FAST(0.18s)" : "NORMAL(0.28s)")"
                            )
                            withAnimation(animation) {
                                verticalScrollProxy.scrollTo(section.id, anchor: .top)
                            }
                        }
                    } else {
                        var transaction = Transaction(animation: nil)
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            verticalScrollProxy.scrollTo(section.id, anchor: .top)
                        }
                    }
                    focusedCardID = cardKey
                    settleCatalogFocus(on: meta, in: section.id)
                    scheduleLandscapeFocus(cardKey: cardKey)
                    TVHomeDebugTrace.log(
                        "home.focus.end section=\(section.id) meta=\(meta.id) ms=\(TVHomeDebugTrace.elapsedMilliseconds(since: focusStarted))"
                    )
                },
                onBlur: { meta in
                    clearLandscapeFocus(cardKey: TVHomeCardIdentity.key(rowID: section.id, item: meta))
                    clearNativeProfileCardFocus(TVHomeCardIdentity.key(rowID: section.id, item: meta))
                },
                onApproachEnd: { meta in
                    let cardKey = TVHomeCardIdentity.key(rowID: section.id, item: meta)
                    if let pending = pendingInitialFocusCardKey, pending != cardKey {
                        return
                    }
                    guard !suppressReturnFocusAnimations else { return }
                    loadMoreSectionIfNeeded(
                        sectionId: section.id, currentItem: meta)
                },
                onSelect: { meta in
                    let cardKey = TVHomeCardIdentity.key(rowID: section.id, item: meta)
                    if section.id == TVHomeSection.calendarTodayId {
                        openCalendarTodayCard(meta, restoreCardID: cardKey)
                    } else if (section.id == TVHomeSection.continueWatchingId || section.id == TVHomeSection.upcomingId),
                        let item = continueWatchingByMetaId[meta.id]
                    {
                        if item.isUpNextEntry && !item.hasAired && !item.isAiringToday {
                            navigateToDetailsFromHome(
                                id: meta.id,
                                type: meta.type,
                                restoreCardID: cardKey
                            )
                        } else {
                            prepareForOverlayPresentation(restoreCardID: cardKey)
                            onResumePlayback(item)
                        }
                    } else {
                        navigateToDetailsFromHome(
                            id: meta.id,
                            type: meta.type,
                            restoreCardID: cardKey
                        )
                    }
                },
                onLongPress: longPressHandler(for: section.id),
                onOpenDetails: { meta in
                    let cardKey = TVHomeCardIdentity.key(rowID: section.id, item: meta)
                    navigateToDetailsFromHome(
                        id: meta.id,
                        type: meta.type,
                        restoreCardID: cardKey,
                        preserveCollectionOrigin: section.id == TVHomeSection.continueWatchingId
                    )
                },
                onPlayContinueWatchingManually: { item in
                    let cardKey = TVHomeCardIdentity.key(rowID: section.id, item: item.meta)
                    prepareForOverlayPresentation(restoreCardID: cardKey)
                    onPlayContinueWatchingManually?(item)
                },
                onStartContinueWatchingFromBeginning: { item in
                    let cardKey = TVHomeCardIdentity.key(rowID: section.id, item: item.meta)
                    prepareForOverlayPresentation(restoreCardID: cardKey)
                    onStartContinueWatchingFromBeginning?(item)
                },
                onRemoveFromContinueWatching: onRemoveFromContinueWatching,
                onRefreshCatalog: { refreshHomeSection(sectionId: section.id) }
            )
            .equatable()
            .frame(
                height: estimatedHeight(for: section),
                alignment: .topLeading
            )
            .id(section.id)
        }
    }

    /// Stable, small signature for progressive row publication. It lets the
    /// lazy viewport retry saved-focus preparation without comparing metadata
    /// arrays or rebuilding work for every card.
    private var initialFocusContentSignature: String {
        "\(store.hasLoaded)_\(store.sectionsRevision)_\(continueWatchingVisible ? continueWatchingMetas.count : 0)_\(continueWatchingVisible ? upcomingMetas.count : 0)"
            + "_\(homeCalendarToday ? calendarToday.metas.count : 0)"
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

            if let cardIndex = section.collectionFolders.firstIndex(where: { TVHomeCardIdentity.folderKey(rowID: section.id, folder: $0) == focusKey }) {
                return (sectionIndex, section.id, cardIndex)
            }
            if homeLayout == "Grid View",
               section.collectionFolders.isEmpty,
               section.id != TVHomeSection.continueWatchingId,
               section.id != TVHomeSection.upcomingId,
               section.id != TVHomeSection.calendarTodayId {
                let previewItems = section.items.prefix(TVHomeGridLayout.previewItemCount(rows: gridRows))
                if let cardIndex = previewItems.firstIndex(where: {
                    TVHomeCardIdentity.key(rowID: section.id, item: $0) == focusKey
                }) {
                    return (sectionIndex, section.id, cardIndex)
                }
                let seeAllKey = "\(section.id)\u{1}\(TVHomeGridLayout.seeAllID)"
                if focusKey == seeAllKey {
                    return (sectionIndex, section.id, previewItems.count)
                }
                continue
            }
            if let cardIndex = section.items.firstIndex(where: { TVHomeCardIdentity.key(rowID: section.id, item: $0) == focusKey }) {
                return (sectionIndex, section.id, cardIndex)
            }
        }
        return nil
    }

    private func retargetOutOfPreviewGridFocusIfNeeded(in sections: [TVHomeSection]) {
        guard homeLayout == "Grid View", let focusKey = initialFocusCardKey else { return }
        for section in sections {
            guard section.collectionFolders.isEmpty,
                  section.id != TVHomeSection.continueWatchingId,
                  section.id != TVHomeSection.upcomingId,
                  section.id != TVHomeSection.calendarTodayId else {
                continue
            }
            let matchingIndex = section.items.firstIndex {
                TVHomeCardIdentity.key(rowID: section.id, item: $0) == focusKey
            }
            guard let matchingIndex,
                  matchingIndex >= TVHomeGridLayout.previewItemCount(rows: gridRows) else {
                continue
            }
            guard let target = validRestoreTarget(focusKey) else { return }
            pendingInitialFocusCardKey = target
            store.lastFocusedCardID = target
            TVHomeDebugTrace.log(
                "home.prepareInitialFocusViewport retargeted out-of-preview grid card "
                    + "from=\(focusKey) to=\(target)"
            )
            return
        }
    }

    /// Seeds both vertical and horizontal restoration state before a distant
    /// saved card can request focus from a lazily mounted row.
    private func prepareInitialFocusViewport(
        for sections: [TVHomeSection],
        using proxy: ScrollViewProxy
    ) {
        if let preparedFocusLayout, preparedFocusLayout != homeLayout {
            didPrepareInitialFocusViewport = false
            didRequestInitialCardFocus = false
            if let savedTarget = focusedCardID ?? store.lastFocusedCardID {
                let target = validRestoreTarget(savedTarget) ?? savedTarget
                pendingInitialFocusCardKey = target
                store.lastFocusedCardID = target
            } else {
                pendingInitialFocusCardKey = nil
            }
        }
        preparedFocusLayout = homeLayout
        guard !didPrepareInitialFocusViewport else { return }
        retargetOutOfPreviewGridFocusIfNeeded(in: sections)
        TVHomeDebugTrace.log(
            "home.prepareInitialFocusViewport start target=\(initialFocusCardKey ?? "nil") "
                + "sections=\(sections.count) hasLoaded=\(store.hasLoaded)"
        )
        guard let location = initialFocusLocation(in: sections) else {
            // Keep a saved target alive while progressive loading has not yet
            // published its section. Once the final tree is known, fall back
            // safely to normal first-row focus if that card truly disappeared.
            if !store.hasLoaded {
                if pendingInitialFocusCardKey == nil {
                    pendingInitialFocusCardKey = store.lastFocusedCardID
                }
                TVHomeDebugTrace.log(
                    "home.prepareInitialFocusViewport awaiting catalogs for target=\(pendingInitialFocusCardKey ?? "nil")"
                )
                return
            }
            TVHomeDebugTrace.log("home.prepareInitialFocusViewport target not found in loaded sections; resetting to first row")
            pendingInitialFocusCardKey = nil
            didPrepareInitialFocusViewport = true
            store.lastFocusedCardID = nil
            return
        }

        didPrepareInitialFocusViewport = true
        if let key = initialFocusCardKey {
            restoreFocusState(for: key)
        } else {
            focusedRowIndex = location.sectionIndex
            focusedSectionId = location.sectionID
            rowScrollStore.setIndex(location.cardIndex, for: location.sectionID)
        }
        let targetSection = sections[location.sectionIndex]
        let isGridCatalogSection = homeLayout == "Grid View"
            && targetSection.collectionFolders.isEmpty
            && targetSection.id != TVHomeSection.continueWatchingId
            && targetSection.id != TVHomeSection.upcomingId
            && targetSection.id != TVHomeSection.calendarTodayId
        let gridRowIndex = isGridCatalogSection
            ? location.cardIndex / TVHomeGridLayout.columns
            : 0
        let scrollAnchor: UnitPoint
        switch gridRowIndex {
        case 1:
            scrollAnchor = .center
        case 2...:
            scrollAnchor = .bottom
        default:
            scrollAnchor = .top
        }
        TVHomeDebugTrace.log(
            "home.prepareInitialFocusViewport target located: sectionIndex=\(location.sectionIndex) "
                + "sectionID=\(location.sectionID) cardIndex=\(location.cardIndex)"
        )

        // Fresh first-row focus already has the correct viewport. Preserve its
        // existing first-load behavior; align later grid rows even when their
        // section is already the first item in the vertical stack.
        guard location.sectionIndex > 0 || gridRowIndex > 0 else { return }
        var immediateTransaction = Transaction()
        immediateTransaction.animation = nil
        withTransaction(immediateTransaction) {
            proxy.scrollTo(location.sectionID, anchor: scrollAnchor)
        }
        DispatchQueue.main.async {
            guard self.isActive, !self.isFullScreenOverlayPresented else { return }
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) {
                proxy.scrollTo(location.sectionID, anchor: scrollAnchor)
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

    private func prepareForOverlayPresentation(restoreCardID: String? = nil) {
        focusWork.defersOverlayPreparation = true
        focusWork.pendingOverlayRestoreCardID = restoreCardID
            ?? focusedCardID
            ?? store.lastFocusedCardID
    }

    /// Captures return identity without publishing SwiftUI state. Publishing
    /// `overlayRestoreCardID` here invalidates the entire Home tree on the same
    /// frame that Details is trying to mount, which is why Search felt faster.
    private func navigateToDetailsFromHome(
        id: String,
        type: String,
        restoreCardID: String? = nil,
        preserveCollectionOrigin: Bool = false
    ) {
        prepareForOverlayPresentation(restoreCardID: restoreCardID)
        if preserveCollectionOrigin, let onNavigateToContinueWatchingDetails {
            onNavigateToContinueWatchingDetails(id, type)
        } else {
            onNavigateToDetails(id, type)
        }
    }

    /// A Today card opens Details on its episode, as in the Calendar tab.
    private func openCalendarTodayCard(_ meta: NuvioMeta, restoreCardID: String) {
        guard let entry = calendarToday.entries[meta.id], let onOpenCalendarEntry else {
            navigateToDetailsFromHome(id: meta.id, type: meta.type, restoreCardID: restoreCardID)
            return
        }
        prepareForOverlayPresentation(restoreCardID: restoreCardID)
        onOpenCalendarEntry(entry)
    }

    private func playTitleFromHome(id: String, type: String) {
        prepareForOverlayPresentation()
        onPlayTitle(id, type)
    }

    private func openCollectionFolderFromHome(
        folder: TVCollectionFolderItem,
        sectionTitle: String,
        restoreCardID: String? = nil
    ) {
        prepareForOverlayPresentation(restoreCardID: restoreCardID)
        onOpenCollectionFolder(folder, sectionTitle)
    }

    private func effectiveTileShape(for section: TVHomeSection) -> CollectionTileShape {
        if section.id == TVHomeSection.continueWatchingId || section.id == TVHomeSection.upcomingId
            || section.id == TVHomeSection.calendarTodayId {
            return continueWatchingLandscape ? .landscape : .poster
        }
        if section.isCollectionRow {
            return section.tileShape
        }
        if let posterShape = section.posterShape {
            let shape = CollectionTileShape.fromStored(posterShape, fallback: .poster)
            if shape == .poster && landscapePosters {
                return .landscape
            }
            return shape
        }
        if landscapePosters {
            return .landscape
        }
        return section.tileShape
    }

    private var visibleSections: [TVHomeSection] {
        let signature = TVHomeFocusWork.VisibleSectionsSignature(
            cwVisible: continueWatchingVisible,
            cwCount: continueWatchingVisible ? continueWatchingMetas.count : 0,
            cwFirstId: continueWatchingVisible ? continueWatchingMetas.first?.id : nil,
            upCount: continueWatchingVisible ? upcomingMetas.count : 0,
            upFirstId: continueWatchingVisible ? upcomingMetas.first?.id : nil,
            localCount: localTitlesSection?.items.count ?? 0,
            jellyfinCount: jellyfinSections.reduce(0) { $0 + $1.items.count },
            storeRevision: store.sectionsRevision,
            hideUnreleased: hideUnreleased,
            cwLandscape: continueWatchingLandscape,
            landscapePosters: landscapePosters,
            calendarToday: homeCalendarToday ? calendarToday.metas : []
        )

        if let cached = focusWork.cachedVisibleSections, cached.signature == signature {
            return cached.sections
        }

        let resumeSection = TVHomeSection(
            id: TVHomeSection.continueWatchingId,
            title: L10n.string("home_continue_watching", fallback: "Continue Watching"),
            items: continueWatchingMetas,
            posterShape: continueWatchingLandscape ? "landscape" : "poster"
        )
        let upcomingSection = TVHomeSection(
            id: TVHomeSection.upcomingId,
            title: L10n.string("tvos_home_upcoming", fallback: "Upcoming"),
            items: upcomingMetas,
            posterShape: continueWatchingLandscape ? "landscape" : "poster"
        )
        let calendarTodaySection = TVHomeSection(
            id: TVHomeSection.calendarTodayId,
            title: L10n.string("calendar_home_today_row", fallback: "Today"),
            items: calendarToday.metas,
            posterShape: continueWatchingLandscape ? "landscape" : "poster"
        )
        let pinnedSections = ((continueWatching.isEmpty || !continueWatchingVisible) ? [] : [resumeSection])
            + ((upcomingMetas.isEmpty || !continueWatchingVisible) ? [] : [upcomingSection])
            + ((calendarToday.isEmpty || !homeCalendarToday) ? [] : [calendarTodaySection])
            + [localTitlesSection].compactMap { $0 }
            + jellyfinSections
        let allSections = collectionHome == nil ? pinnedSections + store.sections : store.sections

        let result: [TVHomeSection]
        if !hideUnreleased {
            result = allSections
        } else {
            let today = ContentReleasePolicy.todayIsoDay()
            result = allSections.map { section in
                // Collection folder rows don't carry title posters; leave them intact.
                if !section.collectionFolders.isEmpty
                    || section.id == TVHomeSection.localTitlesId
                    || section.id == TVHomeSection.jellyfinId
                    || section.id.hasPrefix(TVHomeSection.jellyfinLibraryIdPrefix) {
                    return section
                }
                var copy = section
                copy.items = section.items.filter {
                    !ContentReleasePolicy.isUnreleased($0, today: today)
                }
                return copy
            }
        }

        let contentSections = result.filter(\.hasContent)
        focusWork.cachedVisibleSections = TVHomeFocusWork.CachedVisibleSections(
            signature: signature,
            sections: contentSections
        )
        return contentSections
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
            $0.id != TVHomeSection.continueWatchingId && $0.id != TVHomeSection.upcomingId
                && $0.id != TVHomeSection.calendarTodayId && $0.collectionFolders.isEmpty
        }
        let selectedIDs = (try? JSONDecoder().decode([String].self, from: heroCatalogsData)) ?? []
        let selectedSet = collectionHome == nil ? Set(selectedIDs) : Set<String>()
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
        for candidate in [meta.landscapePosterUrl, meta.backgroundUrl, meta.posterUrl] {
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
        let isNextUpAllowed = !item.isUpNextEntry || ContinueWatchingFeatureFlags.nextUpCardsEnabled
        let isMetaVisible = isVisible(item.meta)
        let isAiredAllowed = showUnairedNextUp || !item.isUpNextEntry || item.hasAired || item.isAiringToday
        let notDismissed = !ContinueWatchingDismissStore.isDismissed(item)
        return isNextUpAllowed && isMetaVisible && isAiredAllowed && notDismissed
    }

    private func requestLoadingFocus() {
        TVHomeDebugTrace.log("home.requestLoadingFocus showsLoading=\(showsLoading)")
        guard showsLoading else { return }
        DispatchQueue.main.async {
            guard self.showsLoading else { return }
            self.isLoadingFocusActive = true
            TVHomeDebugTrace.log("home.isLoadingFocusActive set to true")
        }
    }

    @MainActor
    private func loadWithAutomaticRetry(
        for identity: TVHomeContentIdentity,
        forceReload: Bool = false
    ) async {
        if collectionHome != nil {
            await load(for: identity, forceReload: forceReload)
            return
        }
        if isProfileFocusPending, contentIdentity == identity {
            profileGateFailedLoadIdentity = nil
        }
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
            guard attempt < maximumAttempts - 1 else {
                if isProfileFocusPending,
                   contentIdentity == identity,
                   !store.isLoaded(for: identity),
                   errorMessage != nil {
                    profileGateFailedLoadIdentity = identity
                }
                return
            }

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
        if let collectionHome {
            guard isActive else { return }
            isLoading = true
            errorMessage = nil
            let failure = await collectionHome.load(identity: identity, force: forceReload)
            guard !Task.isCancelled, isActive, contentIdentity == identity else { return }
            errorMessage = failure
            isLoading = false
            if focusedMeta == nil { focusedMeta = store.hero }
            refreshWatchedTitles()
            return
        }
        guard identity.profileId != "none" && !identity.profileId.isEmpty else {
            isLoading = false
            return
        }
        if isProfileFocusPending, contentIdentity == identity {
            profileGateFailedLoadIdentity = nil
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
            return
        }

        let generation = store.beginLoad(for: identity)
        // Captured before the first request so it describes what this load read,
        // not what a settings change mid-flight left behind.
        let inputSignature = repository.homeCatalogInputSignature
        lastLoadedInputSignature = inputSignature
        isLoading = true
        errorMessage = nil

        // Collections are already local once account sync applies them. Publish
        // their folder rows before starting provider requests so a slow catalog
        // host cannot hold the user's collections off Home.
        let collectionSections = await loadCollectionSections()
        guard store.isCurrentLoad(generation, for: identity) else { return }
        let homeVisibility = TVHomeCatalogOrder.homeVisibilityContext()
        let previouslyLoadedCatalogSections = store.sections.filter {
            !$0.isCollectionRow
                && !$0.isLoadingPlaceholder
                && isHomeCatalogSectionFromEnabledSource($0, context: homeVisibility)
        }
        let isColdStart = previouslyLoadedCatalogSections.isEmpty
        // Seeded before the first publish so Home shows its rows'
        // titles and spinning cards immediately, rather than assembling itself
        // row by row under the user.
        homeLoadingPlaceholders = homeSkeletonSections(
            excluding: Set(previouslyLoadedCatalogSections.map(\.id))
                .union(collectionSections.map(\.id))
        )
        publishHomeSections(
            catalogSections: previouslyLoadedCatalogSections,
            collectionSections: collectionSections,
            resetFocusIfEmpty: isColdStart
        )

        var receivedCatalogUpdate = false
        var receivedCatalogPublication = false
        do {
            var latestCatalogSections: [TVHomeSection] = []
            for try await catalogs in repository.homeCatalogsProgressively() {
                try Task.checkCancellation()
                guard store.isCurrentLoad(generation, for: identity) else { return }
                receivedCatalogPublication = true
                let catalogSections = await Self.makeHomeCatalogSections(from: catalogs, repository: repository)
                try Task.checkCancellation()
                guard store.isCurrentLoad(generation, for: identity) else { return }
                latestCatalogSections = catalogSections
                receivedCatalogUpdate = receivedCatalogUpdate || !catalogSections.isEmpty
                guard !catalogSections.isEmpty else { continue }
                let loadedIds = Set(catalogSections.map(\.id))
                let retainedPrevious = previouslyLoadedCatalogSections.filter { !loadedIds.contains($0.id) }
                while isFastScrolling {
                    try? await Task.sleep(nanoseconds: 80_000_000)
                    try Task.checkCancellation()
                    guard store.isCurrentLoad(generation, for: identity) else { return }
                }
                publishHomeSections(
                    // Keep the previous successful tree while this replacement
                    // is still arriving, then publish the exact final result
                    // below. Late rows append without making earlier rows flash.
                    catalogSections: catalogSections + retainedPrevious,
                    collectionSections: collectionSections,
                    resetFocusIfEmpty: isColdStart
                )
            }
            guard receivedCatalogPublication || !collectionSections.isEmpty else {
                throw URLError(.cannotLoadFromNetwork)
            }
            guard store.isCurrentLoad(generation, for: identity) else { return }
            while isFastScrolling {
                try? await Task.sleep(nanoseconds: 80_000_000)
                try Task.checkCancellation()
                guard store.isCurrentLoad(generation, for: identity) else { return }
            }
            // Every row this load was going to produce has arrived; whatever is
            // still a skeleton is never coming.
            clearHomeLoadingPlaceholders(mutateStore: false)
            publishHomeSections(
                catalogSections: receivedCatalogPublication
                    ? latestCatalogSections
                    : previouslyLoadedCatalogSections,
                collectionSections: collectionSections,
                resetFocusIfEmpty: isColdStart
            )
            store.finishLoad(generation, for: identity)
            lastLoadedInputSignature = inputSignature
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
        if collectionHome != nil {
            await load(for: identity, forceReload: true)
            return
        }
        TVHomeDebugTrace.log("home.reloadHomeAfterSyncedInputs started for \(identity.profileId):\(identity.catalogRevision)")
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
        guard !Task.isCancelled, identity == contentIdentity else {
            TVHomeDebugTrace.log("home.reloadHomeAfterSyncedInputs cancelled or identity mismatch")
            return
        }
        let currentSig = repository.homeCatalogInputSignature
        let sigChanged = currentSig != lastLoadedInputSignature
        TVHomeDebugTrace.log("home.reloadHomeAfterSyncedInputs sigChanged=\(sigChanged)")
        guard sigChanged else { return }
        await load(for: identity, forceReload: true)
    }

    private static func makeHomeCatalogSections(
        from catalogs: [NuvioCatalog],
        repository: CatalogRepository
    ) async -> [TVHomeSection] {
        var loadedSections: [TVHomeSection] = []
        loadedSections.reserveCapacity(catalogs.count)

        for catalog in catalogs {
            guard !Task.isCancelled else { return loadedSections }
            var items: [NuvioMeta]
            let pendingItems: [NuvioMeta]
            let nextSkip: Int
            if let catalogItems = catalog.items {
                let initialCount = min(18, catalogItems.count)
                let initialItems = Array(catalogItems.prefix(initialCount))
                items = await TmdbDetailsService.localizedMetadata(for: initialItems)
                let remainingItems = Array(catalogItems.dropFirst(initialCount))
                items.append(contentsOf: remainingItems)
                pendingItems = []
                nextSkip = catalogItems.count
            } else {
                var resolvedItems: [NuvioMeta] = []
                for id in catalog.itemIds {
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
                    manifestURL: catalog.manifestURL,
                    manifestShowInHome: catalog.manifestShowInHome,
                    posterShape: catalog.posterShape,
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
        guard collectionHome == nil else { return sections }
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
        TVHomeDebugTrace.measure("home.publishHomeSections catalog=\(catalogSections.count) col=\(collectionSections.count)") {
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
            let isSameSections = store.sections.count == visible.count && zip(store.sections, visible).allSatisfy { old, new in
                old.id == new.id &&
                old.items.count == new.items.count &&
                old.isLoadingPlaceholder == new.isLoadingPlaceholder &&
                zip(old.items, new.items).allSatisfy { $0.id == $1.id } &&
                old.collectionFolders.count == new.collectionFolders.count
            }
            if !isSameSections {
                TVHomeDebugTrace.log("home.publishHomeSections updating store.sections count=\(visible.count)")
                store.sections = visible
                // The snapshot is what the next launch seeds skeletons *from*, so only
                // rows that actually resolved belong in it.
                TVHomeCatalogOrder.scheduleSnapshotWrite(composed)
            } else {
                TVHomeDebugTrace.log("home.publishHomeSections store.sections unchanged (\(visible.count) sections)")
            }
            if let newHero = composed.lazy.compactMap({ $0.items.first }).first, store.hero?.id != newHero.id {
                store.hero = newHero
            }

            if let currentSectionId = focusedSectionId,
               let loadedSection = visible.first(where: { $0.id == currentSectionId && !$0.isLoadingPlaceholder && $0.hasContent }) {
                let savedIndex = rowScrollStore.index(for: currentSectionId)
                let targetCardKey: String?
                if !loadedSection.collectionFolders.isEmpty {
                    let folderIndex = min(max(savedIndex, 0), loadedSection.collectionFolders.count - 1)
                    targetCardKey = TVHomeCardIdentity.folderKey(rowID: currentSectionId, folder: loadedSection.collectionFolders[folderIndex])
                } else if !loadedSection.items.isEmpty {
                    let itemIndex = min(max(savedIndex, 0), loadedSection.items.count - 1)
                    targetCardKey = TVHomeCardIdentity.key(rowID: currentSectionId, item: loadedSection.items[itemIndex])
                } else {
                    targetCardKey = nil
                }
                if let targetCardKey, store.lastFocusedCardID != targetCardKey {
                    TVHomeDebugTrace.log("home.publishHomeSections maintaining focus on newly loaded section=\(currentSectionId) target=\(targetCardKey)")
                    store.lastFocusedCardID = targetCardKey
                    focusedCardID = targetCardKey
                }
            }

            guard wasEmpty && resetFocusIfEmpty && focusedSectionId == nil else { return }
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
        }
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
        let visibility = TVHomeCatalogOrder.homeVisibilityContext()

        return TVHomeCatalogOrder.snapshotRows().compactMap { row in
            guard !published.contains(row.id),
                  !row.id.hasPrefix(TVHomeSection.collectionIdPrefix),
                  row.id != TVHomeSection.continueWatchingId,
                  row.id != TVHomeSection.upcomingId,
                  isHomeCatalogSnapshotRowFromEnabledSource(row),
                  TVHomeCatalogOrder.isRowEnabled(row, context: visibility) else {
                return nil
            }
            return TVHomeSection(
                id: row.id,
                title: row.title,
                items: [],
                contentType: row.contentType,
                catalogId: row.catalogId,
                addonId: row.addonId,
                addonName: row.addonName,
                manifestURL: row.manifestURL,
                manifestShowInHome: row.manifestShowInHome,
                posterShape: row.posterShape,
                isLoadingPlaceholder: true
            )
        }
    }

    /// A disabled provider must not leave its previous rows or loading
    /// placeholders visible while the replacement Home tree is being built.
    /// Built-in rows have no `addonId`, but their persisted settings key still
    /// carries Cinemeta's manifest id.
    private func isHomeCatalogSectionFromEnabledSource(
        _ section: TVHomeSection,
        context: TVHomeCatalogOrder.HomeVisibilityContext
    ) -> Bool {
        TVHomeCatalogOrder.isRowEnabled(homeCatalogSnapshotRow(for: section), context: context)
    }

    private func homeCatalogSnapshotRow(for section: TVHomeSection) -> TVHomeCatalogOrder.SnapshotRow {
        TVHomeCatalogOrder.SnapshotRow(
            id: section.id,
            title: section.title,
            addonName: section.addonName,
            addonId: section.addonId,
            contentType: section.contentType,
            catalogId: section.catalogId,
            manifestURL: section.manifestURL,
            manifestShowInHome: section.manifestShowInHome,
            settingsKey: section.catalogSettingsKey,
            posterShape: section.posterShape
        )
    }

    private func isHomeCatalogSnapshotRowFromEnabledSource(
        _ row: TVHomeCatalogOrder.SnapshotRow
    ) -> Bool {
        guard !CinemetaCatalogRepository.isCinemetaEnabled else { return true }
        return !(row.settingsKey?.hasPrefix("\(CinemetaCatalogRepository.cinemetaAddonId)_") ?? false)
    }

    /// Drops every skeleton, from the pending list and from what is on screen.
    /// A row that failed has to stop spinning, not spin until the next load.
    private func clearHomeLoadingPlaceholders(mutateStore: Bool = true) {
        homeLoadingPlaceholders = []
        guard mutateStore, store.sections.contains(where: \.isLoadingPlaceholder) else { return }
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
        guard collectionHome == nil else { return }
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
        guard !Task.isCancelled, identity == contentIdentity, store.isLoaded(for: identity) else { return }
        let catalogRows = store.sections.filter { !$0.isCollectionRow }
        let pinned = fresh.filter(\.isPinnedCollection)
        let unpinned = fresh.filter { !$0.isPinnedCollection }
        let merged = homeOrderedSections(pinned + catalogRows + unpinned)
        TVHomeCatalogOrder.scheduleSnapshotWrite(merged)
        // Compare ids *and* folder tile shapes / titles so edits like switching
        // Poster ↔ Landscape actually re-render Home (id-only checks skip them).
        let currentSignature = collectionSectionsSignature(store.sections)
        let nextSignature = collectionSectionsSignature(merged)
        if currentSignature != nextSignature {
            store.sections = merged
        }
        guard repository.homeCatalogInputSignature != lastLoadedInputSignature,
              !store.isLoading(for: identity),
              store.isLoaded(for: identity) else { return }
        await load(for: identity, forceReload: true)
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
        fastNavigation ? 0 : 300_000_000
    }

    /// Catalog title focus: card strip + row offset are immediate; hero/backdrop
    /// publish only after the settle delay (and cancel if focus moves again).
    private func settleCatalogFocus(on meta: NuvioMeta, in sectionId: String) {
        if isActive && !isFullScreenOverlayPresented {
            collectionHome?.prefetchHeroLogos(rowID: sectionId, near: meta)
        }
        focusWork.pendingFocusedMeta = collectionHome?.preparedHero(for: meta) ?? meta
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
        focusWork.heroEnrichmentTask?.cancel()

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

            guard let pendingMeta = focusWork.pendingFocusedMeta,
                  pendingMeta.id == targetMetaId,
                  let targetSectionId,
                  focusWork.pendingSectionId == targetSectionId else { return }

            let settledMeta = collectionHome?.preparedHero(for: pendingMeta) ?? pendingMeta
            focusWork.pendingFocusedMeta = settledMeta

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
            // ask for the full metadata record in the background and fill the missing fields.
            guard settledMeta.needsHeroMetadataEnrichment else { return }
            enrichSettledCatalogMeta(settledMeta, in: targetSectionId)
        }
    }

    private enum EnrichmentFetchOutcome {
        case completed(NuvioMeta?)
        case timedOut
    }

    private static func fetchMetadataWithTimeout(
        repository: CatalogRepository,
        id: String,
        type: String,
        timeoutSeconds: Double = 2.0
    ) async -> NuvioMeta? {
        await withTaskGroup(of: EnrichmentFetchOutcome.self) { group in
            group.addTask {
                let meta = try? await repository.getMetadata(id: id, type: type)
                return .completed(meta)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                return .timedOut
            }
            defer { group.cancelAll() }
            if let first = await group.next() {
                switch first {
                case .completed(let meta):
                    return meta
                case .timedOut:
                    TVHomeDebugTrace.log("hero.enrich timed out after \(timeoutSeconds)s for \(id)")
                    return nil
                }
            }
            return nil
        }
    }

    /// Fetches (or reuses the cached) full `/meta` record for a catalog card
    /// focus has rested on and merges the missing fields into it. Debounced by
    /// `scheduleHeroSettle`, so rapid navigation never generates a request per
    /// card passed over. The fetch and decoding run off-main-thread via
    /// `Task.detached(priority: .utility)`. The merged record replaces
    /// `focusedMeta` (hero) and the pending focus target without stalling `@MainActor`.
    @MainActor
    private func enrichSettledCatalogMeta(_ settledMeta: NuvioMeta, in sectionId: String) {
        let metadataContext = CinemetaCatalogRepository.metadataCacheContext
        let enrichmentKey = "\(metadataContext)\u{1f}\(settledMeta.type.lowercased())\u{1f}\(settledMeta.id)"
        if let cached = focusWork.enrichedHeroMetadata[enrichmentKey] {
            let merged = settledMeta.fillingMissingHeroMetadata(from: cached)
            guard focusWork.pendingFocusedMeta?.id == settledMeta.id,
                  focusWork.pendingSectionId == sectionId,
                  focusWork.pendingFocusedFolder == nil else {
                return
            }
            focusedMeta = merged
            focusWork.pendingFocusedMeta = merged
            TVHomeDebugTrace.log("hero.enrich published cached hero item=\(settledMeta.id)")
            return
        }

        let repository = self.repository
        let targetId = settledMeta.id
        let targetType = settledMeta.type
        focusWork.heroEnrichmentTask?.cancel()
        focusWork.heroEnrichmentTask = Task { @MainActor in
            guard let fetched = await Task.detached(priority: .utility, operation: {
                await Self.fetchMetadataWithTimeout(
                    repository: repository,
                    id: targetId,
                    type: targetType,
                    timeoutSeconds: 2.0
                )
            }).value else {
                return
            }
            guard !Task.isCancelled,
                  metadataContext == CinemetaCatalogRepository.metadataCacheContext else { return }
            focusWork.enrichedHeroMetadata[enrichmentKey] = fetched
            let merged = settledMeta.fillingMissingHeroMetadata(from: fetched)
            guard focusWork.pendingFocusedMeta?.id == settledMeta.id,
                  focusWork.pendingSectionId == sectionId,
                  focusWork.pendingFocusedFolder == nil else {
                return
            }
            focusedMeta = merged
            focusWork.pendingFocusedMeta = merged
            TVHomeDebugTrace.log("hero.enrich published merged hero item=\(settledMeta.id)")
        }
    }

    @MainActor
    private func loadMoreSectionIfNeeded(sectionId: String, currentItem: NuvioMeta) {
        if let collectionHome {
            guard isActive, !isFullScreenOverlayPresented else { return }
            collectionHome.loadMore(rowID: sectionId, currentItem: currentItem)
            return
        }
        // The resume row is built locally from the ledger rather than fetched
        // from an add-on catalog, so it pages through its own path.
        if sectionId == TVHomeSection.continueWatchingId {
            loadMoreContinueWatchingIfNeeded(currentItem: currentItem)
            return
        }
        if sectionId == TVHomeSection.upcomingId || sectionId == TVHomeSection.calendarTodayId {
            return
        }
        guard let sectionIndex = store.sections.firstIndex(where: { $0.id == sectionId }) else { return }
        let section = store.sections[sectionIndex]
        guard section.hasMore,
              !section.isLoadingMore,
              let contentType = section.contentType,
              let catalogId = section.catalogId,
              let itemIndex = section.items.firstIndex(where: { $0.id == currentItem.id }),
              pendingInitialFocusCardKey == nil,
              !suppressReturnFocusAnimations,
              (itemIndex > 0 || section.items.count > TVHomeRowPrefetchThreshold),
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
            let batchCount = min(50, section.pendingItems.count)
            let batch = Array(section.pendingItems.prefix(batchCount))
            store.sections[sectionIndex].pendingItems.removeFirst(batchCount)
            let existingIds = Set(store.sections[sectionIndex].items.map(\.homeTitleIdentity))
            store.sections[sectionIndex].items.append(contentsOf: batch.filter { !existingIds.contains($0.homeTitleIdentity) })
            store.sections[sectionIndex].hasMore =
                !store.sections[sectionIndex].pendingItems.isEmpty
                || (store.sections[sectionIndex].contentType != nil && store.sections[sectionIndex].catalogId != nil)
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
                let enrichedById = Dictionary(TVHomeCardIdentity.uniqueTitles(enrichedBatch).map { ($0.homeTitleIdentity, $0) }, uniquingKeysWith: { first, _ in first })
                store.sections[latestIndex].items = store.sections[latestIndex].items.map { item in
                    enrichedById[item.homeTitleIdentity] ?? item
                }
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
                let existingIds = Set(store.sections[latestIndex].items.map(\.homeTitleIdentity))
                let newItems = page.items.filter { !existingIds.contains($0.homeTitleIdentity) }

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

    private func checkAndTriggerAutoRefresh() {
        guard isActive && !isFullScreenOverlayPresented else { return }
        if let collectionHome, collectionHome.requiresReload {
            homeReloadTask?.cancel()
            let identity = contentIdentity
            homeReloadTask = Task { @MainActor in await load(for: identity, forceReload: true) }
            return
        }
        guard let lastLoaded = store.lastLoadedAt else { return }

        let thresholdSeconds: TimeInterval?
        switch catalogAutoRefreshInterval {
        case "15m", "15 Minutes":
            thresholdSeconds = 15 * 60
        case "30m", "30 Minutes":
            thresholdSeconds = 30 * 60
        case "1h", "1 Hour":
            thresholdSeconds = 60 * 60
        case "Always", "Every Time":
            thresholdSeconds = 0
        default:
            thresholdSeconds = nil
        }

        guard let threshold = thresholdSeconds else { return }
        let elapsed = Date().timeIntervalSince(lastLoaded)
        if elapsed >= threshold {
            TVHomeDebugTrace.log("home.autoRefresh triggered elapsed=\(Int(elapsed))s threshold=\(Int(threshold))s")
            homeReloadTask?.cancel()
            let identity = contentIdentity
            homeReloadTask = Task { @MainActor in
                await load(for: identity, forceReload: true)
            }
        }
    }

    @MainActor
    private func refreshHomeSection(sectionId: String) {
        if collectionHome != nil {
            homeReloadTask?.cancel()
            let identity = contentIdentity
            homeReloadTask = Task { @MainActor in await load(for: identity, forceReload: true) }
            return
        }
        if sectionId == TVHomeSection.continueWatchingId {
            scheduleContinueWatchingRefresh()
            onRequestAccountRefresh(true)
            return
        }
        if sectionId == TVHomeSection.upcomingId {
            scheduleContinueWatchingRefresh()
            return
        }
        if sectionId == TVHomeSection.calendarTodayId {
            CalendarViewModel.shared.load()
            return
        }
        guard let sectionIndex = store.sections.firstIndex(where: { $0.id == sectionId }) else { return }
        let section = store.sections[sectionIndex]
        store.sections[sectionIndex].isLoadingMore = true

        Task { @MainActor in
            defer {
                if let idx = store.sections.firstIndex(where: { $0.id == sectionId }) {
                    store.sections[idx].isLoadingMore = false
                }
            }

            if section.isCollectionRow {
                let collections = await loadCollectionSections()
                if let matchingCol = collections.first(where: { $0.id == sectionId }),
                   let idx = store.sections.firstIndex(where: { $0.id == sectionId }) {
                    store.sections[idx] = matchingCol
                }
                return
            }

            guard let contentType = section.contentType, let catalogId = section.catalogId else { return }
            do {
                let page = try await repository.browseCatalog(
                    addonId: section.addonId,
                    contentType: contentType,
                    catalogId: catalogId,
                    skip: 0,
                    genre: section.catalogGenre
                )
                guard let idx = store.sections.firstIndex(where: { $0.id == sectionId }) else { return }
                store.sections[idx].items = page.items
                store.sections[idx].nextSkip = page.nextSkip ?? page.items.count
                store.sections[idx].hasMore = page.hasMore && !page.items.isEmpty
                store.sections[idx].pendingItems = []
                TVHomeDebugTrace.log("home.refreshSection succeeded section=\(sectionId) count=\(page.items.count)")
            } catch {
                TVHomeDebugTrace.log("home.refreshSection failed section=\(sectionId) error=\(error.localizedDescription)")
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
        let delaySeconds = min(10, max(0, focusedPosterBackdropDelay))
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
        let generation = returnFocusAnimationGeneration
        TVHomeDebugTrace.log("home.suppressReturnFocusAnimations armed gen=\(generation)")
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            suppressReturnFocusAnimations = true
            landscapeFocusedId = nil
        }
        focusWork.pendingLandscapeFocusedId = nil
        focusWork.landscapeFocusTask?.cancel()

        // Safety fallback: Never leave animations suppressed for longer than 0.5s.
        // If focus restoration takes longer, lands on an unpredicted card, or misses
        // a callback, restore normal motion so scrolling never stays stiff or slow.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard self.isActive, self.returnFocusAnimationGeneration == generation else { return }
            if self.suppressReturnFocusAnimations {
                TVHomeDebugTrace.log("home.suppressReturnFocusAnimations safety timer expired gen=\(generation), releasing suppression")
                self.releaseReturnFocusAnimationSuppression()
            }
        }
    }

    private func releaseReturnFocusAnimationSuppression() {
        guard suppressReturnFocusAnimations else { return }
        let generation = returnFocusAnimationGeneration
        TVHomeDebugTrace.log("home.suppressReturnFocusAnimations scheduling release gen=\(generation)")

        // Let the restored card and row settle for a couple of frames while
        // animations are disabled, then restore normal navigation motion.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            guard isActive, returnFocusAnimationGeneration == generation else { return }
            TVHomeDebugTrace.log("home.suppressReturnFocusAnimations released gen=\(generation)")
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

    /// Fast-scroll tracking (matching Android DpadFastScrollModifier):
    /// suppresses intermediate card focus oscillations during continuous remote holding or rapid swiping.
    private func recordFocusTransition() {
        let now = CACurrentMediaTime()
        let delta = now - focusWork.lastFocusTransitionTime
        focusWork.lastFocusTransitionTime = now
        let deltaMs = String(format: "%.1f", delta * 1000)
        if delta > 0 && delta <= 0.28 {
            if !isFastScrolling {
                isFastScrolling = true
                TVHomeDebugTrace.log("⚡️ [FAST_SCROLL_ENTER] delta=\(deltaMs)ms -> isFastScrolling=true")
            }
        }
        TVHomeDebugTrace.log("🕹 [FOCUS_TRANSITION] delta=\(deltaMs)ms isFastScrolling=\(isFastScrolling)")
        focusWork.fastScrollSettleTask?.cancel()
        focusWork.fastScrollSettleTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            TVHomeDebugTrace.log("🏁 [FAST_SCROLL_SETTLE] 180ms rest -> isFastScrolling=false")
            self.isFastScrolling = false
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

    /// Prepare annotations outside focus-driven body evaluation. Resolve the
    /// current collection definition so deletes and artwork edits are honored.
    private func refreshContinueWatchingOrigins(_ items: [ContinueWatchingItem]) {
        guard collectionHome == nil,
              ProfileSettings.activeProfileID == contentIdentity.profileId else {
            continueWatchingOrigins = [:]
            return
        }
        let services = CollectionOriginPresentation.configured(profileID: contentIdentity.profileId)
        let origins = CollectionPlaybackOriginStore.presentations(
            for: items.filter { !$0.isUpNextEntry }.map(\.meta),
            profileID: contentIdentity.profileId, services: services
        )
        if origins != continueWatchingOrigins { continueWatchingOrigins = origins }
    }

    /// Publish Continue Watching and derived lookups together, outside body.
    private func setContinueWatching(_ rawItems: [ContinueWatchingItem]) {
        refreshContinueWatchingOrigins(rawItems)
        if appliedContinueWatchingSort == continueWatchingSort,
           rawContinueWatchingItems.count == rawItems.count {
            let isIdentical = zip(rawContinueWatchingItems, rawItems).allSatisfy { $0.isContentEqual(to: $1) }
            if isIdentical {
                return
            }
        }
        appliedContinueWatchingSort = continueWatchingSort
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
        TVHomeDebugTrace.measure("home.setContinueWatching count=\(all.count)") {
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
    }

    private func refreshContinueWatching(forceImmediate: Bool = false) {
        guard collectionHome == nil else { return }
        let now = Date()
        let elapsed = now.timeIntervalSince(lastContinueWatchingRefreshedAt)
        let cooldown: TimeInterval = 0.15

        if forceImmediate || elapsed >= cooldown {
            pendingContinueWatchingDebounceTask?.cancel()
            pendingContinueWatchingDebounceTask = nil
            lastContinueWatchingRefreshedAt = now
            performRefreshContinueWatching()
        } else {
            // Already refreshed within the cooldown window: coalesce rapid bursts into a trailing refresh.
            guard pendingContinueWatchingDebounceTask == nil else { return }
            let remaining = max(0.01, cooldown - elapsed)
            pendingContinueWatchingDebounceTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                guard !Task.isCancelled else { return }
                pendingContinueWatchingDebounceTask = nil
                lastContinueWatchingRefreshedAt = Date()
                performRefreshContinueWatching()
            }
        }
    }

    private func performRefreshContinueWatching() {
        guard collectionHome == nil else { return }
        TVHomeDebugTrace.measure("home.refreshContinueWatching") {
            guard !usesRemoteProgress else {
                print("[ContinueWatching][Home] refreshContinueWatching: usesRemoteProgress=true (\(selectedProgressSource.rawValue))")
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
            // during playback lands there immediately. Later pages live only in the
            // builder, so merge those back while letting the current store win.
            var byId: [String: ContinueWatchingItem] = [:]
            let storedItems = TVHomeDebugTrace.measure("cw.snapshot.read") { ContinueWatchingStore.items() }
            let mergedItems = ContinueWatchingBuilder.mergeMemoryOnlyItems(
                ContinueWatchingBuilder.memoryOnlyPagedItems,
                with: storedItems
            )
            for item in mergedItems {
                byId[item.meta.id] = item
            }
            // `recencySortDate`, not `lastWatchedAt`: this pass is what the "Default"
            // sort preference ends up being, and a new drop belongs at the top of it
            // on the day it airs rather than wherever the seeding episode's age puts
            // it. They are the same value for every other card.
            let visibleItems: [ContinueWatchingItem] = TVHomeDebugTrace.measure("cw.snapshot.prepare") {
                let keyedItems: [(item: ContinueWatchingItem, date: Date)] = byId.values.map {
                    (item: $0, date: $0.recencySortDate)
                }
                let orderedItems = keyedItems.sorted { lhs, rhs in
                    if lhs.date == rhs.date { return lhs.item.meta.id < rhs.item.meta.id }
                    return lhs.date > rhs.date
                }
                let items = orderedItems.map { $0.item }
                return items.filter(shouldDisplayContinueWatchingItem)
            }
            print("[ContinueWatching][Home] refreshContinueWatching: paged=\(ContinueWatchingBuilder.pagedItems.count), stored=\(storedItems.count), merged=\(byId.count), visible=\(visibleItems.count)")
            setContinueWatching(visibleItems)
            displayedProgressSource = .nuvioSync
            #if DEBUG
            logRowWindow("after CW refresh (\(continueWatching.count) item(s), \(upcomingItems.count) upcoming)")
            #endif
        }
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
              pendingInitialFocusCardKey == nil,
              !suppressReturnFocusAnimations,
              let index = continueIndex,
              (index > 0 || continueWatching.count > TVHomeRowPrefetchThreshold),
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
        guard collectionHome == nil else { return }
        continueWatchingRefreshTask?.cancel()
        continueWatchingRefreshTask = Task {
            await refreshContinueWatchingFromSelectedSource()
        }
    }

    /// Watched history is an account-level Trakt mirror, so it must refresh
    /// independently of the provider selected for Continue Watching. The
    /// service coalesces overlapping requests and the captured profile keeps a
    /// late response from refreshing another profile's UI.
    private func scheduleTraktWatchedHistorySync() {
        guard collectionHome == nil else { return }
        traktWatchedHistorySyncTask?.cancel()
        guard isActive,
              let profileID = WatchedStore.activeProfileId,
              !profileID.isEmpty,
              ProfileSettings.isActiveStore(ProfileSettings.current),
              TraktAuthStore.isAuthenticated(in: ProfileSettings.current) else {
            traktWatchedHistorySyncTask = nil
            return
        }

        let store = ProfileSettings.store(for: profileID)
        traktWatchedHistorySyncTask = Task.detached(priority: .utility) {
            _ = await TraktHistoryService.syncWatchedHistory(store: store)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard WatchedStore.activeProfileId == profileID else { return }
                refreshWatchedTitles()
            }
        }
    }

    @MainActor
    private func refreshContinueWatchingFromSelectedSource() async {
        guard collectionHome == nil else { return }
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

        if usesRemoteProgress {
            refreshContinueWatching()
        }
        guard usesRemoteProgress else {
            // The ledger this just read is only as fresh as the last account
            // pull. Ask for a new one; it lands via the store's change
            // notification, which already refreshes the row.
            let now = Date()
            if let last = lastAccountRefreshRequestedAt, now.timeIntervalSince(last) < 30 {
                return
            }
            lastAccountRefreshRequestedAt = now
            print("[ContinueWatching][Home] refreshContinueWatchingFromSelectedSource: triggering account refresh for local ledger")
            onRequestAccountRefresh(false)
            return
        }

        print("[ContinueWatching][Home] refreshContinueWatchingFromSelectedSource: fetching from remote provider \(source.rawValue)")
        let items = await TraktProgressService.fetchContinueWatching(
            repository: repository,
            source: source,
            displayPredicate: shouldDisplayContinueWatchingItem,
            displaySort: { items in
                TraktProgressService.sortContinueWatchingForDisplaySelection(
                    items,
                    preference: continueWatchingSort
                )
            }
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
            print("[ContinueWatching][Home] refreshContinueWatchingFromSelectedSource: remote returned nil")
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
        print("[ContinueWatching][Home] refreshContinueWatchingFromSelectedSource: remote returned \(items.count) items -> visible \(visibleItems.count)")
        setContinueWatching(visibleItems)
        displayedProgressSource = source

        // Continue Watching is visible now. Other providers own their own
        // watched snapshots; Trakt is refreshed independently above so its
        // history remains available even when another provider owns resume.
        switch source {
        case .nuvioSync, .trakt:
            break
        case .wetrakr:
            Task.detached(priority: .utility) {
                _ = await WeTrakrProgressService.syncWatchedHistory()
            }
        case .simkl:
            Task.detached(priority: .utility) {
                _ = await SimklHistoryService.syncWatchedHistory()
            }
        case .mdblist:
            Task.detached(priority: .utility) {
                _ = await MdbListProgressService.syncWatchedHistory()
            }
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
        guard collectionHome == nil else { return }
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
        focusWork.cachedVisibleSections = nil
        guard collectionHome == nil else { return }
        guard contentIdentity.profileId != "none" && !contentIdentity.profileId.isEmpty else {
            jellyfinSections = []
            return
        }
        guard jellyfinLocalRowEnabled else {
            jellyfinSections = []
            return
        }
        let indexedTitles = JellyfinLibraryIndex.shared.titles()
        let legacyTitles = indexedTitles.filter { $0.libraryID == nil || $0.libraryName == nil }
        var sections: [TVHomeSection] = []
        let legacyMetas = Self.jellyfinMetas(legacyTitles)
        if !legacyMetas.isEmpty {
            sections.append(TVHomeSection(
                id: TVHomeSection.jellyfinId,
                title: L10n.string("home_jellyfin_titles", fallback: "Jellyfin"),
                items: legacyMetas
            ))
        }

        let libraryTitles = indexedTitles.filter { $0.libraryID != nil && $0.libraryName != nil }
        let groupedTitles = Dictionary(grouping: libraryTitles) {
            JellyfinHomeLibraryKey(serverID: $0.serverID, libraryID: $0.libraryID!)
        }
        let serverOrder = Dictionary(uniqueKeysWithValues: JellyfinServerStore.shared.servers.enumerated().map {
            ($0.element.id, $0.offset)
        })
        let orderedKeys = groupedTitles.keys.sorted { lhs, rhs in
            let lhsServerOrder = serverOrder[lhs.serverID] ?? Int.max
            let rhsServerOrder = serverOrder[rhs.serverID] ?? Int.max
            if lhsServerOrder != rhsServerOrder { return lhsServerOrder < rhsServerOrder }
            if lhs.serverID != rhs.serverID { return lhs.serverID < rhs.serverID }
            let lhsName = groupedTitles[lhs]?.first?.libraryName ?? lhs.libraryID
            let rhsName = groupedTitles[rhs]?.first?.libraryName ?? rhs.libraryID
            if lhsName != rhsName { return lhsName < rhsName }
            return lhs.libraryID < rhs.libraryID
        }
        for key in orderedKeys {
            guard let titles = groupedTitles[key],
                  let libraryName = titles.first?.libraryName else { continue }
            let metas = Self.jellyfinMetas(titles)
            guard !metas.isEmpty else { continue }
            sections.append(TVHomeSection(
                id: TVHomeSection.jellyfinLibraryId(serverID: key.serverID, libraryID: key.libraryID),
                title: libraryName,
                items: metas
            ))
        }
        jellyfinSections = sections
    }

    @MainActor
    private static func jellyfinMetas(_ titles: [JellyfinIndexedTitle]) -> [NuvioMeta] {
        titles.sorted {
            if $0.name != $1.name { return $0.name < $1.name }
            return $0.contentId < $1.contentId
        }.compactMap {
            JellyfinLibraryIndex.shared.meta(forContentId: $0.contentId)
        }
    }
}

private struct JellyfinHomeLibraryKey: Hashable {
    let serverID: String
    let libraryID: String
}

struct TVHomeSection: Identifiable {
    static let continueWatchingId = "continue_watching"
    static let upcomingId = "upcoming"
    /// The Today row: the calendar's titles coming out today.
    static let calendarTodayId = "calendar_today"
    static let localTitlesId = "local_titles"
    static let jellyfinId = "jellyfin_titles"
    static let jellyfinLibraryIdPrefix = "jellyfin_library_"
    static func jellyfinLibraryId(serverID: String, libraryID: String) -> String {
        "\(jellyfinLibraryIdPrefix)\(serverID):\(libraryID)"
    }
    /// Id prefix for rows built from account-synced collections.
    static let collectionIdPrefix = "collection_"

    let id: String
    let title: String
    var items: [NuvioMeta] {
        didSet { items = TVHomeCardIdentity.uniqueTitles(items) }
    }
    var contentType: String? = nil
    var catalogId: String? = nil
    var addonId: String? = nil
    /// Display name of the add-on this row came from, for the Settings list.
    var addonName: String? = nil
    var catalogGenre: String? = nil
    var manifestURL: String? = nil
    var manifestShowInHome: Bool? = nil
    var posterShape: String? = nil
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
    var collectionFolders: [TVCollectionFolderItem] = [] {
        didSet { collectionFolders = TVHomeCardIdentity.uniqueFolders(collectionFolders) }
    }

    var tileShape: CollectionTileShape {
        if let posterShape {
            return CollectionTileShape.fromStored(posterShape, fallback: .poster)
        }
        return items.first(where: { $0.tileShape != .poster })?.tileShape ?? .poster
    }

    init(
        id: String, title: String, items: [NuvioMeta],
        contentType: String? = nil, catalogId: String? = nil,
        addonId: String? = nil, addonName: String? = nil,
        catalogGenre: String? = nil, manifestURL: String? = nil,
        manifestShowInHome: Bool? = nil, posterShape: String? = nil,
        pendingItems: [NuvioMeta] = [], nextSkip: Int? = nil,
        hasMore: Bool = false, isLoadingMore: Bool = false,
        isLoadingPlaceholder: Bool = false, isPinnedCollection: Bool = false,
        collectionFolders: [TVCollectionFolderItem] = []
    ) {
        self.id = id
        self.title = title
        self.items = TVHomeCardIdentity.uniqueTitles(items)
        self.contentType = contentType
        self.catalogId = catalogId
        self.addonId = addonId
        self.addonName = addonName
        self.catalogGenre = catalogGenre
        self.manifestURL = manifestURL
        self.manifestShowInHome = manifestShowInHome
        self.posterShape = posterShape
        self.pendingItems = pendingItems
        self.nextSkip = nextSkip
        self.hasMore = hasMore
        self.isLoadingMore = isLoadingMore
        self.isLoadingPlaceholder = isLoadingPlaceholder
        self.isPinnedCollection = isPinnedCollection
        self.collectionFolders = TVHomeCardIdentity.uniqueFolders(collectionFolders)
    }

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
    static let forceRefreshNotification = Notification.Name("nuvio.tv.homeCatalog.forceRefresh")
    private static let snapshotDirectoryName = "catalogSnapshots"
    private static let snapshotWriter = TVHomeCatalogSnapshotWriter()
    private static let snapshotPersistenceQueue = DispatchQueue(label: "nuvio.tv.catalogSnapshot.persistence", qos: .utility)
    private static let snapshotCacheLock = NSLock()
    private static var snapshotCacheData: [String: Data] = [:]
    private static var snapshotCacheRows: [String: [SnapshotRow]] = [:]

    static func waitForSnapshotPersistenceForTesting() {
        snapshotPersistenceQueue.sync {}
    }

    static func invalidateSnapshotCache(for storageKey: String? = nil) {
        snapshotCacheLock.lock()
        defer { snapshotCacheLock.unlock() }
        if let storageKey {
            snapshotCacheData.removeValue(forKey: storageKey)
            snapshotCacheRows.removeValue(forKey: storageKey)
        } else {
            snapshotCacheData.removeAll()
            snapshotCacheRows.removeAll()
        }
    }

    private static func snapshotStorageKey(for settings: UserDefaults) -> String {
        let profileID = settings.string(forKey: "nuvio.tv.profile.settings.profileID") ?? (ProfileSettings.activeProfileID ?? "default")
        return "homeCatalogTitles_\(profileID)"
    }

    static func cleanCatalogTitle(_ name: String, addonName: String?) -> String {
        var title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let addonName = addonName?.trimmingCharacters(in: .whitespacesAndNewlines), !addonName.isEmpty else {
            return title
        }

        let candidates = [
            addonName,
            addonName.replacingOccurrences(of: "Addon", with: "", options: .caseInsensitive).trimmingCharacters(in: .whitespaces),
            addonName.replacingOccurrences(of: "Metadata", with: "", options: .caseInsensitive).trimmingCharacters(in: .whitespaces),
            addonName.replacingOccurrences(of: "Streams", with: "", options: .caseInsensitive).trimmingCharacters(in: .whitespaces)
        ].filter { !$0.isEmpty }

        for candidate in candidates {
            let bracketedPrefixes = [
                "[\(candidate)]",
                "(\(candidate))",
                "【\(candidate)】"
            ]
            for prefix in bracketedPrefixes {
                if let range = title.range(of: prefix, options: [.caseInsensitive, .anchored]) {
                    title = String(title[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if title.hasPrefix("-") || title.hasPrefix(":") || title.hasPrefix("|") || title.hasPrefix("•") {
                        title = String(title.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    return title
                }
            }

            let separators = [" - ", ": ", " | ", " • ", " – ", " — ", "- "]
            for sep in separators {
                let prefix = candidate + sep
                if let range = title.range(of: prefix, options: [.caseInsensitive, .anchored]) {
                    title = String(title[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    return title
                }
            }

            if let range = title.range(of: candidate, options: [.caseInsensitive, .anchored]) {
                let remainder = String(title[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if remainder.hasPrefix("-") || remainder.hasPrefix(":") || remainder.hasPrefix("|") || remainder.hasPrefix("•") {
                    title = String(remainder.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
                    return title
                }
            }
        }

        return title
    }

    static func catalogDisplayTitle(
        _ name: String,
        contentType: String,
        showType: Bool,
        addonName: String? = nil,
        customTitle: String? = nil
    ) -> String {
        if let customTitle = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !customTitle.isEmpty {
            return customTitle
        }
        let cleaned = cleanCatalogTitle(name, addonName: addonName)
        guard showType else { return cleaned }
        let normalized = contentType.lowercased().replacingOccurrences(of: "_", with: "-")
        let suffix: String
        switch normalized {
        case "movie": suffix = "Movies"
        case "series", "show", "tvshow", "tv-show", "tv": suffix = "Series"
        case "anime": suffix = "Anime"
        case "channel", "live", "livetv", "live-tv", "iptv", "radio": suffix = "Channels"
        default: suffix = contentType.prefix(1).uppercased() + contentType.dropFirst()
        }
        let lower = cleaned.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lower.hasSuffix(suffix.lowercased()),
              !(suffix == "Series" && (lower.hasSuffix("tv shows") || lower.hasSuffix("tv show") || lower.hasSuffix("shows") || lower.hasSuffix("series"))) else { return cleaned }
        return "\(cleaned) - \(suffix)"
    }

    static func customCatalogTitles() -> [String: String] {
        HomeCatalogPayloadStore.customCatalogTitles()
    }

    static func customTitle(forCatalogKey key: String) -> String? {
        guard let title = customCatalogTitles()[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return nil }
        return title
    }

    static func setCustomCatalogTitles(_ titles: [String: String]) {
        guard let data = try? JSONEncoder().encode(titles) else { return }
        _ = HomeCatalogPayloadStore.write(data, forKey: SettingsKey.homeCatalogCustomTitles)
    }

    static func savedOrder() -> [String] {
        guard let data = HomeCatalogPayloadStore.data(forKey: SettingsKey.homeCatalogOrder),
              let keys = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return normalizedOrder(keys)
    }

    static func save(_ keys: [String]) {
        let keys = normalizedOrder(keys)
        guard let data = try? JSONEncoder().encode(keys) else { return }
        guard HomeCatalogPayloadStore.write(data, forKey: SettingsKey.homeCatalogOrder) else { return }
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }

    static func clearOrder() {
        HomeCatalogPayloadStore.remove(forKey: SettingsKey.homeCatalogOrder)
        HomeCatalogPayloadStore.remove(forKey: SettingsKey.homeCatalogSyncedOrder)
        HomeCatalogPayloadStore.remove(forKey: SettingsKey.homeCatalogExplicitEnabled)
        HomeCatalogPayloadStore.remove(forKey: SettingsKey.homeCatalogCustomTitles)
        HomeCatalogPayloadStore.remove(forKey: SettingsKey.homeCatalogDeleted)
        ProfileSettings.current.removeObject(forKey: SettingsKey.homeCatalogTitles)
        let storageKey = snapshotStorageKey(for: ProfileSettings.current)
        LargePayloadStore.remove(key: storageKey, directory: snapshotDirectoryName)
        invalidateSnapshotCache(for: storageKey)
        NotificationCenter.default.post(name: changedNotification, object: nil)
        NotificationCenter.default.post(name: snapshotChangedNotification, object: nil)
    }

    static func syncedOrder() -> [String] {
        guard let data = HomeCatalogPayloadStore.data(forKey: SettingsKey.homeCatalogSyncedOrder),
              let keys = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return normalizedOrder(keys)
    }

    static func effectiveOrderKeys() -> [String] {
        let local = savedOrder()
        if !local.isEmpty { return local }
        return syncedOrder()
    }

    /// Home sections use `addon_<catalog-key>` ids while the account layout
    /// uses the catalog key without that UI prefix. Store the canonical form
    /// locally too, so a locally saved reorder survives the next catalog load.
    static func normalizedOrder(_ keys: [String]) -> [String] {
        var seen = Set<String>()
        return keys.compactMap { rawKey in
            let key = sectionOrderKey(rawKey)
            guard !key.isEmpty, seen.insert(key).inserted else { return nil }
            return key
        }
    }

    static func sectionOrderKey(_ id: String) -> String {
        if id.hasPrefix("addon_") {
            return String(id.dropFirst("addon_".count))
        }
        return id
    }

    /// Account catalog keys (`<addonId>_<type>_<catalogId>`) the user has hidden
    /// from Home on another device, pulled from the account. The repository
    /// consults this to drop hidden catalog rows before building Home.
    static func disabledCatalogKeys() -> Set<String> {
        guard let data = HomeCatalogPayloadStore.data(forKey: SettingsKey.homeCatalogDisabled),
              let keys = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(keys)
    }

    /// Keys or IDs permanently deleted locally from Home layout.
    static func deletedCatalogKeys(in settings: UserDefaults = ProfileSettings.current) -> Set<String> {
        guard let data = HomeCatalogPayloadStore.data(forKey: SettingsKey.homeCatalogDeleted, in: settings),
              let keys = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(keys)
    }

    /// Keys explicitly enabled by a local toggle or by the account's Home
    /// order. Local reorder and snapshot rows are intentionally not intent.
    static func explicitHomeCatalogKeys() -> Set<String> {
        explicitHomeCatalogKeys(disabled: disabledCatalogKeys())
    }

    private static func explicitHomeCatalogKeys(disabled: Set<String>) -> Set<String> {
        let account = syncedOrder()
        return localExplicitHomeCatalogKeys().union(account)
            .filter { !$0.hasPrefix(TVHomeSection.collectionIdPrefix) }
            .subtracting(disabled)
    }

    private static func localExplicitHomeCatalogKeys() -> Set<String> {
        guard let data = HomeCatalogPayloadStore.data(forKey: SettingsKey.homeCatalogExplicitEnabled),
              let keys = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(keys)
    }

    struct HomeVisibilityContext {
        let collectionSources: [CatalogHomeVisibilityResolver.Source]
        let explicitHomeKeys: Set<String>
        let disabledCatalogKeys: Set<String>
    }

    static func homeVisibilityContext() -> HomeVisibilityContext {
        let disabled = disabledCatalogKeys()
        return HomeVisibilityContext(
            collectionSources: CatalogHomeVisibilityResolver.collectionSources(),
            explicitHomeKeys: explicitHomeCatalogKeys(disabled: disabled),
            disabledCatalogKeys: disabled
        )
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

    private static let pendingCollectionVisibilityKey = "nuvio.tv.homeCollectionVisibility.pending"

    /// Local choices remain authoritative until an explicit remote item confirms
    /// them. This small profile-scoped journal also survives a failed push/restart.
    static func pendingCollectionVisibility(in settings: UserDefaults = ProfileSettings.current) -> [String: Bool] {
        guard let data = settings.data(forKey: pendingCollectionVisibilityKey),
              let values = try? JSONDecoder().decode([String: Bool].self, from: data) else { return [:] }
        return values
    }

    private static func savePendingCollectionVisibility(_ values: [String: Bool], in settings: UserDefaults) {
        if values.isEmpty {
            settings.removeObject(forKey: pendingCollectionVisibilityKey)
        } else if let data = try? JSONEncoder().encode(values) {
            settings.set(data, forKey: pendingCollectionVisibilityKey)
        }
    }

    private static func recordCollectionVisibility(_ id: String, isEnabled: Bool) {
        let settings = ProfileSettings.current
        var pending = pendingCollectionVisibility(in: settings)
        pending[id] = isEnabled
        savePendingCollectionVisibility(pending, in: settings)
    }

    /// A missing remote item is not an acknowledgement. Conflicting duplicate
    /// items are also left pending rather than discarding the user's choice.
    static func acknowledgeCollectionVisibility(_ remote: [(id: String, enabled: Bool)], in settings: UserDefaults) {
        var pending = pendingCollectionVisibility(in: settings)
        let original = pending
        for (id, enabled) in original {
            let matches = remote.filter { $0.id == id }
            if !matches.isEmpty, matches.allSatisfy({ $0.enabled == enabled }) {
                pending.removeValue(forKey: id)
            }
        }
        if pending != original { savePendingCollectionVisibility(pending, in: settings) }
    }

    /// Remote visibility plus local choices not yet acknowledged by the account.
    static func disabledCollectionIds() -> Set<String> {
        let data = HomeCatalogPayloadStore.data(forKey: SettingsKey.homeCollectionDisabled)
        let keys = data.flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        var disabled = Set(keys)
        for (id, enabled) in pendingCollectionVisibility() {
            if enabled { disabled.remove(id) } else { disabled.insert(id) }
        }
        return disabled
    }

    /// Account catalog keys in the account's Home order → position, used by the
    /// repository to order the add-on catalog rows. Empty when nothing synced.
    static func syncedCatalogOrderIndex() -> [String: Int] {
        guard let data = HomeCatalogPayloadStore.data(forKey: SettingsKey.homeCatalogSyncedOrder),
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
        let syncedKeys = syncedOrder()
        // Prefer the local Settings reorder; otherwise honor the account layout
        // (including `collection_<id>` slots among catalogs).
        let order = localOrder.isEmpty ? syncedKeys : localOrder
        guard !order.isEmpty else { return sections }
        var indexByKey: [String: Int] = [:]
        for (index, key) in order.enumerated() where indexByKey[key] == nil {
            indexByKey[key] = index
        }
        func orderKeys(for section: TVHomeSection) -> [String] {
            var keys = [section.id]
            let normalized = sectionOrderKey(section.id)
            if normalized != section.id {
                keys.append(normalized)
            }
            if let settingsKey = section.catalogSettingsKey, !keys.contains(settingsKey) {
                keys.append(settingsKey)
            }
            return keys
        }
        func bestIndex(for section: TVHomeSection) -> Int? {
            for key in orderKeys(for: section) {
                if let index = indexByKey[key] {
                    return index
                }
            }
            return nil
        }
        let known = sections
            .filter { bestIndex(for: $0) != nil }
            .sorted {
                (bestIndex(for: $0) ?? 0) < (bestIndex(for: $1) ?? 0)
        }
        let unknown = sections.filter { bestIndex(for: $0) == nil }
        return known + unknown
    }

    /// One row as the Settings list needs it: what to call it, which add-on it
    /// came from, and the key that hides it.
    struct SnapshotRow: Equatable, Sendable {
        let id: String
        let title: String
        var addonName: String? = nil
        var addonId: String? = nil
        var contentType: String? = nil
        var catalogId: String? = nil
        var manifestURL: String? = nil
        var manifestShowInHome: Bool? = nil
        /// Nil for a row that cannot be hidden (Continue Watching).
        var settingsKey: String? = nil
        var posterShape: String? = nil
    }

    /// The account's key for a catalog row. Kept here so the repository, Home
    /// and Settings cannot drift into two spellings of the same key.
    static func catalogSettingsKey(addonId: String, contentType: String, catalogId: String) -> String {
        "\(addonId)_\(contentType)_\(catalogId)"
    }

    /// Records the effective rows after a Home load.
    ///
    /// Preserves all previously recorded snapshot rows (both hidden rows and
    /// active rows whose network requests may have been empty, in-flight, or
    /// temporarily failed) at their existing positions so the user's custom
    /// layout order is never purged or scrambled.
    static func writeSnapshot(_ sections: [TVHomeSection]) {
        TVHomeDebugTrace.measure("TVHomeCatalogOrder.writeSnapshot count=\(sections.count)") {
            let rows = mergedSnapshotRows(
                current: makeSnapshotRows(from: sections),
                previous: snapshotRows(in: ProfileSettings.current)
            )
            writeSnapshotRows(rows, in: ProfileSettings.current)
        }
    }

    /// Coalesces Home's progressive catalog updates and persists the result on
    /// a non-main actor. The caller only builds the small row descriptor array;
    /// UserDefaults I/O, JSON serialization, and notification delivery happen
    /// after a quiet period so a catalog response cannot block focus/layout.
    static func scheduleSnapshotWrite(_ sections: [TVHomeSection]) {
        let rows = makeSnapshotRows(from: sections)
        let profileID = ProfileSettings.activeProfileID
        Task {
            await snapshotWriter.schedule(rows: rows, profileID: profileID)
        }
    }

    /// Batches multiple add-on snapshot row updates into a single snapshot write,
    /// avoiding repeated disk writes, settings version bumps, and sync pushes.
    static func batchReplaceSnapshotRows(
        _ updates: [(addonID: String, addonName: String, additions: [SnapshotRow])]
    ) {
        guard !updates.isEmpty else { return }
        for update in updates {
            if let url = update.additions.compactMap(\.manifestURL).first {
                AddonCatalogRemovalStore.didDiscover(addonID: update.addonID, manifestURL: url, in: ProfileSettings.current)
            }
        }
        let current = snapshotRows()
        let deleted = deletedCatalogKeys()
        func isDeleted(_ row: SnapshotRow) -> Bool {
            deleted.contains(row.id)
                || (row.settingsKey != nil && deleted.contains(row.settingsKey!))
                || deleted.contains(sectionOrderKey(row.id))
        }

        var rows = current
        for update in updates {
            let normalizedName = normalizedAddonSourceName(update.addonName)
            func belongsToSource(_ row: SnapshotRow) -> Bool {
                if row.addonId == update.addonID { return true }
                guard row.addonId == nil, let rowName = row.addonName else { return false }
                return normalizedAddonSourceName(rowName) == normalizedName
            }

            let insertionIndex = rows.firstIndex(where: belongsToSource) ?? rows.count
            rows = rows.filter { !belongsToSource($0) && !isDeleted($0) }
            var seen = Set<String>()
            let uniqueAdditions = update.additions.filter { !isDeleted($0) && seen.insert($0.id).inserted }
            rows.insert(contentsOf: uniqueAdditions, at: min(insertionIndex, rows.count))
        }

        guard rows != current else { return }
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
        batchReplaceSnapshotRows([(addonID: addonID, addonName: addonName, additions: additions)])
    }

    static func writeSnapshotRows(_ rows: [SnapshotRow], in settings: UserDefaults = ProfileSettings.current) {
        TVHomeDebugTrace.measure("TVHomeCatalogOrder.writeSnapshotRows count=\(rows.count)") {
            let deleted = deletedCatalogKeys(in: settings)
            let removed = AddonCatalogRemovalStore.context(in: settings)
            let filteredRows = rows.filter { row in
                if removed.removes(row) { return false }
                if deleted.contains(row.id) { return false }
                if let key = row.settingsKey, deleted.contains(key) { return false }
                let normalized = sectionOrderKey(row.id)
                if deleted.contains(normalized) { return false }
                return true
            }
            let uniqueRows = uniqueSnapshotRows(filteredRows)
            let storageKey = snapshotStorageKey(for: settings)
            let removalGeneration = AddonCatalogRemovalStore.generation(in: settings)

            // Synchronously update in-memory row cache under lock so immediate callers/reads reflect changes
            snapshotCacheLock.withLock {
                snapshotCacheRows[storageKey] = uniqueRows
            }

            // Serial persistence stops an older write landing after cleanup.
            snapshotPersistenceQueue.async {
                guard AddonCatalogRemovalStore.generation(in: settings) == removalGeneration else { return }
                let removedNow = AddonCatalogRemovalStore.context(in: settings)
                let payload = uniqueRows.filter { !removedNow.removes($0) }.map { row -> [String: String] in
                    var entry = ["id": row.id, "title": row.title]
                    if let addonName = row.addonName { entry["addon"] = addonName }
                    if let addonId = row.addonId { entry["addonId"] = addonId }
                    if let contentType = row.contentType { entry["type"] = contentType }
                    if let catalogId = row.catalogId { entry["catalogId"] = catalogId }
                    if let manifestURL = row.manifestURL { entry["manifestURL"] = manifestURL }
                    if let manifestShowInHome = row.manifestShowInHome {
                        entry["manifestShowInHome"] = manifestShowInHome ? "true" : "false"
                    }
                    if let settingsKey = row.settingsKey { entry["key"] = settingsKey }
                    if let posterShape = row.posterShape { entry["posterShape"] = posterShape }
                    return entry
                }
                guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
                let isSameAsCached: Bool = snapshotCacheLock.withLock {
                    snapshotCacheData[storageKey] == data
                }
                if isSameAsCached {
                    if settings.object(forKey: SettingsKey.homeCatalogTitles) != nil {
                        settings.removeObject(forKey: SettingsKey.homeCatalogTitles)
                    }
                    if UserDefaults.standard.object(forKey: SettingsKey.homeCatalogTitles) != nil {
                        UserDefaults.standard.removeObject(forKey: SettingsKey.homeCatalogTitles)
                    }
                    return
                }

                let existing = LargePayloadStore.read(key: storageKey, directory: snapshotDirectoryName)
                if existing != data {
                    if LargePayloadStore.write(data, key: storageKey, directory: snapshotDirectoryName) {
                        if settings.object(forKey: SettingsKey.homeCatalogTitles) != nil {
                            settings.removeObject(forKey: SettingsKey.homeCatalogTitles)
                        }
                        if UserDefaults.standard.object(forKey: SettingsKey.homeCatalogTitles) != nil {
                            UserDefaults.standard.removeObject(forKey: SettingsKey.homeCatalogTitles)
                        }
                    }
                    snapshotCacheLock.withLock {
                        snapshotCacheData[storageKey] = data
                    }
                    postSnapshotChangedNotification()
                } else {
                    snapshotCacheLock.withLock {
                        snapshotCacheData[storageKey] = data
                    }
                    if settings.object(forKey: SettingsKey.homeCatalogTitles) != nil {
                        settings.removeObject(forKey: SettingsKey.homeCatalogTitles)
                    }
                    if UserDefaults.standard.object(forKey: SettingsKey.homeCatalogTitles) != nil {
                        UserDefaults.standard.removeObject(forKey: SettingsKey.homeCatalogTitles)
                    }
                }
            }
        }
    }

    static func snapshotRows(in settings: UserDefaults = ProfileSettings.current) -> [SnapshotRow] {
        let storageKey = snapshotStorageKey(for: settings)
        let cached = snapshotCacheLock.withLock {
            snapshotCacheRows[storageKey]
        }
        if let cached {
            let removed = AddonCatalogRemovalStore.context(in: settings)
            return cached.filter { !removed.removes($0) }
        }
        let data: Data? = {
            if let fileData = LargePayloadStore.read(key: storageKey, directory: snapshotDirectoryName) {
                return fileData
            }
            guard let legacy = settings.data(forKey: SettingsKey.homeCatalogTitles) ?? UserDefaults.standard.data(forKey: SettingsKey.homeCatalogTitles) else {
                return nil
            }
            if LargePayloadStore.write(legacy, key: storageKey, directory: snapshotDirectoryName) {
                if settings.object(forKey: SettingsKey.homeCatalogTitles) != nil {
                    settings.removeObject(forKey: SettingsKey.homeCatalogTitles)
                }
                if UserDefaults.standard.object(forKey: SettingsKey.homeCatalogTitles) != nil {
                    UserDefaults.standard.removeObject(forKey: SettingsKey.homeCatalogTitles)
                }
            }
            return legacy
        }()
        guard let data else { return [] }
        guard let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: String]] else {
            LargePayloadStore.remove(key: storageKey, directory: snapshotDirectoryName)
            invalidateSnapshotCache(for: storageKey)
            return []
        }
        let customTitles: [String: String]
        if let customData = HomeCatalogPayloadStore.data(forKey: SettingsKey.homeCatalogCustomTitles, in: settings),
           let decoded = try? JSONDecoder().decode([String: String].self, from: customData) {
            customTitles = decoded
        } else {
            customTitles = [:]
        }
        let deleted = deletedCatalogKeys(in: settings)
        let removed = AddonCatalogRemovalStore.context(in: settings)
        let resolvedRows: [SnapshotRow] = rows.compactMap { (row: [String: String]) -> SnapshotRow? in
            guard let id = row["id"], let title = row["title"] else { return nil }
            if deleted.contains(id) { return nil }
            let addonName = row["addon"]
            let settingsKey = row["key"]
            if let settingsKey, deleted.contains(settingsKey) { return nil }
            let normalized = sectionOrderKey(id)
            if deleted.contains(normalized) { return nil }
            // Resolve the display title: custom title from sync takes precedence,
            // then strip the add-on name prefix from the persisted catalog name.
            let resolvedTitle: String
            if let key = settingsKey, let custom = customTitles[key], !custom.isEmpty {
                resolvedTitle = custom
            } else {
                resolvedTitle = cleanCatalogTitle(title, addonName: addonName)
            }
            return SnapshotRow(
                id: id,
                title: resolvedTitle,
                addonName: addonName,
                addonId: row["addonId"],
                contentType: row["type"],
                catalogId: row["catalogId"],
                manifestURL: row["manifestURL"],
                manifestShowInHome: row["manifestShowInHome"].flatMap(Bool.init),
                settingsKey: settingsKey,
                posterShape: row["posterShape"]
            )
        }
        let uniqueRows = uniqueSnapshotRows(resolvedRows.filter { !removed.removes($0) })
        snapshotCacheLock.withLock {
            snapshotCacheData[storageKey] = data
            snapshotCacheRows[storageKey] = uniqueRows
        }
        return uniqueRows
    }

    private static func makeSnapshotRows(from sections: [TVHomeSection]) -> [SnapshotRow] {
        sections.map {
            SnapshotRow(
                id: $0.id,
                title: $0.title,
                addonName: $0.addonName,
                addonId: $0.addonId,
                contentType: $0.contentType,
                catalogId: $0.catalogId,
                manifestURL: $0.manifestURL,
                manifestShowInHome: $0.manifestShowInHome,
                settingsKey: $0.catalogSettingsKey,
                posterShape: $0.posterShape ?? $0.items.first(where: { $0.posterShape != nil })?.posterShape
            )
        }
    }

    private static func uniqueSnapshotRows(_ rows: [SnapshotRow]) -> [SnapshotRow] {
        var seen = Set<String>()
        return rows.filter { seen.insert($0.id).inserted }
    }

    static func mergedSnapshotRows(
        current: [SnapshotRow],
        previous: [SnapshotRow]
    ) -> [SnapshotRow] {
        let deleted = deletedCatalogKeys()
        func isDeleted(_ row: SnapshotRow) -> Bool {
            deleted.contains(row.id)
                || (row.settingsKey != nil && deleted.contains(row.settingsKey!))
                || deleted.contains(sectionOrderKey(row.id))
        }
        var rows = uniqueSnapshotRows(current).filter { !isDeleted($0) }
        var seen = Set(rows.map(\.id))

        for (index, previousRow) in previous.enumerated() {
            guard !isDeleted(previousRow), seen.insert(previousRow.id).inserted else { continue }
            rows.insert(previousRow, at: min(index, rows.count))
        }
        return rows
    }

    private static func postSnapshotChangedNotification() {
        let post = {
            NotificationCenter.default.post(name: snapshotChangedNotification, object: nil)
        }
        if Thread.isMainThread {
            post()
        } else {
            DispatchQueue.main.async(execute: post)
        }
    }

    /// Rows for the Settings reorder list, from the last Home snapshot.
    static func snapshotRows() -> [SnapshotRow] {
        snapshotRows(in: ProfileSettings.current)
    }

    /// Builds the account payload for the current Home catalog snapshot.
    /// Home's `addon_...` ids are UI-only; sync receives the source add-on id,
    /// media type, catalog id, enabled state, and saved row order.
    static func syncItems() -> [[String: Any]] {
        var items: [[String: Any]] = []
        var seenCollectionIds = Set<String>()
        let visibility = homeVisibilityContext()
        for row in snapshotRows() {
            guard let settingsKey = row.settingsKey else { continue }

            if settingsKey.hasPrefix(TVHomeSection.collectionIdPrefix) {
                let collectionId = String(settingsKey.dropFirst(TVHomeSection.collectionIdPrefix.count))
                guard !collectionId.isEmpty, seenCollectionIds.insert(collectionId).inserted else { continue }
                let customTitle = customTitle(forCatalogKey: settingsKey) ?? ""
                items.append([
                    "addon_id": "",
                    "type": "",
                    "catalog_id": "",
                    "enabled": isRowEnabled(row, context: visibility),
                    "order": items.count,
                    "custom_title": customTitle,
                    "is_collection": true,
                    "collection_id": collectionId
                ])
                continue
            }

            let source = catalogSyncSource(for: row)
            guard !source.addonId.isEmpty,
                  !source.contentType.isEmpty,
                  !source.catalogId.isEmpty else { continue }
            let catalogKey = catalogSettingsKey(addonId: source.addonId, contentType: source.contentType, catalogId: source.catalogId)
            if row.manifestShowInHome != true,
               !visibility.disabledCatalogKeys.contains(catalogKey),
               !visibility.explicitHomeKeys.contains(catalogKey),
               CatalogHomeVisibilityResolver.isCollectionSource(
                   addonID: source.addonId,
                   contentType: source.contentType,
                   catalogID: source.catalogId,
                   collectionSources: visibility.collectionSources,
                   manifestURL: row.manifestURL.flatMap(URL.init(string:))
               ) {
                // A folder's default-hidden state is derived, not a user choice.
                continue
            }
            let customTitle = customTitle(forCatalogKey: catalogKey) ?? ""
            items.append([
                "addon_id": source.addonId,
                "type": source.contentType,
                "catalog_id": source.catalogId,
                "enabled": isRowEnabled(row, context: visibility),
                "order": items.count,
                "custom_title": customTitle,
                "is_collection": false,
                "collection_id": ""
            ])
        }
        // Hidden/new collections may never have appeared in a rendered Home
        // snapshot. Still send their visibility, otherwise the remote merge
        // preserves an old enabled item and the next pull turns them back on.
        if CollectionsStore.activeProfileId == ProfileSettings.activeProfileID {
            let disabled = disabledCollectionIds()
            let deleted = deletedCatalogKeys()
            for collection in CollectionsStore.collections() {
                guard !collection.id.isEmpty, seenCollectionIds.insert(collection.id).inserted else { continue }
                let key = TVHomeSection.collectionIdPrefix + collection.id
                items.append([
                    "addon_id": "", "type": "", "catalog_id": "",
                    "enabled": !disabled.contains(collection.id) && !deleted.contains(key),
                    "order": items.count,
                    "custom_title": customTitle(forCatalogKey: key) ?? "",
                    "is_collection": true,
                    "collection_id": collection.id
                ])
            }
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
        case "addon_simkl_movie_plantowatch", "simkl_plantowatch_movie": return ("simkl", "movie", "plantowatch")
        case "addon_simkl_series_plantowatch", "simkl_plantowatch_series": return ("simkl", "series", "plantowatch")
        default: return ("", "", "")
        }
    }

    /// True when the row is currently shown on Home.
    static func isRowEnabled(_ row: SnapshotRow) -> Bool {
        isRowEnabled(row, context: homeVisibilityContext())
    }

    static func isRowEnabled(_ row: SnapshotRow, context: HomeVisibilityContext) -> Bool {
        if row.addonId == CinemetaCatalogRepository.cinemetaAddonId
            || (row.settingsKey?.hasPrefix(CinemetaCatalogRepository.cinemetaAddonId + "_") ?? false)
            || ["movie_top", "series_top", "movie_rating", "series_rating"].contains(row.id) {
            if !CinemetaCatalogRepository.isCinemetaEnabled {
                return false
            }
        }
        if row.addonId == "simkl"
            || (row.settingsKey?.hasPrefix("simkl_") ?? false)
            || ["addon_simkl_movie_plantowatch", "addon_simkl_series_plantowatch", "simkl_plantowatch_movie", "simkl_plantowatch_series"].contains(row.id) {
            if !SimklSettingsStore.isPlanToWatchHomeCatalogsEnabled || SimklRuntimeSession.authenticatedState() == nil {
                return false
            }
        }
        if let addonId = row.addonId, disabledAddonIDs().contains(addonId) {
            return false
        }
        if let addonName = row.addonName,
           disabledAddonNames().contains(normalizedAddonSourceName(addonName)) {
            return false
        }
        if let key = row.settingsKey, key.hasPrefix(TVHomeSection.collectionIdPrefix) {
            let id = String(key.dropFirst(TVHomeSection.collectionIdPrefix.count))
            return !disabledCollectionIds().contains(id)
        }
        guard row.manifestShowInHome != false else { return false }
        let source = catalogSyncSource(for: row)
        guard !source.addonId.isEmpty,
              !source.contentType.isEmpty,
              !source.catalogId.isEmpty else {
            guard let key = row.settingsKey else { return true }
            return !context.disabledCatalogKeys.contains(key)
        }
        let key = row.settingsKey ?? catalogSettingsKey(
            addonId: source.addonId,
            contentType: source.contentType,
            catalogId: source.catalogId
        )
        guard !context.disabledCatalogKeys.contains(key) else { return false }
        return CatalogHomeVisibilityResolver.shouldInclude(
            addonID: source.addonId,
            contentType: source.contentType,
            catalogID: source.catalogId,
            collectionSources: context.collectionSources,
            manifestURL: row.manifestURL.flatMap(URL.init(string:)),
            explicitHomeKeys: context.explicitHomeKeys,
            manifestShowInHome: row.manifestShowInHome,
            disabledHomeKeys: context.disabledCatalogKeys
        )
    }

    /// Hides or restores one Home row. Writes the same profile settings the
    /// account pull writes, so the repository drops the row on Home's next load
    /// exactly as it would for a catalog hidden on another device.
    static func setRowEnabled(_ row: SnapshotRow, isEnabled: Bool) {
        guard let key = row.settingsKey else { return }
        if key.hasPrefix(TVHomeSection.collectionIdPrefix) {
            let id = String(key.dropFirst(TVHomeSection.collectionIdPrefix.count))
            setCollectionEnabled(id, isEnabled: isEnabled)
            return
        } else {
            var keys = disabledCatalogKeys()
            var explicitlyEnabled = localExplicitHomeCatalogKeys()
            if isEnabled {
                keys.remove(key)
                explicitlyEnabled.insert(key)
            } else {
                keys.insert(key)
                explicitlyEnabled.remove(key)
            }
            persist(keys, forKey: SettingsKey.homeCatalogDisabled)
            persist(explicitlyEnabled, forKey: SettingsKey.homeCatalogExplicitEnabled)
        }
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }

    /// Also used before Home has recorded a snapshot for a newly added collection.
    static func setCollectionEnabled(_ id: String, isEnabled: Bool) {
        guard !id.isEmpty else { return }
        recordCollectionVisibility(id, isEnabled: isEnabled)
        var ids = disabledCollectionIds()
        if isEnabled { ids.remove(id) } else { ids.insert(id) }
        if isEnabled {
            // The collection manager can restore a row even after Home Catalogs
            // deleted its snapshot entry. Remove only this collection's marker
            // so the next Home snapshot can record the restored row again.
            let key = TVHomeSection.collectionIdPrefix + id
            var deleted = deletedCatalogKeys()
            if deleted.remove(key) != nil {
                persist(deleted, forKey: SettingsKey.homeCatalogDeleted)
            }
        }
        persist(ids, forKey: SettingsKey.homeCollectionDisabled)
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }

    /// Permanently deletes a Home catalog row from snapshots, ordering, and active visibility.
    static func deleteRow(_ row: SnapshotRow) {
        var deleted = deletedCatalogKeys()
        deleted.insert(row.id)
        if let key = row.settingsKey {
            deleted.insert(key)
        }
        let normalized = sectionOrderKey(row.id)
        if !normalized.isEmpty {
            deleted.insert(normalized)
        }
        persist(deleted, forKey: SettingsKey.homeCatalogDeleted)

        if let key = row.settingsKey {
            if key.hasPrefix(TVHomeSection.collectionIdPrefix) {
                let id = String(key.dropFirst(TVHomeSection.collectionIdPrefix.count))
                recordCollectionVisibility(id, isEnabled: false)
                var ids = disabledCollectionIds()
                ids.insert(id)
                persist(ids, forKey: SettingsKey.homeCollectionDisabled)
            } else {
                var disabled = disabledCatalogKeys()
                var explicitlyEnabled = localExplicitHomeCatalogKeys()
                disabled.insert(key)
                explicitlyEnabled.remove(key)
                persist(disabled, forKey: SettingsKey.homeCatalogDisabled)
                persist(explicitlyEnabled, forKey: SettingsKey.homeCatalogExplicitEnabled)
            }
        }

        let order = savedOrder().filter { key in
            key != row.id && (row.settingsKey == nil || key != row.settingsKey!) && key != normalized
        }
        save(order)

        let currentSnapshot = snapshotRows().filter { r in
            r.id != row.id && (row.settingsKey == nil || r.settingsKey != row.settingsKey) && sectionOrderKey(r.id) != normalized
        }
        writeSnapshotRows(currentSnapshot)

        NotificationCenter.default.post(name: changedNotification, object: nil)
        NotificationCenter.default.post(name: snapshotChangedNotification, object: nil)
    }

    private static func persist(_ keys: Set<String>, forKey key: String) {
        guard let data = try? JSONEncoder().encode(Array(keys).sorted()) else { return }
        let usesFileStorage = [
            SettingsKey.homeCatalogOrder,
            SettingsKey.homeCatalogSyncedOrder,
            SettingsKey.homeCatalogDisabled,
            SettingsKey.homeCollectionDisabled,
            SettingsKey.homeCatalogCustomTitles,
            SettingsKey.homeCatalogExplicitEnabled,
            SettingsKey.homeCatalogDeleted
        ].contains(key)
        if usesFileStorage {
            _ = HomeCatalogPayloadStore.write(data, forKey: key)
        } else {
            ProfileSettings.current.set(data, forKey: key)
        }
    }
}

/// Debounces Home snapshot writes away from the main actor. The latest tree is
/// the only one that matters once progressive catalog responses settle.
private actor TVHomeCatalogSnapshotWriter {
    private var pendingRows: [TVHomeCatalogOrder.SnapshotRow]?
    private var pendingProfileID: String?
    private var scheduledFlush: Task<Void, Never>?

    func schedule(
        rows: [TVHomeCatalogOrder.SnapshotRow],
        profileID: String?
    ) {
        pendingRows = rows
        pendingProfileID = profileID
        scheduledFlush?.cancel()
        scheduledFlush = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 1_500_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    private func flush() {
        guard let rows = pendingRows else { return }
        let profileID = pendingProfileID
        pendingRows = nil
        pendingProfileID = nil
        scheduledFlush = nil

        let settings = ProfileSettings.store(for: profileID)
        let merged = TVHomeCatalogOrder.mergedSnapshotRows(
            current: rows,
            previous: TVHomeCatalogOrder.snapshotRows(in: settings)
        )
        TVHomeCatalogOrder.writeSnapshotRows(merged, in: settings)
    }
}

/// Section identifier for custom ordering on the Details screen.
enum TVDetailsSection: String, CaseIterable, Identifiable, Codable {
    case episodes
    case cast
    case related
    case network
    case production
    case comments

    var id: String { rawValue }

    init?(caseInsensitive: String) {
        let normalized = caseInsensitive.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "episodes":
            self = .episodes
        case "cast":
            self = .cast
        case "more_like_this", "morelikethis", "related":
            self = .related
        case "network", "networks":
            self = .network
        case "production", "companies":
            self = .production
        case "comments":
            self = .comments
        default:
            return nil
        }
    }

    var title: String {
        switch self {
        case .episodes:
            return L10n.string("settings_meta_episodes", fallback: "Episodes")
        case .cast:
            return L10n.string("details_creator_and_cast", fallback: "Cast & Crew")
        case .related:
            return L10n.string("settings_tmdb_module_more_like_this", fallback: "More Like This")
        case .network:
            return L10n.string("details_network", fallback: "Networks")
        case .production:
            return L10n.string("details_production", fallback: "Production")
        case .comments:
            return L10n.string("details_comments", fallback: "Comments")
        }
    }

    var subtitle: String {
        switch self {
        case .episodes:
            return L10n.string("tvos_settings_details_section_episodes_subtitle", fallback: "Season selector and episode cards")
        case .cast:
            return L10n.string("tvos_settings_details_section_cast_subtitle", fallback: "Creators, actors, and trailer button")
        case .related:
            return L10n.string("tvos_settings_details_section_related_subtitle", fallback: "Similar and recommended titles")
        case .network:
            return L10n.string("tvos_settings_details_section_network_subtitle", fallback: "Broadcast and streaming networks")
        case .production:
            return L10n.string("tvos_settings_details_section_production_subtitle", fallback: "Production companies and studios")
        case .comments:
            return L10n.string("tvos_settings_details_section_comments_subtitle", fallback: "Trakt reviews and viewer comments")
        }
    }
}

/// User-controlled ordering and visibility of sections on the Details screen (Settings → Layout → Details Sections).
enum TVDetailsSectionOrder {
    static let changedNotification = Notification.Name("nuvio.tv.detailsSectionOrder.changed")
    static let defaultOrder: [TVDetailsSection] = [.episodes, .cast, .related, .network, .production, .comments]

    static func currentOrder(in settings: UserDefaults = ProfileSettings.current) -> [TVDetailsSection] {
        var result: [TVDetailsSection] = []
        var seen = Set<TVDetailsSection>()

        if let data = settings.data(forKey: SettingsKey.detailsSectionOrder),
           let rawKeys = try? JSONDecoder().decode([String].self, from: data) {
            for raw in rawKeys {
                if let section = TVDetailsSection(caseInsensitive: raw), seen.insert(section).inserted {
                    result.append(section)
                }
            }
        }

        // Append any default sections not present in saved order to preserve forward compatibility
        for section in defaultOrder {
            if seen.insert(section).inserted {
                result.append(section)
            }
        }
        return result
    }

    static func disabledSections(in settings: UserDefaults = ProfileSettings.current) -> Set<TVDetailsSection> {
        guard let data = settings.data(forKey: SettingsKey.detailsSectionDisabled),
              let rawKeys = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        var disabled = Set<TVDetailsSection>()
        for raw in rawKeys {
            if let section = TVDetailsSection(caseInsensitive: raw) {
                disabled.insert(section)
            }
        }
        return disabled
    }

    static func isSectionEnabled(_ section: TVDetailsSection, in settings: UserDefaults = ProfileSettings.current) -> Bool {
        !disabledSections(in: settings).contains(section)
    }

    static func activeSections(in settings: UserDefaults = ProfileSettings.current) -> [TVDetailsSection] {
        let disabled = disabledSections(in: settings)
        return currentOrder(in: settings).filter { !disabled.contains($0) }
    }

    static func activeSectionCount(in settings: UserDefaults = ProfileSettings.current) -> Int {
        activeSections(in: settings).count
    }

    static func setSectionEnabled(_ section: TVDetailsSection, isEnabled: Bool, in settings: UserDefaults = ProfileSettings.current) {
        var disabled = disabledSections(in: settings)
        if isEnabled {
            disabled.remove(section)
        } else {
            disabled.insert(section)
        }
        let rawKeys = disabled.map(\.rawValue).sorted()
        if let data = try? JSONEncoder().encode(rawKeys) {
            settings.set(data, forKey: SettingsKey.detailsSectionDisabled)
        }
        notifyChange()
    }

    static func saveOrder(_ order: [TVDetailsSection], in settings: UserDefaults = ProfileSettings.current) {
        var seen = Set<TVDetailsSection>()
        var normalized: [TVDetailsSection] = []
        for section in order {
            if seen.insert(section).inserted {
                normalized.append(section)
            }
        }
        for section in defaultOrder {
            if seen.insert(section).inserted {
                normalized.append(section)
            }
        }
        let rawKeys = normalized.map(\.rawValue)
        if let data = try? JSONEncoder().encode(rawKeys) {
            settings.set(data, forKey: SettingsKey.detailsSectionOrder)
        }
        notifyChange()
    }

    static func resetToDefaults(in settings: UserDefaults = ProfileSettings.current) {
        settings.removeObject(forKey: SettingsKey.detailsSectionOrder)
        settings.removeObject(forKey: SettingsKey.detailsSectionDisabled)
        notifyChange()
    }

    private static func notifyChange() {
        ProfileSettings.notifySettingsChanged()
        NotificationCenter.default.post(name: changedNotification, object: nil)
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

    /// Resolves every stored folder source, including folders in collections
    /// hidden from Home. Parent visibility must not change source membership.
    static func collectionSources() -> [Source] {
        CollectionsStore.collections()
            .flatMap { collection in
                collection.folders.flatMap { $0.resolvedSources }
                    .filter { $0.normalizedProvider == "addon" }
                    .compactMap { source in
                        guard let addonId = source.addonId,
                              let type = source.type,
                              let catalogId = source.catalogId else { return nil }
                        return Source(
                            addonIdentifier: addonId,
                            contentType: type,
                            catalogID: catalogId,
                            collectionID: collection.id
                        )
                    }
            }
    }

    /// Compatibility name retained for existing callers.
    static func activeCollectionSources() -> [Source] { collectionSources() }

    static func shouldInclude(
        addonID: String,
        contentType: String,
        catalogID: String,
        collectionSources: [Source],
        manifestURL: URL?,
        explicitHomeKeys: Set<String>,
        manifestShowInHome: Bool? = nil,
        disabledHomeKeys: Set<String> = []
    ) -> Bool {
        let key = TVHomeCatalogOrder.catalogSettingsKey(
            addonId: addonID,
            contentType: contentType,
            catalogId: catalogID
        )
        guard !disabledHomeKeys.contains(key), manifestShowInHome != false else { return false }
        if manifestShowInHome == true || explicitHomeKeys.contains(key) { return true }
        return !isCollectionSource(
            addonID: addonID,
            contentType: contentType,
            catalogID: catalogID,
            collectionSources: collectionSources,
            manifestURL: manifestURL
        )
    }

    static func isCollectionSource(
        addonID: String,
        contentType: String,
        catalogID: String,
        collectionSources: [Source],
        manifestURL: URL?
    ) -> Bool {
        collectionSources.contains { source in
            source.contentType == contentType
                && source.catalogID == catalogID
                && matches(source.addonIdentifier, addonID: addonID, manifestURL: manifestURL)
        }
    }

    static func matches(_ raw: String, addonID: String, manifestURL: URL?) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.caseInsensitiveCompare(addonID) == .orderedSame { return true }
        if (value.caseInsensitiveCompare(CinemetaCatalogRepository.cinemetaAddonId) == .orderedSame || value.caseInsensitiveCompare("cinemeta") == .orderedSame)
            && (addonID.caseInsensitiveCompare(CinemetaCatalogRepository.cinemetaAddonId) == .orderedSame || addonID.caseInsensitiveCompare("cinemeta") == .orderedSame) {
            return true
        }
        var candidates = [value]
        if value.lowercased().hasPrefix("addon:"),
           let separator = value.dropFirst("addon:".count).firstIndex(of: ":") {
            candidates.append(String(value[value.index(after: separator)...]))
            let embeddedID = String(value[value.index(value.startIndex, offsetBy: "addon:".count)..<separator])
            if embeddedID.caseInsensitiveCompare(addonID) == .orderedSame { return true }
        }
        guard let canonical = manifestURL.map(canonicalURL) else { return false }
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
    var collectionScope: String? = nil
}

enum TVProfileGateReadiness: Equatable {
    case waiting(hasFocusableContent: Bool, targetSignature: String?)
    case ready(targetSignature: String, storeLoaded: Bool)
    case empty
    case overlay
}

/// Holds the Home screen's browsing state outside `TVHomeView` so it survives
/// the details/player push (which tears the view down). Owned by `ContentView`;
/// lets returning from a card restore the cached catalog + the focused card
/// instead of reloading and jumping back to the top.
final class TVHomeStore: ObservableObject {
    @Published var sections: [TVHomeSection] = [] {
        didSet { sectionsRevision &+= 1 }
    }
    @Published var sectionsRevision: UInt = 0
    @Published var hero: NuvioMeta?
    @Published var lastLoadedAt: Date?
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
        lastLoadedAt = Date()
        // Collection tabs reuse this store; only the main Home feeds the shelf.
        if identity.collectionScope == nil {
            writeTopShelfFeed()
        }
    }

    /// Mirrors the first populated catalog row on Home into the App Group for
    /// the Top Shelf. Rows the shelf already covers (Continue Watching) and
    /// rows that aren't plain title lists are skipped.
    private func writeTopShelfFeed() {
        guard TopShelfFeedStore.isAvailable else { return }
        let skippedIds: Set<String> = [
            TVHomeSection.continueWatchingId,
            TVHomeSection.upcomingId,
            TVHomeSection.localTitlesId,
            TVHomeSection.jellyfinId,
        ]
        let row = sections.first {
            !skippedIds.contains($0.id) && $0.collectionFolders.isEmpty
                && !$0.isLoadingPlaceholder && !$0.items.isEmpty
        }
        let entries = (row?.items ?? []).prefix(15).map { meta in
            TopShelfEntry(
                contentId: meta.id,
                contentType: meta.type,
                title: meta.name,
                subtitle: nil,
                imageURL: meta.posterUrl,
                backdropURL: meta.backdropUrl,
                progress: nil,
                action: .details
            )
        }
        TopShelfFeedStore.write(Array(entries), section: .catalog, title: row?.title)
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
        lastLoadedAt = nil
        lastFocusedCardID = nil
        loadedContentIdentity = nil
        loadingContentIdentity = nil
    }
}

// MARK: - App Cache Manager

@MainActor
enum AppCacheManager {
    static let didClearCacheNotification = Notification.Name("nuvio.tv.appCacheCleared")

    /// Clears all temporary poster artwork, repository metadata, in-memory row trees,
    /// and catalog order overrides while preserving all user settings and accounts.
    /// Follows up with a full account re-pull from the server/website.
    static func clearCache() async {
        // 1. Wipe poster data (memory + disk + URLSession)
        await PosterArtworkCache.clearAllArtwork()
        BackdropImageCache.shared.purge()
        HomeHeroRatingsCache.shared.clear()
        await PersonProfileImageCache.shared.purge()

        // 2. Wipe catalog order & snapshots
        TVHomeCatalogOrder.clearOrder()

        // 3. Wipe row data & repository caches
        CinemetaCatalogRepository.clearMetadataCache()
        await StremioManifestDataCache.shared.clear()
        await StreamsRepository.clearManifestCache()
        await TmdbDetailsService.clearCache()
        await CalendarSnapshotStore.shared.clear()
        await CalendarTvmazeCache.shared.clear()

        // 4. Notify Home to reset loaded rows and reload
        NotificationCenter.default.post(name: didClearCacheNotification, object: nil)

        // 5. Followed by a new pull from the website / backend
        if let sync = NuvioSyncManager.current {
            sync.forcePull()
        }
    }
}

// Android triggers pagination from the last visible card, six cards from the
// end. tvOS triggers from the focused card instead, so include the roughly six
// cards already visible ahead of focus to give network requests the same runway.
let TVHomeRowPrefetchThreshold = 18

/// Hero header while a collection folder card is focused.
/// Full-screen backdrop is driven by `homeBackdropURL` (folder hero backdrop).
/// This view only draws the title area: optional title logo, else emoji + name.
///
/// Unlike `TVHeroView` (title + meta + multi-line description that fills the
/// block), folder heroes are a single short line. They must sit at the bottom
/// of the hero frame — where a poster description's last line ends — matching
/// Android Modern Home. A large top padding (copied from poster heroes) was
/// making this line sit too high.
private struct TVCollectionFolderHeroView: View, Equatable {
    let folder: TVCollectionFolderItem
    @AppStorage(SettingsKey.homeLayout) private var homeLayout = "Modern"

    static func == (lhs: TVCollectionFolderHeroView, rhs: TVCollectionFolderHeroView) -> Bool {
        lhs.folder.id == rhs.folder.id &&
        lhs.folder.title == rhs.folder.title &&
        lhs.folder.coverEmoji == rhs.folder.coverEmoji &&
        lhs.folder.preferredTitleLogoURLString == rhs.folder.preferredTitleLogoURLString
    }

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

    private var heroHeight: CGFloat {
        homeLayout == "Compact" ? 390 : 500
    }

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
        .frame(height: heroHeight, alignment: .bottomLeading)
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

private enum GridHeroFocusTarget: Hashable {
    case leadingTrap
    case play
    case watchlist
    case info
    case next
    case trailingTrap
}

private final class GridHeroNativeFocusTracker {
    private(set) var currentTarget: GridHeroFocusTarget?
    private var updateGeneration = 0

    func update(target: GridHeroFocusTarget, isFocused: Bool) {
        if isFocused {
            updateGeneration &+= 1
            currentTarget = target
            return
        }
        guard currentTarget == target else { return }
        updateGeneration &+= 1
        let generation = updateGeneration

        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.updateGeneration == generation,
                  self.currentTarget == target else { return }
            self.currentTarget = nil
        }
    }
}

#if os(tvOS)
private enum GridHeroArrow: Equatable {
    case left
    case right
}

private final class GridHeroDirectionalPressTarget: NSObject {
    var onRecognized: ((UITapGestureRecognizer) -> Void)?

    @objc func recognized(_ recognizer: UITapGestureRecognizer) {
        onRecognized?(recognizer)
    }
}

private struct GridHeroActionFocusBoundary<Content: View>: UIViewControllerRepresentable {
    private let content: Content
    private let shouldConsumeArrow: (GridHeroArrow) -> Bool
    private let onArrowPress: (GridHeroArrow) -> Void

    init(
        shouldConsumeArrow: @escaping (GridHeroArrow) -> Bool,
        onArrowPress: @escaping (GridHeroArrow) -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.content = content()
        self.shouldConsumeArrow = shouldConsumeArrow
        self.onArrowPress = onArrowPress
    }

    func makeUIViewController(context: Context) -> GridHeroActionHostingController<Content> {
        GridHeroActionHostingController(
            rootView: content,
            shouldConsumeArrow: shouldConsumeArrow,
            onArrowPress: onArrowPress
        )
    }

    func updateUIViewController(
        _ controller: GridHeroActionHostingController<Content>,
        context: Context
    ) {
        controller.update(
            rootView: content,
            shouldConsumeArrow: shouldConsumeArrow,
            onArrowPress: onArrowPress
        )
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiViewController: GridHeroActionHostingController<Content>,
        context: Context
    ) -> CGSize? {
        uiViewController.sizeThatFits(in: CGSize(
            width: proposal.width ?? UIView.layoutFittingExpandedSize.width,
            height: proposal.height ?? UIView.layoutFittingExpandedSize.height
        ))
    }
}

private final class GridHeroActionHostingController<Content: View>: UIHostingController<Content>, UIGestureRecognizerDelegate {
    private var shouldConsumeArrow: (GridHeroArrow) -> Bool
    private var onArrowPress: (GridHeroArrow) -> Void
    private var consumingArrowPress: GridHeroArrow?
    private let directionalPressTarget = GridHeroDirectionalPressTarget()
    private var leftEdgePressRecognizer: UITapGestureRecognizer?
    private var rightEdgePressRecognizer: UITapGestureRecognizer?

    init(
        rootView: Content,
        shouldConsumeArrow: @escaping (GridHeroArrow) -> Bool,
        onArrowPress: @escaping (GridHeroArrow) -> Void
    ) {
        self.shouldConsumeArrow = shouldConsumeArrow
        self.onArrowPress = onArrowPress
        super.init(rootView: rootView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.clipsToBounds = false

        directionalPressTarget.onRecognized = { [weak self] recognizer in
            self?.handleRecognizedEdgePress(recognizer)
        }
        let leftRecognizer = makeEdgePressRecognizer(for: .left)
        let rightRecognizer = makeEdgePressRecognizer(for: .right)
        leftEdgePressRecognizer = leftRecognizer
        rightEdgePressRecognizer = rightRecognizer
        view.addGestureRecognizer(leftRecognizer)
        view.addGestureRecognizer(rightRecognizer)
    }

    func update(
        rootView: Content,
        shouldConsumeArrow: @escaping (GridHeroArrow) -> Bool,
        onArrowPress: @escaping (GridHeroArrow) -> Void
    ) {
        self.shouldConsumeArrow = shouldConsumeArrow
        self.onArrowPress = onArrowPress
        self.rootView = rootView
    }

    override func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool {
        let previousIsHosted = isHostedFocusItem(context.previouslyFocusedItem)
            || context.previouslyFocusedView.map { isHostedView($0) } == true
        let nextIsHosted = isHostedFocusItem(context.nextFocusedItem)
            || context.nextFocusedView.map { isHostedView($0) } == true
        traceInput(
            "focus prev=\(focusItemType(context.previouslyFocusedItem)) next=\(focusItemType(context.nextFocusedItem)) " +
                "hosted=\(previousIsHosted)/\(nextIsHosted) heading=\(context.focusHeading.rawValue)"
        )
        let isLeftExit = context.focusHeading.contains(.left)
        let isRightExit = context.focusHeading.contains(.right) && shouldConsumeArrow(.right)
        if (isLeftExit || isRightExit), previousIsHosted, !nextIsHosted {
            return false
        }
        return super.shouldUpdateFocus(in: context)
    }

    // Consume remote and hardware-keyboard edge arrows before the sidebar can handle them.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let consumedArrow = presses
            .compactMap { arrowDirection(for: $0) }
            .first(where: shouldConsumeArrow)
        traceInput("responder began \(pressDescription(presses)) gate=\(consumedArrow != nil)")
        if let consumedArrow {
            consumingArrowPress = consumedArrow
            let otherPresses = excluding(consumedArrow, from: presses)
            if !otherPresses.isEmpty { super.pressesBegan(otherPresses, with: event) }
            return
        }
        super.pressesBegan(presses, with: event)
    }

    override func pressesChanged(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        traceInput("responder changed \(pressDescription(presses)) consumed=\(String(describing: consumingArrowPress))")
        if let consumedArrow = consumingArrowPress,
           presses.contains(where: { arrowDirection(for: $0) == consumedArrow }) {
            let otherPresses = excluding(consumedArrow, from: presses)
            if !otherPresses.isEmpty { super.pressesChanged(otherPresses, with: event) }
            return
        }
        super.pressesChanged(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        traceInput("responder ended \(pressDescription(presses)) consumed=\(String(describing: consumingArrowPress))")
        if let consumedArrow = consumingArrowPress,
           presses.contains(where: { arrowDirection(for: $0) == consumedArrow }) {
            consumingArrowPress = nil
            onArrowPress(consumedArrow)
            let otherPresses = excluding(consumedArrow, from: presses)
            if !otherPresses.isEmpty { super.pressesEnded(otherPresses, with: event) }
            return
        }
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        traceInput("responder cancelled \(pressDescription(presses)) consumed=\(String(describing: consumingArrowPress))")
        if let consumedArrow = consumingArrowPress,
           presses.contains(where: { arrowDirection(for: $0) == consumedArrow }) {
            consumingArrowPress = nil
            let otherPresses = excluding(consumedArrow, from: presses)
            if !otherPresses.isEmpty { super.pressesCancelled(otherPresses, with: event) }
            return
        }
        super.pressesCancelled(presses, with: event)
    }

    private func isHostedView(_ candidate: UIView) -> Bool {
        guard let hostedView = viewIfLoaded else { return false }
        return candidate === hostedView || candidate.isDescendant(of: hostedView)
    }

    private func isHostedFocusItem(_ candidate: UIFocusItem?) -> Bool {
        guard let candidate else { return false }
        var environment: any UIFocusEnvironment = candidate
        while true {
            if environment === self { return true }
            guard let parent = environment.parentFocusEnvironment else { return false }
            environment = parent
        }
    }

    private func excluding(_ arrow: GridHeroArrow, from presses: Set<UIPress>) -> Set<UIPress> {
        Set(presses.filter { arrowDirection(for: $0) != arrow })
    }

    private func arrowDirection(for press: UIPress) -> GridHeroArrow? {
        if press.type == .leftArrow || press.key?.keyCode == .keyboardLeftArrow { return .left }
        if press.type == .rightArrow || press.key?.keyCode == .keyboardRightArrow { return .right }
        return nil
    }

    private func makeEdgePressRecognizer(for arrow: GridHeroArrow) -> UITapGestureRecognizer {
        let recognizer = UITapGestureRecognizer(
            target: directionalPressTarget,
            action: #selector(GridHeroDirectionalPressTarget.recognized(_:))
        )
        let pressType: UIPress.PressType = arrow == .left ? .leftArrow : .rightArrow
        recognizer.allowedPressTypes = [NSNumber(value: pressType.rawValue)]
        recognizer.allowedTouchTypes = []
        recognizer.delaysTouchesBegan = true
        recognizer.delaysTouchesEnded = true
        recognizer.cancelsTouchesInView = true
        recognizer.delegate = self
        return recognizer
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive press: UIPress) -> Bool {
        guard let arrow = edgeArrow(for: gestureRecognizer) else { return false }
        let allowed = arrowDirection(for: press) == arrow && shouldConsumeArrow(arrow)
        traceInput("gesture receive press=\(pressDescription(press)) arrow=\(arrow) gate=\(allowed)")
        return allowed
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        false
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        guard let arrow = edgeArrow(for: gestureRecognizer),
              !isEdgePressRecognizer(otherGestureRecognizer),
              shouldConsumeArrow(arrow) else { return false }
        return true
    }

    private func handleRecognizedEdgePress(_ recognizer: UITapGestureRecognizer) {
        guard let arrow = edgeArrow(for: recognizer) else { return }
        traceInput("gesture recognized arrow=\(arrow)")
        // Recognition cancels the delayed responder press; clear its fallback so it cannot advance twice.
        consumingArrowPress = nil
        onArrowPress(arrow)
    }

    private func edgeArrow(for recognizer: UIGestureRecognizer) -> GridHeroArrow? {
        if recognizer === leftEdgePressRecognizer { return .left }
        if recognizer === rightEdgePressRecognizer { return .right }
        return nil
    }

    private func isEdgePressRecognizer(_ recognizer: UIGestureRecognizer) -> Bool {
        recognizer === leftEdgePressRecognizer || recognizer === rightEdgePressRecognizer
    }

    private var isInputTraceEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("-TVGridHeroInputTrace")
    }

    private func traceInput(_ message: @autoclosure () -> String) {
        guard isInputTraceEnabled else { return }
        print("[GridHeroInput] \(message())")
    }

    private func pressDescription(_ press: UIPress) -> String {
        "type=\(press.type.rawValue) key=\(String(describing: press.key?.keyCode))"
    }

    private func pressDescription(_ presses: Set<UIPress>) -> String {
        presses.map { pressDescription($0) }.sorted().joined(separator: ",")
    }

    private func focusItemType(_ item: UIFocusItem?) -> String {
        guard let item else { return "nil" }
        return String(reflecting: type(of: item))
    }
}
#endif

private struct TvHeroActionButtonStyle: ButtonStyle {
    var onNativeFocusChange: ((Bool) -> Void)? = nil

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            #if os(tvOS)
            .background {
                if let onNativeFocusChange {
                    TVNativeFocusObserver(onFocusChange: onNativeFocusChange)
                }
            }
            #endif
            #if os(tvOS)
            .scaleEffect(configuration.isPressed ? 0.985 : 1.0)
            #else
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            #endif
            .animation(.easeInOut(duration: 0.2), value: configuration.isPressed)
    }
}

/// Apple TV native page slider pill matching the tvOS system carousel indicator:
/// dark frosted capsule container with proportional dots and an elongated
/// active track with a bright white indicator.
private struct AppleTvPageSlider: View {
    let totalCount: Int
    let selectedIndex: Int
    var isFocused: Bool = false
    var progress: Double = 0

    var body: some View {
        let trackWidth: CGFloat = isFocused ? 46 : 40
        let clampedProgress = CGFloat(min(max(progress, 0), 1))
        let fillWidth = 14 + (trackWidth - 14) * clampedProgress

        HStack(spacing: 10) {
            ForEach(0..<totalCount, id: \.self) { dotIndex in
                if dotIndex == selectedIndex {
                    // Active indicator track with bright white sliding thumb
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.28))
                            .frame(width: trackWidth, height: 8)

                        Capsule()
                            .fill(Color.white)
                            .frame(width: fillWidth, height: 8)
                    }
                    .transition(.opacity)
                } else {
                    Circle()
                        .fill(Color.white.opacity(dotOpacity(for: dotIndex)))
                        .frame(width: dotSize(for: dotIndex), height: dotSize(for: dotIndex))
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.45))
        )
        .shadow(color: .black.opacity(0.45), radius: 10, y: 5)
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: selectedIndex)
        .animation(.easeOut(duration: 0.15), value: isFocused)
        .animation(.linear(duration: 0.25), value: progress)
    }

    private func dotSize(for dotIndex: Int) -> CGFloat {
        let distance = abs(dotIndex - selectedIndex)
        if distance >= 3 {
            return 5.0
        } else if distance == 2 {
            return 6.5
        }
        return 7.5
    }

    private func dotOpacity(for dotIndex: Int) -> Double {
        let distance = abs(dotIndex - selectedIndex)
        if distance >= 3 {
            return 0.30
        } else if distance == 2 {
            return 0.40
        }
        return 0.55
    }
}

/// Grid View's featured carousel matching Apple TV's home page design:
/// full-width cinematic artwork, rich logo/typography, metadata badges,
/// prominent Play/Watch pill button, circular Watchlist/Info/Next buttons,
/// and native Apple TV page slider pill.
private struct TVGridHeroSlideshowView: View {
    let items: [NuvioMeta]
    let isPlaybackAllowed: Bool
    let repository: CatalogRepository
    let profileID: String
    let catalogRevision: UInt
    @Binding var selectedIndex: Int
    let focusRequestGeneration: Int
    let shouldRequestInitialFocus: Bool
    let onInitialFocusRequested: () -> Void
    let onPlay: (NuvioMeta) -> Void
    var backdropBleed: CGFloat = 0
    var onFocusChange: ((Bool) -> Void)? = nil
    let onSelect: (NuvioMeta) -> Void

    @AppStorage(SettingsKey.amoled) private var amoled = false
    @AppStorage(SettingsKey.bodyColor) private var bodyColor = SettingsBackground.charcoal.rawValue
    @AppStorage(SettingsKey.trailersEnabled) private var trailersEnabled = true
    @AppStorage(SettingsKey.trailerDelay) private var trailerDelay = 7
    @AppStorage(SettingsKey.homeHeroRatingSource) private var homeHeroRatingSource = "imdb"
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var focusedTarget: GridHeroFocusTarget?
    @State private var isInLibraryCache = false
    @State private var gridHeroRatings: [String: [NuvioExternalRating]] = [:]
    @State private var lastFocusChangeTime: CFTimeInterval = 0
    @State private var activeTrailerPreviewIdentity: String?
    @State private var finishedTrailerPreviewIdentity: String?
    @State private var unavailableTrailerPreviewIdentity: String?
    @State private var readyTrailerPreviewIdentity: String?
    @State private var trailerPlaybackProgress = 0.0
    @State private var fallbackCountdownProgress = 0.0
    @State private var nativeFocusTracker = GridHeroNativeFocusTracker()
    @State private var resolvedSeriesMetadata: NuvioMeta?
    @State private var resolvedSeriesMetadataIdentity: String?
    @State private var resolvedPlayTarget: TvDetailsPlayTarget?
    @State private var resolvedPlayTargetIdentity: String?

    private var index: Int {
        guard !items.isEmpty else { return 0 }
        return min(max(selectedIndex, 0), items.count - 1)
    }

    private var activeItem: NuvioMeta? {
        items.indices.contains(index) ? items[index] : nil
    }

    private var isAnyFocused: Bool {
        focusedTarget != nil
    }

    private var currentPlayTargetIdentity: String? {
        activeItem.map { playTargetIdentity(for: $0) }
    }

    private var playTargetTaskIdentity: String {
        "\(currentPlayTargetIdentity ?? "none")\u{1f}\(catalogRevision)\u{1f}\(isPlaybackAllowed && scenePhase == .active)"
    }

    private var currentPlayTarget: TvDetailsPlayTarget? {
        guard let identity = currentPlayTargetIdentity,
              resolvedPlayTargetIdentity == identity else { return nil }
        return resolvedPlayTarget
    }

    private func playTargetIdentity(for meta: NuvioMeta) -> String {
        "\(profileID)\u{1f}\(meta.type)\u{1f}\(meta.id)"
    }

    private var currentTrailerPreviewIdentity: String? {
        activeItem.map { "\(index)\u{1f}\(trailerPreviewIdentity(for: $0))" }
    }

    private var isTrailerPreviewEligible: Bool {
        isPlaybackAllowed && isAnyFocused && scenePhase == .active && trailersEnabled
    }

    private var trailerPreviewTaskIdentity: String {
        "\(currentTrailerPreviewIdentity ?? "none")\u{1f}\(isTrailerPreviewEligible)\u{1f}\(max(0, trailerDelay))\u{1f}\(unavailableTrailerPreviewIdentity ?? "none")"
    }

    private var isFallbackCountdownEligible: Bool {
        isPlaybackAllowed && scenePhase == .active && items.count > 1
            && (!trailersEnabled || !isAnyFocused
                || unavailableTrailerPreviewIdentity == currentTrailerPreviewIdentity)
    }

    private var fallbackCountdownTaskIdentity: String {
        "\(index)\u{1f}\(currentTrailerPreviewIdentity ?? "none")\u{1f}\(isFallbackCountdownEligible)\u{1f}\(unavailableTrailerPreviewIdentity ?? "none")"
    }

    private var sliderProgress: Double {
        if isTrailerPreviewEligible, activeTrailerPreviewIdentity == currentTrailerPreviewIdentity {
            return trailerPlaybackProgress
        }
        if isFallbackCountdownEligible { return fallbackCountdownProgress }
        return 0
    }

    private func trailerPreviewIdentity(for item: NuvioMeta) -> String {
        "\(item.type)\u{1f}\(item.id)\u{1f}\(item.trailerYtIds?.joined(separator: ",") ?? "")"
    }

    private func currentContinueWatchingItem(for meta: NuvioMeta) -> ContinueWatchingItem? {
        if RemoteTrackingState.isProgressSourceAuthenticated {
            return TraktProgressService.currentContinueWatchingItem(for: meta)
        }
        return ContinueWatchingStore.item(for: meta) ?? ContinueWatchingStore.item(for: meta.id)
    }

    private func refreshHeroPlayTargetFromCurrentData() {
        guard let item = activeItem else {
            resolvedSeriesMetadata = nil
            resolvedSeriesMetadataIdentity = nil
            resolvedPlayTarget = nil
            resolvedPlayTargetIdentity = nil
            return
        }

        let identity = playTargetIdentity(for: item)
        if resolvedPlayTargetIdentity != identity {
            resolvedSeriesMetadata = nil
            resolvedSeriesMetadataIdentity = nil
        }
        let targetMeta: NuvioMeta
        let episodes: [NuvioVideo]
        if item.isSeries,
           resolvedSeriesMetadataIdentity == identity,
           let resolvedSeriesMetadata {
            targetMeta = resolvedSeriesMetadata
            episodes = TvDetailsPlayTargetBuilder.orderedEpisodes(resolvedSeriesMetadata.videos ?? [])
        } else {
            targetMeta = item
            episodes = []
        }
        let watchedKeys = WatchedStore.currentSnapshot().watchedEpisodeKeys(meta: targetMeta)
        resolvedPlayTarget = TvDetailsPlayTargetBuilder.makePlayTarget(
            episodes: episodes,
            continueItem: currentContinueWatchingItem(for: targetMeta),
            watchedKeys: watchedKeys
        )
        resolvedPlayTargetIdentity = identity
    }

    @MainActor
    private func resolveCurrentHeroPlayTarget() async {
        refreshHeroPlayTargetFromCurrentData()
        guard isPlaybackAllowed,
              scenePhase == .active,
              let item = activeItem,
              item.isSeries else { return }

        let requestedIdentity = playTargetIdentity(for: item)
        let requestedProfileID = profileID
        do {
            let fullMetadata = try await repository.getMetadata(id: item.id, type: item.type)
            guard !Task.isCancelled,
                  isPlaybackAllowed,
                  scenePhase == .active,
                  profileID == requestedProfileID,
                  currentPlayTargetIdentity == requestedIdentity,
                  fullMetadata.id == item.id,
                  fullMetadata.type == item.type else { return }
            resolvedSeriesMetadata = fullMetadata
            resolvedSeriesMetadataIdentity = requestedIdentity
            refreshHeroPlayTargetFromCurrentData()

            guard let tmdbEpisodes = await TmdbDetailsService.fetchEpisodes(for: fullMetadata),
                  !tmdbEpisodes.isEmpty else { return }
            guard !Task.isCancelled,
                  isPlaybackAllowed,
                  scenePhase == .active,
                  profileID == requestedProfileID,
                  currentPlayTargetIdentity == requestedIdentity,
                  fullMetadata.id == item.id,
                  fullMetadata.type == item.type else { return }
            let mergedEpisodes = DetailsViewModel.mergeEpisodes(
                existing: fullMetadata.videos,
                fromTmdb: tmdbEpisodes,
                parentId: fullMetadata.id
            )
            guard let mergedEpisodes, !mergedEpisodes.isEmpty else { return }
            resolvedSeriesMetadata = fullMetadata.withVideos(mergedEpisodes)
            resolvedSeriesMetadataIdentity = requestedIdentity
            refreshHeroPlayTargetFromCurrentData()
        } catch {
            // Keep the generic Play/Resume target when full series metadata is unavailable.
        }
    }

    @ViewBuilder
    private func artLayer(_ item: NuvioMeta) -> some View {
        let background = Color.nuvioBackground(amoled: amoled, body: bodyColor)

        ZStack {
            CrossfadingBackdrop(
                url: item.backgroundUrl ?? item.landscapePosterUrl ?? item.posterUrl,
                placeholder: background,
                alignment: .top
            )

            #if os(tvOS)
            let previewIdentity = currentTrailerPreviewIdentity ?? trailerPreviewIdentity(for: item)
            if isTrailerPreviewEligible,
               currentTrailerPreviewIdentity == previewIdentity,
               finishedTrailerPreviewIdentity != previewIdentity {
                TrailerPreviewPlayer(
                    meta: item,
                    isActive: activeTrailerPreviewIdentity == previewIdentity,
                    onPlaybackReady: {
                        guard isTrailerPreviewEligible,
                              currentTrailerPreviewIdentity == previewIdentity,
                              activeTrailerPreviewIdentity == previewIdentity else { return }
                        readyTrailerPreviewIdentity = previewIdentity
                    },
                    onPlaybackFinished: {
                        guard isTrailerPreviewEligible,
                              currentTrailerPreviewIdentity == previewIdentity,
                              activeTrailerPreviewIdentity == previewIdentity else { return }
                        finishedTrailerPreviewIdentity = previewIdentity
                        activeTrailerPreviewIdentity = nil
                        readyTrailerPreviewIdentity = nil
                        trailerPlaybackProgress = 1
                        if items.count > 1 {
                            setIndex((index + 1) % items.count)
                        }
                    },
                    onPlaybackProgress: { elapsed, duration in
                        guard isTrailerPreviewEligible,
                              currentTrailerPreviewIdentity == previewIdentity,
                              activeTrailerPreviewIdentity == previewIdentity else { return }
                        trailerPlaybackProgress = min(max(elapsed / duration, 0), 1)
                    },
                    onPlaybackUnavailable: {
                        markTrailerPreviewUnavailable(previewIdentity)
                    }
                )
                .id(previewIdentity)
                .task(id: "\(previewIdentity)|\(activeTrailerPreviewIdentity == previewIdentity)|\(readyTrailerPreviewIdentity == previewIdentity)") {
                    await enforceTrailerRenderReadinessTimeout(for: previewIdentity)
                }
            }
            #endif

            // Leading horizontal gradient for text legibility (soft, focused behind text)
            LinearGradient(
                stops: [
                    .init(color: background.opacity(0.75), location: 0),
                    .init(color: background.opacity(0.45), location: 0.22),
                    .init(color: background.opacity(0.12), location: 0.40),
                    .init(color: .clear, location: 0.58)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )

            // Bottom vertical gradient dissolving softly right at the continue watching shelf
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.70),
                    .init(color: background.opacity(0.35), location: 0.82),
                    .init(color: background.opacity(0.85), location: 0.93),
                    .init(color: background, location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            // Subtle top vignette for status / navigation bar
            LinearGradient(
                stops: [
                    .init(color: background.opacity(0.30), location: 0),
                    .init(color: .clear, location: 0.14)
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
            }

            // Apple TV native slider pill
            if items.count > 1 {
                AppleTvPageSlider(
                    totalCount: items.count,
                    selectedIndex: index,
                    isFocused: isAnyFocused,
                    progress: sliderProgress
                )
                .offset(y: 20)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 830)
        .background(alignment: .top) {
            if let activeItem {
                artLayer(activeItem)
                    .frame(height: 1080, alignment: .top)
            }
        }
        .onAppear {
            updateLibraryStatus()
            guard shouldRequestInitialFocus else { return }
            onInitialFocusRequested()
            DispatchQueue.main.async {
                focusedTarget = .play
                lastFocusChangeTime = CACurrentMediaTime()
            }
        }
        .onChange(of: focusRequestGeneration) { _, _ in
            focusedTarget = .play
            lastFocusChangeTime = CACurrentMediaTime()
        }
        .onChange(of: focusedTarget) { _, newFocus in
            if newFocus == .leadingTrap {
                if items.count > 1 {
                    let prevIndex = (index - 1 + items.count) % items.count
                    setIndex(prevIndex)
                }
                DispatchQueue.main.async {
                    focusedTarget = .play
                }
                return
            }

            if newFocus == .trailingTrap {
                if items.count > 1 {
                    let nextIndex = (index + 1) % items.count
                    setIndex(nextIndex)
                }
                DispatchQueue.main.async {
                    focusedTarget = .next
                }
                return
            }

            let isFocused = newFocus != nil
            onFocusChange?(isFocused)
        }
        .onChange(of: index) { _, _ in
            updateLibraryStatus()
            trailerPlaybackProgress = 0
            fallbackCountdownProgress = 0
        }
        .onReceive(NotificationCenter.default.publisher(for: LibraryStore.changedNotification)) { _ in
            updateLibraryStatus()
        }
        .focusSection()
        .task(id: "\(activeItem?.id ?? "")-\(homeHeroRatingSource)-\(items.count)") {
            guard let item = activeItem,
                  AddonRatingsService.heroNeedsFetchedRatings(source: homeHeroRatingSource, meta: item) else { return }
            // The next slide's ratings, so the timer or Next shows them at once.
            if items.count > 1 {
                let next = items[(index + 1) % items.count]
                if AddonRatingsService.heroNeedsFetchedRatings(source: homeHeroRatingSource, meta: next) {
                    AddonRatingsService.prefetchHomeHeroRatings(for: [next])
                }
            }
            guard gridHeroRatings[item.id] == nil else { return }
            if let cached = AddonRatingsService.cachedHomeHeroRatings(for: item) {
                // Keep them with the slide, so they survive the cache entry expiring.
                gridHeroRatings[item.id] = cached
                return
            }
            let ratings = await AddonRatingsService.fetchHomeHeroRatings(for: item)
            guard !Task.isCancelled else { return }
            gridHeroRatings[item.id] = ratings
        }
        .task(id: playTargetTaskIdentity) {
            await resolveCurrentHeroPlayTarget()
        }
        .onReceive(NotificationCenter.default.publisher(for: WatchedStore.changedNotification).receive(on: RunLoop.main)) { _ in
            refreshHeroPlayTargetFromCurrentData()
        }
        .onReceive(NotificationCenter.default.publisher(for: TraktAuthStore.changedNotification).receive(on: RunLoop.main)) { _ in
            refreshHeroPlayTargetFromCurrentData()
        }
        .onReceive(NotificationCenter.default.publisher(for: ContinueWatchingStore.changedNotification).receive(on: RunLoop.main)) { _ in
            refreshHeroPlayTargetFromCurrentData()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: TraktSettingsStore.continueWatchingChangedNotification)
                .receive(on: RunLoop.main)
        ) { _ in
            refreshHeroPlayTargetFromCurrentData()
        }
        .onChange(of: currentTrailerPreviewIdentity) { _, _ in
            activeTrailerPreviewIdentity = nil
            finishedTrailerPreviewIdentity = nil
            unavailableTrailerPreviewIdentity = nil
            readyTrailerPreviewIdentity = nil
            trailerPlaybackProgress = 0
            fallbackCountdownProgress = 0
        }
        .onChange(of: isTrailerPreviewEligible) { _, eligible in
            guard !eligible else { return }
            activeTrailerPreviewIdentity = nil
            finishedTrailerPreviewIdentity = nil
            unavailableTrailerPreviewIdentity = nil
            readyTrailerPreviewIdentity = nil
            trailerPlaybackProgress = 0
            fallbackCountdownProgress = 0
        }
        .task(id: trailerPreviewTaskIdentity) {
            await activateTrailerPreviewAfterDelay()
        }
        .task(id: fallbackCountdownTaskIdentity) {
            await runFallbackCountdown()
        }
        .onChange(of: items.count) { _, count in
            if count == 0 { selectedIndex = 0 }
            else if selectedIndex >= count { selectedIndex = count - 1 }
            trailerPlaybackProgress = 0
            fallbackCountdownProgress = 0
        }
    }

    @MainActor
    private func activateTrailerPreviewAfterDelay() async {
        activeTrailerPreviewIdentity = nil
        guard let identity = currentTrailerPreviewIdentity,
              isTrailerPreviewEligible,
              finishedTrailerPreviewIdentity != identity,
              unavailableTrailerPreviewIdentity != identity else { return }

        let delay = min(15, max(0, trailerDelay))
        if delay > 0 {
            do {
                try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            } catch {
                return
            }
        }

        guard !Task.isCancelled,
              isTrailerPreviewEligible,
              currentTrailerPreviewIdentity == identity,
              finishedTrailerPreviewIdentity != identity,
              unavailableTrailerPreviewIdentity != identity else { return }
        activeTrailerPreviewIdentity = identity
    }

    @MainActor
    private func runFallbackCountdown() async {
        fallbackCountdownProgress = 0
        guard isFallbackCountdownEligible else { return }

        let startTime = CACurrentMediaTime()
        while !Task.isCancelled {
            let elapsed = max(0, CACurrentMediaTime() - startTime)
            fallbackCountdownProgress = min(elapsed / 10, 1)
            guard elapsed < 10 else {
                guard !Task.isCancelled, isFallbackCountdownEligible else { return }
                setIndex((index + 1) % items.count)
                return
            }

            do {
                try await Task.sleep(nanoseconds: 250_000_000)
            } catch {
                return
            }
        }
    }

    @MainActor
    private func enforceTrailerRenderReadinessTimeout(for identity: String) async {
        guard readyTrailerPreviewIdentity != identity,
              activeTrailerPreviewIdentity == identity,
              isTrailerPreviewEligible else { return }

        do {
            try await Task.sleep(nanoseconds: 15_000_000_000)
        } catch {
            return
        }

        guard !Task.isCancelled,
              readyTrailerPreviewIdentity != identity,
              activeTrailerPreviewIdentity == identity,
              currentTrailerPreviewIdentity == identity,
              isTrailerPreviewEligible else { return }
        markTrailerPreviewUnavailable(identity)
    }

    private func markTrailerPreviewUnavailable(_ identity: String) {
        guard isTrailerPreviewEligible,
              currentTrailerPreviewIdentity == identity,
              activeTrailerPreviewIdentity == identity else { return }
        unavailableTrailerPreviewIdentity = identity
        finishedTrailerPreviewIdentity = identity
        readyTrailerPreviewIdentity = nil
        activeTrailerPreviewIdentity = nil
        trailerPlaybackProgress = 0
    }

    @ViewBuilder
    private func gridHeroContent(_ item: NuvioMeta) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // 1. Logo or Title
            Group {
                if let logoURL = item.logoUrl, !logoURL.isEmpty {
                    CachedHeroLogo(url: logoURL, title: item.name)
                        .frame(maxWidth: 540, maxHeight: 110, alignment: .bottomLeading)
                } else {
                    Text(item.name)
                        .font(.custom("Inter-Bold", size: 48))
                        .foregroundColor(.white)
                        .lineLimit(2)
                        .shadow(color: .black.opacity(0.6), radius: 6, y: 3)
                }
            }
            .id("hero-title-\(item.id)")
            .transition(.opacity)

            // 2. Metadata Row (Apple TV style: Type • Genres • Year • Badge)
            heroMetadataRow(item)
                .id("hero-meta-\(item.id)")
                .transition(.opacity)

            // 2b. "All" rating source: the Details ratings row with icons.
            if AddonRatingsService.heroShowsAllRatings(homeHeroRatingSource) {
                TvHeroRatingsRow(badges: gridRatingBadges(for: item), iconHeight: 22, fontSize: 19)
                    .shadow(color: .black.opacity(0.6), radius: 4, y: 2)
                    .id("hero-ratings-\(item.id)")
                    .transition(.opacity)
            }

            // 3. Description (2 lines, clean Apple TV typography)
            if let description = item.description, !description.isEmpty {
                Text(description)
                    .font(.custom("Inter-Regular", size: 21))
                    .foregroundColor(.white.opacity(0.82))
                    .lineLimit(2)
                    .lineSpacing(4)
                    .frame(maxWidth: 820, alignment: .leading)
                    .shadow(color: .black.opacity(0.7), radius: 4, y: 2)
                    .id("hero-desc-\(item.id)")
                    .transition(.opacity)
            }

            // 4. Apple TV Action Buttons Row (Mounted without dynamic ID so focus is preserved)
            #if os(tvOS)
            GridHeroActionFocusBoundary(
                shouldConsumeArrow: { arrow in
                    let target = nativeFocusTracker.currentTarget ?? focusedTarget
                    switch arrow {
                    case .left:
                        return target == .play
                            || target == .leadingTrap
                            || (target == .watchlist && currentPlayTarget?.isPlayable == false)
                    case .right:
                        return (target == .next || target == .trailingTrap) && items.count > 1
                    }
                },
                onArrowPress: { arrow in
                    switch arrow {
                    case .left:
                        if items.count > 1 {
                            setIndex((index - 1 + items.count) % items.count)
                        }
                        focusedTarget = items.count == 1 && currentPlayTarget?.isPlayable == false
                            ? .watchlist
                            : .play
                    case .right:
                        guard items.count > 1 else { return }
                        setIndex((index + 1) % items.count)
                        focusedTarget = .next
                    }
                }
            ) {
                heroActionButtons(item, playTarget: currentPlayTarget)
            }
                .padding(.top, 4)
            #else
            heroActionButtons(item, playTarget: currentPlayTarget)
                .padding(.top, 4)
            #endif

            // 5. Subtitle info under primary button
            if let subtitle = heroSubtitleText(item) {
                Text(subtitle)
                    .font(.custom("Inter-Medium", size: 15))
                    .foregroundColor(.white.opacity(0.58))
                    .padding(.top, 2)
                    .shadow(color: .black.opacity(0.6), radius: 3, y: 1)
                    .id("hero-sub-\(item.id)")
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.28), value: item.id)
        .frame(maxWidth: 960, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(.leading, TVLayout.rowLeading)
        .padding(.trailing, TVLayout.rowLeading)
        .padding(.bottom, 64)
    }

    private func gridRatingBadges(for item: NuvioMeta) -> [TvRatingBadge] {
        TvRatingBadge.badges(
            from: AddonRatingsService.heroDisplayRatings(for: item, fetched: gridHeroRatings[item.id])
        )
    }

    private func metadataStrings(for item: NuvioMeta) -> [String] {
        let typeLabel = item.isSeries
            ? L10n.string("type_series", fallback: "Series")
            : L10n.string("type_movie", fallback: "Movie")
        let genres = Array((item.genres ?? []).prefix(2))
        var list: [String] = [typeLabel]
        list.append(contentsOf: genres)
        if let year = item.year {
            list.append(String(year))
        } else if let runtime = NuvioRuntimeDisplay.formatted(item.runtime) {
            list.append(runtime)
        }
        return list
    }

    @ViewBuilder
    private func heroMetadataRow(_ item: NuvioMeta) -> some View {
        let metadataItems = metadataStrings(for: item)

        HStack(spacing: 8) {
            Image(systemName: item.isSeries ? "tv" : "film")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white.opacity(0.9))

            Text(metadataItems.joined(separator: "  •  "))
                .font(.custom("Inter-SemiBold", size: 19))
                .foregroundColor(.white.opacity(0.85))

            if let cert = item.certification, !cert.isEmpty {
                heroBadge(cert)
            } else if let badge = item.statusBadgeLabel, !badge.isEmpty {
                heroBadge(badge)
            } else if !AddonRatingsService.heroShowsAllRatings(homeHeroRatingSource) {
                // ("All" shows the full ratings row on its own line instead.)
                let effectiveRatings = (item.externalRatings?.isEmpty == false ? item.externalRatings : nil)
                    ?? gridHeroRatings[item.id]
                    ?? AddonRatingsService.cachedHomeHeroRatings(for: item)
                if let ratingStr = AddonRatingsService.heroRatingString(for: item, source: homeHeroRatingSource, ratings: effectiveRatings) {
                    heroBadge(ratingStr)
                }
            }
        }
        .shadow(color: .black.opacity(0.6), radius: 4, y: 2)
    }

    @ViewBuilder
    private func heroBadge(_ text: String) -> some View {
        Text(text)
            .font(.custom("Inter-Bold", size: 13))
            .foregroundColor(.white.opacity(0.95))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(Color.white.opacity(0.35), lineWidth: 1)
            )
    }

    @ViewBuilder
    private func heroActionButtons(_ item: NuvioMeta, playTarget: TvDetailsPlayTarget?) -> some View {
        HStack(spacing: 26) {
            // Primary Button (Watch Now / Play)
            Button {
                onPlay(item)
            } label: {
                HStack(spacing: 16) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 30, weight: .bold))
                        .accessibilityHidden(true)

                    Text(playTarget?.label ?? L10n.string("action_play", fallback: "Play"))
                        .font(.system(size: 32, weight: .medium))
                        .lineLimit(1)
                        .accessibilityHidden(true)
                }
                .foregroundColor(.black)
                .padding(.horizontal, 44)
                .frame(minWidth: 228, minHeight: 98)
                .frame(height: 98)
                .modifier(TvDetailsGlassBackground(filled: true, shape: Capsule()))
                .shadow(
                    color: .black.opacity(focusedTarget == .play ? 0.35 : 0.18),
                    radius: focusedTarget == .play ? 18 : 7,
                    y: 8
                )
            }
            .buttonStyle(TvHeroActionButtonStyle(onNativeFocusChange: { isFocused in
                nativeFocusTracker.update(target: .play, isFocused: isFocused)
            }))
            .disabled(playTarget?.isPlayable == false)
            .focused($focusedTarget, equals: .play)
            .focusEffectDisabledIfAvailable()
            .scaleEffect(focusedTarget == .play ? 1.08 : 1)
            .animation(.easeOut(duration: 0.14), value: focusedTarget == .play)
            .overlay(alignment: .leading) {
                // Invisible leading focus trap: catches Left press on Play to navigate to previous slide without shifting button layout
                if items.count > 1 {
                    Color.clear
                        .frame(width: 2, height: 98)
                        .offset(x: -16)
                        .focusable()
                        .focused($focusedTarget, equals: .leadingTrap)
                        .focusEffectDisabledIfAvailable()
                        .accessibilityHidden(true)
                }
            }

            // Watchlist / Library Button (+)
            Button {
                toggleLibraryAction(for: item)
            } label: {
                Image(systemName: isInLibraryCache ? "checkmark" : "plus")
                    .font(.system(size: 36, weight: .bold))
                    .foregroundColor(focusedTarget == .watchlist ? .black : .white)
                    .frame(width: 98, height: 98)
                    .modifier(TvDetailsGlassBackground(filled: focusedTarget == .watchlist, shape: Capsule()))
                    .shadow(
                        color: .black.opacity(focusedTarget == .watchlist ? 0.35 : 0.18),
                        radius: focusedTarget == .watchlist ? 18 : 7,
                        y: 8
                    )
            }
            .buttonStyle(TvHeroActionButtonStyle(onNativeFocusChange: { isFocused in
                nativeFocusTracker.update(target: .watchlist, isFocused: isFocused)
            }))
            .focused($focusedTarget, equals: .watchlist)
            .focusEffectDisabledIfAvailable()
            .scaleEffect(focusedTarget == .watchlist ? 1.08 : 1)
            .animation(.easeOut(duration: 0.14), value: focusedTarget == .watchlist)

            // Details / Info Button (ℹ)
            Button {
                onSelect(item)
            } label: {
                Image(systemName: "info")
                    .font(.system(size: 36, weight: .bold))
                    .foregroundColor(focusedTarget == .info ? .black : .white)
                    .frame(width: 98, height: 98)
                    .modifier(TvDetailsGlassBackground(filled: focusedTarget == .info, shape: Capsule()))
                    .shadow(
                        color: .black.opacity(focusedTarget == .info ? 0.35 : 0.18),
                        radius: focusedTarget == .info ? 18 : 7,
                        y: 8
                    )
            }
            .buttonStyle(TvHeroActionButtonStyle(onNativeFocusChange: { isFocused in
                nativeFocusTracker.update(target: .info, isFocused: isFocused)
            }))
            .focused($focusedTarget, equals: .info)
            .focusEffectDisabledIfAvailable()
            .scaleEffect(focusedTarget == .info ? 1.08 : 1)
            .animation(.easeOut(duration: 0.14), value: focusedTarget == .info)

            // Next Slide Button (>)
            if items.count > 1 {
                Button {
                    setIndex((index + 1) % items.count)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 32, weight: .bold))
                        .foregroundColor(focusedTarget == .next ? .black : .white)
                        .frame(width: 98, height: 98)
                        .modifier(TvDetailsGlassBackground(filled: focusedTarget == .next, shape: Capsule()))
                        .shadow(
                            color: .black.opacity(focusedTarget == .next ? 0.35 : 0.18),
                            radius: focusedTarget == .next ? 18 : 7,
                            y: 8
                        )
                }
                .buttonStyle(TvHeroActionButtonStyle(onNativeFocusChange: { isFocused in
                    nativeFocusTracker.update(target: .next, isFocused: isFocused)
                }))
                .focused($focusedTarget, equals: .next)
                .focusEffectDisabledIfAvailable()
                .scaleEffect(focusedTarget == .next ? 1.08 : 1)
                .animation(.easeOut(duration: 0.14), value: focusedTarget == .next)
                .overlay(alignment: .trailing) {
                    // Invisible trailing focus trap: catches Right press on Next button to advance slide
                    Color.clear
                        .frame(width: 2, height: 98)
                        .offset(x: 16)
                        .focusable()
                        .focused($focusedTarget, equals: .trailingTrap)
                        .focusEffectDisabledIfAvailable()
                        .accessibilityHidden(true)
                }
            }
        }
        .focusSection()
    }

    private func heroSubtitleText(_ item: NuvioMeta) -> String? {
        if isInLibraryCache {
            return L10n.string("details_in_library", fallback: "In your library")
        }
        guard !AddonRatingsService.heroShowsAllRatings(homeHeroRatingSource) else {
            return "4K Ultra HD • HDR • Dolby Atmos"
        }
        let effectiveRatings = (item.externalRatings?.isEmpty == false ? item.externalRatings : nil)
            ?? gridHeroRatings[item.id]
            ?? AddonRatingsService.cachedHomeHeroRatings(for: item)
        if let ratingStr = AddonRatingsService.heroRatingString(for: item, source: homeHeroRatingSource, ratings: effectiveRatings) {
            return "\(ratingStr) • 4K Ultra HD • HDR"
        }
        return "4K Ultra HD • HDR • Dolby Atmos"
    }

    private func updateLibraryStatus() {
        guard let item = activeItem else {
            isInLibraryCache = false
            return
        }
        isInLibraryCache = LibraryStore.contains(metaId: item.id, type: item.type)
    }

    private func toggleLibraryAction(for item: NuvioMeta) {
        let currentlyInLibrary = LibraryStore.contains(metaId: item.id, type: item.type)
        if TraktSettingsStore.librarySourceMode != .local && SelectedLibraryService.isSelectedAndAuthenticated {
            let desiredMembership = !currentlyInLibrary
            Task {
                _ = await SelectedLibraryService.setWatchlist(item, isInWatchlist: desiredMembership)
                await MainActor.run {
                    updateLibraryStatus()
                }
            }
        } else {
            _ = LibraryStore.toggle(meta: item)
            updateLibraryStatus()
        }
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

private struct TVHeroMetaLine: View {
    let meta: NuvioMeta
    /// "S1 E3 · Title" for a series in progress; replaces the type/runtime
    /// items so the line reads "S1 E3 · Title • Crime • 2026–".
    var episodeLine: String? = nil
    @AppStorage(SettingsKey.showFullDates) private var showFullDates = true
    @AppStorage(SettingsKey.homeHeroRatingSource) private var homeHeroRatingSource = "imdb"
    @State private var fetchedRatings: [NuvioExternalRating]?
    /// Which title/source `fetchedRatings` belong to, so a reused view never
    /// shows the previous title's scores.
    @State private var fetchedRatingsKey: String?

    var body: some View {
        let values = [
            episodeLine ?? meta.type.capitalized,
            meta.genres?.first,
            episodeLine == nil ? formattedRuntime : nil,
            episodeLine == nil ? releaseDate : (meta.releaseInfo ?? meta.year.map(String.init))
        ].compactMap { $0 }.filter { !$0.isEmpty }

        let badge = meta.statusBadgeLabel
        // Same key as the ratings cache: enrichment can add an IMDb id to a
        // kitsu:/tmdb: item, which must re-run the lookup below.
        let ratingsKey = "\(AddonRatingsService.homeHeroRatingsKey(for: meta))-\(homeHeroRatingSource)"
        let fetched = fetchedRatingsKey == ratingsKey ? fetchedRatings : nil
        let cached = AddonRatingsService.cachedHomeHeroRatings(for: meta)
        let showsAllRatings = AddonRatingsService.heroShowsAllRatings(homeHeroRatingSource)
        let ratingBadges = showsAllRatings
            ? TvRatingBadge.badges(from: AddonRatingsService.heroDisplayRatings(for: meta, fetched: fetched))
            : []
        // Still waiting for MDBList/add-on scores: keep the ratings line.
        let ratingsPending = showsAllRatings && fetched == nil && cached == nil
        let effectiveRatings = (meta.externalRatings?.isEmpty == false ? meta.externalRatings : nil)
            ?? nonEmpty(fetched)
            ?? nonEmpty(cached)
        let rating = showsAllRatings
            ? nil
            : AddonRatingsService.heroRatingString(for: meta, source: homeHeroRatingSource, ratings: effectiveRatings)
        // Movies have no status badge, so their rating would sit alone on the
        // second line; ride it on the primary line right after the date instead.
        let isMovie = !meta.isSeries
        let primaryValues = isMovie ? values + [rating].compactMap { $0 } : values
        let showSecondLine = showsAllRatings
            ? (badge != nil || !ratingBadges.isEmpty || ratingsPending)
            : (!isMovie && (badge != nil || rating != nil))
        // An empty `Text("")` still consumes a full line height and, with the
        // hero VStack spacing, opens a dead gap between the title and the first
        // catalog row (e.g. "The Chi" → "gg"). Collapse entirely when blank.
        let hasPrimary = !primaryValues.isEmpty

        Group {
            if hasPrimary || showSecondLine {
                VStack(alignment: .leading, spacing: 10) {
                    if hasPrimary {
                        Text(primaryValues.joined(separator: "  •  "))
                            .font(.custom("Inter-SemiBold", size: 22))
                            .foregroundColor(.white.opacity(0.66))
                            .lineLimit(1)
                    }

                    // Second line, like the Android hero: "[ONGOING] • IMDb 7.4",
                    // or with "All" the Details ratings row with icons.
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

                            if showsAllRatings {
                                TvHeroRatingsRow(badges: ratingBadges, iconHeight: 26, fontSize: 22)
                            } else if let rating {
                                Text(badge != nil ? "•  \(rating)" : rating)
                                    .font(.custom("Inter-SemiBold", size: 22))
                                    .foregroundColor(.white.opacity(0.66))
                                    .lineLimit(1)
                            }
                        }
                        .frame(minHeight: showsAllRatings ? 34 : nil, alignment: .leading)
                    }
                }
            }
        }
        .task(id: ratingsKey) {
            guard AddonRatingsService.heroNeedsFetchedRatings(source: homeHeroRatingSource, meta: meta) else { return }
            if let cached = AddonRatingsService.cachedHomeHeroRatings(for: meta) {
                // Keep them here too, so the row survives the cache entry expiring.
                fetchedRatings = cached
                fetchedRatingsKey = ratingsKey
                return
            }
            let ratings = await AddonRatingsService.fetchHomeHeroRatings(for: meta)
            guard !Task.isCancelled else { return }
            fetchedRatings = ratings
            fetchedRatingsKey = ratingsKey
        }
    }

    private func nonEmpty(_ ratings: [NuvioExternalRating]?) -> [NuvioExternalRating]? {
        guard let ratings, !ratings.isEmpty else { return nil }
        return ratings
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
            Text(L10n.string("catalog_load_failed", fallback: "Catalog failed"))
                .font(.largeTitle.bold())
            Text(message)
                .font(.title3)
                .foregroundColor(.white.opacity(0.68))
            Button(L10n.string("action_retry", fallback: "Retry"), action: onRetry)
                .buttonStyle(.borderedProminent)
        }
        .foregroundColor(.white)
        .padding(.leading, TVLayout.contentLeading)
        .frame(maxWidth: .infinity, minHeight: 560, alignment: .leading)
        .focusable(true)
    }
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
