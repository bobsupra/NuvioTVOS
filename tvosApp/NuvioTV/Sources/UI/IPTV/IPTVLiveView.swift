import SwiftUI
import Combine

/// High-fidelity Live TV browsing, EPG guide, and source management.
struct IPTVLiveView: View {
    let profileID: String
    let onPlay: (URL, NuvioMeta, [String: String]) -> Void

    // MARK: - Navigation & Filters
    @State private var activeSidebarItem: IPTVNavTab = .liveTV
    @State private var selectedCategory: String = "Alle"
    @State private var showingCredentialsModal = false

    // MARK: - Sources & Core Data
    @State private var sources: [IPTVSource] = []
    @State private var sourcesLoaded = false
    @State private var channels: [IPTVChannel] = []
    @State private var stalkerChannels: [IPTVStalkerChannel] = []
    @State private var stalkerClient: IPTVStalkerClient?
    @State private var selectedID: UUID?

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
    @State private var guideTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    // Channel Selection & Favorites
    @State private var selectedChannelID: String = "sample-nrk1"
    @State private var favorites: Set<String> = []
    @State private var favoriteKeys: [String: String] = [:]
    @State private var recentChannelKey: String?
    @State private var searchText = ""

    private let store = IPTVSourceStore()
    private let loader = IPTVPlaylistLoader()
    private let xtream = IPTVXtreamClient()
    private let guideLoader = IPTVGuideLoader()
    private let guideClock = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
    private let guidePageDuration: TimeInterval = 4 * 60 * 60
    private let guideChannelColumnWidth: CGFloat = 232

    // Standard category tabs
    private let defaultCategories = ["Alle", "Norge", "Sport", "Film", "Serier", "Barn", "Nyheter"]

    var body: some View {
        let visibleChannels = filteredDisplayChannels

        return ZStack {
            // Background
            Color(red: 0.05, green: 0.05, blue: 0.07)
                .ignoresSafeArea()

            HStack(alignment: .top, spacing: 28) {
                // MARK: 1. Left Sidebar Navigation
                sidebarView
                    .frame(width: 230)

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
                            channelListCard
                                .frame(width: 410, height: 656)

                            // Right Column: Preview + Schedule
                            VStack(spacing: 16) {
                                livePlayerPreviewCard
                                scheduleEPGCard
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            .padding(.leading, 48)
            .padding(.trailing, 48)
            .padding(.top, 22)
            .padding(.bottom, 22)
        }
        .sheet(isPresented: $showingCredentialsModal) {
            credentialsModalView
        }
        .onAppear(perform: restoreSources)
        .onReceive(guideClock) { now in
            guideNow = now
            refreshGuideIfDue(now: now)
        }
        .onDisappear {
            requestID = UUID()
            loadTask?.cancel()
            loadTask = nil
            guideTask?.cancel()
            guideTask = nil
            loading = false
        }
    }

    // MARK: - Navigation Tabs
    enum IPTVNavTab: String, CaseIterable {
        case liveTV = "Live TV"
        case guide = "TV-guide"
        case channels = "Kanalliste"
        case favorites = "Favoritter"
        case categories = "Kategorier"
        case recent = "Nylig sett"
        case settings = "Innstillinger"

        var icon: String {
            switch self {
            case .liveTV: return "tv"
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
                .font(.system(size: 34, weight: .bold))
                .foregroundColor(.white)
                .padding(.bottom, 20)
                .padding(.leading, 8)

            ForEach(IPTVNavTab.allCases, id: \.self) { tab in
                Button {
                    handleSidebarSelection(tab)
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 18, weight: .semibold))
                            .frame(width: 24)
                        Text(tab.rawValue)
                            .font(.system(size: 16, weight: activeSidebarItem == tab ? .semibold : .medium))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                        Spacer()
                    }
                    .foregroundColor(activeSidebarItem == tab ? .white : Color.white.opacity(0.65))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(activeSidebarItem == tab ? Color.white.opacity(0.18) : Color.clear)
                    )
                }
                .buttonStyle(PosterCardButtonStyle())
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
    }

    private func handleSidebarSelection(_ tab: IPTVNavTab) {
        activeSidebarItem = tab
        switch tab {
        case .liveTV:
            selectedCategory = "Alle"
        case .guide:
            selectedCategory = "Alle"
            guidePageStartOverride = nil
            selectedGuideProgramme = nil
            selectedGuideChannelID = nil
        case .channels:
            selectedCategory = "Alle"
        case .favorites:
            // Toggle or select favorites view
            break
        case .categories:
            selectedCategory = "Norge"
        case .recent:
            if let recentKey = recentChannelKey,
               let match = displayChannels.first(where: { favoriteKeys[$0.id] == recentKey }) {
                selectedChannelID = match.id
            }
        case .settings:
            showingCredentialsModal = true
        }
    }

    // MARK: - Category Filter Pills
    private var categoryPillsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(allCategories, id: \.self) { category in
                    Button {
                        selectedCategory = category
                    } label: {
                        Text(category)
                            .font(.system(size: 14, weight: selectedCategory == category ? .bold : .medium))
                            .foregroundColor(selectedCategory == category ? .black : .white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 9)
                            .background(
                                Capsule()
                                    .fill(selectedCategory == category ? Color.white : Color.white.opacity(0.12))
                            )
                    }
                    .buttonStyle(PosterCardButtonStyle())
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var allCategories: [String] {
        if channels.isEmpty {
            return defaultCategories
        }
        var list = ["Alle"]
        for group in availableGroups {
            if !list.contains(group) {
                list.append(group)
            }
        }
        return list
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

    private func timeGuideView(channels visibleChannels: [IPTVDisplayChannel]) -> some View {
        let pageStart = guidePageStart
        let pageEnd = guidePageEnd
        let rows = guideRows(from: visibleChannels, between: pageStart, and: pageEnd)
        let hasGuideIDs = channels.contains { $0.guideID != nil }

        return GeometryReader { geometry in
            let timelineWidth = max(1, geometry.size.width - 24 - 20 - guideChannelColumnWidth)

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

                    Spacer(minLength: 10)
                    guidePageButton("Tidligere", icon: "chevron.left", enabled: canBrowseGuideEarlier) {
                        moveGuidePage(by: -guidePageDuration)
                    }
                    guidePageButton("Nå", icon: "dot.circle", enabled: guidePageStartOverride != nil) {
                        guidePageStartOverride = nil
                    }
                    guidePageButton("Senere", icon: "chevron.right", enabled: canBrowseGuideLater) {
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
                        guidePageButton("Prøv igjen", icon: "arrow.clockwise", enabled: !selectedGuideURLs.isEmpty) {
                            retryGuide()
                        }
                    }
                }

                if selectedGuideProgramme != nil {
                    selectedGuideProgrammeCard
                }

                if selectedGuideURLs.isEmpty {
                    guideEmptyState("Ingen TV-guide er konfigurert for denne kilden.", icon: "calendar.badge.exclamationmark")
                } else if !hasGuideIDs {
                    guideEmptyState("Kilden har ingen kanaler med EPG-ID.", icon: "tv.slash")
                } else {
                    VStack(spacing: 6) {
                        guideTimeAxis(start: pageStart, width: timelineWidth)

                        if rows.isEmpty {
                            if guideTask != nil {
                                guideEmptyState("Venter på programdata…", icon: "clock")
                            } else if guideUnavailable {
                                guideEmptyState("Programguiden er utilgjengelig.", icon: "wifi.slash")
                            } else {
                                guideEmptyState("Ingen programinformasjon i dette tidsrommet.", icon: "calendar")
                            }
                        } else {
                            ScrollView(.vertical, showsIndicators: false) {
                                LazyVStack(spacing: 6) {
                                    ForEach(rows) { row in
                                        guideChannelRow(row, start: pageStart, end: pageEnd, timelineWidth: timelineWidth)
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

    private func guidePageButton(_ title: String, icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
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
            .overlay(IPTVGuideFocusOutline(shape: Capsule()))
        }
        .buttonStyle(PosterCardButtonStyle())
        .disabled(!enabled)
    }

    private func guideTimeAxis(start: Date, width: CGFloat) -> some View {
        HStack(spacing: 0) {
            Text("Kanal")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.white.opacity(0.74))
                .padding(.trailing, 10)
                .frame(width: guideChannelColumnWidth, alignment: .leading)

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

    private func guideChannelRow(_ row: IPTVGuideDisplayRow, start: Date, end: Date, timelineWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 12) {
                channelBadgeView(channel: row.channel, size: CGSize(width: 48, height: 42))
                Text(row.channel.name)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
            }
            .padding(.trailing, 10)
            .frame(width: guideChannelColumnWidth, height: 74, alignment: .leading)

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(0.035))
                ForEach(Array(row.programmes.enumerated()), id: \.element.start) { index, programme in
                    let nextStart = index + 1 < row.programmes.count ? row.programmes[index + 1].start : nil
                    guideProgrammeTile(programme, row: row, start: start, end: end, nextStart: nextStart, timelineWidth: timelineWidth)
                }
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
        start: Date,
        end: Date,
        nextStart: Date?,
        timelineWidth: CGFloat
    ) -> some View {
        let clippedStart = max(programme.start, start)
        let clippedEnd = min(min(programme.end, end), nextStart ?? end)
        let duration = max(1, end.timeIntervalSince(start))
        let xOffset = CGFloat(clippedStart.timeIntervalSince(start) / duration) * timelineWidth
        let tileWidth = CGFloat(clippedEnd.timeIntervalSince(clippedStart) / duration) * timelineWidth
        let isCurrent = programme.start <= guideNow && guideNow < programme.end
        let shape = RoundedRectangle(cornerRadius: 9)

        return Button {
            handleGuideProgrammeSelection(programme, channel: row.channel)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(programme.title)
                    .font(.system(size: tileWidth < 100 ? 16 : 20, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                if tileWidth >= 100 {
                    Text(formatTimeRange(start: programme.start, end: programme.end))
                        .font(.system(size: 15, weight: .medium))
                        .monospacedDigit()
                        .foregroundColor(.white.opacity(0.7))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .frame(width: max(1, tileWidth - 3), height: 68, alignment: .leading)
            .background(shape.fill(isCurrent ? Color(red: 0.35, green: 0.18, blue: 0.58) : Color.white.opacity(0.12)))
            .overlay(shape.stroke(isCurrent ? Color(red: 0.72, green: 0.48, blue: 1) : Color.white.opacity(0.08), lineWidth: 1))
            .overlay(IPTVGuideFocusOutline(shape: shape))
        }
        .buttonStyle(PosterCardButtonStyle())
        .offset(x: xOffset)
        .accessibilityLabel("\(programme.title), \(formatTimeRange(start: programme.start, end: programme.end))")
    }

    private func handleGuideProgrammeSelection(_ programme: IPTVProgramme, channel: IPTVDisplayChannel) {
        if programme.start <= guideNow, guideNow < programme.end, let streamURL = channel.streamURL {
            selectedChannelID = channel.id
            selectedCategory = "Alle"
            activeSidebarItem = .liveTV
            selectedGuideProgramme = nil
            selectedGuideChannelID = nil
            recordRecent(channelID: channel.id)
            play(url: streamURL, id: channel.id, name: channel.name, logo: nil)
        } else {
            selectedGuideProgramme = programme
            selectedGuideChannelID = channel.id
        }
    }

    private var selectedGuideProgrammeCard: some View {
        let channel = displayChannels.first(where: { $0.id == selectedGuideChannelID })
        return HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(selectedGuideProgramme?.title ?? "")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                if let programme = selectedGuideProgramme {
                    Text("\(channel?.name ?? "")  •  \(formatTimeRange(start: programme.start, end: programme.end))")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.white.opacity(0.66))
                }
            }
            Spacer()
            guidePageButton("Lukk", icon: "xmark", enabled: true) {
                selectedGuideProgramme = nil
                selectedGuideChannelID = nil
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 68)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.07)))
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
    private var channelListCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Card Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedCategory == "Alle" ? "Alle kanaler" : selectedCategory)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)
                    Text(channels.isEmpty ? "1 248 kanaler" : "\(filteredDisplayChannels.count) kanaler")
                        .font(.system(size: 12))
                        .foregroundColor(Color.white.opacity(0.5))
                }
                Spacer()
                Button {
                    // Cycle or open group picker
                } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(Color.white.opacity(0.8))
                        .padding(6)
                }
                .buttonStyle(PosterCardButtonStyle())
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)

            // Channels List
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 6) {
                    ForEach(Array(filteredDisplayChannels.enumerated()), id: \.element.id) { index, channel in
                        channelRow(index: index, channel: channel)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
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
    private func channelRow(index: Int, channel: IPTVDisplayChannel) -> some View {
        let isSelected = (selectedChannelID == channel.id)
        Button {
            selectedChannelID = channel.id
        } label: {
            HStack(spacing: 12) {
                // Channel Index
                Text("\(index + 1)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Color.white.opacity(0.5))
                    .frame(width: 18, alignment: .trailing)

                // Channel Logo Badge
                channelBadgeView(channel: channel, size: CGSize(width: 44, height: 44))

                // Name, Subtitle, Mini Progress
                VStack(alignment: .leading, spacing: 4) {
                    Text(channel.name)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)

                    Text(channel.programTitle)
                        .font(.system(size: 13))
                        .foregroundColor(Color.white.opacity(0.6))
                        .lineLimit(1)

                    // Purple mini progress bar
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.white.opacity(0.12))
                                .frame(height: 2.5)
                            Capsule()
                                .fill(Color(red: 0.65, green: 0.35, blue: 0.95))
                                .frame(width: max(4, geo.size.width * channel.programProgress), height: 2.5)
                        }
                    }
                    .frame(height: 2.5)
                }

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(isSelected ? Color(red: 0.65, green: 0.35, blue: 0.95).opacity(0.15) : Color.white.opacity(0.02))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(isSelected ? Color(red: 0.65, green: 0.35, blue: 0.95) : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(PosterCardButtonStyle())
    }

    // MARK: - Right Column: Card 1 - Live Player Preview Card
    private var livePlayerPreviewCard: some View {
        let active = activeSelectedChannel
        return Button {
            playCurrentChannel()
        } label: {
            ZStack(alignment: .bottomLeading) {
                // Background image / preview
                GeometryReader { geo in
                    ZStack {
                        if active.id.contains("nrk1") || active.id == "sample-nrk1" {
                            Image("iptv_preview_nrk1_full")
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: geo.size.width, height: geo.size.height)
                                .clipped()
                        } else {
                            ZStack {
                                Color(red: 0.12, green: 0.12, blue: 0.16)
                                active.brandColor.opacity(0.25)
                                VStack {
                                    channelBadgeView(channel: active, size: CGSize(width: 80, height: 60))
                                    Text(active.name)
                                        .font(.title2.bold())
                                        .foregroundColor(.white)
                                }
                            }
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
                        channelBadgeView(channel: active, size: CGSize(width: 54, height: 36))
                        Spacer()
                        // "• Direkte" badge
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color(red: 0.75, green: 0.35, blue: 0.95))
                                .frame(width: 6, height: 6)
                            Text("Direkte")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(Color.black.opacity(0.6))
                        )
                    }
                    .padding(20)
                    Spacer()
                }

                // Bottom Metadata & Controls Overlay
                VStack(alignment: .leading, spacing: 6) {
                    Text(active.programTitle)
                        .font(.system(size: 30, weight: .bold))
                        .foregroundColor(.white)

                    Text("\(active.category) • \(active.programTime)")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(Color.white.opacity(0.75))

                    // Sleek full-width Purple Progress Bar
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.white.opacity(0.2))
                                .frame(height: 4)
                            Capsule()
                                .fill(Color(red: 0.65, green: 0.35, blue: 0.95))
                                .frame(width: max(6, geo.size.width * active.programProgress), height: 4)
                        }
                    }
                    .frame(height: 4)
                    .padding(.top, 4)

                    // Action buttons (Favorite & Info)
                    HStack {
                        Spacer()
                        HStack(spacing: 12) {
                            Button {
                                toggleFavorite(channelID: active.id)
                            } label: {
                                Image(systemName: isFavorite(channelID: active.id) ? "star.fill" : "star")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundColor(isFavorite(channelID: active.id) ? .yellow : .white)
                                    .frame(width: 36, height: 36)
                                    .background(Circle().fill(Color.white.opacity(0.18)))
                            }
                            .buttonStyle(PosterCardButtonStyle())

                            Button {
                                // Info / EPG
                            } label: {
                                Image(systemName: "info")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundColor(.white)
                                    .frame(width: 36, height: 36)
                                    .background(Circle().fill(Color.white.opacity(0.18)))
                            }
                            .buttonStyle(PosterCardButtonStyle())
                        }
                    }
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 18)
            }
            .frame(height: 430)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(PosterCardButtonStyle())
    }

    // MARK: - Right Column: Card 2 - EPG / Program Schedule ("Nå og neste")
    private var scheduleEPGCard: some View {
        let active = activeSelectedChannel
        return VStack(alignment: .leading, spacing: 12) {
            // Header
            Text("\(active.name) – Nå og neste")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)

            // Current show row (with play icon and progress)
            HStack(spacing: 12) {
                Image(systemName: "play.fill")
                    .font(.system(size: 14))
                    .foregroundColor(Color(red: 0.65, green: 0.35, blue: 0.95))

                VStack(alignment: .leading, spacing: 2) {
                    Text(active.programTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                    Text(active.programTime)
                        .font(.system(size: 12))
                        .foregroundColor(Color.white.opacity(0.6))
                }

                Spacer()

                // Progress line
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.12))
                            .frame(height: 3)
                        Capsule()
                            .fill(Color(red: 0.65, green: 0.35, blue: 0.95))
                            .frame(width: max(4, geo.size.width * active.programProgress), height: 3)
                    }
                }
                .frame(width: 140, height: 3)

                // "Direkte" pill
                Text("Direkte")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(red: 0.85, green: 0.65, blue: 1.0))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(Color(red: 0.45, green: 0.20, blue: 0.65).opacity(0.45))
                    )
            }

            Divider()
                .background(Color.white.opacity(0.08))

            // Next show 1
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(active.nextShow1Title)
                        .font(.system(size: 14, weight: .regular))
                        .foregroundColor(Color.white.opacity(0.9))
                    Text(active.nextShow1Time)
                        .font(.system(size: 12))
                        .foregroundColor(Color.white.opacity(0.5))
                }
                Spacer()
            }

            // Next show 2
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(active.nextShow2Title)
                        .font(.system(size: 14, weight: .regular))
                        .foregroundColor(Color.white.opacity(0.9))
                    Text(active.nextShow2Time)
                        .font(.system(size: 12))
                        .foregroundColor(Color.white.opacity(0.5))
                }
                Spacer()
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(red: 0.08, green: 0.08, blue: 0.11))
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }

    // MARK: - Right Column: Card 3 - Popular Live Channels ("Populære live-kanaler")
    private var popularChannelsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Text("Populære live-kanaler")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                Button {
                    selectedCategory = "Alle"
                } label: {
                    Text("Se alle >")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Color(red: 0.65, green: 0.35, blue: 0.95))
                }
                .buttonStyle(PosterCardButtonStyle())
            }

            // Horizontal row of popular channel cards
            HStack(spacing: 12) {
                ForEach(popularChannelsList.prefix(8), id: \.id) { pop in
                    Button {
                        selectedChannelID = pop.id
                    } label: {
                        channelBadgeView(channel: pop, size: CGSize(width: 74, height: 50))
                    }
                    .buttonStyle(PosterCardButtonStyle())
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(red: 0.08, green: 0.08, blue: 0.11))
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }

    // MARK: - Channel Logo / Badge Helper
    @ViewBuilder
    private func channelBadgeView(channel: IPTVDisplayChannel, size: CGSize) -> some View {
        ZStack {
            if channel.id == "sample-tv2nyhet" {
                ZStack {
                    Color(red: 0.84, green: 0.16, blue: 0.16)
                    Image("iptv_logo_tv2")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(5)
                }
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            } else if let asset = channel.logoAsset {
                Image(asset)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else if let url = channel.logoURL {
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

                    Button("Last inn demokanaler (Norge)") {
                        loadSampleNorwegianLineup()
                        showingCredentialsModal = false
                    }

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
        let logoAsset: String?
        let logoURL: URL?
        let group: String
        let category: String
        let programTitle: String
        let programTime: String
        let programProgress: CGFloat
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

    private var activeSelectedChannel: IPTVDisplayChannel {
        filteredDisplayChannels.first(where: { $0.id == selectedChannelID }) ??
        displayChannels.first ??
        sampleChannels[0]
    }

    private var popularChannelsList: [IPTVDisplayChannel] {
        if channels.isEmpty {
            let popularIDs = [
                "sample-nrk1",
                "sample-nrk2",
                "sample-tv2",
                "sample-tvnorge",
                "sample-max",
                "sample-discovery",
                "sample-viasat",
                "sample-skysport"
            ]
            let found = popularIDs.compactMap { id in sampleChannels.first(where: { $0.id == id }) }
            return found.isEmpty ? sampleChannels : found
        }
        let favs = displayChannels.filter { isFavorite(channelID: $0.id) }
        if favs.count >= 4 {
            return favs
        }
        return Array(displayChannels.prefix(8))
    }

    private var filteredDisplayChannels: [IPTVDisplayChannel] {
        let all = displayChannels
        var result = all

        // Filter by active sidebar tab if needed
        if activeSidebarItem == .favorites {
            result = result.filter { isFavorite(channelID: $0.id) }
        }

        // Filter by category
        if selectedCategory != "Alle" {
            result = result.filter { ch in
                ch.category.localizedCaseInsensitiveContains(selectedCategory) ||
                ch.group.localizedCaseInsensitiveContains(selectedCategory)
            }
        }

        // Filter by search text
        if !searchText.isEmpty {
            result = result.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }

        return result.isEmpty ? all : result
    }

    private var displayChannels: [IPTVDisplayChannel] {
        if !channels.isEmpty {
            // Map real channels to display channels
            return channels.enumerated().map { index, ch in
                let prog = currentProgramme(for: ch)
                let upcoming = upcomingProgrammes(for: ch)
                let next1 = upcoming.first
                let next2 = upcoming.count > 1 ? upcoming[1] : nil

                return IPTVDisplayChannel(
                    id: ch.id,
                    name: ch.name,
                    logoAsset: nil,
                    logoURL: ch.logoURL,
                    group: ch.group ?? "Diverse",
                    category: ch.group ?? "Direkte",
                    programTitle: prog?.title ?? ch.name,
                    programTime: prog != nil ? formatTimeRange(start: prog!.start, end: prog!.end) : "Direkte",
                    programProgress: prog != nil ? calculateProgress(start: prog!.start, end: prog!.end) : 0.45,
                    nextShow1Title: next1?.title ?? "Neste program",
                    nextShow1Time: next1 != nil ? formatTimeRange(start: next1!.start, end: next1!.end) : "--:--",
                    nextShow2Title: next2?.title ?? "Følgende program",
                    nextShow2Time: next2 != nil ? formatTimeRange(start: next2!.start, end: next2!.end) : "--:--",
                    brandColor: colorForName(ch.name),
                    logoText: String(ch.name.prefix(3)).uppercased(),
                    streamURL: ch.streamURL
                )
            }
        }
        // Fallback to sample Norwegian lineup matching user mockup
        return sampleChannels
    }

    // MARK: - Sample Norwegian Channels (Matches user mockup)
    private var sampleChannels: [IPTVDisplayChannel] {
        [
            IPTVDisplayChannel(
                id: "sample-nrk1",
                name: "NRK1",
                logoAsset: "iptv_logo_nrk1",
                logoURL: nil,
                group: "Norge",
                category: "Nyheter",
                programTitle: "Dagsrevyen",
                programTime: "17:00 – 17:30",
                programProgress: 0.65,
                nextShow1Title: "Været",
                nextShow1Time: "17:30 – 17:40",
                nextShow2Title: "Norge i dag",
                nextShow2Time: "17:40 – 18:30",
                brandColor: Color(red: 0.10, green: 0.35, blue: 0.75),
                logoText: "NRK 1",
                streamURL: URL(string: "https://example.com/nrk1.m3u8")
            ),
            IPTVDisplayChannel(
                id: "sample-nrk2",
                name: "NRK2",
                logoAsset: "iptv_logo_nrk2",
                logoURL: nil,
                group: "Norge",
                category: "Serier",
                programTitle: "Der Ingen Skulle Tru",
                programTime: "17:00 – 17:50",
                programProgress: 0.20,
                nextShow1Title: "Folk: Min historie",
                nextShow1Time: "17:50 – 18:20",
                nextShow2Title: "Dagsnytt 18",
                nextShow2Time: "18:20 – 19:00",
                brandColor: Color(red: 0.85, green: 0.12, blue: 0.36),
                logoText: "NRK 2",
                streamURL: URL(string: "https://example.com/nrk2.m3u8")
            ),
            IPTVDisplayChannel(
                id: "sample-tv2",
                name: "TV 2 Direkte",
                logoAsset: "iptv_logo_tv2",
                logoURL: nil,
                group: "Norge",
                category: "Underholdning",
                programTitle: "God Morgen Norge",
                programTime: "16:45 – 17:35",
                programProgress: 0.35,
                nextShow1Title: "Nyhetene",
                nextShow1Time: "17:35 – 18:00",
                nextShow2Title: "Farmen",
                nextShow2Time: "18:00 – 19:00",
                brandColor: Color(red: 0.12, green: 0.12, blue: 0.15),
                logoText: "2",
                streamURL: URL(string: "https://example.com/tv2.m3u8")
            ),
            IPTVDisplayChannel(
                id: "sample-tv2nyhet",
                name: "TV 2 Nyhetskanalen",
                logoAsset: "iptv_logo_tv2",
                logoURL: nil,
                group: "Norge",
                category: "Nyheter",
                programTitle: "Nyhetene",
                programTime: "17:00 – 17:30",
                programProgress: 0.45,
                nextShow1Title: "Økonominyhetene",
                nextShow1Time: "17:30 – 17:45",
                nextShow2Title: "18-Nyhetene",
                nextShow2Time: "17:45 – 18:30",
                brandColor: Color(red: 0.84, green: 0.16, blue: 0.16),
                logoText: "2",
                streamURL: URL(string: "https://example.com/tv2nyheter.m3u8")
            ),
            IPTVDisplayChannel(
                id: "sample-tvnorge",
                name: "TV Norge",
                logoAsset: "iptv_logo_tvnorge",
                logoURL: nil,
                group: "Norge",
                category: "Underholdning",
                programTitle: "Sofa",
                programTime: "17:15 – 18:00",
                programProgress: 0.30,
                nextShow1Title: "71 grader nord",
                nextShow1Time: "18:00 – 19:30",
                nextShow2Title: "Neste sommer",
                nextShow2Time: "19:30 – 20:00",
                brandColor: Color(red: 0.78, green: 0.11, blue: 0.15),
                logoText: "N",
                streamURL: URL(string: "https://example.com/tvnorge.m3u8")
            ),
            IPTVDisplayChannel(
                id: "sample-max",
                name: "MAX",
                logoAsset: "iptv_logo_max",
                logoURL: nil,
                group: "Film",
                category: "Film",
                programTitle: "MythBusters",
                programTime: "16:30 – 17:30",
                programProgress: 0.70,
                nextShow1Title: "Top Gear",
                nextShow1Time: "17:30 – 18:30",
                nextShow2Title: "Storage Hunters",
                nextShow2Time: "18:30 – 19:00",
                brandColor: Color(red: 0.0, green: 0.62, blue: 0.29),
                logoText: "MAX",
                streamURL: URL(string: "https://example.com/max.m3u8")
            ),
            IPTVDisplayChannel(
                id: "sample-discovery",
                name: "Discovery",
                logoAsset: "iptv_logo_discovery",
                logoURL: nil,
                group: "Film",
                category: "Serier",
                programTitle: "Gold Rush",
                programTime: "17:00 – 18:00",
                programProgress: 0.20,
                nextShow1Title: "Deadliest Catch",
                nextShow1Time: "18:00 – 19:00",
                nextShow2Title: "Wheeler Dealers",
                nextShow2Time: "19:00 – 20:00",
                brandColor: Color(red: 0.11, green: 0.11, blue: 0.12),
                logoText: "D",
                streamURL: URL(string: "https://example.com/discovery.m3u8")
            ),
            IPTVDisplayChannel(
                id: "sample-viasat",
                name: "Viasat Sport 1",
                logoAsset: "iptv_logo_viasat",
                logoURL: nil,
                group: "Sport",
                category: "Sport",
                programTitle: "Premier League",
                programTime: "16:00 – 18:00",
                programProgress: 0.55,
                nextShow1Title: "Fotball Xtra",
                nextShow1Time: "18:00 – 19:00",
                nextShow2Title: "Match of the Day",
                nextShow2Time: "19:00 – 20:30",
                brandColor: Color(red: 0.10, green: 0.35, blue: 0.65),
                logoText: "V",
                streamURL: URL(string: "https://example.com/viasat.m3u8")
            ),
            IPTVDisplayChannel(
                id: "sample-skysport",
                name: "Sky Sport",
                logoAsset: "iptv_logo_skysport",
                logoURL: nil,
                group: "Sport",
                category: "Sport",
                programTitle: "Live Football",
                programTime: "17:00 – 19:00",
                programProgress: 0.30,
                nextShow1Title: "Super Sunday Preview",
                nextShow1Time: "19:00 – 19:30",
                nextShow2Title: "Premier League Highlights",
                nextShow2Time: "19:30 – 20:30",
                brandColor: Color(red: 0.72, green: 0.0, blue: 0.0),
                logoText: "sky",
                streamURL: URL(string: "https://example.com/skysport.m3u8")
            )
        ]
    }

    private func loadSampleNorwegianLineup() {
        guideTask?.cancel()
        guideTask = nil
        guideRequestID = nil
        guideByChannel = [:]
        guideUnavailable = false
        guideNextRefresh = nil
        guideFailures = 0
        selectedGuideURLs = []
        selectedGuideNeedsSameOrigin = false
        selectedGuideProgramme = nil
        selectedGuideChannelID = nil
        // Pre-populates the demo source
        let demoSource = IPTVSource(
            id: UUID(),
            name: "Norge Premium TV",
            playlistURL: "https://demo.nuvio.tv/norway.m3u",
            kind: .xtream,
            username: "demo_user",
            password: "••••••••",
            mac: nil,
            xtreamOutput: .mpegTS
        )
        sources = [demoSource]
        selectedID = demoSource.id
        selectedChannelID = "sample-nrk1"
    }

    // MARK: - Playback Execution
    private func playCurrentChannel() {
        let ch = activeSelectedChannel
        recordRecent(channelID: ch.id)
        let targetURL = ch.streamURL ?? URL(string: "https://example.com/live.m3u8")!
        play(url: targetURL, id: ch.id, name: ch.name, logo: nil)
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
        } else {
            favorites.insert(key)
        }
        IPTVFavoritesStore(defaults: ProfileSettings.store(for: profileID)).save(favorites)
    }

    private func recordRecent(channelID: String) {
        let key = favoriteKeys[channelID] ?? channelID
        recentChannelKey = key
        IPTVRecentChannelStore(defaults: ProfileSettings.store(for: profileID)).save(key)
    }

    // MARK: - Guide & EPG Calculation Helpers
    private func formatTimeRange(start: Date, end: Date) -> String {
        "\(guideTimeFormatter.string(from: start)) – \(guideTimeFormatter.string(from: end))"
    }

    private func calculateProgress(start: Date, end: Date) -> CGFloat {
        let total = end.timeIntervalSince(start)
        guard total > 0 else { return 0.5 }
        let elapsed = Date().timeIntervalSince(start)
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
        do {
            sources = try store.load(profileID: profileID)
            sourcesLoaded = true
            favorites = IPTVFavoritesStore(defaults: ProfileSettings.store(for: profileID)).load()
            let recent = IPTVRecentChannelStore(defaults: ProfileSettings.store(for: profileID))
            recentChannelKey = recent.load()

            if let source = sources.first {
                selectedID = source.id
                load(source)
            } else {
                // If no sources exist yet, load the mockup lineup by default so the user immediately sees the gorgeous UI!
                loadSampleNorwegianLineup()
            }
        } catch {
            sourcesLoaded = false
            loadSampleNorwegianLineup()
        }
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
        let token = UUID()
        requestID = token
        // Captured before loading: if the profile is deleted meanwhile, the save below does nothing.
        let sourcesGeneration = IPTVSourceStore.generation(for: profileID)
        loading = true
        errorMessage = nil
        loadTask = Task { @MainActor in
            do {
                var loaded: [IPTVChannel] = []
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
                    stalkerChannels = portalChannels
                    stalkerClient = client
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
                        return
                    }
                    sources = updated
                }
                channels = loaded
                if !loaded.isEmpty {
                    selectedChannelID = loaded[0].id
                }
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
                searchText = ""
                if !guideURLs.isEmpty {
                    loadGuide(urls: guideURLs, for: source.id, channels: loaded, sameOrigin: guideNeedsSameOrigin)
                }
            } catch {
                errorMessage = "Kunne ikke laste inn kilden."
            }
            if requestID == token {
                loading = false
                loadTask = nil
            }
        }
    }

    private func remove(_ source: IPTVSource) {
        let updated = sources.filter { $0.id != source.id }
        do {
            try store.save(updated, profileID: profileID)
            sources = updated
            if selectedID == source.id {
                selectedID = nil; channels = []
                favoriteKeys = [:]
                guideTask?.cancel(); guideTask = nil; guideRequestID = nil; guideByChannel = [:]; guideUnavailable = false; guideNextRefresh = nil; guideFailures = 0; selectedGuideURLs = []; selectedGuideNeedsSameOrigin = false; selectedGuideProgramme = nil; selectedGuideChannelID = nil
                searchText = ""
                loadSampleNorwegianLineup()
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
        guard let sourceID = selectedID, !selectedGuideURLs.isEmpty,
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
        guideRequestID = token
        guideTask?.cancel()
        guideTask = Task { @MainActor in
            @MainActor func stillCurrent() -> Bool {
                !Task.isCancelled && guideRequestID == token && selectedID == sourceID
                    && ProfileSettings.activeProfileID == profileID
            }
            do {
                let reader = sameOrigin ? IPTVGuideLoader(session: IPTVAuthenticatedSession.shared) : guideLoader
                let batch = try await reader.load(urls: urls, channelIDs: ids, window: window) { programmes in
                    guard stillCurrent() else { return }
                    guideByChannel = mergedGuide(programmes, retaining: previousGuideByChannel, at: Date())
                    if !guideByChannel.isEmpty { guideUnavailable = false }
                }
                guard stillCurrent() else { return }
                let finishedAt = Date()
                guideNow = finishedAt
                if batch.failedFeedCount == 0 {
                    guideByChannel = Dictionary(grouping: batch.programmes, by: \.channelID)
                    guideFailures = 0
                    guideNextRefresh = IPTVGuideRefreshPolicy.nextRefresh(after: batch.programmes, loadedAt: now)
                    guideUnavailable = false
                } else {
                    guideByChannel = mergedGuide(batch.programmes, retaining: previousGuideByChannel, at: finishedAt)
                    guideFailures += 1
                    let retry = IPTVGuideRefreshPolicy.retry(afterFailures: guideFailures, at: finishedAt)
                    guideNextRefresh = max(retry, finishedAt.addingTimeInterval(IPTVGuideRefreshPolicy.minInterval))
                    guideUnavailable = guideByChannel.isEmpty
                }
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
            }
            guideTask = nil
        }
    }

    private func mergedGuide(
        _ programmes: [IPTVProgramme],
        retaining previous: [String: [IPTVProgramme]],
        at now: Date
    ) -> [String: [IPTVProgramme]] {
        let lowerBound = now.addingTimeInterval(-IPTVGuideRefreshPolicy.lookBehind)
        let upperBound = now.addingTimeInterval(IPTVGuideRefreshPolicy.lookAhead)
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
