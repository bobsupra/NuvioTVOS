import SwiftUI

struct ScenePanelWatchPartyFocusContext {
    let entryLocked: Bool
    let entryFocusTarget: String
    let entryFallbackTarget: String
    let onFocusChanged: (String?) -> Void
    let onMoveUpFromContent: () -> Void
    let focusTab: (SceneTab) -> Void
}

struct ScenePanelView: View {
    @ObservedObject var viewModel: SceneViewModel
    var isAdvancing: Bool = false
    let onDismiss: () -> Void
    let onPlayNextEpisode: (() -> Void)?
    let watchPartyContent: ((
        FocusState<String?>.Binding,
        ScenePanelWatchPartyFocusContext
    ) -> AnyView)?
    let watchPartyFocusTarget: String
    /// The Chapters tab's row, given the card focus and how to leave it (like Watch Party).
    let chaptersContent: ((
        FocusState<String?>.Binding,
        ScenePanelWatchPartyFocusContext
    ) -> AnyView)?
    /// The card the Chapters tab enters on: the playing chapter's.
    let chaptersFocusTarget: String
    /// The AutoSubSync tab: its buttons and diagnostics.
    let autoSyncContent: ((
        FocusState<String?>.Binding,
        ScenePanelWatchPartyFocusContext
    ) -> AnyView)?
    let autoSyncFocusTarget: String

    private enum FocusSection: Equatable { case tabs, content }
    
    @FocusState private var focusedTab: SceneTab?
    @FocusState private var focusedCardID: String?
    @FocusState private var focusedEmptyClose: Bool
    @State private var activeFocusSection: FocusSection = .tabs
    @State private var contentFocusAnchors: [SceneTab: String] = [:]
    @State private var focusHandoffGeneration = 0
    @State private var pendingTabFocusTarget: SceneTab?
    @State private var tabOrder: [SceneTab] = TVSceneTabOrder.currentOrder()
    @State private var disabledTabs: Set<SceneTab> = TVSceneTabOrder.disabledTabs()
    @State private var needsTabReconciliation = false
    /// The card the panel is handing the focus to as it opens (the Chapters tab opens on the
    /// playing chapter): until it has it, the tabs stand aside and only that card takes focus.
    @State private var pendingCardFocusTarget: String?
    
    init(
        viewModel: SceneViewModel,
        isAdvancing: Bool = false,
        onDismiss: @escaping () -> Void,
        onPlayNextEpisode: (() -> Void)? = nil,
        watchPartyContent: ((
            FocusState<String?>.Binding,
            ScenePanelWatchPartyFocusContext
        ) -> AnyView)? = nil,
        watchPartyFocusTarget: String = "party.start",
        chaptersContent: ((
            FocusState<String?>.Binding,
            ScenePanelWatchPartyFocusContext
        ) -> AnyView)? = nil,
        chaptersFocusTarget: String = "chapter-0",
        autoSyncContent: ((
            FocusState<String?>.Binding,
            ScenePanelWatchPartyFocusContext
        ) -> AnyView)? = nil,
        autoSyncFocusTarget: String = "autosync.run"
    ) {
        self.viewModel = viewModel
        self.isAdvancing = isAdvancing
        self.onDismiss = onDismiss
        self.onPlayNextEpisode = onPlayNextEpisode
        self.watchPartyContent = watchPartyContent
        self.watchPartyFocusTarget = watchPartyFocusTarget
        self.chaptersContent = chaptersContent
        self.chaptersFocusTarget = chaptersFocusTarget
        self.autoSyncContent = autoSyncContent
        self.autoSyncFocusTarget = autoSyncFocusTarget
    }
    
    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            
            // Bottom third panel
            VStack(alignment: .leading, spacing: 22) {
                if let selectedTab = selectedVisibleTab {
                    // Tab Header Bar
                    tabHeaderBar
                        .padding(.top, 10)
                        .focusSection()

                    // Active Tab Content
                    Group {
                        content(for: selectedTab)
                    }
                    // Keep the bottom-anchored panel at a constant size across tab navigation.
                    // The previous 272/300pt switch made InSight visibly jump vertically.
                    .frame(height: 300, alignment: .top)
                    .focusSection()
                } else {
                    noAvailableSectionsState
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onExitCommand {
            onDismiss()
        }
        .onDisappear {
            focusHandoffGeneration &+= 1
            pendingTabFocusTarget = nil
            pendingCardFocusTarget = nil
        }
        .onAppear {
            reloadSettings()
            if let firstTab = visibleTabs.first {
                if firstTab == .chapters, chaptersContent != nil {
                    // Chapters open straight on the playing chapter: one Down from playback.
                    // Up goes to the tabs, and Up again closes the panel.
                    openOnChapters()
                } else {
                    requestTabFocus(firstTab)
                }
            } else {
                reconcileAvailableTabs()
            }
        }
        .onChange(of: visibleTabs) { _, _ in
            reconcileAvailableTabs()
        }
        .onChange(of: viewModel.availableTabs) { _, _ in
            reconcileAvailableTabs()
        }
        .onChange(of: viewModel.isDetailVisible) { _, isVisible in
            if isVisible {
                if pendingTabFocusTarget != nil {
                    needsTabReconciliation = true
                }
                invalidateFocusHandoff()
            } else if needsTabReconciliation {
                needsTabReconciliation = false
                if !reloadSettings() {
                    reconcileAvailableTabs()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: TVSceneTabOrder.changedNotification).receive(on: RunLoop.main)) { _ in
            reloadSettings()
        }
        .onReceive(NotificationCenter.default.publisher(for: ProfileSettings.settingsChangedNotification).receive(on: RunLoop.main)) { _ in
            reloadSettings()
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: RunLoop.main)) { _ in
            reloadSettings()
        }
        .onChange(of: focusedTab) { _, newTab in
            guard !viewModel.isDetailVisible else { return }
            if let card = pendingCardFocusTarget {
                // A tab took the focus while the panel opens on a card: hand it back.
                if newTab != nil { reassertPendingCardFocus(card) }
                return
            }
            if let pending = pendingTabFocusTarget {
                guard let newTab else {
                    reassertPendingTabFocus(pending)
                    return
                }
                if newTab == pending {
                    activeFocusSection = .tabs
                } else {
                    reassertPendingTabFocus(pending)
                }
                return
            }
            guard let newTab else { return }
            guard visibleTabs.contains(newTab) else {
                reconcileAvailableTabs()
                return
            }
            invalidateFocusHandoff()
            activeFocusSection = .tabs
            if viewModel.selectedTab != newTab {
                withAnimation(.easeInOut(duration: 0.18)) {
                    viewModel.selectTab(newTab)
                }
            }
        }
        .onChange(of: viewModel.selectedTab) { _, newTab in
            guard !viewModel.isDetailVisible else { return }
            // Opening on a chapter card selects the Chapters tab without focusing it.
            guard pendingCardFocusTarget == nil else { return }
            guard visibleTabs.contains(newTab) else {
                reconcileAvailableTabs()
                return
            }
            if let pending = pendingTabFocusTarget {
                if pending != newTab { requestTabFocus(newTab) }
                else { activeFocusSection = .tabs }
            } else if focusedTab == newTab {
                activeFocusSection = .tabs
            } else {
                requestTabFocus(newTab)
            }
        }
        .onChange(of: focusedCardID) { _, newID in
            guard !viewModel.isDetailVisible else { return }
            if let pending = pendingTabFocusTarget {
                reassertPendingTabFocus(pending)
                return
            }
            guard let newID else { return }
            guard visibleTabs.contains(viewModel.selectedTab) else {
                reconcileAvailableTabs()
                return
            }
            activeFocusSection = .content
            if isValidContentAnchor(newID, for: viewModel.selectedTab) {
                contentFocusAnchors[viewModel.selectedTab] = newID
            }
        }
        .onChange(of: viewModel.snapshot.actors.map(\.id)) { _, _ in
            reconcileActiveContentFocus()
        }
        .onChange(of: viewModel.snapshot.song?.id) { _, _ in
            reconcileActiveContentFocus()
        }
        .onChange(of: viewModel.nextEpisode?.id) { _, _ in
            reconcileActiveContentFocus()
        }
        .onChange(of: watchPartyFocusTarget) { _, _ in
            reconcileActiveContentFocus()
        }
    }
    
    // MARK: - Tab Header Bar
    
    private var tabHeaderBar: some View {
        HStack(spacing: 20) {
            ForEach(visibleTabs) { tab in
                let isSelected = selectedVisibleTab == tab
                let isTabFocused = focusedTab == tab
                
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        viewModel.selectTab(tab)
                    }
                }) {
                    Text(tab.localizedTitle)
                        .font(.system(size: 26, weight: isTabFocused ? .bold : .semibold))
                        .foregroundColor(isTabFocused ? .black : .white.opacity(0.92))
                        .padding(.horizontal, 36)
                        .frame(height: 64)
                        .modifier(TvDetailsGlassBackground(filled: isTabFocused, shape: Capsule()))
                        .overlay {
                            ZStack {
                                if isSelected && !isTabFocused {
                                    Capsule().fill(Color.white.opacity(0.22))
                                }
                                Capsule()
                                    .stroke(Color.white.opacity(isSelected && !isTabFocused ? 0.26 : 0), lineWidth: 1)
                            }
                            .allowsHitTesting(false)
                        }
                }
                .buttonStyle(PosterCardButtonStyle())
                .focused($focusedTab, equals: tab)
                .focusEffectDisabledIfAvailable()
                .disabled((pendingTabFocusTarget != nil && pendingTabFocusTarget != tab)
                    || pendingCardFocusTarget != nil
                    || (activeFocusSection == .content && selectedVisibleTab != tab))
                .scaleEffect(isTabFocused ? 1.05 : 1.0)
                .animation(.easeOut(duration: 0.14), value: isTabFocused)
                .onExitCommand(perform: onDismiss)
                .onMoveCommand { direction in
                    switch direction {
                    case .up:
                        onDismiss()
                    case .down:
                        focusFirstCard()
                    default:
                        break
                    }
                }
            }
        }
        .padding(.horizontal, 60)
        .frame(maxWidth: .infinity, alignment: .leading)
        .defaultFocus($focusedTab, selectedVisibleTab ?? .scene)
    }

    private var visibleTabs: [SceneTab] {
        var runtimeTabs = viewModel.availableTabs.filter {
            $0 != .watchParty && ($0 != .autoSync || autoSyncContent != nil)
        }
        if watchPartyContent != nil {
            runtimeTabs.append(.watchParty)
        }
        let runtimeTabSet = Set(runtimeTabs)
        return tabOrder.filter { runtimeTabSet.contains($0) && !disabledTabs.contains($0) }
    }

    private var selectedVisibleTab: SceneTab? {
        let tabs = visibleTabs
        return tabs.contains(viewModel.selectedTab) ? viewModel.selectedTab : tabs.first
    }

    private var noAvailableSectionsState: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.string("tvos_settings_no_insight_sections_available", fallback: "No InSight sections are available for this playback"))
                .font(.system(size: 24, weight: .semibold))
                .foregroundColor(.white.opacity(0.84))

            Button(action: onDismiss) {
                Text(L10n.string("action_close", fallback: "Close InSight"))
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(focusedEmptyClose ? .black : .white)
                    .padding(.horizontal, 28)
                    .frame(height: 56)
                    .modifier(TvDetailsGlassBackground(filled: focusedEmptyClose, shape: Capsule()))
            }
            .buttonStyle(PosterCardButtonStyle())
            .focused($focusedEmptyClose)
            .focusEffectDisabledIfAvailable()
            .onExitCommand(perform: onDismiss)
        }
        .frame(maxWidth: .infinity, minHeight: 300, alignment: .leading)
        .padding(.horizontal, 60)
        .focusSection()
    }

    @ViewBuilder
    private func content(for tab: SceneTab) -> some View {
        switch tab {
        case .chapters:
            if let chaptersContent {
                chaptersContent(
                    $focusedCardID,
                    ScenePanelWatchPartyFocusContext(
                        entryLocked: viewModel.isDetailVisible
                            || activeFocusSection != .content
                            || pendingCardFocusTarget != nil,
                        entryFocusTarget: pendingCardFocusTarget
                            ?? contentFocusAnchor(for: .chapters) ?? chaptersFocusTarget,
                        entryFallbackTarget: chaptersFocusTarget,
                        onFocusChanged: rememberChapterFocus,
                        onMoveUpFromContent: focusSelectedTabFromContent,
                        focusTab: requestTabFocus
                    )
                )
            } else {
                EmptyView()
            }
        case .autoSync:
            if let autoSyncContent {
                autoSyncContent(
                    $focusedCardID,
                    ScenePanelWatchPartyFocusContext(
                        entryLocked: viewModel.isDetailVisible || activeFocusSection != .content,
                        entryFocusTarget: contentFocusAnchor(for: .autoSync) ?? autoSyncFocusTarget,
                        entryFallbackTarget: autoSyncFocusTarget,
                        onFocusChanged: rememberAutoSyncFocus,
                        onMoveUpFromContent: focusSelectedTabFromContent,
                        focusTab: requestTabFocus
                    )
                )
            } else {
                EmptyView()
            }
        case .scene:
            sceneTabContent
        case .info:
            infoTabContent
        case .upNext:
            upNextTabContent
        case .watchParty:
            if let watchPartyContent {
                watchPartyContent(
                    $focusedCardID,
                    ScenePanelWatchPartyFocusContext(
                        entryLocked: viewModel.isDetailVisible || activeFocusSection != .content,
                        entryFocusTarget: contentFocusAnchor(for: .watchParty) ?? watchPartyFocusTarget,
                        entryFallbackTarget: watchPartyFocusTarget,
                        onFocusChanged: rememberWatchPartyFocus,
                        onMoveUpFromContent: focusSelectedTabFromContent,
                        focusTab: requestTabFocus
                    )
                )
            } else {
                EmptyView()
            }
        }
    }
    
    // MARK: - Scene Tab Content
    
    private var sceneTabContent: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 20) {
                let recognizedActors = viewModel.snapshot.actors
                let playingSong = viewModel.snapshot.song
                
                if recognizedActors.isEmpty, let song = playingSong {
                    let isSongFocused = focusedCardID == "song-\(song.id)"
                    SceneSongCard(song: song, isFocused: isSongFocused) {
                        viewModel.openDetail(.song(song))
                    }
                    .focused($focusedCardID, equals: "song-\(song.id)")
                    .disabled(isContentEntryLocked("song-\(song.id)"))
                    .onExitCommand(perform: onDismiss)
                    .onMoveCommand { direction in
                        if direction == .up {
                            focusSelectedTabFromContent()
                        }
                    }
                } else if !recognizedActors.isEmpty {
                    ForEach(recognizedActors) { actor in
                        let isActorFocused = focusedCardID == "actor-\(actor.id)"
                        SceneActorCard(
                            actor: actor,
                            isLiveRecognized: true,
                            isFocused: isActorFocused
                        ) {
                            viewModel.openDetail(.actor(actor, detail: nil))
                        }
                        .focused($focusedCardID, equals: "actor-\(actor.id)")
                        .disabled(isContentEntryLocked("actor-\(actor.id)"))
                        .onExitCommand(perform: onDismiss)
                        .onMoveCommand { direction in
                            if direction == .up {
                                focusSelectedTabFromContent()
                            }
                        }
                    }
                    
                    if let song = playingSong {
                        let isSongFocused = focusedCardID == "song-\(song.id)"
                        SceneSongCard(song: song, isFocused: isSongFocused) {
                            viewModel.openDetail(.song(song))
                        }
                        .focused($focusedCardID, equals: "song-\(song.id)")
                        .disabled(isContentEntryLocked("song-\(song.id)"))
                        .onExitCommand(perform: onDismiss)
                        .onMoveCommand { direction in
                            if direction == .up {
                                focusSelectedTabFromContent()
                            }
                        }
                    }
                } else {
                    statusCard
                }
            }
            .padding(.horizontal, 60)
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
        .scrollClipDisabled()
    }
    
    @ViewBuilder
    private var statusCard: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 0)
            switch viewModel.snapshot.actorStatus {
            case .analyzing, .preparingReferences:
                ProgressView()
                    .scaleEffect(1.2)
                    .padding(.bottom, 6)
                Text(viewModel.isAnime ? "Loading cast…" : "Scanning scene…")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
            case .unavailable(let reason):
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.system(size: 38))
                    .foregroundColor(.white.opacity(0.35))
                    .padding(.bottom, 4)
                Text(reason.isEmpty ? (viewModel.isAnime ? "No cast available" : "No actors in this shot") : reason)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
            default:
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.system(size: 38))
                    .foregroundColor(.white.opacity(0.35))
                    .padding(.bottom, 4)
                Text(viewModel.isAnime ? "No cast for this episode" : "No actors in this shot")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 12)
        .frame(width: 184, height: 256)
        .modifier(TvCardGlassBackground(isFocused: false, shape: RoundedRectangle(cornerRadius: 32, style: .continuous)))
    }
    
    // MARK: - Info Tab Content (Horizontal Playback Telemetry)
    
    private var infoTabContent: some View {
        let info = viewModel.playbackInfo ?? ScenePlaybackInfo()
        
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 20) {
                // Section 1: PLAYBACK ENGINE
                telemetryCard(title: "PLAYBACK ENGINE", width: 340, height: 256) {
                    VStack(alignment: .leading, spacing: 6) {
                        infoRow(label: "Engine", value: info.engine)
                        infoRow(label: "Version", value: info.version)
                    }
                }
                
                // Section 2: VIDEO STREAM
                telemetryCard(title: "VIDEO STREAM", width: 560, height: 256) {
                    VStack(alignment: .leading, spacing: 4) {
                        infoRow(label: "Codec", value: info.videoCodec)
                        infoRow(label: "Resolution", value: info.resolution)
                        infoRow(label: "Frame Rate", value: info.frameRate)
                        infoRow(label: "Dynamic Range", value: info.dynamicRange)
                        if let profile = info.dolbyVisionProfile, !profile.isEmpty {
                            infoRow(label: "Dolby Vision Profile", value: profile)
                        }
                        infoRow(label: "Bitrate", value: info.videoBitrate)
                        infoRow(label: "Container", value: info.container)
                        infoRow(label: "Decoder", value: info.videoDecoder)
                    }
                }
                
                // Section 3: AUDIO STREAM
                telemetryCard(title: "AUDIO STREAM", width: 540, height: 256) {
                    VStack(alignment: .leading, spacing: 6) {
                        infoRow(label: "Codec", value: info.audioCodec)
                        infoRow(label: "Channels", value: info.audioChannels)
                        infoRow(label: "Language", value: info.audioLanguage)
                        infoRow(label: "Bitrate", value: info.audioBitrate)
                        infoRow(label: "A/V producer gap", value: formattedAVSyncGap(info.avSyncGapMs))
                        infoRow(label: "Spatial format", value: info.audioSpatialFormat)
                        infoRow(label: "Audio pipeline", value: info.audioDecoder, lineLimit: 2)
                    }
                }
            }
            .padding(.horizontal, 60)
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
        .scrollClipDisabled()
    }
    
    private func telemetryCard<Content: View>(
        title: String,
        width: CGFloat,
        height: CGFloat = 236,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 15, weight: .heavy))
                .foregroundColor(.white)
                .tracking(1.2)
            
            Rectangle()
                .fill(Color.white.opacity(0.14))
                .frame(height: 1)
                .padding(.bottom, 2)
            
            content()
            
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .frame(width: width, height: height, alignment: .topLeading)
        .modifier(TvCardGlassBackground(isFocused: false, shape: RoundedRectangle(cornerRadius: 32, style: .continuous)))
    }
    
    private func infoRow(label: String, value: String, lineLimit: Int = 1) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(label)
                .font(.system(size: 15, weight: .regular))
                .foregroundColor(Color.white.opacity(0.65))
                .lineLimit(1)
                .frame(minWidth: 90, alignment: .leading)
            
            Spacer(minLength: 12)
            
            Text(value)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(lineLimit)
                .truncationMode(.tail)
                .multilineTextAlignment(.trailing)
        }
    }
    
    // MARK: - Up Next Tab Content
    
    @ViewBuilder
    private var upNextTabContent: some View {
        let isNextFocused = focusedCardID == "upNext"
        
        VStack(alignment: .leading, spacing: 0) {
            if let next = viewModel.nextEpisode {
                let isPlayable = EpisodeReleasePolicy.hasAired(next.released)
                let airDateText = EpisodeReleasePolicy.airDateText(for: next.released).map { "Airs \($0)" } ?? "Upcoming"
                
                Button(action: {
                    guard isPlayable else { return }
                    onPlayNextEpisode?()
                }) {
                    HStack(spacing: 24) {
                        // Thumbnail
                        ZStack {
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .fill(isNextFocused ? Color.black.opacity(0.08) : Color.white.opacity(0.12))
                                .frame(width: 300, height: 170)
                            
                            if let thumb = next.thumbnail, let url = URL(string: thumb) {
                                AsyncImage(url: url) { phase in
                                    if let img = phase.image {
                                        img.resizable().scaledToFill()
                                            .frame(width: 300, height: 170)
                                            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                                    }
                                }
                            }
                        }
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Up Next")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(isNextFocused ? Color(red: 0.0, green: 0.45, blue: 0.85) : Color(red: 0.10, green: 0.68, blue: 1.0))
                                .textCase(.uppercase)
                            
                            Text("S\(next.season) · E\(next.episode): \(next.title)")
                                .font(.system(size: 24, weight: .bold))
                                .foregroundColor(isNextFocused ? .black : .white)
                                .lineLimit(1)
                            
                            if !isPlayable {
                                Text(airDateText)
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundColor(isNextFocused ? Color.black.opacity(0.7) : Color.white.opacity(0.7))
                            } else if let overview = next.overview, !overview.isEmpty {
                                Text(overview)
                                    .font(.system(size: 16, weight: .regular))
                                    .foregroundColor(isNextFocused ? Color.black.opacity(0.7) : Color.white.opacity(0.7))
                                    .lineLimit(2)
                            }

                            HStack(spacing: 8) {
                                if isAdvancing {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: isNextFocused && isPlayable ? .black : .white))
                                        .scaleEffect(0.8)
                                    Text(L10n.string("player_starting", fallback: "Starting…"))
                                        .font(.system(size: 16, weight: .semibold))
                                } else {
                                    Image(systemName: isPlayable ? "play.fill" : "calendar")
                                        .font(.system(size: 14))
                                    Text(isPlayable ? L10n.string("tvos_play_next_episode", fallback: "Play Next Episode") : L10n.string("player_not_yet", fallback: "Not Yet"))
                                        .font(.system(size: 16, weight: .semibold))
                                }
                            }
                            .foregroundColor(isNextFocused && isPlayable ? .black : .white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .background(
                                Capsule()
                                    .fill(isNextFocused && isPlayable ? Color.white : Color.white.opacity(0.2))
                            )
                            .padding(.top, 4)
                        }
                        .frame(maxWidth: 520, alignment: .leading)
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 16)
                    .frame(height: 256)
                    .modifier(TvDetailsGlassBackground(filled: isNextFocused, shape: RoundedRectangle(cornerRadius: 32, style: .continuous)))
                }
                .buttonStyle(PosterCardButtonStyle())
                .focused($focusedCardID, equals: "upNext")
                .disabled(isContentEntryLocked("upNext"))
                .focusEffectDisabledIfAvailable()
                .scaleEffect(isNextFocused ? 1.03 : 1.0)
                .animation(.easeOut(duration: 0.14), value: isNextFocused)
                .onExitCommand(perform: onDismiss)
                .onMoveCommand { direction in
                    if direction == .up {
                        focusSelectedTabFromContent()
                    }
                }
                .padding(.horizontal, 60)
                .padding(.top, 16)
            } else {
                Text("No upcoming episode")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
                    .padding(.horizontal, 60)
                    .padding(.top, 24)
            }
            
            Spacer(minLength: 0)
        }
    }
    
    // MARK: - Focus Management

    @discardableResult
    private func reloadSettings() -> Bool {
        let currentOrder = TVSceneTabOrder.currentOrder()
        let currentDisabledTabs = TVSceneTabOrder.disabledTabs()
        let settingsChanged = tabOrder != currentOrder || disabledTabs != currentDisabledTabs
        guard settingsChanged else { return false }
        if viewModel.isDetailVisible {
            needsTabReconciliation = true
            return false
        }
        tabOrder = currentOrder
        disabledTabs = currentDisabledTabs
        reconcileAvailableTabs()
        return true
    }

    private func reconcileAvailableTabs() {
        guard !viewModel.isDetailVisible else {
            needsTabReconciliation = true
            return
        }
        let tabs = visibleTabs
        guard let firstTab = tabs.first else {
            invalidateFocusHandoff()
            activeFocusSection = .tabs
            focusedTab = nil
            focusedCardID = nil
            focusedEmptyClose = true
            return
        }

        focusedEmptyClose = false
        let target = tabs.contains(viewModel.selectedTab) ? viewModel.selectedTab : firstTab
        guard viewModel.selectedTab == target else {
            requestTabFocus(target)
            return
        }

        if activeFocusSection == .content {
            reconcileActiveContentFocus()
        } else if focusedTab != target {
            activeFocusSection = .tabs
            focusedTab = target
        }
    }
    
    private func focusFirstCard() {
        guard !viewModel.isDetailVisible else { return }
        invalidateFocusHandoff()
        let generation = focusHandoffGeneration
        guard let tab = selectedVisibleTab else {
            reconcileAvailableTabs()
            return
        }
        guard let target = contentFocusAnchor(for: tab) else {
            requestTabFocus(tab)
            return
        }
        activeFocusSection = .content
        focusedCardID = target
        DispatchQueue.main.async {
            guard focusHandoffGeneration == generation,
                  !viewModel.isDetailVisible,
                  viewModel.selectedTab == tab,
                  activeFocusSection == .content else { return }
            guard let currentTarget = contentFocusAnchor(for: tab) else {
                focusSelectedTabFromContent()
                return
            }
            if focusedCardID != currentTarget {
                focusedCardID = currentTarget
            }
        }
    }

    private func focusSelectedTabFromContent() {
        guard let tab = selectedVisibleTab else {
            reconcileAvailableTabs()
            return
        }
        requestTabFocus(tab)
    }

    private func requestTabFocus(_ tab: SceneTab) {
        guard !viewModel.isDetailVisible else {
            needsTabReconciliation = true
            return
        }
        guard visibleTabs.contains(tab) else {
            reconcileAvailableTabs()
            return
        }
        invalidateFocusHandoff()
        let generation = focusHandoffGeneration
        pendingTabFocusTarget = tab
        activeFocusSection = .tabs
        if viewModel.selectedTab != tab {
            withAnimation(.easeInOut(duration: 0.18)) {
                viewModel.selectTab(tab)
            }
        }
        focusedCardID = nil
        focusedTab = tab
        DispatchQueue.main.async {
            guard focusHandoffGeneration == generation,
                  !viewModel.isDetailVisible,
                  viewModel.selectedTab == tab,
                  pendingTabFocusTarget == tab else { return }
            if focusedTab != tab { focusedTab = tab }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard focusHandoffGeneration == generation,
                  !viewModel.isDetailVisible,
                  pendingTabFocusTarget == tab else { return }
            pendingTabFocusTarget = nil
        }
    }

    private func reassertPendingTabFocus(_ tab: SceneTab) {
        guard !viewModel.isDetailVisible else {
            needsTabReconciliation = true
            return
        }
        guard visibleTabs.contains(tab) else {
            reconcileAvailableTabs()
            return
        }
        let generation = focusHandoffGeneration
        DispatchQueue.main.async {
            guard focusHandoffGeneration == generation,
                  !viewModel.isDetailVisible,
                  pendingTabFocusTarget == tab,
                  viewModel.selectedTab == tab else { return }
            if focusedTab != tab { focusedTab = tab }
        }
    }

    /// Opens on the playing chapter's card instead of the Chapters tab (see `requestCardFocus`).
    private func openOnChapters() {
        if viewModel.selectedTab != .chapters {
            viewModel.selectTab(.chapters)
        }
        guard let card = contentFocusAnchor(for: .chapters) else {
            requestTabFocus(.chapters)
            return
        }
        requestCardFocus(card)
    }

    /// Hands the focus to a card of the selected tab instead of its tab, like `requestTabFocus`:
    /// while the handoff settles, the tabs are disabled and the card is the only one that can focus.
    private func requestCardFocus(_ card: String) {
        guard !viewModel.isDetailVisible else { return }
        invalidateFocusHandoff()
        let generation = focusHandoffGeneration
        let tab = viewModel.selectedTab
        pendingCardFocusTarget = card
        activeFocusSection = .content
        focusedCardID = card
        DispatchQueue.main.async {
            guard focusHandoffGeneration == generation,
                  !viewModel.isDetailVisible,
                  viewModel.selectedTab == tab,
                  pendingCardFocusTarget == card else { return }
            if focusedCardID != card { focusedCardID = card }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard focusHandoffGeneration == generation,
                  pendingCardFocusTarget == card else { return }
            pendingCardFocusTarget = nil
            // The card never took the focus: the tab takes it, as for the other tabs.
            if focusedCardID == nil, focusedTab == nil { focusSelectedTabFromContent() }
        }
    }

    private func reassertPendingCardFocus(_ card: String) {
        let generation = focusHandoffGeneration
        DispatchQueue.main.async {
            guard focusHandoffGeneration == generation,
                  !viewModel.isDetailVisible,
                  pendingCardFocusTarget == card else { return }
            activeFocusSection = .content
            if focusedCardID != card { focusedCardID = card }
        }
    }

    private func invalidateFocusHandoff() {
        focusHandoffGeneration &+= 1
        pendingTabFocusTarget = nil
        pendingCardFocusTarget = nil
    }

    private func isContentEntryLocked(_ id: String) -> Bool {
        guard activeFocusSection != .content else { return false }
        return contentFocusAnchor(for: viewModel.selectedTab) != id
    }

    private func contentFocusAnchor(for tab: SceneTab) -> String? {
        let anchors: [String]
        switch tab {
        case .chapters:
            anchors = [contentFocusAnchors[.chapters] ?? chaptersFocusTarget]
        case .autoSync:
            anchors = [contentFocusAnchors[.autoSync] ?? autoSyncFocusTarget]
        case .scene:
            let actors = viewModel.snapshot.actors.map { "actor-\($0.id)" }
            let song = viewModel.snapshot.song.map { "song-\($0.id)" }
            anchors = actors.isEmpty ? (song.map { [$0] } ?? []) : actors + (song.map { [$0] } ?? [])
        case .info:
            anchors = []
        case .upNext:
            anchors = viewModel.nextEpisode == nil ? [] : ["upNext"]
        case .watchParty:
            anchors = [contentFocusAnchors[.watchParty] ?? watchPartyFocusTarget]
        }
        if let remembered = contentFocusAnchors[tab], anchors.contains(remembered) {
            return remembered
        }
        return anchors.first
    }

    private func isValidContentAnchor(_ id: String, for tab: SceneTab) -> Bool {
        switch tab {
        case .chapters:
            return id.hasPrefix("chapter-")
        case .autoSync:
            return id.hasPrefix("autosync.")
        case .scene:
            return contentFocusAnchorCandidates(for: tab).contains(id)
        case .info:
            return false
        case .upNext:
            return id == "upNext" && viewModel.nextEpisode != nil
        case .watchParty:
            return id.hasPrefix("party.")
        }
    }

    private func contentFocusAnchorCandidates(for tab: SceneTab) -> [String] {
        guard tab == .scene else { return [] }
        let actors = viewModel.snapshot.actors.map { "actor-\($0.id)" }
        let song = viewModel.snapshot.song.map { "song-\($0.id)" }
        return actors + (song.map { [$0] } ?? [])
    }

    /// The chapter cards report their focus, like Watch Party's controls.
    private func rememberChapterFocus(_ id: String?) {
        guard !viewModel.isDetailVisible else { return }
        if let pending = pendingTabFocusTarget {
            reassertPendingTabFocus(pending)
            return
        }
        guard let id, isValidContentAnchor(id, for: .chapters) else { return }
        contentFocusAnchors[.chapters] = id
        activeFocusSection = .content
    }

    /// The AutoSubSync buttons report their focus, like Watch Party's controls.
    private func rememberAutoSyncFocus(_ id: String?) {
        guard !viewModel.isDetailVisible else { return }
        if let pending = pendingTabFocusTarget {
            reassertPendingTabFocus(pending)
            return
        }
        guard let id, isValidContentAnchor(id, for: .autoSync) else { return }
        contentFocusAnchors[.autoSync] = id
        activeFocusSection = .content
    }

    private func rememberWatchPartyFocus(_ id: String?) {
        guard !viewModel.isDetailVisible else { return }
        if let pending = pendingTabFocusTarget {
            reassertPendingTabFocus(pending)
            return
        }
        guard let id, isValidContentAnchor(id, for: .watchParty) else { return }
        contentFocusAnchors[.watchParty] = id
        activeFocusSection = .content
    }

    private func reconcileActiveContentFocus() {
        guard !viewModel.isDetailVisible else {
            needsTabReconciliation = true
            return
        }
        guard activeFocusSection == .content else { return }
        guard let tab = selectedVisibleTab else {
            reconcileAvailableTabs()
            return
        }
        if let focusedCardID, isValidContentAnchor(focusedCardID, for: tab) {
            return
        }
        guard let target = contentFocusAnchor(for: tab) else {
            focusSelectedTabFromContent()
            return
        }
        focusedCardID = target
    }
}
