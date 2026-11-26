import SwiftUI
import Combine
import AVKit
import AetherEngine
import Darwin
import ImageIO
import OSLog

/// High-fidelity Live TV browsing, EPG guide, and source management.
struct IPTVLiveView: View {
    @MainActor final class LoadedCache {
        struct Entry {
            let profileID: String
            let source: IPTVSource
            let loadedAt: Date
            var channels: [IPTVChannel]
            var stalkerChannels: [IPTVStalkerChannel]
            var stalkerClient: IPTVStalkerClient?
            var preparedLineup: IPTVPreparedLineup
            var guideURLs: [URL]
            var sameOrigin: Bool
            var favoriteKeys: [String: String]
            var guideByChannel: [String: [IPTVProgramme]]
            var guideNextRefresh: Date?
            var guideFailures: Int
            var guideUnavailable: Bool
        }

        static let lineupLifetime: TimeInterval = 30 * 60
        private(set) var entry: Entry?

        func validEntry(profileID: String, sources: [IPTVSource], now: Date = Date()) -> Entry? {
            guard let entry else { return nil }
            guard entry.profileID == profileID,
                  sources.first(where: { $0.id == entry.source.id }) == entry.source,
                  now.timeIntervalSince(entry.loadedAt) < Self.lineupLifetime else {
                clear()
                return nil
            }
            return entry
        }

        func store(_ entry: Entry) { self.entry = entry }
        func clear() { entry = nil }

        func updateGuide(
            profileID: String,
            source: IPTVSource,
            guideByChannel: [String: [IPTVProgramme]],
            nextRefresh: Date?,
            failures: Int,
            unavailable: Bool
        ) {
            guard var entry, entry.profileID == profileID, entry.source == source else { return }
            entry.guideByChannel = guideByChannel
            entry.guideNextRefresh = nextRefresh
            entry.guideFailures = failures
            entry.guideUnavailable = unavailable
            self.entry = entry
        }
    }

    let profileID: String
    let isActive: Bool
    let loadedCache: LoadedCache
    let onPlay: (URL, NuvioMeta, [String: String], [IPTVProgramme]) -> Void
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(SettingsKey.amoled) private var amoled = false
    @AppStorage(SettingsKey.amoledSurfaces) private var amoledSurfaces = false
    @AppStorage(SettingsKey.bodyColor) private var bodyColor = SettingsBackground.charcoal.rawValue
    @State private var inlinePreviewPlayer: AVPlayer?
    @State private var inlinePreviewIsReady = false
    @State private var inlinePreviewChannelID: String?
    @State private var inlinePreviewStartedAt: Date?
    @State private var inlinePreviewTarget: IPTVInlinePreviewTarget?
    @State private var inlinePreviewFailureObserver: NSKeyValueObservation?
    @State private var stalkerPreviewTask: Task<Void, Never>?
    @State private var inlineAetherPreviewController: IPTVInlineAetherPreviewController?
    @State private var inlineAetherPreviewIsReady = false
    @State private var fullscreenPreview: IPTVFullscreenPreview?
    @State private var isFullscreenPreviewTransitionActive = false
    @State private var fullscreenReturnChannelID: String?
    @State private var sidebarFocusRequestID = UUID()
    @State private var previewFocusRequestID = UUID()
    @State private var searchFocusRequestID = UUID()
    @State private var guideFocusNowRequestID = UUID()
    @State private var categoryFocusRequest: IPTVCategoryFocusRequest?
    @State private var favoriteFocusMemory = IPTVFavoriteFocusMemory()
    @State private var favoritesFocusRequestID = UUID()
    @State private var favoritesFocusTargetID: String?

    fileprivate static let allCategoriesID = "Alle"

    // MARK: - Navigation & Filters
    @State private var activeSidebarItem: IPTVNavTab = .liveTV
    @State private var selectedCategory: String = allCategoriesID
    @State private var showingHiddenCategories = false
    @State private var renamingCategoryID: String?
    @State private var categoryNameDraft = ""
    @State private var isCategoryNameEditing = false
    @State private var categoryPreferences = IPTVCategoryPreferences.empty
    @State private var showingCredentialsModal = false

    // MARK: - Sources & Core Data
    @State private var sources: [IPTVSource] = []
    @State private var sourcesLoaded = false
    @State private var channels: [IPTVChannel] = []
    @State private var stalkerChannels: [IPTVStalkerChannel] = []
    @State private var stalkerClient: IPTVStalkerClient?
    @State private var preparedLineup = IPTVPreparedLineup.empty
    @State private var cachedAllCategories: [String] = [allCategoriesID]
    @State private var cachedCategoryChooserGroups: [String] = []
    @State private var cachedHasHiddenCategoryGroups = false
    @State private var cachedVisibleChannels: [IPTVIndexedChannel] = []
    @State private var selectedID: UUID?
    @State private var successfullyLoadedSource: IPTVSource?
    @State private var successfullyLoadedAt: Date?
    @State private var loadingSource: IPTVSource?

    // Credentials / Source Editor State
    @State private var editingID: UUID?
    @State private var sourceName = ""
    @State private var sourceURL = ""
    @State private var sourceKind: IPTVSource.Kind = .xtream
    @State private var username = ""
    @State private var password = ""
    @State private var mac = ""
    @State private var xtreamOutput: IPTVXtreamOutput = .mpegTS

    // Network / Async State
    @State private var errorMessage: String?
    @State private var loading = false
    @State private var loadTask: Task<Void, Never>?
    @State private var stalkerPlayTask: Task<Void, Never>?
    @State private var requestID = UUID()
    @State private var guideTask: Task<Void, Never>?
    @State private var guideByChannel: [String: [IPTVProgramme]] = [:]
    @State private var guideRevision = 0
    @State private var guideUnavailable = false
    @State private var guideNow = Date()
    /// When the guide is due to be fetched again (see IPTVGuideRefreshPolicy),
    /// how many loads in a row failed, and the load the guide may still come from.
    @State private var guideNextRefresh: Date?
    @State private var guideFailures = 0
    @State private var guideRequestID: UUID?
    @State private var selectedGuideURLs: [URL] = []
    @State private var selectedGuideNeedsSameOrigin = false
    @State private var guidePageStartOverride: Date?
    @State private var selectedGuideProgramme: IPTVProgramme?
    @State private var selectedGuideChannelID: String?
    @State private var guideTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.locale = AppLocaleManager.shared.locale
        return formatter
    }()
    @State private var guideDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = AppLocaleManager.shared.locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    // Channel Selection & Favorites
    @State private var selectedChannelID: String?
    @State private var favorites: Set<String> = []
    @State private var favoriteOrder: [String] = []
    @State private var favoriteKeys: [String: String] = [:]
    @State private var recentChannelKeys: [String] = []
    @State private var searchText = ""

    private let store = IPTVSourceStore()
    private let loader = IPTVPlaylistLoader()
    private let xtream = IPTVXtreamClient()
    private let guideLoader = IPTVGuideLoader()
    private let guideClock = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
    private let guidePageDuration: TimeInterval = 4 * 60 * 60
#if NUVIO_SIDEBAR_WATCHDOG
    private static let sidebarLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.pyksel.nuviotvos", category: "SidebarWatchdog")

    private final class GuideLoadWatchdog: @unchecked Sendable {
        private struct Snapshot {
            let baselineMB: Double?
            let latestMB: Double?
            let peakMB: Double?
            let endMB: Double?
            let sampleCount: Int
            let unavailableSamples: Int
            let firstListingsMs: Int?
        }

        private let startedAt: TimeInterval
        private let token: String
        private let cachedGuidePresent: Bool
        private let logger: Logger
        private let lock = NSLock()
        private var timer: DispatchSourceTimer?
        private var baselineMB: Double?
        private var latestMB: Double?
        private var peakMB: Double?
        private var endMB: Double?
        private var sampleCount = 0
        private var unavailableSamples = 0
        private var firstListingsMs: Int?
        private var lastProgressAt: TimeInterval = 0
        private var finished = false

        init(startedAt: TimeInterval, token: String, cachedGuidePresent: Bool, logger: Logger) {
            self.startedAt = startedAt
            self.token = token
            self.cachedGuidePresent = cachedGuidePresent
            self.logger = logger

            let startFootprint = Self.physicalFootprintMB()
            lock.lock()
            baselineMB = startFootprint
            latestMB = startFootprint
            peakMB = startFootprint
            if startFootprint == nil {
                unavailableSamples = 1
            } else {
                sampleCount = 1
            }
            lock.unlock()
            let baseline = startFootprint.map(Self.formattedMB) ?? "unavailable"
            logger.notice("guide watchdog start token=\(self.token, privacy: .public) baselineMiB=\(baseline, privacy: .public) cachedGuide=\(self.cachedGuidePresent, privacy: .public)")

            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
            timer.schedule(deadline: .now(), repeating: .milliseconds(250), leeway: .milliseconds(50))
            timer.setEventHandler { [weak self] in self?.sample() }
            self.timer = timer
            timer.resume()
        }

        deinit {
            timer?.cancel()
        }

        func recordFirstListingsIfNeeded(programmeCount: Int) {
            guard programmeCount > 0 else { return }
            lock.lock()
            if firstListingsMs == nil {
                firstListingsMs = Int(max(0, ProcessInfo.processInfo.systemUptime - startedAt) * 1_000)
            }
            lock.unlock()
        }

        func finish(status: String) {
            let endFootprint = Self.physicalFootprintMB()
            let elapsed = max(0, ProcessInfo.processInfo.systemUptime - startedAt)
            lock.lock()
            guard !finished else {
                lock.unlock()
                return
            }
            endMB = endFootprint
            if let endFootprint {
                latestMB = endFootprint
                peakMB = max(peakMB ?? endFootprint, endFootprint)
                sampleCount += 1
            } else {
                unavailableSamples += 1
            }
            finished = true
            let snapshot = makeSnapshotLocked()
            lock.unlock()

            timer?.cancel()
            timer = nil
            let durationMs = Int(elapsed * 1_000)
            let firstListings = snapshot.firstListingsMs.map(String.init) ?? "none"
            let baseline = snapshot.baselineMB.map(Self.formattedMB) ?? "unavailable"
            let peak = snapshot.peakMB.map(Self.formattedMB) ?? "unavailable"
            let end = snapshot.endMB.map(Self.formattedMB) ?? "unavailable"
            let peakDelta = Self.deltaText(peak: snapshot.peakMB, baseline: snapshot.baselineMB)
            logger.notice("guide watchdog summary token=\(self.token, privacy: .public) status=\(status, privacy: .public) cachedGuide=\(self.cachedGuidePresent, privacy: .public) durationMs=\(durationMs, privacy: .public) firstListingsMs=\(firstListings, privacy: .public) baselineMiB=\(baseline, privacy: .public) processWidePeakMiB=\(peak, privacy: .public) endMiB=\(end, privacy: .public) peakMinusBaselineMiB=\(peakDelta, privacy: .public) samples=\(snapshot.sampleCount, privacy: .public) unavailableSamples=\(snapshot.unavailableSamples, privacy: .public)")
        }

        private func sample() {
            let footprint = Self.physicalFootprintMB()
            let elapsed = max(0, ProcessInfo.processInfo.systemUptime - startedAt)
            lock.lock()
            guard !finished else {
                lock.unlock()
                return
            }
            if let footprint {
                latestMB = footprint
                peakMB = max(peakMB ?? footprint, footprint)
                sampleCount += 1
            } else {
                unavailableSamples += 1
            }
            guard elapsed - lastProgressAt >= 5 else {
                lock.unlock()
                return
            }
            lastProgressAt = elapsed
            let snapshot = makeSnapshotLocked()
            lock.unlock()

            let elapsedMs = Int(elapsed * 1_000)
            let current = snapshot.latestMB.map(Self.formattedMB) ?? "unavailable"
            let baseline = snapshot.baselineMB.map(Self.formattedMB) ?? "unavailable"
            let peak = snapshot.peakMB.map(Self.formattedMB) ?? "unavailable"
            let firstListings = snapshot.firstListingsMs.map(String.init) ?? "none"
            let peakDelta = Self.deltaText(peak: snapshot.peakMB, baseline: snapshot.baselineMB)
            logger.notice("guide watchdog progress token=\(self.token, privacy: .public) elapsedMs=\(elapsedMs, privacy: .public) firstListingsMs=\(firstListings, privacy: .public) footprintMiB=\(current, privacy: .public) baselineMiB=\(baseline, privacy: .public) processWidePeakMiB=\(peak, privacy: .public) peakMinusBaselineMiB=\(peakDelta, privacy: .public) samples=\(snapshot.sampleCount, privacy: .public) unavailableSamples=\(snapshot.unavailableSamples, privacy: .public)")
        }

        private func makeSnapshotLocked() -> Snapshot {
            Snapshot(
                baselineMB: baselineMB,
                latestMB: latestMB,
                peakMB: peakMB,
                endMB: endMB,
                sampleCount: sampleCount,
                unavailableSamples: unavailableSamples,
                firstListingsMs: firstListingsMs
            )
        }

        private static func formattedMB(_ value: Double) -> String {
            String(format: "%.1f", value)
        }

        private static func deltaText(peak: Double?, baseline: Double?) -> String {
            guard let peak, let baseline else { return "unavailable" }
            return formattedMB(peak - baseline)
        }

        private static func physicalFootprintMB() -> Double? {
            var vmInfo = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &vmInfo) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            guard result == KERN_SUCCESS else { return nil }
            return Double(vmInfo.phys_footprint) / (1024 * 1024)
        }
    }
#endif

    var body: some View {
        let activeChannel = activeSelectedChannel
        let activeEPG = activeChannel.map { epgSnapshot(for: $0) }
        let previewRequest = activeChannel.flatMap { eligibleInlinePreviewRequest(for: $0) }
        let activeCategoryLabel = activeChannel.map { categoryPreferences.customNames[$0.group] ?? $0.category }

        return ZStack {
            // Background
            Self.backgroundColor(amoled: amoled, bodyColor: bodyColor)
                .ignoresSafeArea()

            HStack(alignment: .top, spacing: 28) {
                // MARK: 1. Left Sidebar Navigation
                IPTVSidebarView(
                    activeSidebarItem: activeSidebarItem,
                    loading: loading,
                    isActive: isActive,
                    focusLiveTVRequestID: sidebarFocusRequestID,
                    onSelect: handleSidebarSelection
                )
                .frame(width: 280)
                .frame(maxHeight: .infinity)

                // MARK: 2. Main Content Area
                VStack(alignment: .leading, spacing: 14) {
                    // Top Category Filter Pills (lazy & equatable)
                    IPTVCategoryPillsRow(
                        categories: cachedAllCategories,
                        selectedCategory: selectedCategory,
                        customNames: categoryPreferences.customNames,
                        onSelect: selectCategory
                    )
                    .equatable()

                    if activeSidebarItem == .guide {
                        IPTVTimeGuideView(
                            visibleChannels: cachedVisibleChannels,
                            baseChannelsByID: preparedLineup.baseChannelsByID,
                            hasGuideIDs: preparedLineup.hasGuideIDs,
                            selectedCategory: selectedCategory,
                            hiddenGroupIDs: categoryPreferences.hiddenGroupIDs,
                            guideByChannel: guideByChannel,
                            guideRevision: guideRevision,
                            guideNow: guideNow,
                            guidePageStart: guidePageStart,
                            guidePageEnd: guidePageEnd,
                            guidePageDuration: guidePageDuration,
                            canBrowseGuideEarlier: canBrowseGuideEarlier,
                            canBrowseGuideLater: canBrowseGuideLater,
                            isLoadingGuide: guideTask != nil,
                            guideFailures: guideFailures,
                            guideUnavailable: guideUnavailable,
                            selectedGuideURLsIsEmpty: selectedGuideURLs.isEmpty,
                            selectedGuideProgramme: $selectedGuideProgramme,
                            selectedGuideChannelID: $selectedGuideChannelID,
                            guideTimeFormatter: guideTimeFormatter,
                            guideDateFormatter: guideDateFormatter,
                            cardSurfaceFill: cardSurfaceFill,
                            isActive: isActive,
                            focusNowRequestID: guideFocusNowRequestID,
                            onMoveGuidePage: moveGuidePage,
                            onResetGuideNow: { guidePageStartOverride = nil },
                            onRetryGuide: retryGuide,
                            onTuneChannel: { channel in
                                selectChannelForPreview(channel, openFullscreenIfAlreadyPreviewing: false)
                                activeSidebarItem = .liveTV
                                selectedGuideProgramme = nil
                                selectedGuideChannelID = nil
                                recomputeVisibleChannels()
                                focusPreviewAfterGuideTune(channelID: channel.id)
                            },
                            onExitToSidebar: returnToLiveTVSidebar
                        )
                    } else {
                        // Two-column content: Channel List + Detail & Schedule Stack
                        HStack(alignment: .top, spacing: 20) {
                            // Left Column: Channel List Card
                            IPTVChannelListCard(
                                sectionTitle: sectionTitle,
                                emptySectionMessage: emptySectionMessage,
                                activeSidebarItem: activeSidebarItem,
                                selectedCategory: selectedCategory,
                                isChoosingCategory: isChoosingCategory,
                                hasHiddenCategoryGroups: cachedHasHiddenCategoryGroups,
                                showingHiddenCategories: showingHiddenCategories,
                                categoryChooserGroups: cachedCategoryChooserGroups,
                                categoryPreferences: categoryPreferences,
                                renamingCategoryID: renamingCategoryID,
                                categoryNameDraft: $categoryNameDraft,
                                isCategoryNameEditing: $isCategoryNameEditing,
                                searchText: $searchText,
                                visibleChannels: cachedVisibleChannels,
                                selectedChannelID: selectedChannelID,
                                favorites: favorites,
                                favoriteKeys: favoriteKeys,
                                guideByChannel: guideByChannel,
                                guideRevision: guideRevision,
                                guideNow: guideNow,
                                cardSurfaceFill: cardSurfaceFill,
                                isActive: isActive,
                                searchFocusRequestID: searchFocusRequestID,
                                favoritesFocusRequestID: favoritesFocusRequestID,
                                favoritesFocusTargetID: $favoritesFocusTargetID,
                                favoriteFocusMemory: favoriteFocusMemory,
                                categoryFocusRequest: categoryFocusRequest,
                                onToggleShowingHiddenCategories: {
                                    showingHiddenCategories.toggle()
                                    recomputeCategories()
                                },
                                onCommitCategoryRename: commitCategoryRename,
                                onSelectCategory: selectCategory,
                                onMoveCategory: moveCategory,
                                onSetCategoryHidden: setCategoryHidden,
                                onBeginCategoryRename: beginCategoryRename,
                                onSelectChannel: { channel in selectChannelForPreview(channel) },
                                onPlayChannel: playChannel,
                                onToggleFavorite: toggleFavorite,
                                onMoveFavorite: moveFavorite
                            )
                            .frame(width: 415)
                            .frame(maxHeight: .infinity)

                            // Right Column: Preview + Schedule
                            VStack(alignment: .leading, spacing: 14) {
                                IPTVLivePreviewCard(
                                    activeChannel: activeChannel,
                                    activeEPG: activeEPG,
                                    categoryLabel: activeCategoryLabel,
                                    inlinePreviewPlayer: inlinePreviewPlayer,
                                    inlineAetherPreviewController: inlineAetherPreviewController,
                                    inlineAetherPreviewIsReady: inlineAetherPreviewIsReady,
                                    isFullscreenPreviewTransitionActive: isFullscreenPreviewTransitionActive,
                                    loading: loading,
                                    sourcesIsEmpty: sources.isEmpty,
                                    errorMessage: errorMessage,
                                    cardSurfaceFill: cardSurfaceFill,
                                    previewBackdropFill: previewBackdropFill,
                                    focusRequestID: previewFocusRequestID,
                                    onPlay: playChannel,
                                    onMarkInlinePreviewReady: markInlinePreviewReady,
                                    onOpenCredentials: {
                                        resetSourceEditor()
                                        showingCredentialsModal = true
                                    }
                                )
                                .frame(maxWidth: .infinity, maxHeight: .infinity)

                                IPTVScheduleEPGCard(
                                    activeChannelName: activeChannel?.name,
                                    activeEPG: activeEPG,
                                    cardSurfaceFill: cardSurfaceFill
                                )
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .frame(maxHeight: .infinity, alignment: .top)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
                .focusSection()
                .onExitCommand(perform: activeSidebarItem == .guide ? nil : returnToLiveTVSidebar)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.leading, 48)
            .padding(.trailing, 48)
            .padding(.top, 22)
            .padding(.bottom, 22)
        }
        .sheet(isPresented: $showingCredentialsModal) {
            credentialsModalView
        }
        .onAppear {
            // A local full-screen player can cause this view to reappear while
            // its inline AVPlayer session is still alive. Keep that session and
            // its source state intact on the way back.
            guard !isFullscreenPreviewTransitionActive,
                  inlinePreviewPlayer == nil,
                  inlineAetherPreviewController?.activeChannelID == nil else { return }
            restoreSources()
        }
        .onChange(of: selectedID) { _, sourceID in
            selectedCategory = Self.allCategoriesID
            showingHiddenCategories = false
            cancelCategoryRename()
            loadCategoryPreferences(for: sourceID)
        }
        .onChange(of: searchText) { _, _ in
            if activeSidebarItem == .search {
                recomputeVisibleChannels()
            }
        }
        .onReceive(guideClock) { now in
            guard isActive, scenePhase == .active else { return }
            if !guideByChannel.isEmpty || activeSidebarItem == .guide {
                guideNow = now
                if activeSidebarItem == .sportsNow || activeSidebarItem == .search {
                    recomputeVisibleChannels()
                }
            }
            refreshGuideIfDue(now: now)
        }
        .onChange(of: previewRequest, initial: true) { _, request in
            updateInlinePreview(for: request)
        }
        .onDisappear {
            if isFullscreenPreviewTransitionActive && isActive && scenePhase == .active { return }
            inlinePreviewChannelID = nil
            stopInlinePreview(releaseAetherEngine: true)
            cancelSourceAndGuideWork()
        }
        .onChange(of: isActive) { _, active in
            if !active {
                discardInlinePreviewForExternalExit()
                cancelSourceAndGuideWork()
            } else if scenePhase == .active {
                restoreSources()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                discardInlinePreviewForExternalExit()
                cancelSourceAndGuideWork()
            } else if isActive {
                restoreSources()
            }
        }
        .fullScreenCover(item: $fullscreenPreview, onDismiss: fullscreenPreviewDidDismiss) { preview in
            AVPlayerFullscreenOverlay(
                player: preview.player,
                title: preview.channelTitle,
                year: nil,
                isLive: true,
                isReady: true,
                liveProgrammes: preview.programmes,
                liveStartedAt: preview.startedAt,
                onTrailerReady: {},
                onDismiss: requestFullscreenPreviewDismissal
            )
        }
    }

    // MARK: - Navigation Tabs
    enum IPTVNavTab: String, CaseIterable {
        case search
        case liveTV
        case sportsNow
        case guide
        case channels
        case favorites
        case categories
        case recent
        case settings

        var title: String {
            switch self {
            case .search: return L10n.string("nav_search", fallback: "Search")
            case .liveTV: return L10n.string("nav_live_tv", fallback: "Live TV")
            case .sportsNow: return L10n.string("iptv_nav_sports_now", fallback: "Sports now")
            case .guide: return L10n.string("iptv_nav_guide", fallback: "TV guide")
            case .channels: return L10n.string("iptv_nav_channels", fallback: "Channel list")
            case .favorites: return L10n.string("iptv_nav_favorites", fallback: "Favorites")
            case .categories: return L10n.string("iptv_nav_categories", fallback: "Categories")
            case .recent: return L10n.string("iptv_nav_recent", fallback: "Recently watched")
            case .settings: return L10n.string("nav_settings", fallback: "Settings")
            }
        }

        var icon: String {
            switch self {
            case .search: return "magnifyingglass"
            case .liveTV: return "tv"
            case .sportsNow: return "sportscourt"
            case .guide: return "calendar"
            case .channels: return "list.bullet"
            case .favorites: return "heart"
            case .categories: return "square.grid.2x2"
            case .recent: return "clock"
            case .settings: return "gearshape"
            }
        }
    }

    private func handleSidebarSelection(_ tab: IPTVNavTab) {
        activeSidebarItem = tab
        showingHiddenCategories = false
        cancelCategoryRename()
        switch tab {
        case .search:
            selectedCategory = Self.allCategoriesID
            recomputeCategories()
            recomputeVisibleChannels()
            searchFocusRequestID = UUID()
        case .liveTV:
            selectedCategory = Self.allCategoriesID
            recomputeCategories()
            recomputeVisibleChannels()
        case .sportsNow:
            selectedCategory = Self.allCategoriesID
            recomputeCategories()
            recomputeVisibleChannels()
        case .guide:
            selectedCategory = Self.allCategoriesID
            guidePageStartOverride = nil
            selectedGuideProgramme = nil
            selectedGuideChannelID = nil
            recomputeCategories()
            recomputeVisibleChannels()
            guideFocusNowRequestID = UUID()
        case .channels:
            selectedCategory = Self.allCategoriesID
            recomputeCategories()
            recomputeVisibleChannels()
        case .favorites:
            selectedCategory = Self.allCategoriesID
            recomputeCategories()
            recomputeVisibleChannels()
            focusFavoriteChannelAfterSidebarSelection()
        case .categories:
            selectedCategory = Self.allCategoriesID
            recomputeCategories()
            recomputeVisibleChannels()
        case .recent:
            selectedCategory = Self.allCategoriesID
            recomputeCategories()
            recomputeVisibleChannels()
        case .settings:
            recomputeCategories()
            recomputeVisibleChannels()
            resetSourceEditor()
            showingCredentialsModal = true
        }
    }

    private func selectCategory(_ category: String) {
        guard selectedCategory != category else { return }
        selectedCategory = category
        recomputeVisibleChannels()
    }

    private func focusFavoriteChannelAfterSidebarSelection() {
        let visibleFavorites = cachedVisibleChannels
        guard !visibleFavorites.isEmpty else { return }
        let lastFocused = favoriteFocusMemory.lastFocusedID
        let targetID = visibleFavorites.first(where: { $0.id == lastFocused })?.id
            ?? visibleFavorites.first(where: { $0.id == selectedChannelID })?.id
            ?? visibleFavorites.first?.id
        guard let targetID else { return }
        favoritesFocusTargetID = targetID
        favoritesFocusRequestID = UUID()
    }

    private func categoryDisplayName(_ groupID: String) -> String {
        categoryPreferences.customNames[groupID] ?? groupID
    }

    private func loadCategoryPreferences(for sourceID: UUID?) {
        guard let sourceID else {
            categoryPreferences = .empty
            recomputeCategories()
            recomputeVisibleChannels()
            return
        }
        categoryPreferences = IPTVCategoryPreferencesStore.load(
            defaults: ProfileSettings.store(for: profileID),
            sourceID: sourceID
        )
        recomputeCategories()
        recomputeVisibleChannels()
    }

    // MARK: - Time-based Programme Guide Helpers
    private var guidePageStart: Date {
        let lower = startOfHour(guideNow.addingTimeInterval(-IPTVGuideRefreshPolicy.lookBehind))
        let upper = startOfHour(guideNow.addingTimeInterval(IPTVGuideRefreshPolicy.lookAhead - guidePageDuration))
        return min(max(guidePageStartOverride ?? startOfHour(guideNow), lower), upper)
    }

    private var guidePageEnd: Date {
        min(guidePageStart.addingTimeInterval(guidePageDuration), guideNow.addingTimeInterval(IPTVGuideRefreshPolicy.lookAhead))
    }

    private func startOfHour(_ date: Date) -> Date {
        Calendar.current.dateInterval(of: .hour, for: date)?.start ?? date
    }

    private var canBrowseGuideEarlier: Bool {
        guidePageStart > startOfHour(guideNow.addingTimeInterval(-IPTVGuideRefreshPolicy.lookBehind))
    }

    private var canBrowseGuideLater: Bool {
        guidePageStart < startOfHour(guideNow.addingTimeInterval(IPTVGuideRefreshPolicy.lookAhead - guidePageDuration))
    }

    private func moveGuidePage(by interval: TimeInterval) {
        let lower = startOfHour(guideNow.addingTimeInterval(-IPTVGuideRefreshPolicy.lookBehind))
        let upper = startOfHour(guideNow.addingTimeInterval(IPTVGuideRefreshPolicy.lookAhead - guidePageDuration))
        guidePageStartOverride = min(max(guidePageStart.addingTimeInterval(interval), lower), upper)
    }

    private func returnToLiveTVSidebar() {
        handleSidebarSelection(.liveTV)
        sidebarFocusRequestID = UUID()
    }

    private func focusPreviewAfterGuideTune(channelID: String) {
        Task { @MainActor in
            await Task.yield()
            guard isActive, scenePhase == .active, activeSidebarItem == .liveTV,
                  selectedChannelID == channelID, inlinePreviewChannelID == channelID else { return }
            previewFocusRequestID = UUID()
        }
    }

    static func backgroundColor(amoled: Bool, bodyColor: String) -> Color {
        Color.nuvioBackground(amoled: amoled, body: bodyColor)
    }

    static func surfaceFill(amoled: Bool, amoledSurfaces: Bool, opacity: Double = 0.045) -> Color {
        (amoled && amoledSurfaces) ? .black : Color.white.opacity(opacity)
    }

    private var cardSurfaceFill: Color {
        Self.surfaceFill(amoled: amoled, amoledSurfaces: amoledSurfaces)
    }

    private var previewBackdropFill: Color {
        Self.surfaceFill(amoled: amoled, amoledSurfaces: amoledSurfaces, opacity: 0.06)
    }

    // MARK: - Credentials & Source Configuration Sheet
    private var credentialsModalView: some View {
        ZStack {
            Color.nuvioBackground(amoled: amoled, body: bodyColor).ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text(editingID == nil
                        ? L10n.string("iptv_add_iptv_source", fallback: "Add IPTV source")
                        : L10n.string("iptv_edit_iptv_source", fallback: "Edit IPTV source"))
                        .font(.system(size: 36, weight: .bold))
                        .foregroundColor(.white)

                    IPTVSettingsGroup(
                        title: L10n.string("iptv_settings_title", fallback: "Live TV"),
                        subtitle: L10n.string("iptv_credentials_subtitle", fallback: "Enter your M3U playlist, Xtream Codes, or Stalker Portal details to watch live TV.")
                    ) {
                        IPTVChoiceRow(
                            title: L10n.string("iptv_source_type", fallback: "Source type"),
                            selection: sourceKindSelection,
                            options: IPTVSource.Kind.allCases.map { sourceKindLabel($0) }
                        )

                        IPTVFormTextFieldRow(
                            title: L10n.string("iptv_source_name", fallback: "Source name"),
                            placeholder: L10n.string("iptv_source_name_placeholder", fallback: "Source name (e.g. My IPTV)"),
                            text: $sourceName,
                            autocapitalizationType: .words
                        )

                        IPTVFormTextFieldRow(
                            title: sourceKind == .m3u
                                ? L10n.string("iptv_source_url", fallback: "Playlist URL")
                                : (sourceKind == .stalker
                                    ? L10n.string("iptv_portal_endpoint", fallback: "Portal endpoint URL")
                                    : L10n.string("iptv_server_url", fallback: "Server URL")),
                            placeholder: sourceKind == .m3u ? L10n.string("iptv_m3u_url_placeholder", fallback: "M3U URL (e.g. https://.../playlist.m3u)") :
                                (sourceKind == .stalker
                                    ? L10n.string("iptv_portal_url_placeholder", fallback: "Portal URL")
                                    : L10n.string("iptv_server_url_placeholder", fallback: "Server URL (e.g. http://server.com:8080)")),
                            text: $sourceURL,
                            isSecure: true,
                            keyboardType: .URL
                        )
                    }

                    if sourceKind == .xtream || sourceKind == .stalker {
                        IPTVSettingsGroup(
                            title: L10n.string("smb_authentication", fallback: "Authentication"),
                            subtitle: L10n.string("tvos_settings_stored_locally_on_this_apple_tv", fallback: "Stored locally on this Apple TV")
                        ) {
                            if sourceKind == .xtream {
                                IPTVFormTextFieldRow(
                                    title: L10n.string("iptv_username", fallback: "Username"),
                                    placeholder: L10n.string("iptv_username", fallback: "Username"),
                                    text: $username
                                )
                                IPTVFormTextFieldRow(
                                    title: L10n.string("iptv_password", fallback: "Password"),
                                    placeholder: L10n.string("iptv_password", fallback: "Password"),
                                    text: $password,
                                    isSecure: true
                                )
                                IPTVChoiceRow(
                                    title: L10n.string("iptv_xtream_format", fallback: "Stream format"),
                                    selection: xtreamOutputSelection,
                                    options: IPTVXtreamOutput.allCases.map { xtreamOutputLabel($0) }
                                )
                            }

                            if sourceKind == .stalker {
                                IPTVFormTextFieldRow(
                                    title: L10n.string("iptv_stalker_mac", fallback: "MAC address"),
                                    placeholder: L10n.string("iptv_mac_placeholder", fallback: "MAC address (e.g. 00:1A:79:...)"),
                                    text: $mac
                                )
                            }
                        }
                    }

                    HStack {
                        IPTVDialogButton(
                            title: L10n.string("action_close", fallback: "Close"),
                            isPrimary: false
                        ) {
                            showingCredentialsModal = false
                        }

                        if editingID != nil {
                            IPTVDialogButton(
                                title: L10n.string("iptv_add_new_source", fallback: "Add new"),
                                isPrimary: false
                            ) {
                                resetSourceEditor()
                            }
                        }

                        Spacer()

                        IPTVDialogButton(
                            title: editingID == nil
                                ? L10n.string("iptv_save_and_load_source", fallback: "Save & load source")
                                : L10n.string("iptv_save_changes", fallback: "Save changes"),
                            isPrimary: true,
                            enabled: !sourceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !sourceURL.isEmpty
                        ) {
                            addSource()
                            showingCredentialsModal = false
                        }
                    }
                    .focusSection()

                    if !sources.isEmpty {
                        IPTVSettingsGroup(
                            title: L10n.string("iptv_configured_sources", fallback: "Configured sources"),
                            subtitle: L10n.string("iptv_switch_source_subtitle", fallback: "Select a source to switch portals, or edit and remove saved sources.")
                        ) {
                            ForEach(sources) { src in
                                IPTVConfiguredSourceRow(
                                    source: src,
                                    kindLabel: sourceKindLabel(src.kind),
                                    isActiveSource: src.id == selectedID,
                                    onSelect: { selectSource(src) },
                                    onEdit: { edit(src) },
                                    onDelete: { remove(src) }
                                )
                            }
                        }
                    }
                }
                .padding(40)
            }
        }
    }

    private func sourceKindLabel(_ kind: IPTVSource.Kind) -> String {
        switch kind {
        case .xtream: return "Xtream Codes"
        case .m3u: return L10n.string("iptv_source_type_m3u", fallback: "M3U Playlist")
        case .stalker: return "Stalker Portal"
        }
    }

    private func xtreamOutputLabel(_ output: IPTVXtreamOutput) -> String {
        switch output {
        case .mpegTS: return "MPEG-TS"
        case .hls: return "HLS"
        }
    }

    private var sourceKindSelection: Binding<String> {
        Binding(
            get: { sourceKindLabel(sourceKind) },
            set: { label in
                sourceKind = IPTVSource.Kind.allCases.first { sourceKindLabel($0) == label } ?? .xtream
            }
        )
    }

    private var xtreamOutputSelection: Binding<String> {
        Binding(
            get: { xtreamOutputLabel(xtreamOutput) },
            set: { label in
                xtreamOutput = IPTVXtreamOutput.allCases.first { xtreamOutputLabel($0) == label } ?? .mpegTS
            }
        )
    }

    // MARK: - Display Model & Cached Data Mapping
    private var activeSelectedChannel: IPTVBaseChannel? {
        if let selectedChannelID, let found = preparedLineup.baseChannelsByID[selectedChannelID] {
            return found
        }
        return preparedLineup.baseChannels.first
    }

    private var sectionTitle: String {
        switch activeSidebarItem {
        case .search: return L10n.string("nav_search", fallback: "Search")
        case .sportsNow: return L10n.string("iptv_nav_sports_now", fallback: "Sports now")
        case .favorites: return L10n.string("iptv_nav_favorites", fallback: "Favorites")
        case .recent: return L10n.string("iptv_nav_recent", fallback: "Recently watched")
        case .categories where selectedCategory == Self.allCategoriesID: return L10n.string("iptv_nav_categories", fallback: "Categories")
        default: return selectedCategory == Self.allCategoriesID
            ? L10n.string("iptv_all_channels", fallback: "All channels")
            : categoryDisplayName(selectedCategory)
        }
    }

    private var isChoosingCategory: Bool {
        activeSidebarItem == .categories && selectedCategory == Self.allCategoriesID
    }

    private func recomputeCategories() {
        let base = preparedLineup.baseCategoryGroups
        let orderedVisible = IPTVCategoryPreferencesStore.orderedGroups(
            base,
            preferences: categoryPreferences
        )
        let newAll = [Self.allCategoriesID] + orderedVisible
        if cachedAllCategories != newAll {
            cachedAllCategories = newAll
        }
        let newChooser = showingHiddenCategories
            ? IPTVCategoryPreferencesStore.orderedGroups(
                base,
                preferences: categoryPreferences,
                includingHidden: true
            )
            : orderedVisible
        if cachedCategoryChooserGroups != newChooser {
            cachedCategoryChooserGroups = newChooser
        }
        let newHasHidden = !categoryPreferences.hiddenGroupIDs.isEmpty
            && base.contains { categoryPreferences.hiddenGroupIDs.contains($0) }
        if cachedHasHiddenCategoryGroups != newHasHidden {
            cachedHasHiddenCategoryGroups = newHasHidden
        }
    }

    private func recomputeVisibleChannels() {
        if isChoosingCategory {
            if !cachedVisibleChannels.isEmpty { cachedVisibleChannels = [] }
            return
        }
        let query = channelSearchQuery
        if activeSidebarItem == .search && query.isEmpty {
            if !cachedVisibleChannels.isEmpty { cachedVisibleChannels = [] }
            return
        }

        let all = preparedLineup.baseChannels
        var result: [IPTVBaseChannel]

        switch activeSidebarItem {
        case .favorites:
            result = all.filter { isFavorite(channelID: $0.id) }
        case .recent:
            var channelsByKey: [String: IPTVBaseChannel] = [:]
            for channel in all where channel.streamURL != nil {
                if let key = favoriteKeys[channel.id], channelsByKey[key] == nil {
                    channelsByKey[key] = channel
                }
            }
            result = recentChannelKeys.compactMap { channelsByKey[$0] }
        default:
            result = all
        }

        if selectedCategory != Self.allCategoriesID {
            result = result.filter { $0.group == selectedCategory }
        }

        // Hidden groups stay available through explicit Favorites and Recent
        // navigation, while ordinary browsing, search, and the guide omit them.
        if activeSidebarItem != .favorites && activeSidebarItem != .recent {
            let hiddenGroupIDs = categoryPreferences.hiddenGroupIDs
            if !hiddenGroupIDs.isEmpty {
                result = result.filter { !hiddenGroupIDs.contains($0.group) }
            }
        }

        // Use only the current EPG programme, never an upcoming listing or the static playlist group.
        if activeSidebarItem == .sportsNow {
            if guideByChannel.isEmpty {
                result = []
            } else {
                result = result.filter { channel in
                    guard channel.streamURL != nil,
                          let guideID = channel.guideID,
                          let programmes = guideByChannel[guideID],
                          let current = IPTVChannelGuideLookup.currentProgramme(in: programmes, at: guideNow) else {
                        return false
                    }
                    return IPTVChannelFilter.isSportsEventTitle(current.title)
                }
            }
        }

        if activeSidebarItem == .search {
            let hasGuide = !guideByChannel.isEmpty
            result = result.filter { channel in
                let currentTitle: String?
                if hasGuide, let guideID = channel.guideID, let programmes = guideByChannel[guideID] {
                    currentTitle = IPTVChannelGuideLookup.currentProgramme(in: programmes, at: guideNow)?.title
                } else {
                    currentTitle = nil
                }
                return IPTVChannelFilter.matches(
                    name: channel.name,
                    group: channel.group,
                    query: query,
                    selectedGroup: nil,
                    currentProgrammeTitle: currentTitle
                )
            }
        }

        if activeSidebarItem == .favorites {
            var positions: [String: Int] = [:]
            positions.reserveCapacity(favoriteOrder.count)
            for (index, key) in favoriteOrder.enumerated() where positions[key] == nil {
                positions[key] = index
            }
            result = result.enumerated().sorted { lhs, rhs in
                let lhsPosition = positions[favoriteKeys[lhs.element.id] ?? lhs.element.id] ?? Int.max
                let rhsPosition = positions[favoriteKeys[rhs.element.id] ?? rhs.element.id] ?? Int.max
                return lhsPosition == rhsPosition ? lhs.offset < rhs.offset : lhsPosition < rhsPosition
            }.map(\.element)
        }

        var indexed: [IPTVIndexedChannel] = []
        indexed.reserveCapacity(result.count)
        for (offset, channel) in result.enumerated() {
            indexed.append(IPTVIndexedChannel(number: offset + 1, channel: channel))
        }
        cachedVisibleChannels = indexed
    }

    private func epgSnapshot(for channel: IPTVBaseChannel) -> IPTVChannelEPGSnapshot {
        let liveBadge = L10n.string("iptv_live_badge", fallback: "Live")
        let nextProgramTitle = L10n.string("iptv_next_program", fallback: "Next program")
        let followingProgramTitle = L10n.string("iptv_following_program", fallback: "Following program")

        guard let guideID = channel.guideID, let programmes = guideByChannel[guideID], !programmes.isEmpty else {
            return IPTVChannelEPGSnapshot(
                programTitle: channel.name,
                programTime: liveBadge,
                programProgress: nil,
                nextShow1Title: nextProgramTitle,
                nextShow1Time: "--:--",
                nextShow2Title: followingProgramTitle,
                nextShow2Time: "--:--"
            )
        }

        let prog = IPTVChannelGuideLookup.currentProgramme(in: programmes, at: guideNow)
        let upcoming = IPTVChannelGuideLookup.upcomingProgrammes(in: programmes, at: guideNow, limit: 2)
        let next1 = upcoming.first
        let next2 = upcoming.count > 1 ? upcoming[upcoming.index(after: upcoming.startIndex)] : nil

        return IPTVChannelEPGSnapshot(
            programTitle: prog?.title ?? channel.name,
            programTime: prog != nil ? formatTimeRange(start: prog!.start, end: prog!.end) : liveBadge,
            programProgress: prog.map { calculateProgress(start: $0.start, end: $0.end) },
            nextShow1Title: next1?.title ?? nextProgramTitle,
            nextShow1Time: next1 != nil ? formatTimeRange(start: next1!.start, end: next1!.end) : "--:--",
            nextShow2Title: next2?.title ?? followingProgramTitle,
            nextShow2Time: next2 != nil ? formatTimeRange(start: next2!.start, end: next2!.end) : "--:--"
        )
    }

    private func moveCategory(_ groupID: String, by offset: Int) {
        guard let selectedID else { return }
        IPTVCategoryPreferencesStore.move(
            groupID: groupID,
            by: offset,
            among: preparedLineup.baseCategoryGroups,
            visibleGroupIDs: cachedCategoryChooserGroups,
            defaults: ProfileSettings.store(for: profileID),
            sourceID: selectedID
        )
        loadCategoryPreferences(for: selectedID)
    }

    private func setCategoryHidden(_ hidden: Bool, groupID: String) {
        guard let selectedID else { return }
        IPTVCategoryPreferencesStore.setHidden(
            hidden,
            for: groupID,
            defaults: ProfileSettings.store(for: profileID),
            sourceID: selectedID
        )
        if hidden && selectedCategory == groupID {
            selectedCategory = Self.allCategoriesID
        }
        loadCategoryPreferences(for: selectedID)
    }

    private func beginCategoryRename(_ groupID: String) {
        renamingCategoryID = groupID
        categoryNameDraft = categoryDisplayName(groupID)
        isCategoryNameEditing = true
    }

    private func commitCategoryRename() {
        guard let groupID = renamingCategoryID else {
            isCategoryNameEditing = false
            return
        }
        if !saveCategoryRename(for: groupID) {
            cancelCategoryRename(restoreFocus: true)
        }
    }

    @discardableResult
    private func saveCategoryRename(for groupID: String) -> Bool {
        guard let selectedID,
              IPTVCategoryPreferencesStore.rename(
                categoryNameDraft,
                for: groupID,
                defaults: ProfileSettings.store(for: profileID),
                sourceID: selectedID
              ) else { return false }
        loadCategoryPreferences(for: selectedID)
        cancelCategoryRename(restoreFocus: true)
        return true
    }

    private func cancelCategoryRename(restoreFocus: Bool = false) {
        let groupID = renamingCategoryID
        let sourceID = selectedID
        isCategoryNameEditing = false
        renamingCategoryID = nil
        categoryNameDraft = ""
        guard restoreFocus, let groupID else { return }
        Task { @MainActor in
            await Task.yield()
            guard isChoosingCategory,
                  selectedID == sourceID,
                  cachedCategoryChooserGroups.contains(groupID) else { return }
            categoryFocusRequest = IPTVCategoryFocusRequest(groupID: groupID)
        }
    }

    private var emptySectionMessage: String {
        switch activeSidebarItem {
        case .search:
            return channelSearchQuery.isEmpty
                ? L10n.string("iptv_search_empty_prompt", fallback: "Enter channel or program")
                : L10n.string("iptv_no_matches", fallback: "No matching channels.")
        case .sportsNow: return L10n.string("iptv_empty_sports_now", fallback: "No sports programs on now")
        case .favorites: return L10n.string("iptv_empty_favorites", fallback: "No favorite channels")
        case .recent: return L10n.string("iptv_empty_recent", fallback: "No recently watched channels")
        case .categories where selectedCategory == Self.allCategoriesID: return L10n.string("iptv_choose_category", fallback: "Choose a category")
        default:
            return sources.isEmpty
                ? L10n.string("iptv_no_sources_added", fallback: "No IPTV sources added")
                : L10n.string("iptv_empty_category", fallback: "No channels in this category")
        }
    }

    private var channelSearchQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Playback Execution
    private var activeSourceRecord: IPTVSource? {
        sources.first(where: { $0.id == selectedID }) ?? successfullyLoadedSource
    }

    private func selectChannelForPreview(_ channel: IPTVBaseChannel, openFullscreenIfAlreadyPreviewing: Bool = true) {
        if openFullscreenIfAlreadyPreviewing,
           selectedChannelID == channel.id,
           inlinePreviewChannelID == channel.id,
           channel.streamURL != nil {
            playChannel(channel)
            return
        }
        selectedChannelID = channel.id
        inlinePreviewChannelID = channel.streamURL == nil ? nil : channel.id
        if inlinePreviewIsReady,
           let player = inlinePreviewPlayer,
           inlinePreviewItemMatches(for: channel, player: player),
           player.rate == 0 {
            player.play()
        }
    }

    private func playChannel(_ channel: IPTVBaseChannel) {
        let programmes = channel.guideID.flatMap { guideByChannel[$0] } ?? []
        if presentInlinePreviewFullscreen(for: channel, programmes: programmes) { return }
        inlinePreviewChannelID = nil
        stopInlinePreview()
        stalkerPlayTask?.cancel()
        stalkerPlayTask = nil
        if let streamURL = channel.streamURL, streamURL.scheme != "stalker" {
            selectedChannelID = channel.id
            recordRecent(channelID: channel.id)
            play(url: streamURL, id: channel.id, name: channel.name, logo: channel.logoURL?.absoluteString, programmes: programmes)
            return
        }
        guard let stalker = stalkerChannels.first(where: { $0.id == channel.id }),
              let client = stalkerClient else { return }
        let targetChannelID = channel.id
        selectedChannelID = targetChannelID
        stalkerPlayTask = Task { @MainActor in
            defer {
                if selectedChannelID == targetChannelID {
                    stalkerPlayTask = nil
                }
            }
            do {
                let playback = try await client.resolve(stalker)
                guard !Task.isCancelled, isActive, selectedChannelID == targetChannelID else { return }
                recordRecent(channelID: targetChannelID)
                play(url: playback.url, id: targetChannelID, name: channel.name, logo: stalker.logo, headers: playback.headers, programmes: programmes)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, isActive, selectedChannelID == targetChannelID else { return }
                errorMessage = L10n.string("iptv_play_error", fallback: "Could not open this channel. Try loading the source again.")
            }
        }
    }

    private func eligibleInlinePreviewRequest(for channel: IPTVBaseChannel) -> IPTVInlinePreviewRequestKey? {
        guard isActive, !loading, inlinePreviewChannelID == channel.id,
              selectedChannelID == channel.id, scenePhase == .active, !showingCredentialsModal,
              let url = channel.streamURL,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" || scheme == "stalker" else { return nil }
        return IPTVInlinePreviewRequestKey(channelID: channel.id, streamURL: url, sourceID: selectedID)
    }

    private func updateInlinePreview(for request: IPTVInlinePreviewRequestKey?) {
        guard let request else {
            stopInlinePreview()
            return
        }
        if inlinePreviewTarget?.channelID == request.channelID,
           (inlinePreviewPlayer != nil || inlineAetherPreviewController?.activeChannelID == request.channelID) {
            return
        }
        if stalkerPreviewTask != nil, inlinePreviewChannelID == request.channelID,
           request.streamURL.scheme?.lowercased() == "stalker" {
            return
        }

        stopInlinePreview()
        let scheme = request.streamURL.scheme?.lowercased()
        if scheme == "http" || scheme == "https" {
            let source = activeSourceRecord
            let backend = IPTVInlinePreviewPolicy.backend(
                for: request.streamURL,
                sourceKind: source?.kind,
                xtreamOutput: source?.xtreamOutput
            )
            startInlinePreview(
                channelID: request.channelID,
                url: request.streamURL,
                headers: [:],
                backend: backend
            )
            return
        }

        guard scheme == "stalker",
              let stalker = stalkerChannels.first(where: { $0.id == request.channelID }),
              let client = stalkerClient else { return }

        let targetChannelID = request.channelID
        stalkerPreviewTask = Task { @MainActor in
            defer {
                if inlinePreviewChannelID == targetChannelID {
                    stalkerPreviewTask = nil
                }
            }
            do {
                let playback = try await client.resolve(stalker)
                guard !Task.isCancelled,
                      isActive,
                      !loading,
                      scenePhase == .active,
                      !showingCredentialsModal,
                      selectedChannelID == targetChannelID,
                      inlinePreviewChannelID == targetChannelID else { return }
                let backend = IPTVInlinePreviewPolicy.backend(
                    for: playback.url,
                    sourceKind: .stalker,
                    xtreamOutput: nil
                )
                startInlinePreview(
                    channelID: targetChannelID,
                    url: playback.url,
                    headers: playback.headers,
                    backend: backend
                )
            } catch {
                return
            }
        }
    }

    private func startInlinePreview(
        channelID: String,
        url: URL,
        headers: [String: String],
        backend: IPTVInlinePreviewBackend
    ) {
        inlinePreviewFailureObserver?.invalidate()
        inlinePreviewFailureObserver = nil
        inlinePreviewPlayer?.pause()
        inlinePreviewPlayer?.replaceCurrentItem(with: nil)
        inlinePreviewPlayer = nil
        inlinePreviewIsReady = false
        inlineAetherPreviewController?.stop()
        inlineAetherPreviewIsReady = false

        inlinePreviewTarget = IPTVInlinePreviewTarget(
            channelID: channelID,
            url: url,
            headers: headers,
            backend: backend
        )
        inlinePreviewStartedAt = Date()

        switch backend {
        case .avPlayer:
            let assetOptions: [String: Any]? = headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": headers]
            let asset = AVURLAsset(url: url, options: assetOptions)
            let item = AVPlayerItem(asset: asset)
            let player = AVPlayer(playerItem: item)
            PlaybackAudioSession.activateMoviePlayback()
            player.isMuted = false
            inlinePreviewPlayer = player
            inlinePreviewFailureObserver = item.observe(\.status, options: [.new]) { observedItem, _ in
                guard observedItem.status == .failed else { return }
                Task { @MainActor in
                    guard inlinePreviewPlayer === player,
                          inlinePreviewChannelID == channelID,
                          selectedChannelID == channelID,
                          isActive,
                          scenePhase == .active,
                          !showingCredentialsModal else { return }
                    startInlinePreview(
                        channelID: channelID,
                        url: url,
                        headers: headers,
                        backend: .aether
                    )
                }
            }
            player.play()

        case .aether:
            let controller = inlineAetherPreviewController ?? IPTVInlineAetherPreviewController()
            guard let controller else { return }
            inlineAetherPreviewController = controller
            controller.load(url: url, headers: headers, channelID: channelID) {
                guard inlinePreviewChannelID == channelID,
                      selectedChannelID == channelID,
                      inlineAetherPreviewController === controller else { return }
                inlineAetherPreviewIsReady = true
                recordRecent(channelID: channelID)
            }
        }
    }

    private func inlinePreviewItemMatches(for channel: IPTVBaseChannel, player: AVPlayer) -> Bool {
        guard inlinePreviewPlayer === player,
              inlinePreviewChannelID == channel.id,
              selectedChannelID == channel.id,
              eligibleInlinePreviewRequest(for: channel) != nil,
              let expectedURL = inlinePreviewTarget?.channelID == channel.id ? inlinePreviewTarget?.url : channel.streamURL,
              let item = player.currentItem,
              item.status == .readyToPlay,
              item.error == nil,
              let asset = item.asset as? AVURLAsset,
              asset.url == expectedURL else { return false }
        return true
    }

    private func markInlinePreviewReady(for player: AVPlayer, channelID: String) {
        guard !inlinePreviewIsReady,
              inlinePreviewPlayer === player,
              selectedChannelID == channelID,
              inlinePreviewChannelID == channelID else { return }
        inlinePreviewIsReady = true
        recordRecent(channelID: channelID)
    }

    private func presentInlinePreviewFullscreen(for channel: IPTVBaseChannel, programmes: [IPTVProgramme]) -> Bool {
        guard inlinePreviewIsReady,
              let player = inlinePreviewPlayer,
              inlinePreviewItemMatches(for: channel, player: player) else { return false }

        // Retain the exact player and current item while its AVPlayerLayer
        // temporarily moves to fullscreen with zero reconnect or loading screen.
        fullscreenReturnChannelID = channel.id
        isFullscreenPreviewTransitionActive = true
        fullscreenPreview = IPTVFullscreenPreview(
            player: player,
            channelTitle: channel.name,
            programmes: programmes,
            startedAt: inlinePreviewStartedAt ?? Date()
        )
        return true
    }

    private func requestFullscreenPreviewDismissal() {
        fullscreenPreview = nil
    }

    private func fullscreenPreviewDidDismiss() {
        let returnChannelID = fullscreenReturnChannelID
        fullscreenReturnChannelID = nil
        isFullscreenPreviewTransitionActive = false

        guard isActive, scenePhase == .active,
              let returnChannelID,
              selectedChannelID == returnChannelID,
              let player = inlinePreviewPlayer,
              inlinePreviewChannelID == returnChannelID,
              inlinePreviewIsReady,
              let channel = preparedLineup.baseChannelsByID[returnChannelID],
              inlinePreviewItemMatches(for: channel, player: player) else { return }

        Task { @MainActor in
            await Task.yield()
            guard isActive, scenePhase == .active, selectedChannelID == returnChannelID else { return }
            previewFocusRequestID = UUID()
        }
    }

    private func discardInlinePreviewForExternalExit() {
        fullscreenPreview = nil
        inlinePreviewChannelID = nil
        stopInlinePreview(releaseAetherEngine: true)
    }

    private func stopInlinePreview(releaseAetherEngine: Bool = false) {
        stalkerPreviewTask?.cancel()
        stalkerPreviewTask = nil
        inlinePreviewFailureObserver?.invalidate()
        inlinePreviewFailureObserver = nil
        inlinePreviewTarget = nil
        inlinePreviewPlayer?.pause()
        inlinePreviewPlayer?.replaceCurrentItem(with: nil)
        inlinePreviewPlayer = nil
        inlinePreviewIsReady = false
        inlineAetherPreviewController?.stop()
        if releaseAetherEngine {
            inlineAetherPreviewController = nil
        }
        inlineAetherPreviewIsReady = false
        inlinePreviewStartedAt = nil
    }

    private func play(
        url: URL,
        id: String,
        name: String,
        logo: String?,
        headers: [String: String] = [:],
        programmes: [IPTVProgramme] = []
    ) {
        onPlay(url, NuvioMeta(
            id: "iptv:\(id)", name: name, description: nil, posterUrl: logo, backgroundUrl: nil, logoUrl: nil,
            imdbId: nil, tmdbId: nil, type: "channel", year: nil, genres: nil,
            rating: nil, releaseInfo: nil, runtime: nil, cast: nil, director: nil,
            writer: nil, certification: nil, country: nil, released: nil
        ), headers, programmes)
    }

    // MARK: - Favorites & Recents
    private func isFavorite(channelID: String) -> Bool {
        if let key = favoriteKeys[channelID] {
            return favorites.contains(key)
        }
        return favorites.contains(channelID)
    }

    private func toggleFavorite(channelID: String) {
        let key = favoriteKeys[channelID] ?? channelID
        if favorites.contains(key) {
            favorites.remove(key)
            favoriteOrder.removeAll { $0 == key }
        } else {
            favorites.insert(key)
            if !favoriteOrder.contains(key) { favoriteOrder.append(key) }
        }
        let store = IPTVFavoritesStore(defaults: ProfileSettings.store(for: profileID))
        store.save(favorites)
        store.saveOrder(favoriteOrder)
        if activeSidebarItem == .favorites {
            recomputeVisibleChannels()
        }
    }

    private func visibleFavoriteKeys() -> [String] {
        cachedVisibleChannels.map { favoriteKeys[$0.id] ?? $0.id }
    }

    private func moveFavorite(channelID: String, direction: Int) {
        let key = favoriteKeys[channelID] ?? channelID
        let visible = visibleFavoriteKeys()
        guard let index = visible.firstIndex(of: key), visible.indices.contains(index + direction) else { return }
        let visibleSet = Set(visible)
        let slots = favoriteOrder.indices.filter { visibleSet.contains(favoriteOrder[$0]) }
        guard slots.count == visible.count else { return }
        var reorderedVisible = slots.map { favoriteOrder[$0] }
        reorderedVisible.swapAt(index, index + direction)
        for (slot, reorderedKey) in zip(slots, reorderedVisible) { favoriteOrder[slot] = reorderedKey }
        IPTVFavoritesStore(defaults: ProfileSettings.store(for: profileID)).saveOrder(favoriteOrder)
        if activeSidebarItem == .favorites {
            recomputeVisibleChannels()
        }
    }

    private func recordRecent(channelID: String) {
        guard let key = favoriteKeys[channelID], recentChannelKeys.first != key else { return }
        let recent = IPTVRecentChannelStore(defaults: ProfileSettings.store(for: profileID))
        recent.save(key)
        recentChannelKeys = recent.loadAll()
        if activeSidebarItem == .recent {
            recomputeVisibleChannels()
        }
    }

    // MARK: - Guide & EPG Calculation Helpers
    private func formatTimeRange(start: Date, end: Date) -> String {
        "\(guideTimeFormatter.string(from: start)) – \(guideTimeFormatter.string(from: end))"
    }

    private func calculateProgress(start: Date, end: Date) -> CGFloat {
        let total = end.timeIntervalSince(start)
        guard total > 0 else { return 0 }
        let elapsed = guideNow.timeIntervalSince(start)
        return CGFloat(min(max(elapsed / total, 0.0), 1.0))
    }

    // MARK: - Source Management & Lifecycle
    private func restoreSources() {
        guard isActive, scenePhase == .active else { return }
        do {
            sources = try store.load(profileID: profileID)
            sourcesLoaded = true
            favorites = IPTVFavoritesStore(defaults: ProfileSettings.store(for: profileID)).load()
            favoriteOrder = IPTVFavoritesStore(defaults: ProfileSettings.store(for: profileID)).loadOrder()
            let recent = IPTVRecentChannelStore(defaults: ProfileSettings.store(for: profileID))
            recentChannelKeys = recent.loadAll()

            let now = Date()
            let cached = loadedCache.validEntry(profileID: profileID, sources: sources, now: now)
            let savedSourceID = IPTVSelectedSourceStore.load(defaults: ProfileSettings.store(for: profileID))
            if loadingSource != nil, loadTask != nil { return }
            if let source = sources.first(where: { $0.id == selectedID })
                ?? cached?.source
                ?? sources.first(where: { $0.id == savedSourceID })
                ?? sources.first {
                selectedID = source.id
                IPTVSelectedSourceStore.save(source.id, defaults: ProfileSettings.store(for: profileID))
                if successfullyLoadedSource == source,
                   let successfullyLoadedAt,
                   now.timeIntervalSince(successfullyLoadedAt) < LoadedCache.lineupLifetime {
                    if loadedCache.entry == nil { storeLoadedCache() }
                    recomputeCategories()
                    recomputeVisibleChannels()
                    refreshGuideIfDue(now: now)
                } else if let cached, cached.source == source {
                    channels = cached.channels
                    stalkerChannels = cached.stalkerChannels
                    stalkerClient = cached.stalkerClient
                    preparedLineup = cached.preparedLineup
                    selectedGuideURLs = cached.guideURLs
                    selectedGuideNeedsSameOrigin = cached.sameOrigin
                    favoriteKeys = cached.favoriteKeys
                    guideByChannel = cached.guideByChannel
                    guideRevision &+= 1
                    guideNextRefresh = cached.guideNextRefresh
                    guideFailures = cached.guideFailures
                    guideUnavailable = cached.guideUnavailable
                    successfullyLoadedSource = source
                    successfullyLoadedAt = cached.loadedAt
                    if selectedChannelID.flatMap({ preparedLineup.baseChannelsByID[$0] }) == nil {
                        selectedChannelID = preparedLineup.baseChannels.first?.id
                    }
                    guideNow = now
                    loadCategoryPreferences(for: source.id)
#if NUVIO_SIDEBAR_WATCHDOG
                    Self.sidebarLogger.notice("playlist cache restored channels=\(cached.channels.count) stalkerChannels=\(cached.stalkerChannels.count) feeds=\(cached.guideURLs.count)")
#endif
                    refreshGuideIfDue(now: Date())
                } else {
                    loadedCache.clear()
                    clearLoadedContent()
                    load(source)
                }
            } else {
                resetLoadedStateForEmptySources()
            }
        } catch {
            sourcesLoaded = false
            resetLoadedStateForEmptySources()
        }
    }

    private func resetLoadedStateForEmptySources() {
        cancelSourceAndGuideWork()
        loadedCache.clear()
        clearLoadedContent()
        inlinePreviewChannelID = nil
        stopInlinePreview(releaseAetherEngine: true)
        selectedID = nil
        IPTVSelectedSourceStore.save(nil, defaults: ProfileSettings.store(for: profileID))
        selectedChannelID = nil
        loadCategoryPreferences(for: nil)
    }

    private func clearLoadedContent() {
        stalkerPlayTask?.cancel()
        stalkerPlayTask = nil
        successfullyLoadedSource = nil
        successfullyLoadedAt = nil
        channels = []
        stalkerChannels = []
        stalkerClient = nil
        preparedLineup = .empty
        favoriteKeys = [:]
        guideByChannel = [:]
        guideRevision &+= 1
        guideUnavailable = false
        guideNextRefresh = nil
        guideFailures = 0
        selectedGuideURLs = []
        selectedGuideNeedsSameOrigin = false
        selectedGuideProgramme = nil
        selectedGuideChannelID = nil
        selectedChannelID = nil
        recomputeCategories()
        recomputeVisibleChannels()
    }

    private func storeLoadedCache() {
        guard let source = successfullyLoadedSource, let loadedAt = successfullyLoadedAt else { return }
        loadedCache.store(.init(
            profileID: profileID,
            source: source,
            loadedAt: loadedAt,
            channels: channels,
            stalkerChannels: stalkerChannels,
            stalkerClient: stalkerClient,
            preparedLineup: preparedLineup,
            guideURLs: selectedGuideURLs,
            sameOrigin: selectedGuideNeedsSameOrigin,
            favoriteKeys: favoriteKeys,
            guideByChannel: guideByChannel,
            guideNextRefresh: guideNextRefresh,
            guideFailures: guideFailures,
            guideUnavailable: guideUnavailable
        ))
    }

    private func storeGuideCache() {
        guard let source = successfullyLoadedSource else { return }
        loadedCache.updateGuide(
            profileID: profileID,
            source: source,
            guideByChannel: guideByChannel,
            nextRefresh: guideNextRefresh,
            failures: guideFailures,
            unavailable: guideUnavailable
        )
    }

    private func cancelSourceAndGuideWork() {
        requestID = UUID()
        loadTask?.cancel()
        loadTask = nil
        stalkerPlayTask?.cancel()
        stalkerPlayTask = nil
        loadingSource = nil
        loading = false
        if guideTask != nil { guideNextRefresh = nil }
        guideTask?.cancel()
        guideTask = nil
        guideRequestID = nil
    }

    private func addSource() {
        let name = sourceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawURL = sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: rawURL) else {
            errorMessage = L10n.string("iptv_invalid_url", fallback: "Enter a valid playlist URL.")
            return
        }
        let source = IPTVSource(
            id: editingID ?? UUID(),
            name: name,
            playlistURL: rawURL,
            kind: sourceKind,
            username: sourceKind == .xtream ? username : nil,
            password: sourceKind == .xtream ? password : nil,
            mac: sourceKind == .stalker ? mac : nil,
            xtreamOutput: sourceKind == .xtream ? xtreamOutput : .mpegTS
        )
        beginLoad(source: source, url: url, saveAfterLoading: true)
    }

    private func load(_ source: IPTVSource) {
        guard let url = URL(string: source.playlistURL) else { return }
        beginLoad(source: source, url: url, saveAfterLoading: false)
    }

    private func beginLoad(source: IPTVSource, url: URL, saveAfterLoading: Bool) {
        loadTask?.cancel()
        if loadedCache.entry?.source != source { loadedCache.clear() }
        let token = UUID()
        requestID = token
        loadingSource = source
        // Captured before loading: if the profile is deleted meanwhile, the save below does nothing.
        let sourcesGeneration = IPTVSourceStore.generation(for: profileID)
        let startedAt = ProcessInfo.processInfo.systemUptime
        let liveBadge = L10n.string("iptv_live_badge", fallback: "Live")
        let miscCategory = L10n.string("iptv_category_misc", fallback: "Other")
        loading = true
        errorMessage = nil
#if NUVIO_SIDEBAR_WATCHDOG
        Self.sidebarLogger.notice("playlist load started kind=\(source.kind.rawValue, privacy: .public)")
#endif
        loadTask = Task { @MainActor in
            do {
                var loaded: [IPTVChannel] = []
                var loadedStalkerChannels: [IPTVStalkerChannel]?
                var loadedStalkerClient: IPTVStalkerClient?
                var guideURLs: [URL] = []
                var guideNeedsSameOrigin = false

                switch source.kind {
                case .m3u:
                    let playlist = try await loader.loadPlaylist(url: url, sourceID: source.id.uuidString)
                    loaded = playlist.channels
                    guideURLs = playlist.guideURLs
                case .xtream:
                    guard let u = source.username, let p = source.password else { throw IPTVSourceStoreError.invalidSource }
                    let credentials = IPTVXtreamCredentials(server: url, username: u, password: p, output: source.xtreamOutput)
                    loaded = try await xtream.loadChannels(credentials: credentials, sourceID: source.id.uuidString)
                    if let guideURL = IPTVXtreamClient.guideURL(credentials: credentials) {
                        guideURLs = [guideURL]
                    }
                    guideNeedsSameOrigin = true
                case .stalker:
                    guard let m = source.mac else { throw IPTVSourceStoreError.invalidSource }
                    let client = try IPTVStalkerClient(portal: url, mac: m)
                    let portalChannels = try await client.loadChannels()
                    loadedStalkerChannels = portalChannels
                    loadedStalkerClient = client
                }

                guard !Task.isCancelled, requestID == token else { return }

                // Precompute base channels, lookup table, URL parsing, sorted categories, and favorite keys off main thread.
                let capturedLoaded = loaded
                let capturedStalker = loadedStalkerChannels ?? []
                let capturedSourceID = source.id
                let lineup = await Task.detached(priority: .userInitiated) {
                    IPTVPreparedLineup.build(
                        channels: capturedLoaded,
                        stalkerChannels: capturedStalker,
                        sourceID: capturedSourceID,
                        liveBadge: liveBadge,
                        miscCategory: miscCategory
                    )
                }.value

                guard !Task.isCancelled, requestID == token else { return }
                if saveAfterLoading {
                    var updated = sources
                    if let index = updated.firstIndex(where: { $0.id == source.id }) {
                        updated[index] = source
                    } else {
                        updated.append(source)
                    }
                    guard try store.save(updated, profileID: profileID, ifGeneration: sourcesGeneration) else {
                        loading = false
                        loadTask = nil
                        loadingSource = nil
                        return
                    }
                    sources = updated
                }
                channels = loaded
                if let loadedStalkerChannels {
                    stalkerChannels = loadedStalkerChannels
                    stalkerClient = loadedStalkerClient
                } else {
                    stalkerChannels = []
                    stalkerClient = nil
                }
                preparedLineup = lineup
                successfullyLoadedSource = source
                successfullyLoadedAt = Date()
                inlinePreviewChannelID = nil
                stopInlinePreview()
                selectedChannelID = lineup.baseChannels.first?.id
                guideTask?.cancel()
                guideTask = nil
                guideRequestID = nil
                guideByChannel = [:]
                guideRevision &+= 1
                guideUnavailable = false
                guideNextRefresh = nil
                guideFailures = 0
                selectedGuideURLs = guideURLs
                selectedGuideNeedsSameOrigin = guideNeedsSameOrigin
                selectedGuideProgramme = nil
                selectedGuideChannelID = nil
                selectedID = source.id
                IPTVSelectedSourceStore.save(source.id, defaults: ProfileSettings.store(for: profileID))
                favoriteKeys = lineup.favoriteKeys
                let favoriteStore = IPTVFavoritesStore(defaults: ProfileSettings.store(for: profileID))
                favoriteOrder = favoriteStore.reconciledOrder(favoriteOrder, playlistOrder: lineup.orderedFavoriteKeys, favorites: favorites)
                favoriteStore.saveOrder(favoriteOrder)
                searchText = ""
                loadCategoryPreferences(for: source.id)
                storeLoadedCache()
#if NUVIO_SIDEBAR_WATCHDOG
                Self.sidebarLogger.notice("playlist load finished kind=\(source.kind.rawValue, privacy: .public) channels=\(loaded.count) stalkerChannels=\(stalkerChannels.count) durationMs=\(Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000))")
#endif
                if !guideURLs.isEmpty {
                    loadGuide(urls: guideURLs, for: source.id, channels: loaded, sameOrigin: guideNeedsSameOrigin)
                }
            } catch {
                guard !Task.isCancelled, requestID == token else { return }
                let failure = IPTVFailureKind.classify(error)
                errorMessage = L10n.string(failure.localizationKey, fallback: failure.fallbackMessage)
#if NUVIO_SIDEBAR_WATCHDOG
                Self.sidebarLogger.warning("playlist load failed kind=\(source.kind.rawValue, privacy: .public) durationMs=\(Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000))")
#endif
            }
            if requestID == token {
                loading = false
                loadTask = nil
                loadingSource = nil
            }
        }
    }

    private func remove(_ source: IPTVSource) {
        let updated = sources.filter { $0.id != source.id }
        do {
            try store.save(updated, profileID: profileID)
            sources = updated
            if successfullyLoadedSource?.id == source.id {
                successfullyLoadedSource = nil
                successfullyLoadedAt = nil
            }
            let settings = ProfileSettings.store(for: profileID)
            IPTVCategoryPreferencesStore.remove(sourceID: source.id, defaults: settings)
            favorites = IPTVFavoritesStore.removingSource(source.id, from: favorites)
            let favoriteStore = IPTVFavoritesStore(defaults: settings)
            favoriteStore.save(favorites)
            favoriteOrder = favoriteOrder.filter { favorites.contains($0) }
            favoriteStore.saveOrder(favoriteOrder)
            let recent = IPTVRecentChannelStore(defaults: settings)
            recent.removeIfOwned(by: source.id)
            recentChannelKeys = recent.loadAll()
            if selectedID == source.id {
                resetLoadedStateForEmptySources()
                if let nextSource = updated.first {
                    selectedID = nextSource.id
                    IPTVSelectedSourceStore.save(nextSource.id, defaults: ProfileSettings.store(for: profileID))
                    loadCategoryPreferences(for: nextSource.id)
                    load(nextSource)
                }
            }
        } catch {
            errorMessage = L10n.string("iptv_delete_error", fallback: "Could not delete this source.")
        }
    }

    private func selectSource(_ source: IPTVSource) {
        showingCredentialsModal = false
        resetSourceEditor()
        if selectedID == source.id,
           successfullyLoadedSource == source,
           !loading {
            return
        }
        cancelSourceAndGuideWork()
        loadedCache.clear()
        clearLoadedContent()
        inlinePreviewChannelID = nil
        stopInlinePreview(releaseAetherEngine: true)
        selectedID = source.id
        IPTVSelectedSourceStore.save(source.id, defaults: ProfileSettings.store(for: profileID))
        loadCategoryPreferences(for: source.id)
        load(source)
    }

    private func resetSourceEditor() {
        editingID = nil
        sourceName = ""
        sourceURL = ""
        sourceKind = .xtream
        username = ""
        password = ""
        mac = ""
        xtreamOutput = .mpegTS
    }

    private func edit(_ source: IPTVSource) {
        editingID = source.id
        sourceName = source.name
        sourceURL = source.playlistURL
        sourceKind = source.kind
        username = source.username ?? ""
        password = source.password ?? ""
        mac = source.mac ?? ""
        xtreamOutput = source.xtreamOutput
        showingCredentialsModal = true
    }

    /// Fetches the guide when IPTVGuideRefreshPolicy.shouldLoad says so.
    private func refreshGuideIfDue(now: Date) {
        guard isActive, scenePhase == .active, !loading,
              let sourceID = selectedID, !selectedGuideURLs.isEmpty,
              successfullyLoadedSource?.id == sourceID,
              preparedLineup.hasGuideIDs,
              IPTVGuideRefreshPolicy.shouldLoad(isLoading: guideTask != nil, nextRefresh: guideNextRefresh, now: now)
        else { return }
        loadGuide(urls: selectedGuideURLs, for: sourceID, channels: channels, sameOrigin: selectedGuideNeedsSameOrigin)
    }

    private func retryGuide() {
        guideNextRefresh = nil
        refreshGuideIfDue(now: Date())
    }

    /// Loads every advertised feed. Incremental results apply only to the
    /// active source/profile; previous useful programmes survive partial errors.
    private func loadGuide(urls: [URL], for sourceID: UUID, channels: [IPTVChannel], sameOrigin: Bool) {
        let ids = Set(channels.compactMap(\.guideID))
        guard !urls.isEmpty, !ids.isEmpty else { return }
        let now = Date()
        let window = IPTVGuideRefreshPolicy.window(around: now)
        let previousGuideByChannel = guideByChannel
        let token = UUID()
        let startedAt = ProcessInfo.processInfo.systemUptime
#if NUVIO_SIDEBAR_WATCHDOG
        let cachedGuidePresent = !guideByChannel.isEmpty
        let watchdogToken = String(token.uuidString.prefix(8)).lowercased()
        let guideWatchdog = GuideLoadWatchdog(
            startedAt: startedAt,
            token: watchdogToken,
            cachedGuidePresent: cachedGuidePresent,
            logger: Self.sidebarLogger
        )
#endif
        guideRequestID = token
        guideTask?.cancel()
#if NUVIO_SIDEBAR_WATCHDOG
        let kind = successfullyLoadedSource?.kind.rawValue ?? "unknown"
        Self.sidebarLogger.notice("guide load started kind=\(kind, privacy: .public) channels=\(ids.count) feeds=\(urls.count) cachedGuide=\(cachedGuidePresent, privacy: .public)")
#endif
        guideTask = Task { @MainActor in
#if NUVIO_SIDEBAR_WATCHDOG
            var watchdogStatus = "stale"
            defer { guideWatchdog.finish(status: Task.isCancelled ? "cancelled" : watchdogStatus) }
#endif
            @MainActor func stillCurrent() -> Bool {
                !Task.isCancelled && guideRequestID == token && selectedID == sourceID
                    && ProfileSettings.activeProfileID == profileID
            }
            do {
                let reader = sameOrigin ? IPTVGuideLoader(session: IPTVAuthenticatedSession.shared) : guideLoader
                let batch = try await reader.load(urls: urls, channelIDs: ids, window: window) { programmes in
                    guard stillCurrent() else { return }
                    let merged = await mergedGuide(programmes, retaining: previousGuideByChannel, at: Date())
                    guard stillCurrent() else { return }
                    guideByChannel = merged
                    guideRevision &+= 1
                    if activeSidebarItem == .sportsNow || activeSidebarItem == .search {
                        recomputeVisibleChannels()
                    }
#if NUVIO_SIDEBAR_WATCHDOG
                    guideWatchdog.recordFirstListingsIfNeeded(programmeCount: merged.isEmpty ? 0 : programmes.count)
#endif
                    if !guideByChannel.isEmpty { guideUnavailable = false }
                    storeGuideCache()
                }
                guard stillCurrent() else { return }
                let finishedAt = Date()
                guideNow = finishedAt
                if batch.failedFeedCount == 0 {
                    let grouped = await groupedGuide(batch.programmes)
                    guard stillCurrent() else { return }
                    guideByChannel = grouped
                    guideRevision &+= 1
#if NUVIO_SIDEBAR_WATCHDOG
                    guideWatchdog.recordFirstListingsIfNeeded(programmeCount: batch.programmes.count)
#endif
                    guideFailures = 0
                    guideNextRefresh = IPTVGuideRefreshPolicy.nextRefresh(after: batch.programmes, loadedAt: now)
                    guideUnavailable = false
                } else {
                    let merged = await mergedGuide(batch.programmes, retaining: previousGuideByChannel, at: finishedAt)
                    guard stillCurrent() else { return }
                    guideByChannel = merged
                    guideRevision &+= 1
#if NUVIO_SIDEBAR_WATCHDOG
                    guideWatchdog.recordFirstListingsIfNeeded(programmeCount: merged.isEmpty ? 0 : batch.programmes.count)
#endif
                    guideFailures += 1
                    let retry = IPTVGuideRefreshPolicy.retry(afterFailures: guideFailures, at: finishedAt)
                    guideNextRefresh = max(retry, finishedAt.addingTimeInterval(IPTVGuideRefreshPolicy.minInterval))
                    guideUnavailable = guideByChannel.isEmpty
                }
                if activeSidebarItem == .sportsNow || activeSidebarItem == .search {
                    recomputeVisibleChannels()
                }
                storeGuideCache()
#if NUVIO_SIDEBAR_WATCHDOG
                watchdogStatus = batch.programmes.isEmpty ? "empty" : "success"
                Self.sidebarLogger.notice("guide load finished kind=\(kind, privacy: .public) channels=\(ids.count) feeds=\(urls.count) programmes=\(batch.programmes.count) failedFeeds=\(batch.failedFeedCount) durationMs=\(Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000))")
#endif
            } catch {
                guard stillCurrent() else { return }
                guideFailures += 1
                let failedAt = Date()
                let retry = IPTVGuideRefreshPolicy.retry(afterFailures: guideFailures, at: failedAt)
                if urls.count > 1 {
                    let refresh = IPTVGuideRefreshPolicy.nextRefresh(after: [], loadedAt: failedAt)
                    guideNextRefresh = max(refresh, retry)
                } else {
                    guideNextRefresh = retry
                }
                // Programmes still on air keep showing; only say unavailable with nothing to show.
                guideUnavailable = guideByChannel.isEmpty
                storeGuideCache()
#if NUVIO_SIDEBAR_WATCHDOG
                watchdogStatus = "error"
                Self.sidebarLogger.warning("guide load failed kind=\(kind, privacy: .public) channels=\(ids.count) feeds=\(urls.count) durationMs=\(Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000))")
#endif
            }
            guideTask = nil
        }
    }

    private func mergedGuide(
        _ programmes: [IPTVProgramme],
        retaining previous: [String: [IPTVProgramme]],
        at now: Date
    ) async -> [String: [IPTVProgramme]] {
        await Task.detached(priority: .utility) {
            let lowerBound = now.addingTimeInterval(-IPTVGuideRefreshPolicy.lookBehind)
            let upperBound = now.addingTimeInterval(IPTVGuideRefreshPolicy.lookAhead)
            if previous.isEmpty {
                return Dictionary(grouping: programmes.filter {
                    $0.end > lowerBound && $0.start < upperBound
                }, by: \.channelID)
            }
            var byChannel: [String: [Date: IPTVProgramme]] = [:]
            for (channelID, schedules) in previous {
                for programme in schedules where programme.end > lowerBound && programme.start < upperBound {
                    byChannel[channelID, default: [:]][programme.start] = programme
                }
            }
            for programme in programmes where programme.end > lowerBound && programme.start < upperBound {
                byChannel[programme.channelID, default: [:]][programme.start] = programme
            }
            return byChannel.mapValues { $0.values.sorted { $0.start < $1.start } }
        }
        .value
    }

    private func groupedGuide(_ programmes: [IPTVProgramme]) async -> [String: [IPTVProgramme]] {
        await Task.detached(priority: .utility) {
            Dictionary(grouping: programmes, by: \.channelID)
        }.value
    }
}

// MARK: - Prepared Lineup & Display Models

struct IPTVBaseChannel: Identifiable, Equatable, Sendable {
    static let brandColors: [Color] = [
        Color(red: 0.15, green: 0.40, blue: 0.85),
        Color(red: 0.85, green: 0.20, blue: 0.35),
        Color(red: 0.10, green: 0.65, blue: 0.45),
        Color(red: 0.55, green: 0.25, blue: 0.85),
        Color(red: 0.90, green: 0.45, blue: 0.15),
        Color(red: 0.20, green: 0.60, blue: 0.85)
    ]

    let id: String
    let name: String
    let logoURL: URL?
    let group: String
    let category: String
    let guideID: String?
    let brandColorIndex: Int
    let logoText: String
    let streamURL: URL?

    var brandColor: Color {
        Self.brandColors[brandColorIndex]
    }

    static func colorIndex(for name: String) -> Int {
        Int(UInt(bitPattern: name.hashValue) % UInt(brandColors.count))
    }
}

struct IPTVIndexedChannel: Identifiable, Equatable {
    let number: Int
    let channel: IPTVBaseChannel
    var id: String { channel.id }
}

struct IPTVChannelEPGSnapshot: Equatable {
    let programTitle: String
    let programTime: String
    let programProgress: CGFloat?
    let nextShow1Title: String
    let nextShow1Time: String
    let nextShow2Title: String
    let nextShow2Time: String
}

struct IPTVPreparedLineup: Sendable {
    let baseChannels: [IPTVBaseChannel]
    let baseChannelsByID: [String: IPTVBaseChannel]
    let baseCategoryGroups: [String]
    let favoriteKeys: [String: String]
    let orderedFavoriteKeys: [String]
    let hasGuideIDs: Bool

    static let empty = IPTVPreparedLineup(
        baseChannels: [],
        baseChannelsByID: [:],
        baseCategoryGroups: [],
        favoriteKeys: [:],
        orderedFavoriteKeys: [],
        hasGuideIDs: false
    )

    static func build(
        channels: [IPTVChannel],
        stalkerChannels: [IPTVStalkerChannel],
        sourceID: UUID,
        liveBadge: String,
        miscCategory: String
    ) -> IPTVPreparedLineup {
        let totalCount = channels.count + stalkerChannels.count
        var baseChannels: [IPTVBaseChannel] = []
        baseChannels.reserveCapacity(totalCount)
        var baseChannelsByID: [String: IPTVBaseChannel] = [:]
        baseChannelsByID.reserveCapacity(totalCount)
        var groupSet = Set<String>()
        var hasGuideIDs = false

        for ch in channels {
            if ch.guideID != nil { hasGuideIDs = true }
            let group = ch.group ?? ""
            if !group.isEmpty, group != IPTVLiveView.allCategoriesID {
                groupSet.insert(group)
            }
            let item = IPTVBaseChannel(
                id: ch.id,
                name: ch.name,
                logoURL: ch.logoURL,
                group: group,
                category: ch.group ?? liveBadge,
                guideID: ch.guideID,
                brandColorIndex: IPTVBaseChannel.colorIndex(for: ch.name),
                logoText: String(ch.name.prefix(3)).uppercased(),
                streamURL: ch.streamURL
            )
            baseChannels.append(item)
            if baseChannelsByID[item.id] == nil {
                baseChannelsByID[item.id] = item
            }
        }

        for stk in stalkerChannels {
            let group = stk.categoryName ?? ""
            if !group.isEmpty, group != IPTVLiveView.allCategoriesID {
                groupSet.insert(group)
            }
            let logoURL: URL?
            if let rawLogo = stk.logo, !rawLogo.isEmpty,
               let parsed = URL(string: rawLogo),
               let scheme = parsed.scheme?.lowercased(),
               scheme == "http" || scheme == "https" {
                logoURL = parsed
            } else {
                logoURL = nil
            }
            let item = IPTVBaseChannel(
                id: stk.id,
                name: stk.name,
                logoURL: logoURL,
                group: group,
                category: stk.categoryName ?? miscCategory,
                guideID: nil,
                brandColorIndex: IPTVBaseChannel.colorIndex(for: stk.name),
                logoText: String(stk.name.prefix(3)).uppercased(),
                streamURL: URL(string: "stalker://channel/\(stk.id)")
            )
            baseChannels.append(item)
            if baseChannelsByID[item.id] == nil {
                baseChannelsByID[item.id] = item
            }
        }

        let sortedGroups = groupSet.sorted { $0.localizedStandardCompare($1) == .orderedAscending }

        var keys: [String: String] = [:]
        let orderedKeys: [String]
        if !channels.isEmpty {
            keys.reserveCapacity(channels.count)
            var list: [String] = []
            list.reserveCapacity(channels.count)
            for channel in channels {
                let key = IPTVFavoritesStore.key(sourceID: sourceID, channelID: channel.id)
                keys[channel.id] = key
                list.append(key)
            }
            orderedKeys = list
        } else {
            keys.reserveCapacity(stalkerChannels.count)
            var list: [String] = []
            list.reserveCapacity(stalkerChannels.count)
            for channel in stalkerChannels {
                let key = IPTVFavoritesStore.key(sourceID: sourceID, channelID: channel.id)
                keys[channel.id] = key
                list.append(key)
            }
            orderedKeys = list
        }

        return IPTVPreparedLineup(
            baseChannels: baseChannels,
            baseChannelsByID: baseChannelsByID,
            baseCategoryGroups: sortedGroups,
            favoriteKeys: keys,
            orderedFavoriteKeys: orderedKeys,
            hasGuideIDs: hasGuideIDs
        )
    }
}

@MainActor
private final class IPTVFavoriteFocusMemory {
    var lastFocusedID: String?
}

private struct IPTVCategoryFocusRequest: Equatable {
    let id = UUID()
    let groupID: String
}

// MARK: - Isolated Subviews

private struct IPTVSidebarView: View {
    let activeSidebarItem: IPTVLiveView.IPTVNavTab
    let loading: Bool
    let isActive: Bool
    let focusLiveTVRequestID: UUID
    let onSelect: (IPTVLiveView.IPTVNavTab) -> Void

    @FocusState private var focusedTab: IPTVLiveView.IPTVNavTab?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.string("nav_live_tv", fallback: "Live TV"))
                .font(.system(size: 38, weight: .bold))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .padding(.bottom, 22)
                .padding(.leading, 10)

            ForEach(IPTVLiveView.IPTVNavTab.allCases, id: \.self) { tab in
                Button {
                    onSelect(tab)
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 23, weight: .semibold))
                            .frame(width: 24)
                        Text(tab.title)
                            .font(.system(size: 22, weight: activeSidebarItem == tab ? .semibold : .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                        Spacer(minLength: 0)
                    }
                    .foregroundColor(activeSidebarItem == tab ? .white : Color.white.opacity(0.65))
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                    .background(
                        Capsule()
                            .fill(activeSidebarItem == tab ? Color.white.opacity(0.18) : Color.white.opacity(0.055))
                    )
                    .overlay(IPTVFocusOutline(shape: Capsule()))
                }
                .buttonStyle(PosterCardButtonStyle())
                .focused($focusedTab, equals: tab)
            }

            Spacer()

            if loading {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(L10n.string("iptv_loading_source", fallback: "Loading source…"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.leading, 8)
            }
        }
        .focusSection()
        .onChange(of: focusLiveTVRequestID) { _, _ in
            Task { @MainActor in
                await Task.yield()
                guard isActive, activeSidebarItem == .liveTV else { return }
                focusedTab = .liveTV
            }
        }
    }
}

private struct IPTVCategoryPillsRow: View, Equatable {
    let categories: [String]
    let selectedCategory: String
    let customNames: [String: String]
    let onSelect: (String) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.categories == rhs.categories
            && lhs.selectedCategory == rhs.selectedCategory
            && lhs.customNames == rhs.customNames
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 10) {
                ForEach(categories, id: \.self) { category in
                    let isSelected = selectedCategory == category
                    let label = category == IPTVLiveView.allCategoriesID
                        ? L10n.string("action_all", fallback: "All")
                        : (customNames[category] ?? category)
                    Button {
                        onSelect(category)
                    } label: {
                        Text(label)
                            .font(.system(size: 20, weight: isSelected ? .bold : .medium))
                            .foregroundColor(isSelected ? .black : .white)
                            .padding(.horizontal, 22)
                            .padding(.vertical, 12)
                            .background(
                                Capsule()
                                    .fill(isSelected ? Color.white : Color.white.opacity(0.12))
                            )
                            .overlay(IPTVFocusOutline(
                                shape: Capsule(),
                                color: isSelected ? Color.black.opacity(0.8) : nil
                            ))
                    }
                    .buttonStyle(PosterCardButtonStyle())
                }
            }
            .padding(.vertical, 2)
        }
        .frame(height: 56)
    }
}

private struct IPTVChannelListCard: View {
    private static let initialRenderBatch = 200
    private static let renderBatchStep = 250
    private static let prefetchThreshold = 60

    let sectionTitle: String
    let emptySectionMessage: String
    let activeSidebarItem: IPTVLiveView.IPTVNavTab
    let selectedCategory: String
    let isChoosingCategory: Bool
    let hasHiddenCategoryGroups: Bool
    let showingHiddenCategories: Bool
    let categoryChooserGroups: [String]
    let categoryPreferences: IPTVCategoryPreferences
    let renamingCategoryID: String?
    @Binding var categoryNameDraft: String
    @Binding var isCategoryNameEditing: Bool
    @Binding var searchText: String
    let visibleChannels: [IPTVIndexedChannel]
    let selectedChannelID: String?
    let favorites: Set<String>
    let favoriteKeys: [String: String]
    let guideByChannel: [String: [IPTVProgramme]]
    let guideRevision: Int
    let guideNow: Date
    let cardSurfaceFill: Color
    let isActive: Bool
    let searchFocusRequestID: UUID
    let favoritesFocusRequestID: UUID
    @Binding var favoritesFocusTargetID: String?
    let favoriteFocusMemory: IPTVFavoriteFocusMemory
    let categoryFocusRequest: IPTVCategoryFocusRequest?

    let onToggleShowingHiddenCategories: () -> Void
    let onCommitCategoryRename: () -> Void
    let onSelectCategory: (String) -> Void
    let onMoveCategory: (String, Int) -> Void
    let onSetCategoryHidden: (Bool, String) -> Void
    let onBeginCategoryRename: (String) -> Void
    let onSelectChannel: (IPTVBaseChannel) -> Void
    let onPlayChannel: (IPTVBaseChannel) -> Void
    let onToggleFavorite: (String) -> Void
    let onMoveFavorite: (String, Int) -> Void

    @FocusState private var isChannelSearchFocused: Bool
    @FocusState private var focusedCategoryRowID: String?
    @FocusState private var focusedFavoriteRowID: String?
    @State private var renderedChannelLimit = initialRenderBatch

    private var listResetKey: String {
        "\(activeSidebarItem.rawValue)|\(selectedCategory)|\(visibleChannels.count)|\(visibleChannels.first?.id ?? "")"
    }

    var body: some View {
        let totalVisibleCount = visibleChannels.count
        let renderedCount = min(totalVisibleCount, renderedChannelLimit)
        let renderedSlice = visibleChannels.prefix(renderedCount)
        let hasGuide = !guideByChannel.isEmpty
        let isFavoritesTab = activeSidebarItem == .favorites

        return VStack(alignment: .leading, spacing: 14) {
            // Card Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(sectionTitle)
                        .font(.system(size: 23, weight: .bold))
                        .foregroundColor(.white)
                    Text(isChoosingCategory
                        ? "\(L10n.format("iptv_categories_count", fallback: "%d categories", categoryChooserGroups.count)) • \(L10n.string("iptv_category_manage_hint", fallback: "Hold Select to hide or reorder"))"
                        : L10n.format("iptv_channels_count", fallback: "%d channels", totalVisibleCount))
                        .font(.system(size: 16))
                        .foregroundColor(Color.white.opacity(0.5))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Spacer()
                if isChoosingCategory && hasHiddenCategoryGroups {
                    Button(showingHiddenCategories
                        ? L10n.string("iptv_hide_hidden_categories", fallback: "Hide hidden")
                        : L10n.string("iptv_show_hidden_categories", fallback: "Show hidden")) {
                        onToggleShowingHiddenCategories()
                    }
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .frame(height: 44)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
                    .overlay(IPTVFocusOutline(shape: Capsule()))
                    .buttonStyle(PosterCardButtonStyle())
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)

            if activeSidebarItem == .search {
                IPTVGlassSearchField(
                    text: $searchText,
                    placeholder: L10n.string("iptv_search_placeholder", fallback: "Search for channel or program"),
                    isFocused: $isChannelSearchFocused
                )
                .padding(.horizontal, 14)
                .onAppear { DispatchQueue.main.async { isChannelSearchFocused = true } }
                .onChange(of: searchFocusRequestID) { _, _ in
                    DispatchQueue.main.async { isChannelSearchFocused = true }
                }
            }

            if isChoosingCategory {
                HiddenIPTVTextField(
                    text: $categoryNameDraft,
                    isEditing: $isCategoryNameEditing,
                    placeholder: L10n.string("iptv_category_new_name", fallback: "New name"),
                    autocapitalizationType: .words,
                    onCommit: onCommitCategoryRename
                )
                .frame(width: 1, height: 1)
                .offset(x: -4_000)
                .allowsHitTesting(false)
            }

            // Channels / Categories List
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 6) {
                        if isChoosingCategory {
                            let categoryCount = categoryChooserGroups.count
                            ForEach(Array(categoryChooserGroups.enumerated()), id: \.element) { index, group in
                                categoryChooserRow(index: index, categoryCount: categoryCount, group: group)
                            }
                        } else if visibleChannels.isEmpty {
                            Text(emptySectionMessage)
                                .font(.system(size: 19, weight: .medium))
                                .foregroundColor(.white.opacity(0.55))
                                .frame(maxWidth: .infinity, minHeight: 100)
                        } else {
                            ForEach(renderedSlice) { item in
                                let rowEPG = rowProgramInfo(for: item.channel, hasGuide: hasGuide)
                                let rowIsFavorite = isFavorite(channelID: item.id)
                                IPTVChannelRowView(
                                    channelNumber: item.number,
                                    visibleCount: totalVisibleCount,
                                    channel: item.channel,
                                    programTitle: rowEPG.title,
                                    programProgress: rowEPG.progress,
                                    isSelected: selectedChannelID == item.id,
                                    isFavorite: rowIsFavorite,
                                    isFavoritesTab: isFavoritesTab,
                                    onSelect: { onSelectChannel(item.channel) },
                                    onPlay: { onPlayChannel(item.channel) },
                                    onToggleFavorite: { onToggleFavorite(item.id) },
                                    onMoveFavorite: { direction in onMoveFavorite(item.id, direction) },
                                    onFavoriteFocusGained: isFavoritesTab ? { favoriteFocusMemory.lastFocusedID = item.id } : nil
                                )
                                .equatable()
                                .modifier(IPTVOptionalFocusBinding(
                                    binding: isFavoritesTab ? $focusedFavoriteRowID : nil,
                                    value: item.id
                                ))
                                .id(item.id)
                                .onAppear {
                                    if item.number >= renderedChannelLimit - Self.prefetchThreshold,
                                       renderedChannelLimit < totalVisibleCount {
                                        renderedChannelLimit = min(totalVisibleCount, renderedChannelLimit + Self.renderBatchStep)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
                }
                .focusSection()
                .onChange(of: listResetKey) { _, _ in
                    renderedChannelLimit = Self.initialRenderBatch
                }
                .onChange(of: categoryFocusRequest) { _, request in
                    guard let request, isChoosingCategory else { return }
                    focusedCategoryRowID = request.groupID
                }
                .onChange(of: favoritesFocusRequestID, initial: true) { _, requestID in
                    guard activeSidebarItem == .favorites,
                          let targetID = favoritesFocusTargetID,
                          let targetIndex = visibleChannels.firstIndex(where: { $0.id == targetID }) else { return }
                    if targetIndex >= renderedChannelLimit {
                        renderedChannelLimit = min(visibleChannels.count, targetIndex + Self.renderBatchStep)
                    }
                    Task { @MainActor in
                        await Task.yield()
                        guard activeSidebarItem == .favorites,
                              favoritesFocusRequestID == requestID,
                              favoritesFocusTargetID == targetID else { return }
                        proxy.scrollTo(targetID, anchor: .center)
                        await Task.yield()
                        guard isActive, activeSidebarItem == .favorites,
                              favoritesFocusRequestID == requestID,
                              favoritesFocusTargetID == targetID else { return }
                        focusedFavoriteRowID = targetID
                        favoritesFocusTargetID = nil
                    }
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(cardSurfaceFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }

    private func categoryChooserRow(index: Int, categoryCount: Int, group: String) -> some View {
        let hidden = categoryPreferences.hiddenGroupIDs.contains(group)
        let displayName = categoryPreferences.customNames[group] ?? group
        let trimmedDraft = categoryNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let labelTitle = (renamingCategoryID == group && !trimmedDraft.isEmpty) ? categoryNameDraft : displayName

        return Button {
            if hidden {
                onSetCategoryHidden(false, group)
            } else {
                onSelectCategory(group)
            }
        } label: {
            HStack {
                Text(labelTitle)
                    .lineLimit(1)
                Spacer()
                if hidden {
                    Label(L10n.string("iptv_category_hidden", fallback: "Hidden"), systemImage: "eye.slash")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white.opacity(0.55))
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                }
            }
            .font(.system(size: 19, weight: .medium))
            .foregroundColor(.white.opacity(0.88))
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 66, maxHeight: 66, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.055)))
            .overlay(IPTVFocusOutline(shape: RoundedRectangle(cornerRadius: 12)))
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($focusedCategoryRowID, equals: group)
        .accessibilityHint(hidden
            ? L10n.string("iptv_category_unhide_hint", fallback: "Shows the category again")
            : L10n.string("iptv_category_open_hint", fallback: "Opens the category"))
        .contextMenu {
            Button(L10n.string("iptv_move_up", fallback: "Move up"), systemImage: "arrow.up") {
                onMoveCategory(group, -1)
            }
            .disabled(index == 0)

            Button(L10n.string("iptv_move_down", fallback: "Move down"), systemImage: "arrow.down") {
                onMoveCategory(group, 1)
            }
            .disabled(index >= categoryCount - 1)

            Button(
                hidden
                    ? L10n.string("iptv_show_category", fallback: "Show category")
                    : L10n.string("iptv_hide_category", fallback: "Hide category"),
                systemImage: hidden ? "eye" : "eye.slash"
            ) {
                onSetCategoryHidden(!hidden, group)
            }

            Button(L10n.string("iptv_rename", fallback: "Rename"), systemImage: "pencil") {
                onBeginCategoryRename(group)
            }
        }
    }

    private func isFavorite(channelID: String) -> Bool {
        if let key = favoriteKeys[channelID] {
            return favorites.contains(key)
        }
        return favorites.contains(channelID)
    }

    private func rowProgramInfo(for channel: IPTVBaseChannel, hasGuide: Bool) -> (title: String?, progress: CGFloat?) {
        guard hasGuide,
              let guideID = channel.guideID,
              let programmes = guideByChannel[guideID],
              let current = IPTVChannelGuideLookup.currentProgramme(in: programmes, at: guideNow) else {
            return (nil, nil)
        }
        let total = current.end.timeIntervalSince(current.start)
        let progress: CGFloat = total > 0
            ? CGFloat(min(max(guideNow.timeIntervalSince(current.start) / total, 0.0), 1.0))
            : 0
        return (current.title, progress)
    }
}

private struct IPTVOptionalFocusBinding<Value: Hashable>: ViewModifier {
    let binding: FocusState<Value?>.Binding?
    let value: Value

    @ViewBuilder
    func body(content: Content) -> some View {
        if let binding {
            content.focused(binding, equals: value)
        } else {
            content
        }
    }
}

private struct IPTVChannelRowView: View, Equatable {
    let channelNumber: Int
    let visibleCount: Int
    let channel: IPTVBaseChannel
    let programTitle: String?
    let programProgress: CGFloat?
    let isSelected: Bool
    let isFavorite: Bool
    let isFavoritesTab: Bool
    let onSelect: () -> Void
    let onPlay: () -> Void
    let onToggleFavorite: () -> Void
    let onMoveFavorite: (Int) -> Void
    let onFavoriteFocusGained: (() -> Void)?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.channelNumber == rhs.channelNumber
            && lhs.visibleCount == rhs.visibleCount
            && lhs.channel == rhs.channel
            && lhs.programTitle == rhs.programTitle
            && lhs.programProgress == rhs.programProgress
            && lhs.isSelected == rhs.isSelected
            && lhs.isFavorite == rhs.isFavorite
            && lhs.isFavoritesTab == rhs.isFavoritesTab
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                // Channel Index
                Text("\(channelNumber)")
                    .font(.system(size: 15, weight: .medium))
                    .monospacedDigit()
                    .foregroundColor(Color.white.opacity(0.5))
                    .lineLimit(1)
                    .frame(width: 40, alignment: .trailing)

                // Channel Logo Badge
                IPTVChannelBadgeView(channel: channel, size: CGSize(width: 56, height: 56))

                // Name, Subtitle, Mini Progress
                VStack(alignment: .leading, spacing: 4) {
                    Text(channel.name)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)

                    if let programTitle,
                       programTitle.localizedCaseInsensitiveCompare(channel.name) != .orderedSame {
                        Text(programTitle)
                            .font(.system(size: 17))
                            .foregroundColor(Color.white.opacity(0.6))
                            .lineLimit(1)
                    }

                    // Purple mini progress bar (no GeometryReader layout pass)
                    if let progress = programProgress {
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.white.opacity(0.12))
                            Capsule()
                                .fill(Color(red: 0.65, green: 0.35, blue: 0.95))
                                .scaleEffect(x: max(0, min(1, progress)), y: 1, anchor: .leading)
                        }
                        .frame(height: 2.5)
                        .clipShape(Capsule())
                    }
                }

                Spacer()
                if isFavorite {
                    Image(systemName: "star.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Color.yellow)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(height: 80)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(isSelected ? Color(red: 0.65, green: 0.35, blue: 0.95).opacity(0.15) : Color.white.opacity(0.02))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(isSelected ? Color(red: 0.65, green: 0.35, blue: 0.95) : Color.clear, lineWidth: 2)
            )
            .overlay(IPTVFocusOutline(shape: RoundedRectangle(cornerRadius: 14)))
        }
        .buttonStyle(PosterCardButtonStyle(onNativeFocusChange: onFavoriteFocusGained.map { callback in
            { focused in
                if focused { callback() }
            }
        }))
        .contextMenu {
            if channel.streamURL != nil {
                Button(
                    isFavorite
                        ? L10n.string("iptv_remove_favorite", fallback: "Remove favorite")
                        : L10n.string("iptv_add_favorite", fallback: "Add favorite"),
                    systemImage: isFavorite ? "star.slash" : "star"
                ) {
                    onToggleFavorite()
                }
            }
            if isFavoritesTab {
                Button(L10n.string("iptv_move_up", fallback: "Move up"), systemImage: "arrow.up") {
                    onMoveFavorite(-1)
                }
                .disabled(channelNumber == 1)
                Button(L10n.string("iptv_move_down", fallback: "Move down"), systemImage: "arrow.down") {
                    onMoveFavorite(1)
                }
                .disabled(channelNumber >= visibleCount)
            }
        }
        .onPlayPauseCommand(perform: onPlay)
    }
}

private struct IPTVLivePreviewCard: View {
    let activeChannel: IPTVBaseChannel?
    let activeEPG: IPTVChannelEPGSnapshot?
    let categoryLabel: String?
    let inlinePreviewPlayer: AVPlayer?
    let inlineAetherPreviewController: IPTVInlineAetherPreviewController?
    let inlineAetherPreviewIsReady: Bool
    let isFullscreenPreviewTransitionActive: Bool
    let loading: Bool
    let sourcesIsEmpty: Bool
    let errorMessage: String?
    let cardSurfaceFill: Color
    let previewBackdropFill: Color
    let focusRequestID: UUID
    let onPlay: (IPTVBaseChannel) -> Void
    let onMarkInlinePreviewReady: (AVPlayer, String) -> Void
    let onOpenCredentials: () -> Void

    @FocusState private var isPreviewButtonFocused: Bool

    var body: some View {
        Group {
            if let active = activeChannel, let epg = activeEPG {
                activeCard(for: active, epg: epg)
            } else {
                emptyCard
            }
        }
        .onChange(of: focusRequestID) { _, _ in
            isPreviewButtonFocused = true
        }
    }

    private func activeCard(for active: IPTVBaseChannel, epg: IPTVChannelEPGSnapshot) -> some View {
        let hasCurrentProgramme = epg.programProgress != nil
        return Button {
            onPlay(active)
        } label: {
            ZStack(alignment: .bottomLeading) {
                GeometryReader { geo in
                    ZStack {
                        previewBackdropFill
                        active.brandColor.opacity(0.25)
                        VStack {
                            IPTVChannelBadgeView(channel: active, size: CGSize(width: 80, height: 60))
                            Text(active.name)
                                .font(.title2.bold())
                                .foregroundColor(.white)
                        }

                        if !isFullscreenPreviewTransitionActive, let player = inlinePreviewPlayer {
                            IPTVVideoSurface(player: player) {
                                onMarkInlinePreviewReady(player, active.id)
                            }
                            .frame(width: geo.size.width, height: geo.size.height)
                            .id(ObjectIdentifier(player))
                            .accessibilityHidden(true)
                            .allowsHitTesting(false)
                        } else if !isFullscreenPreviewTransitionActive,
                                  let aetherController = inlineAetherPreviewController,
                                  aetherController.activeChannelID == active.id {
                            IPTVAetherVideoSurface(controller: aetherController)
                                .frame(width: geo.size.width, height: geo.size.height)
                                .opacity(inlineAetherPreviewIsReady ? 1 : 0)
                                .accessibilityHidden(true)
                                .allowsHitTesting(false)
                        }

                        LinearGradient(
                            colors: [.clear, Color.black.opacity(0.3), Color.black.opacity(0.92)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                }

                VStack {
                    HStack {
                        IPTVChannelBadgeView(channel: active, size: CGSize(width: 72, height: 48))
                        Spacer()
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color(red: 0.75, green: 0.35, blue: 0.95))
                                .frame(width: 8, height: 8)
                            Text(L10n.string("iptv_live_badge", fallback: "Live"))
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            Capsule()
                                .fill(Color.black.opacity(0.6))
                        )
                    }
                    .padding(20)
                    Spacer()
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text(hasCurrentProgramme ? epg.programTitle : active.name)
                        .font(.system(size: 32, weight: .bold))
                        .foregroundColor(.white)

                    let resolvedCategory = categoryLabel ?? active.category
                    Text(hasCurrentProgramme ? "\(resolvedCategory) • \(epg.programTime)" : resolvedCategory)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(Color.white.opacity(0.75))
                }
                .padding(.leading, 28)
                .padding(.trailing, active.streamURL == nil ? 28 : 230)
                .padding(.bottom, 24)
            }
            .overlay(alignment: .bottomTrailing) {
                if active.streamURL != nil {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 19, weight: .semibold))
                        Text(L10n.string("iptv_fullscreen", fallback: "Fullscreen"))
                            .font(.system(size: 19, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .frame(height: 54)
                    .padding(.horizontal, 20)
                    .background(Capsule().fill(Color.white.opacity(0.18)))
                    .padding(.trailing, 28)
                    .padding(.bottom, 24)
                }
            }
            .frame(minHeight: 310, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .overlay(IPTVFocusOutline(shape: RoundedRectangle(cornerRadius: 20)))
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($isPreviewButtonFocused)
        .disabled(active.streamURL == nil)
    }

    private var emptyCard: some View {
        ZStack {
            cardSurfaceFill
            VStack(spacing: 16) {
                if loading {
                    ProgressView()
                    Text(L10n.string("iptv_loading_channels", fallback: "Loading channels…"))
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(.white.opacity(0.72))
                } else {
                    Image(systemName: "tv")
                        .font(.system(size: 44, weight: .semibold))
                        .foregroundColor(.white.opacity(0.55))

                    Text(sourcesIsEmpty
                        ? L10n.string("iptv_no_source_configured", fallback: "No IPTV source configured")
                        : L10n.string("iptv_no_channels_available", fallback: "No channels available"))
                        .font(.system(size: 26, weight: .bold))
                        .foregroundColor(.white)

                    Text(errorMessage ?? (sourcesIsEmpty
                        ? L10n.string("iptv_no_source_subtitle", fallback: "Add an M3U playlist, Xtream Codes, or Stalker portal to watch live TV.")
                        : L10n.string("iptv_no_channels_subtitle", fallback: "Check or change the IPTV source in settings.")))
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.white.opacity(0.68))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 540)

                    Button(action: onOpenCredentials) {
                        Text(sourcesIsEmpty
                            ? L10n.string("iptv_add_iptv_source", fallback: "Add IPTV source")
                            : L10n.string("iptv_manage_sources", fallback: "Manage sources"))
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 24)
                            .frame(height: 54)
                            .background(Capsule().fill(Color.white.opacity(0.16)))
                            .overlay(IPTVFocusOutline(shape: Capsule()))
                    }
                    .buttonStyle(PosterCardButtonStyle())
                    .focused($isPreviewButtonFocused)
                }
            }
            .padding(32)
        }
        .frame(maxWidth: .infinity, minHeight: 310, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct IPTVScheduleEPGCard: View, Equatable {
    let activeChannelName: String?
    let activeEPG: IPTVChannelEPGSnapshot?
    let cardSurfaceFill: Color

    var body: some View {
        let hasCurrentProgramme = activeEPG?.programProgress != nil
        let upcomingPrograms: [(title: String, time: String)] = activeEPG.map { epg in
            [
                (title: epg.nextShow1Title, time: epg.nextShow1Time),
                (title: epg.nextShow2Title, time: epg.nextShow2Time)
            ].filter { $0.time != "--:--" && !$0.title.isEmpty }
        } ?? []

        return VStack(alignment: .leading, spacing: 10) {
            Text(activeChannelName.map { L10n.format("iptv_now_and_next_for_channel", fallback: "%@ – Now & Next", $0) }
                ?? L10n.string("iptv_now_and_next", fallback: "Now & Next"))
                .font(.system(size: 23, weight: .bold))
                .foregroundColor(.white)

            if let epg = activeEPG, hasCurrentProgramme {
                guideProgramRow(
                    title: epg.programTitle,
                    time: epg.programTime,
                    isCurrent: true,
                    progress: epg.programProgress
                )
            }

            if upcomingPrograms.isEmpty {
                if !hasCurrentProgramme {
                    Text(L10n.string("iptv_no_program_info", fallback: "No program information"))
                        .font(.system(size: 16))
                        .foregroundColor(Color.white.opacity(0.65))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.045)))
                }
            } else {
                ForEach(Array(upcomingPrograms.prefix(2).enumerated()), id: \.offset) { _, programme in
                    guideProgramRow(title: programme.title, time: programme.time, isCurrent: false)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(cardSurfaceFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }

    @ViewBuilder
    private func guideProgramRow(title: String, time: String, isCurrent: Bool, progress: CGFloat? = nil) -> some View {
        HStack(spacing: 12) {
            if isCurrent {
                Image(systemName: "play.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(Color(red: 0.75, green: 0.48, blue: 1.0))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 20, weight: isCurrent ? .semibold : .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text(time)
                    .font(.system(size: 16))
                    .foregroundColor(Color.white.opacity(0.62))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if isCurrent {
                if let progress {
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.12))
                        Capsule()
                            .fill(Color(red: 0.65, green: 0.35, blue: 0.95))
                            .scaleEffect(x: max(0, min(1, progress)), y: 1, anchor: .leading)
                    }
                    .frame(width: 120, height: 4)
                    .clipShape(Capsule())
                }

                Text(L10n.string("iptv_live_badge", fallback: "Live"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Color(red: 0.88, green: 0.72, blue: 1.0))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Color(red: 0.45, green: 0.20, blue: 0.65).opacity(0.45)))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(isCurrent ? Color(red: 0.45, green: 0.20, blue: 0.65).opacity(0.16) : Color.white.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(isCurrent ? Color(red: 0.65, green: 0.35, blue: 0.95).opacity(0.42) : Color.white.opacity(0.05), lineWidth: 1)
        )
    }
}

private struct IPTVTimeGuideView: View {
    private enum GuideFocusTarget: Hashable {
        case programme(channelID: String, start: Date)
        case control(GuideControl)
    }

    private enum GuideControl: Hashable {
        case earlier
        case now
        case later
        case retrySummary
        case retryEmpty
        case detailsClose
    }

    private struct GuideProgrammeSpan: Identifiable {
        let programme: IPTVProgramme
        let leadingGap: CGFloat
        let tileWidth: CGFloat
        let trailingGap: CGFloat
        let isFocusable: Bool
        var id: Date { programme.start }
    }

    private struct IPTVGuideDisplayRow: Identifiable {
        let channel: IPTVBaseChannel
        let programmes: [IPTVProgramme]
        var id: String { channel.id }
    }

    private static let initialRowBatch = 80
    private static let rowBatchStep = 100
    private static let rowPrefetchThreshold = 25

    let visibleChannels: [IPTVIndexedChannel]
    let baseChannelsByID: [String: IPTVBaseChannel]
    let hasGuideIDs: Bool
    let selectedCategory: String
    let hiddenGroupIDs: Set<String>
    let guideByChannel: [String: [IPTVProgramme]]
    let guideRevision: Int
    let guideNow: Date
    let guidePageStart: Date
    let guidePageEnd: Date
    let guidePageDuration: TimeInterval
    let canBrowseGuideEarlier: Bool
    let canBrowseGuideLater: Bool
    let isLoadingGuide: Bool
    let guideFailures: Int
    let guideUnavailable: Bool
    let selectedGuideURLsIsEmpty: Bool
    @Binding var selectedGuideProgramme: IPTVProgramme?
    @Binding var selectedGuideChannelID: String?
    let guideTimeFormatter: DateFormatter
    let guideDateFormatter: DateFormatter
    let cardSurfaceFill: Color
    let isActive: Bool
    let focusNowRequestID: UUID
    let onMoveGuidePage: (TimeInterval) -> Void
    let onResetGuideNow: () -> Void
    let onRetryGuide: () -> Void
    let onTuneChannel: (IPTVBaseChannel) -> Void
    let onExitToSidebar: () -> Void

    @FocusState private var guideFocusTarget: GuideFocusTarget?
    @State private var guideTimelineWidth: CGFloat = 1
    @State private var cachedRows: [IPTVGuideDisplayRow] = []
    @State private var renderedRowLimit = initialRowBatch

    private let guideChannelColumnWidth: CGFloat = 232
    private let guideProgrammeGap: CGFloat = 3
    private let guideProgrammeMinimumFocusWidth: CGFloat = 24

    private var rowsDependencyKey: String {
        "\(visibleChannels.count)|\(selectedCategory)|\(guideRevision)|\(guidePageStart.timeIntervalSince1970)|\(guidePageEnd.timeIntervalSince1970)"
    }

    var body: some View {
        let pageStart = guidePageStart
        let pageEnd = guidePageEnd
        let renderedRows = cachedRows.prefix(min(cachedRows.count, renderedRowLimit))

        return GeometryReader { geometry in
            let panelContentWidth = geometry.size.width.isFinite ? max(1, geometry.size.width - 24) : 1
            let rowContentWidth = max(1, panelContentWidth - 20)
            let channelColumnWidth = min(guideChannelColumnWidth, max(1, rowContentWidth - 1))
            let timelineWidth = max(1, rowContentWidth - channelColumnWidth)

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.string("iptv_nav_guide", fallback: "TV guide"))
                            .font(.system(size: 30, weight: .bold))
                            .foregroundColor(.white)
                        Text("\(guideDateRange(start: pageStart, end: pageEnd))  •  \(formatTimeRange(start: pageStart, end: pageEnd))  •  \(L10n.format("iptv_channels_count", fallback: "%d channels", cachedRows.count))")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(.white.opacity(0.62))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }

                    Spacer(minLength: 12)
                    guidePageButton(L10n.string("iptv_guide_earlier", fallback: "Earlier"), icon: "chevron.left", enabled: canBrowseGuideEarlier, focusTarget: .control(.earlier)) {
                        onMoveGuidePage(-guidePageDuration)
                    }
                    guidePageButton(L10n.string("iptv_guide_now", fallback: "Now"), icon: "dot.circle", enabled: true, focusTarget: .control(.now)) {
                        onResetGuideNow()
                    }
                    guidePageButton(L10n.string("iptv_guide_later", fallback: "Later"), icon: "chevron.right", enabled: canBrowseGuideLater, focusTarget: .control(.later)) {
                        onMoveGuidePage(guidePageDuration)
                    }
                }

                if isLoadingGuide {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(L10n.string("iptv_guide_loading", fallback: "Loading program guide…"))
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(.white.opacity(0.72))
                    }
                } else if guideFailures > 0 {
                    HStack(spacing: 14) {
                        Text(L10n.string("iptv_guide_partial_error", fallback: "Some program guide feeds could not be loaded."))
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(.white.opacity(0.72))
                        guidePageButton(L10n.string("action_retry", fallback: "Retry"), icon: "arrow.clockwise", enabled: !selectedGuideURLsIsEmpty, focusTarget: .control(.retrySummary)) {
                            onRetryGuide()
                            guideFocusTarget = .control(.now)
                        }
                    }
                }

                if selectedGuideProgramme != nil {
                    selectedGuideProgrammeCard(timelineWidth: timelineWidth)
                }

                if selectedGuideURLsIsEmpty {
                    guideEmptyState(L10n.string("iptv_guide_not_configured", fallback: "No TV guide is configured for this source."), icon: "calendar.badge.exclamationmark")
                } else if !hasGuideIDs {
                    guideEmptyState(L10n.string("iptv_guide_no_epg_ids", fallback: "This source has no channels with an EPG ID."), icon: "tv.slash")
                } else {
                    VStack(spacing: 6) {
                        guideTimeAxis(start: pageStart, width: timelineWidth, channelColumnWidth: channelColumnWidth)

                        if cachedRows.isEmpty {
                            if isLoadingGuide {
                                guideEmptyState(L10n.string("iptv_guide_waiting", fallback: "Waiting for program data…"), icon: "clock")
                            } else if guideUnavailable {
                                HStack(spacing: 14) {
                                    guideEmptyState(L10n.string("iptv_guide_unavailable", fallback: "Program guide unavailable."), icon: "wifi.slash")
                                    guidePageButton(L10n.string("action_retry", fallback: "Retry"), icon: "arrow.clockwise", enabled: true, focusTarget: .control(.retryEmpty)) {
                                        onRetryGuide()
                                        guideFocusTarget = .control(.now)
                                    }
                                }
                            } else {
                                guideEmptyState(L10n.string("iptv_guide_empty_window", fallback: "No program information in this time range."), icon: "calendar")
                            }
                        } else {
                            ScrollView(.vertical, showsIndicators: false) {
                                LazyVStack(spacing: 6) {
                                    ForEach(Array(renderedRows.enumerated()), id: \.element.id) { index, row in
                                        guideChannelRow(
                                            row,
                                            start: pageStart,
                                            end: pageEnd,
                                            timelineWidth: timelineWidth,
                                            channelColumnWidth: channelColumnWidth
                                        )
                                        .onAppear {
                                            if index >= renderedRowLimit - Self.rowPrefetchThreshold,
                                               renderedRowLimit < cachedRows.count {
                                                renderedRowLimit = min(cachedRows.count, renderedRowLimit + Self.rowBatchStep)
                                            }
                                        }
                                    }
                                }
                                .padding(.bottom, 8)
                            }
                        }
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 18)
                            .fill(cardSurfaceFill)
                            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.08), lineWidth: 1))
                    )
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .focusSection()
            .onExitCommand { handleGuideBackCommand(timelineWidth: guideTimelineWidth) }
            .onChange(of: timelineWidth, initial: true) { _, width in
                guard width.isFinite, width > 0 else { return }
                guideTimelineWidth = width
            }
            .onChange(of: rowsDependencyKey, initial: true) { _, _ in
                rebuildGuideRows()
            }
            .onChange(of: focusNowRequestID, initial: true) { _, _ in
                Task { @MainActor in
                    await Task.yield()
                    guard isActive else { return }
                    guideFocusTarget = .control(.now)
                }
            }
            .onChange(of: guideFocusTarget) { oldTarget, newTarget in
                guard case let .programme(channelID, start) = oldTarget,
                      newTarget == nil else { return }
                Task { @MainActor in
                    await Task.yield()
                    guard isActive, guideFocusTarget == nil,
                          !guideProgrammeFocusIsAvailable(channelID: channelID, start: start, timelineWidth: timelineWidth) else { return }
                    guideFocusTarget = .control(.now)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func rebuildGuideRows() {
        let start = guidePageStart
        let end = guidePageEnd
        var rows: [IPTVGuideDisplayRow] = []
        for indexed in visibleChannels {
            let channel = indexed.channel
            guard let guideID = channel.guideID,
                  let programmes = guideByChannel[guideID] else { continue }
            let visibleProgrammes = programmes.filter { $0.start < end && $0.end > start }
            guard !visibleProgrammes.isEmpty else { continue }
            rows.append(IPTVGuideDisplayRow(channel: channel, programmes: visibleProgrammes))
        }
        cachedRows = rows
        renderedRowLimit = Self.initialRowBatch
    }

    private func guideProgrammeSpans(
        programmes: [IPTVProgramme],
        start: Date,
        end: Date,
        timelineWidth: CGFloat
    ) -> [GuideProgrammeSpan] {
        let duration = end.timeIntervalSince(start)
        guard duration.isFinite, duration > 0, timelineWidth.isFinite, timelineWidth > 0 else { return [] }

        let sortedProgrammes = programmes.sorted {
            $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start
        }
        var candidates: [(programme: IPTVProgramme, xStart: CGFloat, xEnd: CGFloat)] = []

        for (index, programme) in sortedProgrammes.enumerated() {
            let clippedStart = max(programme.start, start)
            let nextStart = index + 1 < sortedProgrammes.count ? sortedProgrammes[index + 1].start : end
            let clippedEnd = min(min(programme.end, end), nextStart)
            guard clippedEnd > clippedStart else { continue }

            let rawStart = CGFloat(clippedStart.timeIntervalSince(start) / duration) * timelineWidth
            let rawEnd = CGFloat(clippedEnd.timeIntervalSince(start) / duration) * timelineWidth
            guard rawStart.isFinite, rawEnd.isFinite else { continue }
            let xStart = min(max(0, rawStart), timelineWidth)
            let xEnd = min(max(xStart, rawEnd), timelineWidth)
            guard xEnd > xStart else { continue }
            candidates.append((programme, xStart, xEnd))
        }

        var previousEnd: CGFloat = 0
        return candidates.enumerated().map { index, candidate in
            let rawWidth = candidate.xEnd - candidate.xStart
            let trailingGap = index + 1 < candidates.count
                ? min(guideProgrammeGap, rawWidth / 2)
                : 0
            let span = GuideProgrammeSpan(
                programme: candidate.programme,
                leadingGap: max(0, candidate.xStart - previousEnd),
                tileWidth: max(0, rawWidth - trailingGap),
                trailingGap: trailingGap,
                isFocusable: rawWidth - trailingGap >= guideProgrammeMinimumFocusWidth
            )
            previousEnd = candidate.xEnd
            return span
        }
    }

    private func guidePageButton(
        _ title: String,
        icon: String,
        enabled: Bool,
        focusTarget: GuideFocusTarget,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            guard enabled else { return }
            action()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                Text(title)
                    .font(.system(size: 18, weight: .semibold))
            }
            .foregroundColor(.white.opacity(enabled ? 0.92 : 0.35))
            .padding(.horizontal, 16)
            .frame(height: 48)
            .background(Capsule().fill(Color.white.opacity(enabled ? 0.1 : 0.045)))
            .overlay(IPTVFocusOutline(shape: Capsule()))
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($guideFocusTarget, equals: focusTarget)
        .accessibilityHint(enabled ? "" : L10n.string("iptv_not_available", fallback: "Not available"))
    }

    private func guideTimeAxis(start: Date, width: CGFloat, channelColumnWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            Text(L10n.string("iptv_channel_column", fallback: "Channel"))
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.white.opacity(0.74))
                .padding(.trailing, 10)
                .frame(width: channelColumnWidth, alignment: .leading)

            HStack(spacing: 0) {
                ForEach(0..<4, id: \.self) { tick in
                    Text(guideClockLabel(start.addingTimeInterval(Double(tick) * 60 * 60)))
                        .font(.system(size: 17, weight: .medium))
                        .monospacedDigit()
                        .foregroundColor(.white.opacity(0.6))
                        .frame(width: width / 4, alignment: .leading)
                }
            }
            .frame(width: width, alignment: .leading)
            .overlay(alignment: .trailing) {
                Text(guideClockLabel(start.addingTimeInterval(guidePageDuration)))
                    .font(.system(size: 17, weight: .medium))
                    .monospacedDigit()
                    .foregroundColor(.white.opacity(0.6))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .overlay(alignment: .bottom) { Color.white.opacity(0.12).frame(height: 1) }
    }

    private func guideChannelRow(
        _ row: IPTVGuideDisplayRow,
        start: Date,
        end: Date,
        timelineWidth: CGFloat,
        channelColumnWidth: CGFloat
    ) -> some View {
        let spans = guideProgrammeSpans(programmes: row.programmes, start: start, end: end, timelineWidth: timelineWidth)
        return HStack(spacing: 0) {
            HStack(spacing: 12) {
                IPTVChannelBadgeView(channel: row.channel, size: CGSize(width: 48, height: 42))
                Text(row.channel.name)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
            }
            .padding(.trailing, 10)
            .frame(width: channelColumnWidth, height: 74, alignment: .leading)

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(0.035))
                HStack(spacing: 0) {
                    ForEach(spans) { span in
                        if span.leadingGap > 0 {
                            Color.clear.frame(width: span.leadingGap, height: 74)
                        }
                        if span.isFocusable {
                            guideProgrammeTile(span.programme, row: row, width: span.tileWidth)
                        } else {
                            guideProgrammeVisualSpan(span)
                        }
                        if span.trailingGap > 0 {
                            Color.clear.frame(width: span.trailingGap, height: 74)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
            .frame(width: timelineWidth, height: 74)
            .clipped()
        }
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.035)))
    }

    private func guideProgrammeTile(
        _ programme: IPTVProgramme,
        row: IPTVGuideDisplayRow,
        width: CGFloat
    ) -> some View {
        let isCurrent = programme.start <= guideNow && guideNow < programme.end
        let shape = RoundedRectangle(cornerRadius: 9)

        return Button {
            selectedGuideProgramme = programme
            selectedGuideChannelID = row.channel.id
            if isCurrent, row.channel.streamURL != nil {
                onTuneChannel(row.channel)
            }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(programme.title)
                    .font(.system(size: width < 100 ? 16 : 20, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                if width >= 100 {
                    Text(formatTimeRange(start: programme.start, end: programme.end))
                        .font(.system(size: 15, weight: .medium))
                        .monospacedDigit()
                        .foregroundColor(.white.opacity(0.7))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .frame(width: width, height: 68, alignment: .leading)
            .background(shape.fill(isCurrent ? Color(red: 0.35, green: 0.18, blue: 0.58) : Color.white.opacity(0.12)))
            .overlay(shape.stroke(isCurrent ? Color(red: 0.72, green: 0.48, blue: 1) : Color.white.opacity(0.08), lineWidth: 1))
            .overlay(IPTVFocusOutline(shape: shape))
        }
        .frame(width: width, height: 74)
        .buttonStyle(PosterCardButtonStyle())
        .focused($guideFocusTarget, equals: .programme(channelID: row.channel.id, start: programme.start))
        .accessibilityLabel("\(programme.title), \(formatTimeRange(start: programme.start, end: programme.end))")
    }

    private func guideProgrammeVisualSpan(_ span: GuideProgrammeSpan) -> some View {
        let isCurrent = span.programme.start <= guideNow && guideNow < span.programme.end
        let shape = RoundedRectangle(cornerRadius: 9)
        return shape
            .fill(isCurrent ? Color(red: 0.35, green: 0.18, blue: 0.58) : Color.white.opacity(0.12))
            .overlay(shape.stroke(isCurrent ? Color(red: 0.72, green: 0.48, blue: 1) : Color.white.opacity(0.08), lineWidth: 1))
            .frame(width: span.tileWidth, height: 68)
            .frame(width: span.tileWidth, height: 74)
            .accessibilityHidden(true)
    }

    private func guideProgrammeFocusIsAvailable(channelID: String, start: Date, timelineWidth: CGFloat) -> Bool {
        let pageStart = guidePageStart
        let pageEnd = guidePageEnd
        guard let channel = baseChannelsByID[channelID],
              selectedCategory == IPTVLiveView.allCategoriesID || channel.group == selectedCategory,
              !hiddenGroupIDs.contains(channel.group),
              let guideID = channel.guideID,
              let programmes = guideByChannel[guideID] else { return false }
        let visibleProgrammes = programmes.filter { $0.start < pageEnd && $0.end > pageStart }
        return guideProgrammeSpans(programmes: visibleProgrammes, start: pageStart, end: pageEnd, timelineWidth: timelineWidth)
            .contains { $0.programme.start == start && $0.isFocusable }
    }

    private func selectedGuideProgrammeCard(timelineWidth: CGFloat) -> some View {
        let channelName = selectedGuideChannelID.flatMap { baseChannelsByID[$0]?.name } ?? ""
        return HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(selectedGuideProgramme?.title ?? "")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                if let programme = selectedGuideProgramme {
                    Text("\(channelName)  •  \(formatTimeRange(start: programme.start, end: programme.end))")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.white.opacity(0.66))
                }
            }
            Spacer()
            guidePageButton(L10n.string("action_close", fallback: "Close"), icon: "xmark", enabled: true, focusTarget: .control(.detailsClose)) {
                let channelID = selectedGuideChannelID
                let programmeStart = selectedGuideProgramme?.start
                selectedGuideProgramme = nil
                selectedGuideChannelID = nil
                restoreGuideFocusAfterDetailsClose(channelID: channelID, programmeStart: programmeStart, timelineWidth: timelineWidth)
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 68)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.07)))
    }

    private func restoreGuideFocusAfterDetailsClose(channelID: String?, programmeStart: Date?, timelineWidth: CGFloat) {
        Task { @MainActor in
            await Task.yield()
            guard isActive else { return }
            if let channelID, let programmeStart,
               guideProgrammeFocusIsAvailable(channelID: channelID, start: programmeStart, timelineWidth: timelineWidth) {
                guideFocusTarget = .programme(channelID: channelID, start: programmeStart)
            } else {
                guideFocusTarget = .control(.now)
            }
        }
    }

    private func handleGuideBackCommand(timelineWidth: CGFloat) {
        if selectedGuideProgramme != nil {
            let channelID = selectedGuideChannelID
            let programmeStart = selectedGuideProgramme?.start
            selectedGuideProgramme = nil
            selectedGuideChannelID = nil
            restoreGuideFocusAfterDetailsClose(channelID: channelID, programmeStart: programmeStart, timelineWidth: timelineWidth)
            return
        }
        onExitToSidebar()
    }

    private func guideEmptyState(_ message: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .medium))
            Text(message)
                .font(.system(size: 20, weight: .medium))
                .lineLimit(2)
        }
        .foregroundColor(.white.opacity(0.62))
        .frame(maxWidth: .infinity, minHeight: 86, alignment: .leading)
        .padding(.horizontal, 18)
    }

    private func guideClockLabel(_ date: Date) -> String {
        guideTimeFormatter.string(from: date)
    }

    private func formatTimeRange(start: Date, end: Date) -> String {
        "\(guideTimeFormatter.string(from: start)) – \(guideTimeFormatter.string(from: end))"
    }

    private func guideDateRange(start: Date, end: Date) -> String {
        let startDate = guideDateFormatter.string(from: start)
        let endDate = guideDateFormatter.string(from: end.addingTimeInterval(-1))
        return startDate == endDate ? startDate : "\(startDate) – \(endDate)"
    }
}

// MARK: - Cached Channel Logo Badge

private struct IPTVChannelBadgeView: View {
    let channel: IPTVBaseChannel
    let size: CGSize

    var body: some View {
        ZStack {
            if let url = channel.logoURL {
                IPTVChannelLogoImage(url: url, maxPixelSize: max(size.width, size.height) * 2) {
                    brandBadgeFallback
                }
            } else {
                brandBadgeFallback
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var brandBadgeFallback: some View {
        ZStack {
            channel.brandColor
            Text(channel.logoText)
                .font(.system(size: min(size.width, size.height) * 0.35, weight: .bold))
                .foregroundColor(.white)
        }
        .frame(width: size.width, height: size.height)
    }
}

private struct IPTVChannelLogoImage<Placeholder: View>: View {
    let url: URL
    let maxPixelSize: CGFloat
    @ViewBuilder let placeholder: () -> Placeholder

    @State private var image: UIImage?

    init(url: URL, maxPixelSize: CGFloat, @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.url = url
        self.maxPixelSize = maxPixelSize
        self.placeholder = placeholder
        _image = State(initialValue: IPTVLogoImageCache.shared.cachedImage(for: url))
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            if let cached = IPTVLogoImageCache.shared.cachedImage(for: url) {
                if image !== cached { image = cached }
                return
            }
            let loaded = await IPTVLogoImageCache.shared.loadImage(for: url, maxPixelSize: maxPixelSize)
            guard !Task.isCancelled else { return }
            if let loaded {
                image = loaded
            }
        }
    }
}

private final class IPTVLogoImageCache: @unchecked Sendable {
    static let shared = IPTVLogoImageCache()

    private let cache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 250
        cache.totalCostLimit = 24 * 1024 * 1024
        return cache
    }()

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        config.httpMaximumConnectionsPerHost = 4
        config.urlCache = URLCache(memoryCapacity: 8 * 1024 * 1024, diskCapacity: 32 * 1024 * 1024)
        return URLSession(configuration: config)
    }()

    private let lock = NSLock()
    private var inFlight: [NSURL: Task<UIImage?, Never>] = [:]
    private var failedAt: [NSURL: Date] = [:]
    private static let failureTTL: TimeInterval = 5 * 60
    private static let maxFailureEntries = 500
    private static let maxLogoBytes = 2 * 1024 * 1024

    func cachedImage(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    func loadImage(for url: URL, maxPixelSize: CGFloat) async -> UIImage? {
        let key = url as NSURL
        if let cached = cache.object(forKey: key) {
            return cached
        }
        let now = Date()
        let task: Task<UIImage?, Never>? = lock.withLock {
            if let failed = failedAt[key], now.timeIntervalSince(failed) < Self.failureTTL {
                return nil
            }
            if let existing = inFlight[key] {
                return existing
            }
            let created = Task.detached(priority: .utility) { [weak self] () -> UIImage? in
                guard let self else { return nil }
                defer {
                    self.lock.withLock { self.inFlight[key] = nil }
                }
                var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 8)
                request.setValue("NuvioTV", forHTTPHeaderField: "User-Agent")
                guard let (data, response) = try? await self.session.data(for: request),
                      let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      !data.isEmpty,
                      data.count <= Self.maxLogoBytes,
                      let decoded = Self.downsampledImage(from: data, maxPixelSize: maxPixelSize) else {
                    self.recordFailure(for: key)
                    return nil
                }
                let cost = Int(decoded.size.width * decoded.size.height * decoded.scale * decoded.scale * 4)
                self.cache.setObject(decoded, forKey: key, cost: max(1, cost))
                return decoded
            }
            inFlight[key] = created
            return created
        }
        guard let task else { return nil }
        return await task.value
    }

    private func recordFailure(for key: NSURL) {
        lock.withLock {
            if failedAt.count >= Self.maxFailureEntries {
                failedAt.removeAll(keepingCapacity: true)
            }
            failedAt[key] = Date()
        }
    }

    private static func downsampledImage(from data: Data, maxPixelSize: CGFloat) -> UIImage? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else {
            return UIImage(data: data)
        }
        let clampedPixels = max(32, min(256, Int(maxPixelSize.rounded(.up))))
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: clampedPixels
        ]
        if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) {
            return UIImage(cgImage: cgImage)
        }
        return UIImage(data: data)
    }
}

private struct IPTVGuideFocusOutline<Shape: InsettableShape>: View {
    @Environment(\.isFocused) private var isFocused
    let shape: Shape

    var body: some View {
        shape.strokeBorder(isFocused ? Color.white.opacity(0.95) : .clear, lineWidth: 3)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct IPTVFocusOutline<Shape: InsettableShape>: View {
    @Environment(\.isFocused) private var isFocused
    let shape: Shape
    var color: Color? = nil

    var body: some View {
        shape.strokeBorder(isFocused ? (color ?? AppFocusOutline.color) : .clear, lineWidth: AppFocusOutline.width)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct IPTVFullscreenPreview: Identifiable {
    let id = UUID()
    let player: AVPlayer
    let channelTitle: String
    let programmes: [IPTVProgramme]
    let startedAt: Date
}

private struct IPTVInlinePreviewRequestKey: Equatable {
    let channelID: String
    let streamURL: URL
    let sourceID: UUID?
}

private struct IPTVInlinePreviewTarget: Equatable {
    let channelID: String
    let url: URL
    let headers: [String: String]
    let backend: IPTVInlinePreviewBackend
}

@MainActor
private final class IPTVInlineAetherPreviewController {
    let engine: AetherEngine
    let playerView: AetherPlayerView

    private(set) var activeChannelID: String?
    private var loadTask: Task<Void, Never>?
    private var readinessCancellable: AnyCancellable?
    private var generation: UInt64 = 0

    init?() {
        guard let engine = try? AetherEngine() else { return nil }
        self.engine = engine
        self.playerView = AetherPlayerView()
        self.playerView.backgroundColor = .clear
        self.playerView.clipsToBounds = true
        self.engine.ownsVideoNowPlayingSession = false
        self.engine.nativeAudioSessionActivationEnabled = true
        self.engine.videoGravity = .resizeAspectFill
        self.engine.bind(view: self.playerView)
    }

    func rebindSurface() {
        engine.videoGravity = .resizeAspectFill
        engine.bind(view: playerView)
    }

    func load(url: URL, headers: [String: String], channelID: String, onFirstFrame: @escaping () -> Void) {
        stop()
        generation &+= 1
        let gen = generation
        activeChannelID = channelID

        rebindSurface()
        PlaybackAudioSession.activateMoviePlayback()

        var didNotify = false
        readinessCancellable = engine.$hasFirstFrameReadyForDisplay
            .removeDuplicates()
            .sink { [weak self] isReady in
                guard let self, self.generation == gen, isReady, !didNotify else { return }
                didNotify = true
                onFirstFrame()
            }

        let options = LoadOptions(
            displayCriteriaOwner: .host,
            httpHeaders: headers,
            matchContentEnabled: false,
            isLive: true,
            liveJoinProfile: .fastZap,
            liveStartupGraceSeconds: 0.5,
            liveStartupSingleSegmentMinimumSeconds: 1.5,
            liveEdgeCushionSeconds: 3.0,
            liveJoinStartsImmediately: true,
            nativeRemoteHLS: false,
            generatesBackgroundScrubPreviews: false,
            confirmAtmos: false,
            retainsSessionCacheAfterStop: false,
            progressiveSegmentDelivery: false,
            autoplay: true
        )

        loadTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled, self.generation == gen else { return }
            do {
                _ = try await self.engine.load(url: url, options: options)
                guard !Task.isCancelled, self.generation == gen else { return }
                self.engine.play()
            } catch {
                return
            }
        }
    }

    func stop() {
        generation &+= 1
        loadTask?.cancel()
        loadTask = nil
        readinessCancellable?.cancel()
        readinessCancellable = nil
        activeChannelID = nil
        engine.stop(resetDisplayCriteria: false)
    }
}

private struct IPTVAetherVideoSurface: UIViewRepresentable {
    let controller: IPTVInlineAetherPreviewController

    func makeUIView(context: Context) -> AetherPlayerView {
        controller.rebindSurface()
        return controller.playerView
    }

    func updateUIView(_ uiView: AetherPlayerView, context: Context) {
        controller.rebindSurface()
    }
}

struct IPTVVideoSurface: UIViewRepresentable {
    let player: AVPlayer
    var videoGravity: AVLayerVideoGravity = .resizeAspectFill
    var onLayerAvailable: ((AVPlayerLayer) -> Void)? = nil
    let onFirstFrame: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFirstFrame: onFirstFrame)
    }

    func makeUIView(context: Context) -> TrailerPlayerLayerView {
        let view = TrailerPlayerLayerView()
        view.playerLayer.videoGravity = videoGravity
        view.playerLayer.player = player
        if let onLayerAvailable {
            let layer = view.playerLayer
            DispatchQueue.main.async {
                onLayerAvailable(layer)
            }
        }
        context.coordinator.observe(view.playerLayer, player: player)
        return view
    }

    func updateUIView(_ view: TrailerPlayerLayerView, context: Context) {
        context.coordinator.onFirstFrame = onFirstFrame
        view.playerLayer.videoGravity = videoGravity
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
            context.coordinator.observe(view.playerLayer, player: player)
        }
    }

    static func dismantleUIView(_ view: TrailerPlayerLayerView, coordinator: Coordinator) {
        coordinator.stopObserving()
        view.playerLayer.player = nil
    }

    final class Coordinator {
        var onFirstFrame: () -> Void
        private var readinessObservation: NSKeyValueObservation?
        private weak var observedLayer: AVPlayerLayer?
        private weak var observedPlayer: AVPlayer?
        private var didReportFrame = false

        init(onFirstFrame: @escaping () -> Void) {
            self.onFirstFrame = onFirstFrame
        }

        func observe(_ layer: AVPlayerLayer, player: AVPlayer) {
            stopObserving()
            observedLayer = layer
            observedPlayer = player
            didReportFrame = false
            readinessObservation = layer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self, weak layer] _, _ in
                DispatchQueue.main.async { [weak self, weak layer] in
                    guard let self, let layer,
                          self.observedLayer === layer,
                          let player = self.observedPlayer,
                          layer.player === player,
                          layer.isReadyForDisplay,
                          !self.didReportFrame else { return }
                    self.didReportFrame = true
                    self.onFirstFrame()
                }
            }
        }

        func stopObserving() {
            readinessObservation?.invalidate()
            readinessObservation = nil
            observedLayer = nil
            observedPlayer = nil
        }
    }
}

private struct IPTVGlassSearchField: View {
    @Binding var text: String
    let placeholder: String
    var isFocused: FocusState<Bool>.Binding

    @State private var isEditing = false

    var body: some View {
        ZStack(alignment: .leading) {
            HiddenIPTVTextField(
                text: $text,
                isEditing: $isEditing,
                placeholder: placeholder,
                returnKeyType: .search
            )
            .frame(width: 1, height: 1)
            .offset(x: -4_000)
            .allowsHitTesting(false)

            Button {
                isFocused.wrappedValue = true
                isEditing = true
            } label: {
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PosterCardButtonStyle())
            .focused(isFocused)
            .focusEffectDisabledIfAvailable()

            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))

                Text(text.isEmpty ? placeholder : text)
                    .font(.system(size: 19, weight: .regular))
                    .foregroundColor(text.isEmpty ? .white.opacity(0.45) : .white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .allowsHitTesting(false)

                Spacer(minLength: 0)

                if !text.isEmpty {
                    Button {
                        text = ""
                        isFocused.wrappedValue = true
                        isEditing = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 20))
                            .foregroundColor(.white.opacity(0.55))
                    }
                    .buttonStyle(PosterCardButtonStyle())
                    .focusEffectDisabledIfAvailable()
                }
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 56)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(GlassCapsule(focused: isFocused.wrappedValue || isEditing))
    }
}

private struct IPTVSettingsGroup<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.appFont(size: 28, weight: .bold))
                    .foregroundColor(.white)

                Text(subtitle)
                    .font(.appFont(size: 18, weight: .medium))
                    .foregroundColor(.white.opacity(0.56))
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 12) {
                content
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .iptvSettingsGlass(shape: RoundedRectangle(cornerRadius: 32, style: .continuous), isProminent: false)
        .overlay(
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
    }
}

private struct IPTVRowShell<Content: View>: View {
    let isFocused: Bool
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 16) {
            content
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(minHeight: 74)
        .iptvSettingsGlass(shape: RoundedRectangle(cornerRadius: 24, style: .continuous), isProminent: false)
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(isFocused ? AppFocusOutline.color : Color.white.opacity(0.10), lineWidth: isFocused ? AppFocusOutline.width : 1)
        )
        .animation(.easeOut(duration: 0.18), value: isFocused)
    }
}

private struct IPTVChoiceRow: View {
    let title: String
    @Binding var selection: String
    let options: [String]

    @FocusState private var isFocused: Bool
    @State private var showOptions = false

    var body: some View {
        Button { showOptions = true } label: {
            IPTVRowShell(isFocused: isFocused) {
                Text(title)
                    .font(.appFont(size: 22, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)

                Spacer(minLength: 24)

                HStack(spacing: 10) {
                    Text(selection)
                        .font(.appFont(size: 19, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.76)

                    Image(systemName: "chevron.down")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(.white)
                }
                .frame(maxWidth: 280, alignment: .trailing)
            }
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($isFocused)
        .focusEffectDisabledIfAvailable()
        .confirmationDialog(title, isPresented: $showOptions, titleVisibility: .visible) {
            ForEach(options, id: \.self) { option in
                Button(option) { selection = option }
            }
        }
    }
}

private struct IPTVDialogButton: View {
    let title: String
    let isPrimary: Bool
    var enabled: Bool = true
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 21, weight: .bold))
                .foregroundColor(isPrimary ? .black : .white)
                .padding(.horizontal, 28)
                .padding(.vertical, 14)
                .background(Capsule().fill(backgroundColor))
                .overlay(
                    Capsule().strokeBorder(isFocused ? AppFocusOutline.color : Color.clear, lineWidth: 2)
                )
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($isFocused)
        .focusEffectDisabledIfAvailable()
        .disabled(isPrimary && !enabled)
    }

    private var backgroundColor: Color {
        guard isPrimary else { return Color.white.opacity(0.12) }
        guard enabled else { return Color.white.opacity(0.3) }
        return Color.white.opacity(isFocused ? 0.9 : 0.75)
    }
}

private struct IPTVConfiguredSourceRow: View {
    let source: IPTVSource
    let kindLabel: String
    let isActiveSource: Bool
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @FocusState private var isRowFocused: Bool
    @FocusState private var isEditFocused: Bool
    @FocusState private var isDeleteFocused: Bool

    var body: some View {
        HStack(spacing: 14) {
            Button(action: onSelect) {
                IPTVRowShell(isFocused: isRowFocused) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(source.name)
                            .font(.appFont(size: 22, weight: .semibold))
                            .foregroundColor(.white)
                            .lineLimit(1)

                        Text(kindLabel)
                            .font(.appFont(size: 17, weight: .medium))
                            .foregroundColor(.white.opacity(0.56))
                            .lineLimit(1)
                    }

                    Spacer(minLength: 24)

                    HStack(spacing: 10) {
                        if isActiveSource {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 10, height: 10)
                            Text(L10n.string("iptv_source_active", fallback: "Active"))
                                .font(.appFont(size: 19, weight: .bold))
                                .foregroundColor(.white)
                        } else {
                            Text(L10n.string("iptv_source_switch", fallback: "Switch"))
                                .font(.appFont(size: 19, weight: .bold))
                                .foregroundColor(.white)
                            Image(systemName: "arrow.left.arrow.right")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(.white.opacity(0.75))
                        }
                    }
                }
            }
            .buttonStyle(PosterCardButtonStyle())
            .focused($isRowFocused)
            .focusEffectDisabledIfAvailable()

            Button(action: onEdit) {
                Image(systemName: isEditFocused ? "pencil.circle.fill" : "pencil.circle")
                    .font(.system(size: 32))
                    .foregroundColor(isEditFocused ? .white : .white.opacity(0.6))
                    .frame(width: 60, height: 60)
            }
            .buttonStyle(PosterCardButtonStyle())
            .focused($isEditFocused)
            .focusEffectDisabledIfAvailable()
            .accessibilityLabel(L10n.string("iptv_edit", fallback: "Edit"))

            Button(role: .destructive, action: onDelete) {
                Image(systemName: isDeleteFocused ? "trash.circle.fill" : "trash.circle")
                    .font(.system(size: 32))
                    .foregroundColor(isDeleteFocused ? .red : .white.opacity(0.6))
                    .frame(width: 60, height: 60)
            }
            .buttonStyle(PosterCardButtonStyle())
            .focused($isDeleteFocused)
            .focusEffectDisabledIfAvailable()
            .accessibilityLabel(L10n.string("action_delete", fallback: "Delete"))
        }
    }
}

private extension View {
    @ViewBuilder
    func iptvSettingsGlass<S: InsettableShape>(shape: S, isProminent: Bool) -> some View {
        if #available(tvOS 26.0, *), AppleTVCapability.current.supportsLiquidGlass {
            self
                .background(isProminent ? Color.white.opacity(0.13) : Color.white.opacity(0.045), in: shape)
                .glassEffect(.regular, in: shape)
        } else {
            self.background(
                (isProminent ? Color.white.opacity(0.18) : Color.white.opacity(0.07)),
                in: shape
            )
        }
    }
}

private struct IPTVFormTextFieldRow: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    var isSecure: Bool = false
    var keyboardType: UIKeyboardType = .default
    var autocapitalizationType: UITextAutocapitalizationType = .none

    @FocusState private var isFocused: Bool
    @State private var isEditing = false

    var body: some View {
        Button {
            isEditing = true
        } label: {
            IPTVRowShell(isFocused: isFocused || isEditing) {
                Text(title)
                    .font(.appFont(size: 22, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)

                Spacer(minLength: 24)

                ZStack(alignment: .leading) {
                    HiddenIPTVTextField(
                        text: $text,
                        isEditing: $isEditing,
                        placeholder: placeholder,
                        isSecure: isSecure,
                        keyboardType: keyboardType,
                        autocapitalizationType: autocapitalizationType
                    )
                    .frame(width: 1, height: 1)
                    .offset(x: -4_000)
                    .allowsHitTesting(false)

                    Text(displayText)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(text.isEmpty ? .white.opacity(0.45) : .white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, alignment: text.isEmpty ? .center : .leading)
                        .padding(.horizontal, text.isEmpty ? 8 : 16)
                        .allowsHitTesting(false)
                }
                .frame(width: 480, height: 48)
                .modifier(GlassCapsule(focused: isFocused || isEditing))
            }
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($isFocused)
        .focusEffectDisabledIfAvailable()
    }

    private var displayText: String {
        guard !text.isEmpty else { return placeholder }
        return isSecure ? String(repeating: "•", count: text.count) : text
    }
}

private struct HiddenIPTVTextField: UIViewRepresentable {
    @Binding var text: String
    @Binding var isEditing: Bool
    var placeholder: String = ""
    var isSecure: Bool = false
    var keyboardType: UIKeyboardType = .default
    var returnKeyType: UIReturnKeyType = .done
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var onCommit: () -> Void = {}

    func makeUIView(context: Context) -> HiddenIPTVUITextField {
        let textField = HiddenIPTVUITextField(frame: .zero)
        textField.delegate = context.coordinator
        textField.backgroundColor = .clear
        textField.textColor = .clear
        textField.tintColor = .clear
        textField.keyboardAppearance = .dark
        textField.autocorrectionType = .no
        textField.placeholder = placeholder
        textField.isSecureTextEntry = isSecure
        textField.keyboardType = keyboardType
        textField.returnKeyType = returnKeyType
        textField.autocapitalizationType = autocapitalizationType
        textField.addTarget(
            context.coordinator,
            action: #selector(Coordinator.textDidChange(_:)),
            for: .editingChanged
        )
        return textField
    }

    func updateUIView(_ uiView: HiddenIPTVUITextField, context: Context) {
        context.coordinator.update(text: $text, isEditing: $isEditing, onCommit: onCommit)
        if !uiView.isFirstResponder {
            if uiView.text != text {
                uiView.text = text
            }
            if uiView.placeholder != placeholder {
                uiView.placeholder = placeholder
            }
            if uiView.isSecureTextEntry != isSecure {
                uiView.isSecureTextEntry = isSecure
            }
            if uiView.keyboardType != keyboardType {
                uiView.keyboardType = keyboardType
            }
            if uiView.returnKeyType != returnKeyType {
                uiView.returnKeyType = returnKeyType
            }
            if uiView.autocapitalizationType != autocapitalizationType {
                uiView.autocapitalizationType = autocapitalizationType
            }
        }

        if isEditing && !uiView.isFirstResponder {
            context.coordinator.activateIfNeeded(uiView)
        } else if !isEditing {
            context.coordinator.cancelPendingActivation()
            if uiView.isFirstResponder {
                DispatchQueue.main.async {
                    if uiView.isFirstResponder {
                        uiView.resignFirstResponder()
                    }
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, isEditing: $isEditing, onCommit: onCommit)
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        private var text: Binding<String>
        private var isEditing: Binding<Bool>
        private var onCommit: () -> Void
        private var committedCurrentEditingSession = false
        private var isActivating = false
        private var pendingActivationGeneration: UInt = 0

        init(text: Binding<String>, isEditing: Binding<Bool>, onCommit: @escaping () -> Void) {
            self.text = text
            self.isEditing = isEditing
            self.onCommit = onCommit
        }

        func update(text: Binding<String>, isEditing: Binding<Bool>, onCommit: @escaping () -> Void) {
            self.text = text
            self.isEditing = isEditing
            self.onCommit = onCommit
        }

        func activateIfNeeded(_ textField: UITextField, attempt: Int = 0) {
            guard isEditing.wrappedValue, !textField.isFirstResponder else {
                cancelPendingActivation()
                return
            }
            if attempt == 0 {
                guard !isActivating else { return }
                isActivating = true
                pendingActivationGeneration &+= 1
            }
            let generation = pendingActivationGeneration
            let delay: TimeInterval = attempt == 0 ? 0.02 : 0.08
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak textField] in
                guard let self, let textField,
                      self.pendingActivationGeneration == generation,
                      self.isEditing.wrappedValue else {
                    self?.isActivating = false
                    return
                }
                if textField.isFirstResponder {
                    self.isActivating = false
                    return
                }
                if textField.window != nil, textField.becomeFirstResponder() {
                    self.isActivating = false
                    return
                }
                if attempt < 10 {
                    self.activateIfNeeded(textField, attempt: attempt + 1)
                } else {
                    self.isActivating = false
                    self.isEditing.wrappedValue = false
                }
            }
        }

        func cancelPendingActivation() {
            guard isActivating else { return }
            isActivating = false
            pendingActivationGeneration &+= 1
        }

        @objc func textDidChange(_ sender: UITextField) {
            text.wrappedValue = sender.text ?? ""
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            isActivating = false
            committedCurrentEditingSession = false
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            commit(textField)
            textField.resignFirstResponder()
            return true
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            commit(textField)
        }

        private func commit(_ textField: UITextField) {
            cancelPendingActivation()
            text.wrappedValue = textField.text ?? ""
            isEditing.wrappedValue = false
            guard !committedCurrentEditingSession else { return }
            committedCurrentEditingSession = true
            onCommit()
        }
    }
}

private final class HiddenIPTVUITextField: UITextField {
    override var canBecomeFocused: Bool { false }
}
