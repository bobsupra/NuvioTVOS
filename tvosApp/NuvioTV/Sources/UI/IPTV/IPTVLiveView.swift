import SwiftUI
import Combine
import AVKit
import Darwin
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
    let onPlay: (URL, NuvioMeta, [String: String]) -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var inlinePreviewPlayer: AVPlayer?
    @State private var inlinePreviewIsReady = false
    @State private var inlinePreviewChannelID: String?
    @State private var fullscreenPreview: IPTVFullscreenPreview?
    @State private var isFullscreenPreviewTransitionActive = false
    @State private var fullscreenReturnChannelID: String?
    @FocusState private var isPreviewButtonFocused: Bool
    @FocusState private var isChannelSearchFocused: Bool
    @FocusState private var isCategoryNameFocused: Bool
    @FocusState private var focusedCategoryRowID: String?
    @FocusState private var guideFocusTarget: GuideFocusTarget?
    @FocusState private var focusedChannelRowID: String?
    @State private var lastFocusedFavoriteChannelID: String?
    @State private var favoritesFocusRequestID = UUID()
    @State private var favoritesFocusTargetID: String?

    // MARK: - Navigation & Filters
    @State private var activeSidebarItem: IPTVNavTab = .liveTV
    @State private var selectedCategory: String = "Alle"
    @State private var showingHiddenCategories = false
    @State private var renamingCategoryID: String?
    @State private var categoryNameDraft = ""
    @State private var categoryPreferences = IPTVCategoryPreferences.empty
    @State private var showingCredentialsModal = false

    // MARK: - Sources & Core Data
    @State private var sources: [IPTVSource] = []
    @State private var sourcesLoaded = false
    @State private var channels: [IPTVChannel] = []
    @State private var stalkerChannels: [IPTVStalkerChannel] = []
    @State private var stalkerClient: IPTVStalkerClient?
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
    @State private var requestID = UUID()
    @State private var guideTask: Task<Void, Never>?
    @State private var guideByChannel: [String: [IPTVProgramme]] = [:]
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
    @State private var guideTimelineWidth: CGFloat = 1
    @State private var guideTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
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
    private let guideChannelColumnWidth: CGFloat = 232
    private let guideProgrammeGap: CGFloat = 3
    private let guideProgrammeMinimumFocusWidth: CGFloat = 24
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

    private enum GuideFocusTarget: Hashable {
        case programme(channelID: String, start: Date)
        case control(GuideControl)
        case sidebar(IPTVNavTab)
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

    var body: some View {
        let visibleChannels = filteredDisplayChannels
        let previewURL = activeSelectedChannel.flatMap { eligibleInlinePreviewURL(for: $0) }

        return ZStack {
            // Background
            Color(red: 0.05, green: 0.05, blue: 0.07)
                .ignoresSafeArea()

            HStack(alignment: .top, spacing: 28) {
                // MARK: 1. Left Sidebar Navigation
                sidebarView
                    .frame(width: 260)
                    .frame(maxHeight: .infinity)

                // MARK: 2. Main Content Area
                VStack(alignment: .leading, spacing: 14) {
                    // Top Category Filter Pills
                    categoryPillsRow

                    if activeSidebarItem == .guide {
                        timeGuideView(channels: visibleChannels)
                    } else {
                        // Two-column content: Channel List + Detail & Schedule Stack
                        HStack(alignment: .top, spacing: 20) {
                            // Left Column: Channel List Card
                            channelListCard(channels: visibleChannels)
                                .frame(width: 415)
                                .frame(maxHeight: .infinity)

                            // Right Column: Preview + Schedule
                            VStack(alignment: .leading, spacing: 14) {
                                livePlayerPreviewCard
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                scheduleEPGCard
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
            guard !isFullscreenPreviewTransitionActive, inlinePreviewPlayer == nil else { return }
            restoreSources()
        }
        .onChange(of: selectedID) { _, sourceID in
            selectedCategory = "Alle"
            showingHiddenCategories = false
            cancelCategoryRename()
            loadCategoryPreferences(for: sourceID)
        }
        .onReceive(guideClock) { now in
            guideNow = now
            refreshGuideIfDue(now: now)
        }
        .onChange(of: previewURL, initial: true) { _, url in
            if let url, let player = inlinePreviewPlayer,
               inlinePreviewItemIsForSameURL(player, url: url) { return }
            stopInlinePreview()
            guard let url else { return }
            let player = AVPlayer(url: url)
            PlaybackAudioSession.activateMoviePlayback()
            player.isMuted = false
            inlinePreviewIsReady = false
            inlinePreviewPlayer = player
            player.play()
        }
        .onDisappear {
            if isFullscreenPreviewTransitionActive && isActive && scenePhase == .active { return }
            inlinePreviewChannelID = nil
            stopInlinePreview()
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
                onTrailerReady: {},
                onDismiss: requestFullscreenPreviewDismissal
            )
            .ignoresSafeArea()
        }
    }

    // MARK: - Navigation Tabs
    enum IPTVNavTab: String, CaseIterable {
        case search = "Søk"
        case liveTV = "Live TV"
        case sportsNow = "Sport nå"
        case guide = "TV-guide"
        case channels = "Kanalliste"
        case favorites = "Favoritter"
        case categories = "Kategorier"
        case recent = "Nylig sett"
        case settings = "Innstillinger"

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

    // MARK: - Sidebar View
    private var sidebarView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Live TV")
                .font(.system(size: 38, weight: .bold))
                .foregroundColor(.white)
                .padding(.bottom, 22)
                .padding(.leading, 10)

            ForEach(IPTVNavTab.allCases, id: \.self) { tab in
                Button {
                    handleSidebarSelection(tab)
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 23, weight: .semibold))
                            .frame(width: 24)
                        Text(tab.rawValue)
                            .font(.system(size: 22, weight: activeSidebarItem == tab ? .semibold : .medium))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                        Spacer()
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
                .focused($guideFocusTarget, equals: .sidebar(tab))
            }

            Spacer()

            if loading {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Laster kilde...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.leading, 8)
            }
        }
        .focusSection()
    }

    private func handleSidebarSelection(_ tab: IPTVNavTab) {
        activeSidebarItem = tab
        showingHiddenCategories = false
        cancelCategoryRename()
        switch tab {
        case .search:
            selectedCategory = "Alle"
            DispatchQueue.main.async { isChannelSearchFocused = true }
        case .liveTV:
            selectedCategory = "Alle"
        case .sportsNow:
            selectedCategory = "Alle"
        case .guide:
            selectedCategory = "Alle"
            guidePageStartOverride = nil
            selectedGuideProgramme = nil
            selectedGuideChannelID = nil
            Task { @MainActor in
                await Task.yield()
                guard isActive, activeSidebarItem == .guide else { return }
                guideFocusTarget = .control(.now)
            }
        case .channels:
            selectedCategory = "Alle"
        case .favorites:
            selectedCategory = "Alle"
            focusFavoriteChannelAfterSidebarSelection()
        case .categories:
            selectedCategory = "Alle"
        case .recent:
            selectedCategory = "Alle"
        case .settings:
            showingCredentialsModal = true
        }
    }

    private func focusFavoriteChannelAfterSidebarSelection() {
        let visibleFavorites = filteredDisplayChannels
        guard !visibleFavorites.isEmpty else { return }
        let targetID = visibleFavorites.first(where: { $0.id == lastFocusedFavoriteChannelID })?.id
            ?? visibleFavorites.first(where: { $0.id == selectedChannelID })?.id
            ?? visibleFavorites.first?.id
        guard let targetID else { return }
        favoritesFocusTargetID = targetID
        favoritesFocusRequestID = UUID()
    }

    // MARK: - Category Filter Pills
    private var categoryPillsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(allCategories, id: \.self) { category in
                    Button {
                        selectedCategory = category
                    } label: {
                        Text(category == "Alle" ? "Alle" : categoryDisplayName(category))
                            .font(.system(size: 20, weight: selectedCategory == category ? .bold : .medium))
                            .foregroundColor(selectedCategory == category ? .black : .white)
                            .padding(.horizontal, 22)
                            .padding(.vertical, 12)
                            .background(
                                Capsule()
                                    .fill(selectedCategory == category ? Color.white : Color.white.opacity(0.12))
                            )
                            .overlay(IPTVFocusOutline(
                                shape: Capsule(),
                                color: selectedCategory == category ? Color.black.opacity(0.8) : nil
                            ))
                    }
                    .buttonStyle(PosterCardButtonStyle())
                }
            }
            .padding(.vertical, 2)
        }
        .frame(height: 56)
    }

    private var allCategories: [String] {
        ["Alle"] + orderedCategoryGroups
    }

    private var orderedCategoryGroups: [String] {
        IPTVCategoryPreferencesStore.orderedGroups(
            baseCategoryGroups,
            preferences: categoryPreferences
        )
    }

    private var baseCategoryGroups: [String] {
        availableGroups.filter { $0 != "Alle" }
    }

    private func categoryDisplayName(_ groupID: String) -> String {
        categoryPreferences.customNames[groupID] ?? groupID
    }

    private func isCategoryHidden(_ groupID: String?) -> Bool {
        guard let groupID else { return false }
        return categoryPreferences.hiddenGroupIDs.contains(groupID)
    }

    private func loadCategoryPreferences(for sourceID: UUID?) {
        guard let sourceID else {
            categoryPreferences = .empty
            return
        }
        categoryPreferences = IPTVCategoryPreferencesStore.load(
            defaults: ProfileSettings.store(for: profileID),
            sourceID: sourceID
        )
    }

    // MARK: - Time-based Programme Guide
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

    private func guideRows(from visibleChannels: [IPTVDisplayChannel], between start: Date, and end: Date) -> [IPTVGuideDisplayRow] {
        var sourceChannelsByID: [String: IPTVChannel] = [:]
        for channel in channels where sourceChannelsByID[channel.id] == nil {
            sourceChannelsByID[channel.id] = channel
        }

        return visibleChannels.compactMap { displayChannel in
            guard let sourceChannel = sourceChannelsByID[displayChannel.id],
                  let guideID = sourceChannel.guideID,
                  let programmes = guideByChannel[guideID] else { return nil }
            let visibleProgrammes = programmes.filter { $0.start < end && $0.end > start }
            guard !visibleProgrammes.isEmpty else { return nil }
            return IPTVGuideDisplayRow(channel: displayChannel, programmes: visibleProgrammes)
        }
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

    private func timeGuideView(channels visibleChannels: [IPTVDisplayChannel]) -> some View {
        let pageStart = guidePageStart
        let pageEnd = guidePageEnd
        let rows = guideRows(from: visibleChannels, between: pageStart, and: pageEnd)
        let hasGuideIDs = channels.contains { $0.guideID != nil }

        return GeometryReader { geometry in
            let panelContentWidth = geometry.size.width.isFinite ? max(1, geometry.size.width - 24) : 1
            let rowContentWidth = max(1, panelContentWidth - 20)
            let channelColumnWidth = min(guideChannelColumnWidth, max(1, rowContentWidth - 1))
            let timelineWidth = max(1, rowContentWidth - channelColumnWidth)

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("TV-guide")
                            .font(.system(size: 30, weight: .bold))
                            .foregroundColor(.white)
                        Text("\(guideDateRange(start: pageStart, end: pageEnd))  •  \(formatTimeRange(start: pageStart, end: pageEnd))  •  \(rows.count) kanaler")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(.white.opacity(0.62))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }

                    Spacer(minLength: 12)
                    guidePageButton("Tidligere", icon: "chevron.left", enabled: canBrowseGuideEarlier, focusTarget: .control(.earlier)) {
                        moveGuidePage(by: -guidePageDuration)
                    }
                    guidePageButton("Nå", icon: "dot.circle", enabled: true, focusTarget: .control(.now)) {
                        guidePageStartOverride = nil
                    }
                    guidePageButton("Senere", icon: "chevron.right", enabled: canBrowseGuideLater, focusTarget: .control(.later)) {
                        moveGuidePage(by: guidePageDuration)
                    }
                }

                if guideTask != nil {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Laster programguide…")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(.white.opacity(0.72))
                    }
                } else if guideFailures > 0 {
                    HStack(spacing: 14) {
                        Text("Noen programguide-feeder kunne ikke lastes.")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(.white.opacity(0.72))
                        guidePageButton("Prøv igjen", icon: "arrow.clockwise", enabled: !selectedGuideURLs.isEmpty, focusTarget: .control(.retrySummary)) {
                            retryGuide()
                            guideFocusTarget = .control(.now)
                        }
                    }
                }

                if selectedGuideProgramme != nil {
                    selectedGuideProgrammeCard(timelineWidth: timelineWidth)
                }

                if selectedGuideURLs.isEmpty {
                    guideEmptyState("Ingen TV-guide er konfigurert for denne kilden.", icon: "calendar.badge.exclamationmark")
                } else if !hasGuideIDs {
                    guideEmptyState("Kilden har ingen kanaler med EPG-ID.", icon: "tv.slash")
                } else {
                    VStack(spacing: 6) {
                        guideTimeAxis(start: pageStart, width: timelineWidth, channelColumnWidth: channelColumnWidth)

                        if rows.isEmpty {
                            if guideTask != nil {
                                guideEmptyState("Venter på programdata…", icon: "clock")
                            } else if guideUnavailable {
                                HStack(spacing: 14) {
                                    guideEmptyState("Programguiden er utilgjengelig.", icon: "wifi.slash")
                                        guidePageButton("Prøv igjen", icon: "arrow.clockwise", enabled: true, focusTarget: .control(.retryEmpty)) {
                                        retryGuide()
                                            guideFocusTarget = .control(.now)
                                    }
                                }
                            } else {
                                guideEmptyState("Ingen programinformasjon i dette tidsrommet.", icon: "calendar")
                            }
                        } else {
                            ScrollView(.vertical, showsIndicators: false) {
                                LazyVStack(spacing: 6) {
                                    ForEach(rows) { row in
                                        guideChannelRow(
                                            row,
                                            start: pageStart,
                                            end: pageEnd,
                                            timelineWidth: timelineWidth,
                                            channelColumnWidth: channelColumnWidth
                                        )
                                    }
                                }
                                .padding(.bottom, 8)
                            }
                        }
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 18)
                            .fill(Color(red: 0.08, green: 0.08, blue: 0.11))
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
            .onChange(of: guideFocusTarget) { oldTarget, newTarget in
                guard case let .programme(channelID, start) = oldTarget,
                      newTarget == nil,
                      activeSidebarItem == .guide else { return }
                Task { @MainActor in
                    await Task.yield()
                    guard isActive, activeSidebarItem == .guide, guideFocusTarget == nil,
                          !guideProgrammeFocusIsAvailable(channelID: channelID, start: start, timelineWidth: timelineWidth) else { return }
                    guideFocusTarget = .control(.now)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .accessibilityHint(enabled ? "" : "Ikke tilgjengelig")
    }

    private func guideTimeAxis(start: Date, width: CGFloat, channelColumnWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            Text("Kanal")
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
                channelBadgeView(channel: row.channel, size: CGSize(width: 48, height: 42))
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
                selectChannelForPreview(row.channel)
                activeSidebarItem = .liveTV
                selectedGuideProgramme = nil
                selectedGuideChannelID = nil
                focusPreviewAfterGuideTune(channelID: row.channel.id)
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
        guard let channel = channels.first(where: { $0.id == channelID }),
              selectedCategory == "Alle" || channel.group == selectedCategory,
              !isCategoryHidden(channel.group),
              let guideID = channel.guideID,
              let programmes = guideByChannel[guideID] else { return false }
        let visibleProgrammes = programmes.filter { $0.start < pageEnd && $0.end > pageStart }
        return guideProgrammeSpans(programmes: visibleProgrammes, start: pageStart, end: pageEnd, timelineWidth: timelineWidth)
            .contains { $0.programme.start == start && $0.isFocusable }
    }

    private func selectedGuideProgrammeCard(timelineWidth: CGFloat) -> some View {
        let channelName = channels.first(where: { $0.id == selectedGuideChannelID })?.name ?? ""
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
            guidePageButton("Lukk", icon: "xmark", enabled: true, focusTarget: .control(.detailsClose)) {
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
            guard isActive, activeSidebarItem == .guide else { return }
            if let channelID, let programmeStart,
               guideProgrammeFocusIsAvailable(channelID: channelID, start: programmeStart, timelineWidth: timelineWidth) {
                guideFocusTarget = .programme(channelID: channelID, start: programmeStart)
            } else {
                guideFocusTarget = .control(.now)
            }
        }
    }

    private func handleGuideBackCommand(timelineWidth: CGFloat) {
        guard activeSidebarItem == .guide else { return }
        if selectedGuideProgramme != nil {
            let channelID = selectedGuideChannelID
            let programmeStart = selectedGuideProgramme?.start
            selectedGuideProgramme = nil
            selectedGuideChannelID = nil
            restoreGuideFocusAfterDetailsClose(channelID: channelID, programmeStart: programmeStart, timelineWidth: timelineWidth)
            return
        }

        returnToLiveTVSidebar()
    }

    private func returnToLiveTVSidebar() {
        handleSidebarSelection(.liveTV)
        Task { @MainActor in
            await Task.yield()
            guard isActive, activeSidebarItem == .liveTV else { return }
            guideFocusTarget = .sidebar(.liveTV)
        }
    }

    private func focusPreviewAfterGuideTune(channelID: String) {
        Task { @MainActor in
            await Task.yield()
            guard isActive, scenePhase == .active, activeSidebarItem == .liveTV,
                  selectedChannelID == channelID, inlinePreviewChannelID == channelID else { return }
            isPreviewButtonFocused = true
        }
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

    private func guideDateRange(start: Date, end: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        let startDate = formatter.string(from: start)
        let endDate = formatter.string(from: end.addingTimeInterval(-1))
        return startDate == endDate ? startDate : "\(startDate) – \(endDate)"
    }

    // MARK: - Left Column: Channel List Card ("Alle kanaler")
    private func channelListCard(channels visibleChannels: [IPTVDisplayChannel]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // Card Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(sectionTitle)
                        .font(.system(size: 23, weight: .bold))
                        .foregroundColor(.white)
                    Text(isChoosingCategory ? "\(categoryChooserGroups.count) kategorier" : "\(visibleChannels.count) kanaler")
                        .font(.system(size: 16))
                        .foregroundColor(Color.white.opacity(0.5))
                }
                Spacer()
                if isChoosingCategory && hasHiddenCategoryGroups {
                    Button(showingHiddenCategories ? "Skjul skjulte" : "Vis skjulte") {
                        showingHiddenCategories.toggle()
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
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.white.opacity(0.55))
                    TextField("Søk etter kanal eller program", text: $searchText)
                        .font(.system(size: 20))
                        .foregroundColor(.white)
                        .focused($isChannelSearchFocused)
                        .submitLabel(.search)
                }
                .padding(.horizontal, 16)
                .frame(height: 56)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.08)))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(isChannelSearchFocused ? AppFocusOutline.color : .clear, lineWidth: AppFocusOutline.width)
                )
                .padding(.horizontal, 14)
                .onAppear { DispatchQueue.main.async { isChannelSearchFocused = true } }
            }

            // Channels List
            ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 6) {
                    if isChoosingCategory {
                        ForEach(Array(categoryChooserGroups.enumerated()), id: \.element) { index, group in
                            if renamingCategoryID == group {
                                HStack {
                                    TextField("Nytt navn", text: $categoryNameDraft)
                                        .font(.system(size: 18, weight: .medium))
                                        .foregroundColor(.white)
                                        .focused($isCategoryNameFocused)
                                        .submitLabel(.done)
                                        .onSubmit { saveCategoryRename(for: group) }
                                    Button {
                                        saveCategoryRename(for: group)
                                    } label: {
                                        Image(systemName: "checkmark")
                                            .frame(width: 38, height: 42)
                                    }
                                    .buttonStyle(PosterCardButtonStyle())
                                    Button {
                                        cancelCategoryRename(restoreFocus: true)
                                    } label: {
                                        Image(systemName: "xmark")
                                            .frame(width: 38, height: 42)
                                    }
                                    .buttonStyle(PosterCardButtonStyle())
                                }
                                .font(.system(size: 19, weight: .medium))
                                .foregroundColor(.white.opacity(0.88))
                                .padding(.horizontal, 16)
                                .frame(maxWidth: .infinity, minHeight: 66, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.055)))
                                .overlay(IPTVFocusOutline(shape: RoundedRectangle(cornerRadius: 12)))
                            } else {
                                Button {
                                    if isCategoryHidden(group) {
                                        setCategoryHidden(false, groupID: group)
                                    } else {
                                        selectedCategory = group
                                    }
                                } label: {
                                    HStack {
                                        Text(categoryDisplayName(group)).lineLimit(1)
                                        Spacer()
                                        if isCategoryHidden(group) {
                                            Label("Skjult", systemImage: "eye.slash")
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
                                    .frame(maxWidth: .infinity, minHeight: 66, alignment: .leading)
                                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.055)))
                                    .overlay(IPTVFocusOutline(shape: RoundedRectangle(cornerRadius: 12)))
                                }
                                .buttonStyle(PosterCardButtonStyle())
                                .focused($focusedCategoryRowID, equals: group)
                                .accessibilityHint(isCategoryHidden(group) ? "Viser kategorien igjen" : "Åpner kategorien")
                                .contextMenu {
                                    Button("Flytt opp", systemImage: "arrow.up") {
                                        moveCategory(group, by: -1)
                                    }
                                    .disabled(index == 0)

                                    Button("Flytt ned", systemImage: "arrow.down") {
                                        moveCategory(group, by: 1)
                                    }
                                    .disabled(index >= categoryChooserGroups.count - 1)

                                    Button(
                                        isCategoryHidden(group) ? "Vis kategori" : "Skjul kategori",
                                        systemImage: isCategoryHidden(group) ? "eye" : "eye.slash"
                                    ) {
                                        setCategoryHidden(!isCategoryHidden(group), groupID: group)
                                    }

                                    Button("Gi nytt navn", systemImage: "pencil") {
                                        beginCategoryRename(group)
                                    }
                                }
                            }
                        }
                    } else if visibleChannels.isEmpty {
                        Text(emptySectionMessage)
                            .font(.system(size: 19, weight: .medium))
                            .foregroundColor(.white.opacity(0.55))
                            .frame(maxWidth: .infinity, minHeight: 100)
                    } else {
                        ForEach(Array(visibleChannels.enumerated()), id: \.element.id) { index, channel in
                            channelRow(index: index, visibleCount: visibleChannels.count, channel: channel)
                                .id(channel.id)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
            .focusSection()
            .onChange(of: favoritesFocusRequestID, initial: true) { _, requestID in
                guard activeSidebarItem == .favorites,
                      let targetID = favoritesFocusTargetID,
                      visibleChannels.contains(where: { $0.id == targetID }) else { return }
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
                    focusedChannelRowID = targetID
                    favoritesFocusTargetID = nil
                }
            }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(red: 0.08, green: 0.08, blue: 0.11))
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }

    @ViewBuilder
    private func channelRow(index: Int, visibleCount: Int, channel: IPTVDisplayChannel) -> some View {
        let isSelected = (selectedChannelID == channel.id)
        Button {
            selectChannelForPreview(channel)
        } label: {
            HStack(spacing: 12) {
                // Channel Index
                Text("\(index + 1)")
                    .font(.system(size: 15, weight: .medium))
                    .monospacedDigit()
                    .foregroundColor(Color.white.opacity(0.5))
                    .lineLimit(1)
                    .frame(width: 40, alignment: .trailing)

                // Channel Logo Badge
                channelBadgeView(channel: channel, size: CGSize(width: 56, height: 56))

                // Name, Subtitle, Mini Progress
                VStack(alignment: .leading, spacing: 4) {
                    Text(channel.name)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)

                    if channel.programTitle.localizedCaseInsensitiveCompare(channel.name) != .orderedSame {
                        Text(channel.programTitle)
                            .font(.system(size: 17))
                            .foregroundColor(Color.white.opacity(0.6))
                            .lineLimit(1)
                    }

                    // Purple mini progress bar
                    if let progress = channel.programProgress {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color.white.opacity(0.12))
                                    .frame(height: 2.5)
                                Capsule()
                                    .fill(Color(red: 0.65, green: 0.35, blue: 0.95))
                                    .frame(width: geo.size.width * progress, height: 2.5)
                            }
                        }
                        .frame(height: 2.5)
                    }
                }

                Spacer()
                if isFavorite(channelID: channel.id) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Color.yellow)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(minHeight: 76)
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
        .buttonStyle(PosterCardButtonStyle())
        .focused($focusedChannelRowID, equals: channel.id)
        .onChange(of: focusedChannelRowID) { _, focusedID in
            guard activeSidebarItem == .favorites, focusedID == channel.id else { return }
            lastFocusedFavoriteChannelID = channel.id
        }
        .contextMenu {
            if channel.streamURL != nil {
                let isFavorite = isFavorite(channelID: channel.id)
                Button(
                    isFavorite ? "Fjern fra favoritter" : "Legg til favoritter",
                    systemImage: isFavorite ? "star.slash" : "star"
                ) {
                    toggleFavorite(channelID: channel.id)
                }
            }
            if activeSidebarItem == .favorites {
                Button("Flytt opp", systemImage: "arrow.up") { moveFavorite(channelID: channel.id, direction: -1) }
                    .disabled(index == 0)
                Button("Flytt ned", systemImage: "arrow.down") { moveFavorite(channelID: channel.id, direction: 1) }
                    .disabled(index >= visibleCount - 1)
            }
        }
        .onPlayPauseCommand {
            playChannel(channel)
        }
    }

    // MARK: - Right Column: Card 1 - Live Player Preview Card
    @ViewBuilder
    private var livePlayerPreviewCard: some View {
        if let active = activeSelectedChannel {
            activeLivePlayerPreviewCard(for: active)
        } else {
            emptyLivePlayerPreviewCard
        }
    }

    private func activeLivePlayerPreviewCard(for active: IPTVDisplayChannel) -> some View {
        let hasCurrentProgramme = active.programProgress != nil
        return Button {
            playChannel(active)
        } label: {
            ZStack(alignment: .bottomLeading) {
                // Background / preview
                GeometryReader { geo in
                    ZStack {
                        Color(red: 0.12, green: 0.12, blue: 0.16)
                        active.brandColor.opacity(0.25)
                        VStack {
                            channelBadgeView(channel: active, size: CGSize(width: 80, height: 60))
                            Text(active.name)
                                .font(.title2.bold())
                                .foregroundColor(.white)
                        }

                        if !isFullscreenPreviewTransitionActive, let player = inlinePreviewPlayer {
                            IPTVVideoSurface(player: player) {
                                markInlinePreviewReady(for: player, channelID: active.id)
                            }
                            .frame(width: geo.size.width, height: geo.size.height)
                            .id(ObjectIdentifier(player))
                            .accessibilityHidden(true)
                            .allowsHitTesting(false)
                        }

                        // Gradient overlay for bottom readability
                        LinearGradient(
                            colors: [.clear, Color.black.opacity(0.3), Color.black.opacity(0.92)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                }

                // Top Bar Overlay (Logo on left, Direkte badge on right)
                VStack {
                    HStack {
                        channelBadgeView(channel: active, size: CGSize(width: 72, height: 48))
                        Spacer()
                        // "• Direkte" badge
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color(red: 0.75, green: 0.35, blue: 0.95))
                                .frame(width: 8, height: 8)
                            Text("Direkte")
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

                // Bottom Metadata & Controls Overlay
                VStack(alignment: .leading, spacing: 10) {
                    Text(hasCurrentProgramme ? active.programTitle : active.name)
                        .font(.system(size: 32, weight: .bold))
                        .foregroundColor(.white)

                    let categoryLabel = categoryPreferences.customNames[active.group] ?? active.category
                    Text(hasCurrentProgramme ? "\(categoryLabel) • \(active.programTime)" : categoryLabel)
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
                        Text("Fullskjerm")
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

    private var emptyLivePlayerPreviewCard: some View {
        ZStack {
            Color(red: 0.10, green: 0.10, blue: 0.14)
            VStack(spacing: 16) {
                if loading {
                    ProgressView()
                    Text("Laster kanaler...")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(.white.opacity(0.72))
                } else {
                    Image(systemName: "tv")
                        .font(.system(size: 44, weight: .semibold))
                        .foregroundColor(.white.opacity(0.55))

                    Text(sources.isEmpty ? "Ingen IPTV-kilde konfigurert" : "Ingen kanaler tilgjengelig")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundColor(.white)

                    Text(errorMessage ?? (sources.isEmpty
                        ? "Legg til en M3U-spilleliste, Xtream Codes eller Stalker-portal for å se direkte-TV."
                        : "Kontroller eller endre IPTV-kilden i innstillingene."))
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.white.opacity(0.68))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 540)

                    Button {
                        if sources.isEmpty { editingID = nil }
                        showingCredentialsModal = true
                    } label: {
                        Text(sources.isEmpty ? "Legg til IPTV-kilde" : "Administrer kilder")
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

    // MARK: - Right Column: Card 2 - EPG / Program Schedule ("Nå og neste")
    private var scheduleEPGCard: some View {
        let active = activeSelectedChannel
        let hasCurrentProgramme = active?.programProgress != nil
        let upcomingPrograms: [(title: String, time: String)] = active.map { active in
            [
                (title: active.nextShow1Title, time: active.nextShow1Time),
                (title: active.nextShow2Title, time: active.nextShow2Time)
            ].filter { $0.time != "--:--" && !$0.title.isEmpty }
        } ?? []

        return VStack(alignment: .leading, spacing: 10) {
            Text(active.map { "\($0.name) – Nå og neste" } ?? "Nå og neste")
                .font(.system(size: 23, weight: .bold))
                .foregroundColor(.white)

            if let active, hasCurrentProgramme {
                guideProgramRow(
                    title: active.programTitle,
                    time: active.programTime,
                    isCurrent: true,
                    progress: active.programProgress
                )
            }

            if upcomingPrograms.isEmpty {
                if !hasCurrentProgramme {
                    Text("Ingen programinformasjon")
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
                .fill(Color(red: 0.08, green: 0.08, blue: 0.11))
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
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.white.opacity(0.12))
                                .frame(height: 4)
                            Capsule()
                                .fill(Color(red: 0.65, green: 0.35, blue: 0.95))
                                .frame(width: geometry.size.width * progress, height: 4)
                        }
                    }
                    .frame(width: 120, height: 4)
                }

                Text("Direkte")
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

    // MARK: - Channel Logo / Badge Helper
    @ViewBuilder
    private func channelBadgeView(channel: IPTVDisplayChannel, size: CGSize) -> some View {
        ZStack {
            if let url = channel.logoURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    default:
                        brandBadgeFallback(channel: channel, size: size)
                    }
                }
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                brandBadgeFallback(channel: channel, size: size)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func brandBadgeFallback(channel: IPTVDisplayChannel, size: CGSize) -> some View {
        ZStack {
            channel.brandColor
            Text(channel.logoText)
                .font(.system(size: min(size.width, size.height) * 0.35, weight: .bold))
                .foregroundColor(.white)
        }
        .frame(width: size.width, height: size.height)
    }

    // MARK: - Credentials & Source Configuration Sheet
    private var credentialsModalView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(editingID == nil ? "Legg til IPTV-kilde" : "Rediger IPTV-kilde")
                    .font(.largeTitle.bold())

                Text("Legg inn din M3U spilleliste eller Xtream Codes legitimasjon for å se direkte-TV.")
                    .foregroundColor(.secondary)

                Picker("Kildetype", selection: $sourceKind) {
                    Text("Xtream Codes").tag(IPTVSource.Kind.xtream)
                    Text("M3U Spilleliste").tag(IPTVSource.Kind.m3u)
                    Text("Stalker Portal").tag(IPTVSource.Kind.stalker)
                }

                TextField("Navn på kilde (f.eks. Min IPTV)", text: $sourceName)

                SecureField(
                    sourceKind == .m3u ? "M3U URL (f.eks. https://.../playlist.m3u)" :
                    (sourceKind == .stalker ? "Portal URL" : "Serveradresse (f.eks. http://server.com:8080)"),
                    text: $sourceURL
                )

                if sourceKind == .xtream {
                    TextField("Brukernavn", text: $username)
                    SecureField("Passord", text: $password)
                    Picker("Format", selection: $xtreamOutput) {
                        Text("MPEG-TS").tag(IPTVXtreamOutput.mpegTS)
                        Text("HLS").tag(IPTVXtreamOutput.hls)
                    }
                }

                if sourceKind == .stalker {
                    TextField("MAC-adresse (f.eks. 00:1A:79:...)", text: $mac)
                }

                HStack(spacing: 16) {
                    Button(editingID == nil ? "Lagre og last inn kilde" : "Lagre endringer") {
                        addSource()
                        showingCredentialsModal = false
                    }
                    .disabled(sourceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sourceURL.isEmpty)

                    Button("Lukk") {
                        showingCredentialsModal = false
                    }
                }

                if !sources.isEmpty {
                    Divider()
                    Text("Konfigurerte kilder").font(.headline)
                    ForEach(sources) { src in
                        HStack {
                            Text(src.name).bold()
                            Spacer()
                            Button("Rediger") { edit(src) }
                            Button("Slett", role: .destructive) { remove(src) }
                        }
                    }
                }
            }
            .padding(40)
        }
    }

    // MARK: - Display Model & Data Mapping
    struct IPTVDisplayChannel: Identifiable {
        let id: String
        let name: String
        let logoURL: URL?
        let group: String
        let category: String
        let programTitle: String
        let programTime: String
        let programProgress: CGFloat?
        let nextShow1Title: String
        let nextShow1Time: String
        let nextShow2Title: String
        let nextShow2Time: String
        let brandColor: Color
        let logoText: String
        let streamURL: URL?
    }

    private struct IPTVGuideDisplayRow: Identifiable {
        let channel: IPTVDisplayChannel
        let programmes: [IPTVProgramme]
        var id: String { channel.id }
    }

    private var activeSelectedChannel: IPTVDisplayChannel? {
        let channels = displayChannels
        return channels.first(where: { $0.id == selectedChannelID }) ?? channels.first
    }

    private var sectionTitle: String {
        switch activeSidebarItem {
        case .search: return "Søk"
        case .sportsNow: return "Sport nå"
        case .favorites: return "Favoritter"
        case .recent: return "Nylig sett"
        case .categories where selectedCategory == "Alle": return "Kategorier"
        default: return selectedCategory == "Alle" ? "Alle kanaler" : categoryDisplayName(selectedCategory)
        }
    }

    private var isChoosingCategory: Bool {
        activeSidebarItem == .categories && selectedCategory == "Alle"
    }

    private var categoryChooserGroups: [String] {
        IPTVCategoryPreferencesStore.orderedGroups(
            baseCategoryGroups,
            preferences: categoryPreferences,
            includingHidden: showingHiddenCategories
        )
    }

    private var hasHiddenCategoryGroups: Bool {
        baseCategoryGroups.contains { categoryPreferences.hiddenGroupIDs.contains($0) }
    }

    private func moveCategory(_ groupID: String, by offset: Int) {
        guard let selectedID else { return }
        IPTVCategoryPreferencesStore.move(
            groupID: groupID,
            by: offset,
            among: baseCategoryGroups,
            visibleGroupIDs: categoryChooserGroups,
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
        loadCategoryPreferences(for: selectedID)
        if hidden && selectedCategory == groupID {
            selectedCategory = "Alle"
        }
    }

    private func beginCategoryRename(_ groupID: String) {
        renamingCategoryID = groupID
        categoryNameDraft = categoryDisplayName(groupID)
        DispatchQueue.main.async { isCategoryNameFocused = true }
    }

    private func saveCategoryRename(for groupID: String) {
        guard let selectedID,
              IPTVCategoryPreferencesStore.rename(
                categoryNameDraft,
                for: groupID,
                defaults: ProfileSettings.store(for: profileID),
                sourceID: selectedID
              ) else { return }
        loadCategoryPreferences(for: selectedID)
        cancelCategoryRename(restoreFocus: true)
    }

    private func cancelCategoryRename(restoreFocus: Bool = false) {
        let groupID = renamingCategoryID
        let sourceID = selectedID
        renamingCategoryID = nil
        categoryNameDraft = ""
        isCategoryNameFocused = false
        guard restoreFocus, let groupID else { return }
        Task { @MainActor in
            await Task.yield()
            guard isChoosingCategory,
                  selectedID == sourceID,
                  categoryChooserGroups.contains(groupID) else { return }
            focusedCategoryRowID = groupID
        }
    }

    private var emptySectionMessage: String {
        switch activeSidebarItem {
        case .search: return channelSearchQuery.isEmpty ? "Skriv inn kanal eller program" : "Ingen treff"
        case .sportsNow: return "Ingen sportsprogrammer pågår nå"
        case .favorites: return "Ingen favorittkanaler"
        case .recent: return "Ingen nylig sette kanaler"
        case .categories where selectedCategory == "Alle": return "Velg en kategori"
        default: return sources.isEmpty ? "Ingen IPTV-kilder lagt til" : "Ingen kanaler i denne kategorien"
        }
    }

    private var channelSearchQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredDisplayChannels: [IPTVDisplayChannel] {
        if isChoosingCategory { return [] }
        if activeSidebarItem == .search && channelSearchQuery.isEmpty { return [] }
        let all = displayChannels
        var result = all

        // Filter by active sidebar tab if needed
        if activeSidebarItem == .favorites {
            result = result.filter { isFavorite(channelID: $0.id) }
        } else if activeSidebarItem == .recent {
            var channelsByKey: [String: IPTVDisplayChannel] = [:]
            for channel in all where channel.streamURL != nil {
                if let key = favoriteKeys[channel.id], channelsByKey[key] == nil { channelsByKey[key] = channel }
            }
            result = recentChannelKeys.compactMap { channelsByKey[$0] }
        }

        // Filter by category
        if selectedCategory != "Alle" {
            result = result.filter { $0.group == selectedCategory }
        }

        // Hidden groups stay available through explicit Favorites and Recent
        // navigation, while ordinary browsing, search, and the guide omit them.
        if activeSidebarItem != .favorites && activeSidebarItem != .recent {
            let hiddenGroupIDs = categoryPreferences.hiddenGroupIDs
            result = result.filter { !hiddenGroupIDs.contains($0.group) }
        }

        // Use only the current EPG programme, never an upcoming listing or the static playlist group.
        if activeSidebarItem == .sportsNow {
            result = result.filter {
                $0.streamURL != nil && $0.programProgress != nil
                    && IPTVChannelFilter.isSportsEventTitle($0.programTitle)
            }
        }

        // Filter by search text
        if activeSidebarItem == .search {
            result = result.filter {
                IPTVChannelFilter.matches(
                    name: $0.name,
                    group: $0.group,
                    query: channelSearchQuery,
                    selectedGroup: nil,
                    currentProgrammeTitle: $0.programProgress != nil ? $0.programTitle : nil
                )
            }
        }

        if activeSidebarItem == .favorites {
            var positions: [String: Int] = [:]
            for (index, key) in favoriteOrder.enumerated() where positions[key] == nil {
                positions[key] = index
            }
            result = result.enumerated().sorted { lhs, rhs in
                let lhsPosition = positions[favoriteKeys[lhs.element.id] ?? lhs.element.id] ?? Int.max
                let rhsPosition = positions[favoriteKeys[rhs.element.id] ?? rhs.element.id] ?? Int.max
                return lhsPosition == rhsPosition ? lhs.offset < rhs.offset : lhsPosition < rhsPosition
            }.map(\.element)
        }
        return result
    }

    private var displayChannels: [IPTVDisplayChannel] {
        let regular: [IPTVDisplayChannel] = channels.map { ch in
            let prog = currentProgramme(for: ch)
            let upcoming = upcomingProgrammes(for: ch)
            let next1 = upcoming.first
            let next2 = upcoming.count > 1 ? upcoming[1] : nil

            return IPTVDisplayChannel(
                id: ch.id,
                name: ch.name,
                logoURL: ch.logoURL,
                group: ch.group ?? "Diverse",
                category: ch.group ?? "Direkte",
                programTitle: prog?.title ?? ch.name,
                programTime: prog != nil ? formatTimeRange(start: prog!.start, end: prog!.end) : "Direkte",
                programProgress: prog.map { calculateProgress(start: $0.start, end: $0.end) },
                nextShow1Title: next1?.title ?? "Neste program",
                nextShow1Time: next1 != nil ? formatTimeRange(start: next1!.start, end: next1!.end) : "--:--",
                nextShow2Title: next2?.title ?? "Følgende program",
                nextShow2Time: next2 != nil ? formatTimeRange(start: next2!.start, end: next2!.end) : "--:--",
                brandColor: colorForName(ch.name),
                logoText: String(ch.name.prefix(3)).uppercased(),
                streamURL: ch.streamURL
            )
        }
        guard !stalkerChannels.isEmpty else { return regular }
        let stalker: [IPTVDisplayChannel] = stalkerChannels.map { stk in
            let group = stk.categoryName ?? "Diverse"
            return IPTVDisplayChannel(
                id: stk.id,
                name: stk.name,
                logoURL: stk.logo.flatMap(URL.init(string:)),
                group: group,
                category: group,
                programTitle: stk.name,
                programTime: "Direkte",
                programProgress: nil,
                nextShow1Title: "Neste program",
                nextShow1Time: "--:--",
                nextShow2Title: "Følgende program",
                nextShow2Time: "--:--",
                brandColor: colorForName(stk.name),
                logoText: String(stk.name.prefix(3)).uppercased(),
                streamURL: URL(string: "stalker://channel/\(stk.id)")
            )
        }
        return regular + stalker
    }

    // MARK: - Playback Execution
    private func selectChannelForPreview(_ channel: IPTVDisplayChannel) {
        selectedChannelID = channel.id
        inlinePreviewChannelID = channel.streamURL == nil ? nil : channel.id
        if inlinePreviewIsReady,
           let player = inlinePreviewPlayer,
           inlinePreviewItemMatches(for: channel, player: player),
           player.rate == 0 {
            player.play()
        }
    }

    private func playChannel(_ channel: IPTVDisplayChannel) {
        if presentInlinePreviewFullscreen(for: channel) { return }
        inlinePreviewChannelID = nil
        stopInlinePreview()
        if let streamURL = channel.streamURL, streamURL.scheme != "stalker" {
            selectedChannelID = channel.id
            recordRecent(channelID: channel.id)
            play(url: streamURL, id: channel.id, name: channel.name, logo: nil)
            return
        }
        guard let stalker = stalkerChannels.first(where: { $0.id == channel.id }),
              let client = stalkerClient else { return }
        selectedChannelID = channel.id
        recordRecent(channelID: channel.id)
        Task { @MainActor in
            guard let playback = try? await client.resolve(stalker) else { return }
            play(url: playback.url, id: channel.id, name: channel.name, logo: stalker.logo, headers: playback.headers)
        }
    }

    private func eligibleInlinePreviewURL(for channel: IPTVDisplayChannel) -> URL? {
        guard isActive, !loading, inlinePreviewChannelID == channel.id,
              selectedChannelID == channel.id, scenePhase == .active, !showingCredentialsModal,
              let url = channel.streamURL,
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    private func inlinePreviewItemMatches(for channel: IPTVDisplayChannel, player: AVPlayer) -> Bool {
        guard inlinePreviewPlayer === player,
              inlinePreviewChannelID == channel.id,
              selectedChannelID == channel.id,
              let expectedURL = eligibleInlinePreviewURL(for: channel),
              let item = player.currentItem,
              item.status == .readyToPlay,
              item.error == nil,
              let asset = item.asset as? AVURLAsset,
              asset.url == expectedURL else { return false }
        return true
    }

    private func inlinePreviewItemIsForSameURL(_ player: AVPlayer, url: URL) -> Bool {
        guard let item = player.currentItem,
              item.status != .failed,
              item.error == nil,
              let asset = item.asset as? AVURLAsset,
              asset.url == url else { return false }
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

    private func presentInlinePreviewFullscreen(for channel: IPTVDisplayChannel) -> Bool {
        guard inlinePreviewIsReady,
              let player = inlinePreviewPlayer,
              inlinePreviewItemMatches(for: channel, player: player) else { return false }

        // Retain the exact player and current item while its AVPlayerLayer
        // temporarily moves to the shared custom overlay.
        fullscreenReturnChannelID = channel.id
        isFullscreenPreviewTransitionActive = true
        fullscreenPreview = IPTVFullscreenPreview(player: player, channelTitle: channel.name)
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
              let channel = displayChannels.first(where: { $0.id == returnChannelID }),
              inlinePreviewItemMatches(for: channel, player: player) else { return }

        Task { @MainActor in
            await Task.yield()
            guard isActive, scenePhase == .active, selectedChannelID == returnChannelID else { return }
            isPreviewButtonFocused = true
        }
    }

    private func discardInlinePreviewForExternalExit() {
        fullscreenPreview = nil
        inlinePreviewChannelID = nil
        stopInlinePreview()
    }

    private func stopInlinePreview() {
        inlinePreviewPlayer?.pause()
        inlinePreviewPlayer?.replaceCurrentItem(with: nil)
        inlinePreviewPlayer = nil
        inlinePreviewIsReady = false
    }

    private func play(url: URL, id: String, name: String, logo: String?, headers: [String: String] = [:]) {
        onPlay(url, NuvioMeta(
            id: "iptv:\(id)", name: name, description: nil, posterUrl: logo, backgroundUrl: nil, logoUrl: nil,
            imdbId: nil, tmdbId: nil, type: "channel", year: nil, genres: nil,
            rating: nil, releaseInfo: nil, runtime: nil, cast: nil, director: nil,
            writer: nil, certification: nil, country: nil, released: nil
        ), headers)
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
    }

    private func visibleFavoriteKeys() -> [String] {
        filteredDisplayChannels.map { favoriteKeys[$0.id] ?? $0.id }
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
    }

    private func recordRecent(channelID: String) {
        guard let key = favoriteKeys[channelID], recentChannelKeys.first != key else { return }
        let recent = IPTVRecentChannelStore(defaults: ProfileSettings.store(for: profileID))
        recent.save(key)
        recentChannelKeys = recent.loadAll()
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

    private func currentProgramme(for channel: IPTVChannel) -> IPTVProgramme? {
        guard let id = channel.guideID else { return nil }
        return guideByChannel[id]?.first { $0.start <= guideNow && guideNow < $0.end }
    }

    private func upcomingProgrammes(for channel: IPTVChannel) -> [IPTVProgramme] {
        guard let id = channel.guideID else { return [] }
        return Array((guideByChannel[id] ?? []).lazy.drop(while: { $0.start < guideNow }).prefix(2))
    }

    private func colorForName(_ name: String) -> Color {
        let colors: [Color] = [
            Color(red: 0.15, green: 0.40, blue: 0.85),
            Color(red: 0.85, green: 0.20, blue: 0.35),
            Color(red: 0.10, green: 0.65, blue: 0.45),
            Color(red: 0.55, green: 0.25, blue: 0.85),
            Color(red: 0.90, green: 0.45, blue: 0.15),
            Color(red: 0.20, green: 0.60, blue: 0.85)
        ]
        let hash = abs(name.hashValue)
        return colors[hash % colors.count]
    }

    private var availableGroups: [String] {
        let groups = IPTVChannelFilter.groups(in: channels) + stalkerChannels.compactMap(\.categoryName)
        return Array(Set(groups)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
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
            if loadingSource != nil, loadTask != nil { return }
            if let source = cached?.source ?? sources.first(where: { $0.id == selectedID }) ?? sources.first {
                selectedID = source.id
                if successfullyLoadedSource == source,
                   let successfullyLoadedAt,
                   now.timeIntervalSince(successfullyLoadedAt) < LoadedCache.lineupLifetime {
                    if loadedCache.entry == nil { storeLoadedCache() }
                    refreshGuideIfDue(now: now)
                } else if let cached, cached.source == source {
                    channels = cached.channels
                    stalkerChannels = cached.stalkerChannels
                    stalkerClient = cached.stalkerClient
                    selectedGuideURLs = cached.guideURLs
                    selectedGuideNeedsSameOrigin = cached.sameOrigin
                    favoriteKeys = cached.favoriteKeys
                    guideByChannel = cached.guideByChannel
                    guideNextRefresh = cached.guideNextRefresh
                    guideFailures = cached.guideFailures
                    guideUnavailable = cached.guideUnavailable
                    successfullyLoadedSource = source
                    successfullyLoadedAt = cached.loadedAt
                    if !channels.contains(where: { $0.id == selectedChannelID })
                        && !stalkerChannels.contains(where: { $0.id == selectedChannelID }) {
                        selectedChannelID = channels.first?.id ?? stalkerChannels.first?.id
                    }
                    guideNow = now
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
        stopInlinePreview()
        selectedID = nil
        selectedChannelID = nil
        loadCategoryPreferences(for: nil)
    }

    private func clearLoadedContent() {
        successfullyLoadedSource = nil
        successfullyLoadedAt = nil
        channels = []
        stalkerChannels = []
        stalkerClient = nil
        favoriteKeys = [:]
        guideByChannel = [:]
        guideUnavailable = false
        guideNextRefresh = nil
        guideFailures = 0
        selectedGuideURLs = []
        selectedGuideNeedsSameOrigin = false
        selectedGuideProgramme = nil
        selectedGuideChannelID = nil
        selectedChannelID = nil
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
            errorMessage = "Ugyldig URL"
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
                successfullyLoadedSource = source
                successfullyLoadedAt = Date()
                inlinePreviewChannelID = nil
                stopInlinePreview()
                selectedChannelID = loaded.first?.id ?? loadedStalkerChannels?.first?.id
                guideTask?.cancel()
                guideTask = nil
                guideRequestID = nil
                guideByChannel = [:]
                guideUnavailable = false
                guideNextRefresh = nil
                guideFailures = 0
                selectedGuideURLs = guideURLs
                selectedGuideNeedsSameOrigin = guideNeedsSameOrigin
                selectedGuideProgramme = nil
                selectedGuideChannelID = nil
                selectedID = source.id
                var keys: [String: String] = [:]
                for channel in loaded { keys[channel.id] = IPTVFavoritesStore.key(sourceID: source.id, channelID: channel.id) }
                favoriteKeys = keys
                let favoriteStore = IPTVFavoritesStore(defaults: ProfileSettings.store(for: profileID))
                favoriteOrder = favoriteStore.reconciledOrder(favoriteOrder, playlistOrder: loaded.map { keys[$0.id] ?? $0.id }, favorites: favorites)
                favoriteStore.saveOrder(favoriteOrder)
                searchText = ""
                storeLoadedCache()
#if NUVIO_SIDEBAR_WATCHDOG
                Self.sidebarLogger.notice("playlist load finished kind=\(source.kind.rawValue, privacy: .public) channels=\(loaded.count) stalkerChannels=\(stalkerChannels.count) durationMs=\(Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000))")
#endif
                if !guideURLs.isEmpty {
                    loadGuide(urls: guideURLs, for: source.id, channels: loaded, sameOrigin: guideNeedsSameOrigin)
                }
            } catch {
                guard !Task.isCancelled, requestID == token else { return }
                errorMessage = "Kunne ikke laste inn kilden."
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
                    loadCategoryPreferences(for: nextSource.id)
                    load(nextSource)
                }
            }
        } catch {
            errorMessage = "Kunne ikke slette kilden."
        }
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
              channels.contains(where: { $0.guideID != nil }),
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
#if NUVIO_SIDEBAR_WATCHDOG
                    guideWatchdog.recordFirstListingsIfNeeded(programmeCount: merged.isEmpty ? 0 : batch.programmes.count)
#endif
                    guideFailures += 1
                    let retry = IPTVGuideRefreshPolicy.retry(afterFailures: guideFailures, at: finishedAt)
                    guideNextRefresh = max(retry, finishedAt.addingTimeInterval(IPTVGuideRefreshPolicy.minInterval))
                    guideUnavailable = guideByChannel.isEmpty
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
}

struct IPTVVideoSurface: UIViewRepresentable {
    let player: AVPlayer
    var videoGravity: AVLayerVideoGravity = .resizeAspectFill
    let onFirstFrame: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFirstFrame: onFirstFrame)
    }

    func makeUIView(context: Context) -> TrailerPlayerLayerView {
        let view = TrailerPlayerLayerView()
        view.playerLayer.videoGravity = videoGravity
        view.playerLayer.player = player
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
