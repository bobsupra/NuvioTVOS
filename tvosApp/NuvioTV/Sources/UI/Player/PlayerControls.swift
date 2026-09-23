import SwiftUI
import AVKit
import CoreGraphics

enum PlayerControlFocus: Hashable {
    case pip
    case episodes
    case sources
    case subtitles
    case settings
    case timeline
}

struct PlayerControls: View {
    @ObservedObject var viewModel: PlayerViewModel
    var isSkipSegmentFocused: Bool = false
    var isNextEpisodeFocused: Bool = false
    @Binding var requestedFocus: PlayerControlFocus?
    var onFocusSkipSegment: () -> Void = {}
    var onFocusNextEpisode: () -> Void = {}

    @FocusState private var focusedControl: PlayerControlFocus?

    @AppStorage(SettingsKey.playerShowPiP) private var playerShowPiP = true
    @AppStorage(SettingsKey.playerShowEpisodes) private var playerShowEpisodes = true
    @AppStorage(SettingsKey.playerShowSources) private var playerShowSources = true
    @AppStorage(SettingsKey.playerShowSubtitles) private var playerShowSubtitles = true

    var body: some View {
        GlassControlsContainer {
            VStack {
                topBar
                Spacer()
                bottomControls
            }
        }
        .onExitCommand {
            if viewModel.isScrubbing {
                viewModel.cancelScrub()
            } else {
                viewModel.hideControls()
            }
        }
        .onChange(of: requestedFocus) { _, target in
            guard let target, viewModel.showControls else { return }
            DispatchQueue.main.async {
                if target == .timeline {
                    focusedControl = .timeline
                } else {
                    focusedControl = isTransportButtonFocusable(target) ? target : (transportFocusOrder.first ?? .settings)
                }
                requestedFocus = nil
            }
        }
        .onChange(of: viewModel.showSettingsPanel) { _, isPresented in
            if !isPresented, viewModel.showControls {
                DispatchQueue.main.async { focusedControl = .settings }
            }
        }
        .onAppear {
            if isPlaybackStarted,
               !viewModel.showPauseOverlay,
               !viewModel.postPlayState.isVisible,
               !isSkipSegmentFocused,
               !isNextEpisodeFocused {
                DispatchQueue.main.async {
                    focusedControl = viewModel.isLiveStream ? (transportFocusOrder.first ?? .settings) : .timeline
                }
            }
        }
        .onChange(of: viewModel.status) { _, status in
            if status == .paused,
               viewModel.showControls,
               !viewModel.showPauseOverlay,
               !viewModel.postPlayState.isVisible,
               !isSkipSegmentFocused,
               !isNextEpisodeFocused {
                DispatchQueue.main.async {
                    focusedControl = viewModel.isLiveStream ? (transportFocusOrder.first ?? .settings) : .timeline
                }
            } else if status == .playing,
               viewModel.showControls,
               !viewModel.showPauseOverlay,
               !viewModel.postPlayState.isVisible,
               !isSkipSegmentFocused,
               !isNextEpisodeFocused,
               focusedControl == nil {
                DispatchQueue.main.async {
                    focusedControl = viewModel.isLiveStream ? (transportFocusOrder.first ?? .settings) : .timeline
                }
            }
        }
        .onChange(of: viewModel.showControls) { _, isVisible in
            // Don't steal focus while the pause metadata sheet, loading, or post play owns the remote.
            if isVisible,
               isPlaybackStarted,
               !viewModel.isSwitchingSource,
               !viewModel.showPauseOverlay,
               !viewModel.postPlayState.isVisible,
               !isSkipSegmentFocused,
               !isNextEpisodeFocused {
                DispatchQueue.main.async {
                    focusedControl = viewModel.isLiveStream ? (transportFocusOrder.first ?? .settings) : .timeline
                }
            } else if !isVisible {
                DispatchQueue.main.async {
                    focusedControl = nil
                }
            }
        }
        .onChange(of: viewModel.isTimelineFocused) { _, isTimelineFocused in
            if isTimelineFocused,
               viewModel.showControls,
               !viewModel.showPauseOverlay,
               !viewModel.postPlayState.isVisible,
               !isSkipSegmentFocused,
               !isNextEpisodeFocused,
               focusedControl != .timeline {
                DispatchQueue.main.async {
                    focusedControl = viewModel.isLiveStream ? (transportFocusOrder.first ?? .settings) : .timeline
                }
            }
        }
        .onChange(of: viewModel.isLiveStream) { _, isLive in
            if isLive, focusedControl == .timeline {
                DispatchQueue.main.async { focusedControl = transportFocusOrder.first ?? .settings }
            }
        }
        .onChange(of: viewModel.showPauseOverlay) { _, visible in
            if visible { focusedControl = nil }
        }
        .onChange(of: viewModel.postPlayState.isVisible) { _, visible in
            if visible { focusedControl = nil }
        }
        .onChange(of: isSkipSegmentFocused) { _, isFocused in
            if isFocused { focusedControl = nil }
        }
        .onChange(of: isNextEpisodeFocused) { _, isFocused in
            if isFocused { focusedControl = nil }
        }
        .onChange(of: viewModel.isHoldingSeek) { _, isHolding in
            if isHolding, viewModel.showControls {
                DispatchQueue.main.async {
                    focusedControl = .timeline
                }
            }
        }
        .onChange(of: focusedControl) { _, newControl in
            // Keep this in lockstep with focus so hold-to-seek gating is correct
            // even before the next render cycle.
            let onTimeline = (newControl == .timeline)
            viewModel.setTimelineFocused(onTimeline)
            viewModel.setControlsAutoHideSuspended(false)
            if onTimeline {
                viewModel.scheduleControlsHide(after: 5.0)
            } else if newControl != nil {
                viewModel.scheduleControlsHide(after: 10.0)
            }
        }
        .onDisappear {
            viewModel.setTimelineFocused(false)
            viewModel.setControlsAutoHideSuspended(false)
        }
    }

    private var isPlaybackStarted: Bool {
        viewModel.status == .playing || viewModel.status == .paused || viewModel.time.duration > 0 || viewModel.isLiveStream || viewModel.hasRenderedFirstFrame
    }

    /// Transport + timeline are focusable whenever chrome is up. Do not gate on
    /// `focusedControl != .timeline` — toggling `.focusable` when moving between
    /// buttons left Select dead after visiting settings/episodes/sources.
    private var controlsInteractable: Bool {
        (viewModel.showControls || viewModel.isScrubbing)
            && isPlaybackStarted
            && !viewModel.isSwitchingSource
            && !viewModel.showPauseOverlay
            && !viewModel.showSettingsPanel
            && !viewModel.postPlayState.isVisible
            && viewModel.sidePanel == nil
    }

    /// Left-to-right order of currently visible transport buttons.
    private var transportFocusOrder: [PlayerControlFocus] {
        var order: [PlayerControlFocus] = []
        if viewModel.isPictureInPictureSupported && playerShowPiP { order.append(.pip) }
        if viewModel.canShowEpisodesPanel && playerShowEpisodes { order.append(.episodes) }
        if viewModel.canShowSourcesPanel && playerShowSources { order.append(.sources) }
        if canShowSubtitlePicker && playerShowSubtitles { order.append(.subtitles) }
        order.append(.settings)
        return order
    }

    private var canShowSubtitlePicker: Bool {
        !subtitlePanelOptions(for: viewModel).isEmpty
    }

    private var subtitleNoneOption: SubtitlePanelOption? {
        guard let off = viewModel.subtitles.first(where: { $0.id == "off" }) else { return nil }
        return SubtitlePanelOption(
            id: "off",
            kind: .track(off),
            badge: "",
            title: "None",
            detail: nil,
            language: "",
            isSelected: off.isSelected
        )
    }

    private var subtitlePickerOptions: [SubtitlePanelOption] {
        subtitlePanelOptions(for: viewModel)
    }

    /// Settings-style flash prevention: while the progress bar owns focus, only
    /// the first transport button stays focusable in the transport row. tvOS spatial focus lands on the
    /// geometric nearest *focusable* control — with a single candidate it goes
    /// straight to it, so other buttons never receive a one-frame flash.
    /// Once any transport button is focused, every visible button is focusable
    /// again so left/right still walks the full row.
    private func isTransportButtonFocusable(_ key: PlayerControlFocus) -> Bool {
        guard controlsInteractable else { return false }
        if focusedControl == .timeline || focusedControl == nil {
            return key == (transportFocusOrder.first ?? .settings)
        }
        return true
    }

    private func moveFocus(to control: PlayerControlFocus) {
        // tvOS often applies spatial focus *before* `onMoveCommand` runs (and
        // may also apply it after). Force the intended control now and re-assert
        // on the next runloop so native geometry cannot keep a wrong target
        // (e.g. episodes → settings skipping sources).
        focusedControl = control
        DispatchQueue.main.async {
            focusedControl = control
        }
    }

    /// Navigate from the control that *received* the move — not `focusedControl`,
    /// which may already have been updated by the spatial focus engine.
    private func handleMove(_ direction: MoveCommandDirection, from origin: PlayerControlFocus) {
        guard !isSkipSegmentFocused, !isNextEpisodeFocused else { return }
        guard controlsInteractable else { return }

        // If we are currently holding to seek, stay on timeline and extend hold
        if viewModel.isHoldingSeek {
            if direction == .left || direction == .right {
                viewModel.handleMoveSeek(direction: direction)
            }
            return
        }

        if viewModel.moveSuppressed { return }

        switch direction {
        case .up:
            viewModel.cancelMoveSeekTracking()
            if origin == .timeline {
                if viewModel.showSkipSegmentCard {
                    onFocusSkipSegment()
                } else {
                    moveFocus(to: transportFocusOrder.first ?? .settings)
                }
            } else if viewModel.showNextEpisodeCard {
                onFocusNextEpisode()
            }
        case .down:
            viewModel.cancelMoveSeekTracking()
            if origin != .timeline, !viewModel.isLiveStream {
                moveFocus(to: .timeline)
            }
        case .left:
            if origin == .timeline, !viewModel.isLiveStream {
                if viewModel.isScrubbing {
                    viewModel.scrubJump(-Double(max(viewModel.seekStepSeconds * 4, 60)))
                } else if viewModel.status == .playing {
                    viewModel.handleMoveSeek(direction: .left)
                }
                moveFocus(to: .timeline)
            } else if let index = transportFocusOrder.firstIndex(of: origin),
                      index > 0 {
                moveFocus(to: transportFocusOrder[index - 1])
            } else if origin == transportFocusOrder.first, viewModel.showSkipSegmentCard {
                onFocusSkipSegment()
            }
        case .right:
            if origin == .timeline, !viewModel.isLiveStream {
                if viewModel.isScrubbing {
                    viewModel.scrubJump(Double(max(viewModel.seekStepSeconds * 4, 60)))
                } else if viewModel.status == .playing {
                    viewModel.handleMoveSeek(direction: .right)
                }
                moveFocus(to: .timeline)
            } else if let index = transportFocusOrder.firstIndex(of: origin),
                      index < transportFocusOrder.count - 1 {
                moveFocus(to: transportFocusOrder[index + 1])
            }
        default:
            break
        }
    }

    // MARK: - Top bar

    private var isSeekingOrScrubbing: Bool {
        viewModel.isScrubbing || viewModel.isHoldingSeek || viewModel.pendingSeekDelta != 0
    }

    private var topBar: some View {
        Group {
            if !isSeekingOrScrubbing {
                VStack(spacing: 12) {
                    HStack(alignment: .top, spacing: 24) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(viewModel.title)
                                .font(.system(size: 38, weight: .bold))
                                .foregroundColor(.white)
                                .lineLimit(1)

                            if !viewModel.subtitle.isEmpty {
                                Text(viewModel.subtitle)
                                    .font(.system(size: 21, weight: .medium))
                                    .foregroundColor(.white.opacity(0.68))
                                    .lineLimit(1)
                            }
                        }

                        Spacer()
                    }
                }
                .padding(.horizontal, 60)
                .padding(.top, 34)
                .shadow(color: .black.opacity(0.82), radius: 18, x: 0, y: 6)
                .transition(.opacity)
            }
        }
        .animation(.playerControls, value: isSeekingOrScrubbing)
    }

    // MARK: - Bottom controls

    private var bottomControls: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !isSeekingOrScrubbing {
                transportRow
                    .transition(.opacity)
            }
            timelineBar
        }
        .padding(.horizontal, 60)
        .padding(.bottom, 54)
        .animation(.playerControls, value: isSeekingOrScrubbing)
    }

    private var transportRow: some View {
        HStack(spacing: 18) {
            Spacer()

            if viewModel.isPictureInPictureSupported && playerShowPiP {
                glassIconButton(
                    size: 70,
                    iconSize: 28,
                    focusKey: .pip,
                    isFocused: focusedControl == .pip
                ) {
                    viewModel.togglePictureInPicture()
                } icon: {
                    Image(systemName: "pip.enter")
                }
                .id("pip_button")
            }

            if viewModel.canShowEpisodesPanel && playerShowEpisodes {
                glassIconButton(
                    size: 70,
                    iconSize: 28,
                    focusKey: .episodes,
                    isFocused: focusedControl == .episodes
                ) {
                    viewModel.openSidePanel(.episodes)
                } icon: {
                    Image(systemName: "list.bullet")
                }
                .id("episodes_button")
            }

            if viewModel.canShowSourcesPanel && playerShowSources {
                glassIconButton(
                    size: 70,
                    iconSize: 28,
                    focusKey: .sources,
                    isFocused: focusedControl == .sources
                ) {
                    viewModel.openSidePanel(.sources)
                } icon: {
                    Image(systemName: "square.stack.3d.up")
                }
                .id("sources_button")
            }

            if canShowSubtitlePicker && playerShowSubtitles {
                subtitleMenuButton
            }

            glassIconButton(
                size: 70,
                iconSize: 30,
                focusKey: .settings,
                isFocused: focusedControl == .settings
            ) {
                viewModel.showSettingsPanel = true
            } icon: {
                Image(systemName: "ellipsis")
            }
            .id("settings_button")
        }
        .shadow(color: .black.opacity(0.74), radius: 20, x: 0, y: 8)
    }

    private func glassIconButton<Icon: View>(
        size: CGFloat,
        iconSize: CGFloat,
        focusKey: PlayerControlFocus,
        isFocused: Bool,
        action: @escaping () -> Void,
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        // Use a real Button action for Siri Remote Select. Do not stack an extra
        // `.focusable(...)` on the Button — toggling that when focus leaves the
        // timeline (or moves settings → play) can leave the control visually
        // focused while Select no longer activates the action.
        //
        // Mirror Settings category pills: `.disabled` removes a button from the
        // spatial focus graph without changing appearance (PosterCardButtonStyle
        // ignores isEnabled). That prevents the Episodes flash on up-from-timeline.
        Button {
            focusedControl = focusKey
            action()
        } label: {
            icon()
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundColor(isFocused ? .black : .white)
                .frame(width: size, height: size)
                .modifier(PlayerGlassCircleButtonBackground(filled: isFocused))
                .shadow(color: .black.opacity(0.82), radius: 14, x: 0, y: 7)
                .frame(width: size, height: size)
                .clipShape(Circle())
                .contentShape(Circle())
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($focusedControl, equals: focusKey)
        .disabled(!isTransportButtonFocusable(focusKey))
        .focusEffectDisabledIfAvailable()
        .onMoveCommand { direction in
            // Route from this button's key so a native spatial jump across the
            // row Spacer cannot make us advance from the wrong origin (which
            // skipped sources / never returned up-to-play).
            handleMove(direction, from: focusKey)
        }
        .scaleEffect(isFocused ? 1.06 : 1.0)
        .animation(.easeOut(duration: 0.14), value: isFocused)
    }

    private var subtitleLanguageGroups: [SubtitleLanguageGroup] {
        var groups: [String: [SubtitlePanelOption]] = [:]
        var order: [String] = []
        for option in subtitlePickerOptions {
            if groups[option.language] == nil {
                order.append(option.language)
            }
            groups[option.language, default: []].append(option)
        }
        let preferredLanguages = SubtitleLanguagePreferences.orderedFromDefaults()
        let sortedLanguages = order.sorted { lhs, rhs in
            let lhsRank = preferredLanguages.firstIndex {
                SubtitleLanguagePreferences.matches(lhs, target: $0)
            }
            let rhsRank = preferredLanguages.firstIndex {
                SubtitleLanguagePreferences.matches(rhs, target: $0)
            }
            switch (lhsRank, rhsRank) {
            case let (left?, right?) where left != right:
                return left < right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                break
            }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }

        return sortedLanguages.map { lang in
            SubtitleLanguageGroup(language: lang, options: groups[lang] ?? [])
        }
    }

    private var subtitleMenuButton: some View {
        let isFocused = focusedControl == .subtitles

        return Menu {
            if let none = subtitleNoneOption {
                Button {
                    selectSubtitlePickerOption(none)
                } label: {
                        subtitleMenuItem(
                            title: L10n.string("action_none", fallback: "None"),
                            isSelected: none.isSelected
                        )
                }
            }

            ForEach(subtitleLanguageGroups) { group in
                Menu {
                    if !group.builtInOptions.isEmpty {
                        Section(L10n.string("tvos_settings_option_built_in", fallback: "Built-In")) {
                            ForEach(group.builtInOptions) { option in
                                Button {
                                    selectSubtitlePickerOption(option)
                                } label: {
                                    subtitleMenuItem(
                                        title: builtInMenuTitle(option: option),
                                        isSelected: option.isSelected
                                    )
                                }
                            }
                        }
                    }

                    if !group.externalOptions.isEmpty {
                        Section(L10n.string("player_external_subtitles", fallback: "External Subtitles")) {
                            ForEach(group.externalOptions) { option in
                                Button {
                                    selectSubtitlePickerOption(option)
                                } label: {
                                    subtitleMenuItem(
                                        title: groupedExternalMenuTitle(option: option),
                                        isSelected: option.isSelected
                                    )
                                }
                            }
                        }
                    }
                } label: {
                    HStack {
                        Text(group.language)
                        Spacer()
                        if group.hasSelected {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "captions.bubble")
                .font(.system(size: 28, weight: .semibold))
                .foregroundColor(isFocused ? .black : .white)
                .frame(width: 70, height: 70)
                .modifier(PlayerGlassCircleButtonBackground(filled: isFocused))
                .shadow(color: .black.opacity(0.82), radius: 14, x: 0, y: 7)
                .frame(width: 70, height: 70)
                .clipShape(Circle())
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .focused($focusedControl, equals: .subtitles)
        .focusEffectDisabledIfAvailable()
        .onMoveCommand { direction in
            handleMove(direction, from: .subtitles)
        }
        .scaleEffect(isFocused ? 1.06 : 1.0)
        .animation(.easeOut(duration: 0.14), value: isFocused)
        .id("subtitles_button")
    }

    private func sanitizeSubtitleLabel(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        // Filter out hashes, OpenSubtitles v3 file tokens (e.g. v3_e1_...), UUIDs, or long alphanumeric keys
        if raw.hasPrefix("v3_") || raw.hasPrefix("sub_") || raw.contains("AfAB") || raw.count > 25 {
            return nil
        }
        if raw.range(of: #"[a-zA-Z0-9_-]{15,}"#, options: .regularExpression) != nil {
            return nil
        }
        let stripped = raw.replacingOccurrences(
            of: #"\b\d{5,}\b|[_\-]\d{5,}"#,
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: CharacterSet(charactersIn: " -_()[]"))
        return stripped.isEmpty ? nil : stripped
    }

    private func builtInMenuTitle(option: SubtitlePanelOption) -> String {
        let title = option.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanLabel = sanitizeSubtitleLabel(option.detail)
        let displayTitle = title.isEmpty ? option.language : title
        if let cleanLabel,
           cleanLabel.caseInsensitiveCompare(displayTitle) != .orderedSame,
           cleanLabel.caseInsensitiveCompare(option.language) != .orderedSame {
            return "\(displayTitle) (\(cleanLabel))"
        }
        return displayTitle
    }

    private func groupedExternalMenuTitle(option: SubtitlePanelOption) -> String {
        let addon = option.badge.isEmpty ? "External" : option.badge
        let cleanLabel = sanitizeSubtitleLabel(option.detail)

        if let cleanLabel, cleanLabel.caseInsensitiveCompare(option.language) != .orderedSame {
            return "\(addon) (\(cleanLabel))"
        }
        return addon
    }

    private func subtitleMenuItem(title: String, isSelected: Bool) -> some View {
        HStack {
            Text(title)
            Spacer()
            if isSelected {
                Image(systemName: "checkmark")
            }
        }
    }

    private func selectSubtitlePickerOption(_ option: SubtitlePanelOption) {
        switch option.kind {
        case .track(let track):
            viewModel.selectSubtitle(track)
        case .external(let subtitle):
            viewModel.selectExternalSubtitle(subtitle)
        }
    }

    // MARK: - Timeline

    private var isTimelineFocused: Bool {
        focusedControl == .timeline || viewModel.isHoldingSeek
    }

    @ViewBuilder
    private var timelineBar: some View {
        if viewModel.isLiveStream {
            liveStatusBar
        } else {
            finiteTimelineBar
        }
    }

    private var liveStatusBar: some View {
        HStack(spacing: 11) {
            Circle()
                .fill(Color.red)
                .frame(width: 12, height: 12)
                .shadow(color: .red.opacity(0.65), radius: 7)
            Text(L10n.string("player_live", fallback: "LIVE"))
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(.white.opacity(0.9))
            Spacer()
        }
        .frame(height: 44)
        .shadow(color: .black.opacity(0.82), radius: 16, x: 0, y: 7)
    }

    private var finiteTimelineBar: some View {
        PlayerTimelineBar(
            clock: viewModel.clock,
            isTimelineFocused: isTimelineFocused,
            isScrubbing: viewModel.isScrubbing,
            isHoldingSeek: viewModel.isHoldingSeek,
            pendingSeekDelta: viewModel.pendingSeekDelta,
            speedMultiplier: viewModel.seekSpeedMultiplier,
            seekStepSeconds: viewModel.seekStepSeconds
        )
        .overlay(alignment: .top) {
            // Keep the geometry mounted even while a still is unavailable so
            // its first frame is positioned directly over the target. The
            // overlay never participates in controls layout or hit testing.
            SeekPreviewTimelineCard(
                clock: viewModel.clock,
                isScrubbing: viewModel.isScrubbing,
                isHoldingSeek: viewModel.isHoldingSeek,
                pendingSeekDelta: viewModel.pendingSeekDelta,
                image: ((viewModel.isHoldingSeek || viewModel.isScrubbing) && viewModel.isSeekPreviewEnabled) ? viewModel.scrubThumbnail : nil,
                naturalSize: viewModel.videoNaturalSize,
                speedMultiplier: viewModel.seekSpeedMultiplier,
                wheelEngaged: viewModel.wheelEngaged
            )
            .offset(y: -(270 + 16))
            .allowsHitTesting(false)
            .transaction { transaction in transaction.animation = nil }
        }
        .focusable(
            (viewModel.showControls || viewModel.isScrubbing)
                && !viewModel.showSettingsPanel
                && !viewModel.showPauseOverlay
        )
        .focused($focusedControl, equals: .timeline)
        .focusEffectDisabledIfAvailable()
        .onTapGesture {
            if viewModel.isScrubbing {
                viewModel.commitScrub()
            } else {
                viewModel.togglePlayPause()
            }
        }
        .onMoveCommand { direction in
            // Timeline owns move while focused so hold-to-seek cannot promote
            // focus onto the transport buttons. Always route from `.timeline`
            // even if spatial focus already hopped to a transport button.
            handleMove(direction, from: .timeline)
        }
        .shadow(color: .black.opacity(0.82), radius: 16, x: 0, y: 7)
        .animation(.easeOut(duration: 0.14), value: focusedControl)
        .animation(.easeOut(duration: 0.12), value: viewModel.pendingSeekDelta)
        .animation(.easeOut(duration: 0.16), value: viewModel.isScrubbing)
    }
}

private struct SeekPreviewTimelineCard: View {
    @ObservedObject var clock: PlaybackClock
    let isScrubbing: Bool
    var isHoldingSeek: Bool = false
    let pendingSeekDelta: Double
    let image: CGImage?
    var naturalSize: CGSize = CGSize(width: 16, height: 9)
    var speedMultiplier: Int? = nil
    var wheelEngaged: Bool = false

    private var target: Double {
        if isScrubbing {
            return clock.scrubTarget ?? clock.position
        }
        return min(max(clock.position + pendingSeekDelta, 0), max(clock.duration, 0))
    }

    var body: some View {
        GeometryReader { geo in
            let duration = max(clock.duration, 0.001)
            let fraction = CGFloat(min(max(target / duration, 0), 1))
            let width = min(CGFloat(480), max(CGFloat(1), geo.size.width - 32))
            let cardSize = AppCardStyle.seekCardSize(
                for: naturalSize,
                maxWidth: width,
                maxHeight: width * 9 / 16
            )
            let cardHalfW = cardSize.width / 2
            let targetX = geo.size.width * fraction
            let cardX = min(max(targetX, cardHalfW + 16), geo.size.width - cardHalfW - 16)

            if isScrubbing || isHoldingSeek {
                SeekPreviewCard(image: image, width: width, naturalSize: naturalSize)
                    .position(x: cardX, y: 270 - cardSize.height / 2)
            }
        }
        .frame(height: 270)
    }
}

// MARK: - Isolated Timeline Bar

private struct PlayerTimelineBar: View {
    @ObservedObject var clock: PlaybackClock
    let isTimelineFocused: Bool
    let isScrubbing: Bool
    var isHoldingSeek: Bool = false
    let pendingSeekDelta: Double
    var speedMultiplier: Int? = nil
    var seekStepSeconds: Int = PlayerSeekSettings.defaultStep

    private var duration: Double {
        max(clock.duration, 0.001)
    }

    private var skipIconName: String {
        let prefix = pendingSeekDelta < 0 ? "gobackward" : "goforward"
        let validSteps = [5, 10, 15, 30, 45, 60, 75, 90]
        if validSteps.contains(seekStepSeconds) {
            return "\(prefix).\(seekStepSeconds)"
        }
        return prefix
    }

    private var isSeekingOrScrubbing: Bool {
        isScrubbing || isHoldingSeek || pendingSeekDelta != 0
    }

    private var targetPosition: Double {
        if isScrubbing {
            return clock.scrubTarget ?? clock.position
        }
        let position = clock.position + pendingSeekDelta
        return min(max(position, 0), max(clock.duration, 0))
    }

    private var progress: CGFloat {
        CGFloat(min(max(targetPosition / duration, 0), 1))
    }

    var body: some View {
        VStack(spacing: 10) {
            GeometryReader { geo in
                let w = geo.size.width
                let targetX = min(max(w * progress, 0), w)
                let trackHeight: CGFloat = (isTimelineFocused || isSeekingOrScrubbing) ? 10 : 7
                let h: CGFloat = (isTimelineFocused || isSeekingOrScrubbing) ? trackHeight + 2 : trackHeight
                let needleHeight: CGFloat = 22
                let originalProgress = CGFloat(min(max(clock.position / duration, 0), 1))
                let originalX = min(max(w * originalProgress, 0), w)
                let bottomOfTrack = geo.size.height / 2 + h / 2

                ZStack(alignment: .leading) {
                    PlayerProgressTrack(
                        played: Double(progress),
                        buffered: clock.buffered / duration,
                        height: trackHeight,
                        showThumb: false,
                        emphasized: isTimelineFocused || isSeekingOrScrubbing,
                        glassTrack: true
                    )

                    if isScrubbing || isHoldingSeek {
                        // Ghost tick: original paused playback position flush within track
                        if abs(targetX - originalX) > 3 {
                            Rectangle()
                                .fill(Color.white.opacity(0.4))
                                .frame(width: 1.5, height: h)
                                .position(x: originalX, y: geo.size.height / 2)
                        }

                        // Active scrub/seek needle: extends upwards toward preview card and is flush at bottom of track
                        Rectangle()
                            .fill(Color.white)
                            .frame(width: 2, height: needleHeight)
                            .shadow(color: .black.opacity(0.45), radius: 1.5)
                            .position(x: targetX, y: bottomOfTrack - needleHeight / 2)
                    }
                }
            }
            .frame(height: (isTimelineFocused || isSeekingOrScrubbing) ? 16 : 11)

            // Timestamps: when seeking or scrubbing, center the time and direction/speed directly beneath the needle
            if isSeekingOrScrubbing {
                GeometryReader { geo in
                    let w = geo.size.width
                    let targetX = min(max(w * progress, 60), w - 60)
                    HStack(spacing: 8) {
                        Text(PlayerTime.formatted(time: targetPosition))
                            .font(.system(size: 26, weight: .bold).monospacedDigit())
                            .foregroundColor(.white)

                        if isHoldingSeek || speedMultiplier != nil {
                            let isForward = pendingSeekDelta >= 0
                            Image(systemName: isForward ? "forward.fill" : "backward.fill")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.white)
                                .frame(width: 26, height: 26)
                                .background(Color.white.opacity(0.22), in: Circle())

                            if let speedMultiplier {
                                Text("\(speedMultiplier)")
                                    .font(.system(size: 26, weight: .bold).monospacedDigit())
                                    .foregroundColor(.white)
                            }
                        } else if pendingSeekDelta != 0 {
                            Image(systemName: skipIconName)
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundColor(.white)
                        }
                    }
                    .shadow(color: .black.opacity(0.85), radius: 6, x: 0, y: 2)
                    .position(x: targetX, y: 14)
                }
                .frame(height: 28)
            } else {
                HStack(spacing: 10) {
                    Text(PlayerTime.formatted(time: targetPosition))
                    Spacer()
                    Text("-" + PlayerTime.formatted(time: max(0, duration - targetPosition)))
                }
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(.white.opacity(isTimelineFocused ? 0.82 : 0.54))
            }
        }
    }
}

// MARK: - Liquid glass appearance

extension Animation {
    /// Fluid spring that drives the player controls materialize / dematerialize.
    static var playerControls: Animation {
        .spring(response: 0.42, dampingFraction: 0.86)
    }
}

// MARK: - Liquid Glass helpers
//
// Liquid Glass (`glassEffect`, `GlassEffectContainer`) ships in tvOS 26+. The app
// deploys back to tvOS 15.1, so every use is availability-gated with an
// `.ultraThinMaterial` fallback that keeps the same shapes on older systems.

/// Wraps content in a `GlassEffectContainer` on tvOS 26+ so adjacent glass
/// surfaces blend/morph together; a plain passthrough otherwise.
struct GlassControlsContainer<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        if #available(tvOS 26.0, *) {
            GlassEffectContainer(spacing: 28) { content }
        } else {
            content
        }
    }
}

extension View {
    @ViewBuilder
    func glassCircle() -> some View {
        if #available(tvOS 26.0, *) {
            glassEffect(.regular.interactive(), in: .circle)
        } else {
            background(.ultraThinMaterial, in: Circle())
        }
    }

    @ViewBuilder
    func glassCircleSurface() -> some View {
        if #available(tvOS 26.0, *) {
            glassEffect(.regular, in: .circle)
        } else {
            background(.ultraThinMaterial, in: Circle())
        }
    }

    @ViewBuilder
    func glassCapsule() -> some View {
        if #available(tvOS 26.0, *) {
            glassEffect(.regular.interactive(), in: .capsule)
        } else {
            background(.ultraThinMaterial, in: Capsule())
        }
    }

    @ViewBuilder
    func glassRoundedRect(cornerRadius: CGFloat) -> some View {
        if #available(tvOS 26.0, *) {
            glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }

}
// MARK: - Next episode card
//
// Next-episode prompt shown near the end of an episode. Liquid Glass card with
// the upcoming episode's thumbnail, and manual Play/Cancel Auto-Play actions.
struct NextEpisodeOverlay: View {
    let episode: NuvioVideo
    let isAdvancing: Bool
    var isFocused: Bool
    let isAutoPlayCancelled: Bool

    @AppStorage(SettingsKey.cardCornerRadius) private var cardCornerRadiusSetting = AppCardStyle.defaultCornerRadiusRaw

    private var overlayCornerRadius: CGFloat {
        max(14, AppCardStyle.episodeCornerRadius(for: cardCornerRadiusSetting))
    }

    private var thumbCornerRadius: CGFloat {
        max(6, AppCardStyle.cornerRadius(for: cardCornerRadiusSetting, fallback: 16) * 0.75)
    }

    private var episodeLine: String {
        "S\(episode.season) E\(episode.episode) • \(episode.title)"
    }

    private var isPlayable: Bool {
        EpisodeReleasePolicy.hasAired(episode.released)
    }

    private var airDateText: String {
        EpisodeReleasePolicy.airDateText(for: episode.released).map { "Airs \($0)" } ?? "Upcoming"
    }

    var body: some View {
        HStack(spacing: 22) {
            thumbnail

            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.string("player_next_episode", fallback: "Next Episode"))
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundColor(.white.opacity(0.62))
                Text(episodeLine)
                    .font(.system(size: 29, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                if !isPlayable {
                    Text(airDateText)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                } else if isAutoPlayCancelled {
                    Text(L10n.string("player_autoplay_cancelled", fallback: "Auto-Play cancelled"))
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.white.opacity(0.7))
                }
            }

            Spacer(minLength: 20)

            playButton
        }
        .padding(18)
        .frame(width: 780)
        .glassRoundedRect(cornerRadius: overlayCornerRadius)
        .overlay(
            RoundedRectangle(cornerRadius: overlayCornerRadius, style: .continuous)
                .strokeBorder(isFocused ? AppFocusOutline.color : Color.white.opacity(0.14), lineWidth: isFocused ? AppFocusOutline.width : 1)
        )
        .shadow(color: .black.opacity(0.55), radius: 22, x: 0, y: 10)
        .animation(.easeInOut(duration: 0.18), value: isFocused)
    }

    private var thumbnail: some View {
        ZStack {
            Color.white.opacity(0.06)
            if let thumb = episode.thumbnail, let url = URL(string: thumb) {
                AsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Image(systemName: "play.rectangle")
                        .font(.system(size: 30))
                        .foregroundColor(.white.opacity(0.4))
                }
            } else {
                Image(systemName: "play.rectangle")
                    .font(.system(size: 30))
                    .foregroundColor(.white.opacity(0.4))
            }
        }
        .frame(width: 158, height: 90)
        .clipShape(RoundedRectangle(cornerRadius: thumbCornerRadius, style: .continuous))
    }

    private var playButton: some View {
        HStack(spacing: 12) {
            if isAdvancing {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: isFocused ? .black : .white))
                    .scaleEffect(0.9)
                Text(L10n.string("player_starting", fallback: "Starting…"))
            } else {
                Image(systemName: isPlayable ? "play.fill" : "calendar")
                    .font(.system(size: 22, weight: .bold))
                Text(isPlayable ? L10n.string("action_play", fallback: "Play") : L10n.string("player_not_yet", fallback: "Not Yet"))
            }
        }
        .font(.system(size: 24, weight: .semibold))
        .foregroundColor(isFocused && isPlayable ? .black : .white)
        .padding(.horizontal, 30)
        .padding(.vertical, 16)
        .background {
            if isFocused && isPlayable {
                Capsule().fill(Color.white)
            } else {
                Capsule().fill(Color.white.opacity(0.14))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.4), lineWidth: 1))
            }
        }
    }
}

struct SkipSegmentOverlay: View {
    let interval: SkipInterval
    let countdown: Int?
    var isFocused: Bool

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "forward.end.fill")
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(isFocused ? .black : .white)
                .frame(width: 46, height: 46)
                .background {
                    Circle().fill(isFocused ? Color.white : Color.white.opacity(0.14))
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(interval.label)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(.white)
                Text(detailText)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.white.opacity(0.62))
                    .contentTransition(.numericText())
            }

            Spacer(minLength: 10)
        }
        .padding(.leading, 18)
        .padding(.trailing, 20)
        .padding(.vertical, 14)
        .frame(width: 330)
        .glassRoundedRect(cornerRadius: 24)
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(isFocused ? AppFocusOutline.color : Color.white.opacity(0.14), lineWidth: isFocused ? AppFocusOutline.width : 1)
        )
        .shadow(color: .black.opacity(0.55), radius: 22, x: 0, y: 10)
        .animation(.easeInOut(duration: 0.18), value: isFocused)
        .animation(.easeInOut(duration: 0.18), value: countdown)
    }

    private var detailText: String {
        return "Ends at \(PlayerTime.formatted(time: interval.endTime))"
    }
}

private struct PlayerGlassCircleButtonBackground: ViewModifier {
    let filled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if filled {
            content.background(Color.white, in: Circle())
        } else if #available(tvOS 26.0, *) {
            content.glassEffect(.regular, in: Circle())
        } else {
            content.background(.ultraThinMaterial, in: Circle())
        }
    }
}

// MARK: - Player settings panel
//
// Full-screen overlay opened from the controls' ellipsis button. Three pages:
// Subtitles (default — languages / tracks / style, mirroring the iOS app's
// player subtitle screen), Audio, and Speed. Renders over the dimmed video so
// style changes are visible live on the captions behind it.

/// One row of the panel's Subtitles column — an mpv track (embedded or
/// already-loaded external) or an add-on subtitle that loads on demand.
private struct SubtitlePanelOption: Identifiable {
    enum Kind {
        case track(SubtitleTrack)
        case external(NuvioSubtitle)
    }

    let id: String
    let kind: Kind
    let badge: String
    let title: String
    let detail: String?
    let language: String
    let isSelected: Bool
}

private struct SubtitleLanguageGroup: Identifiable {
    var id: String { language }
    let language: String
    let options: [SubtitlePanelOption]
    var builtInOptions: [SubtitlePanelOption] {
        options.filter { option in
            guard case .track(let track) = option.kind else { return false }
            return track.externalFilename.isEmpty
        }
    }
    var externalOptions: [SubtitlePanelOption] {
        options.filter { option in
            switch option.kind {
            case .track(let track):
                return !track.externalFilename.isEmpty
            case .external:
                return true
            }
        }
    }
    var hasSelected: Bool {
        options.contains(where: \.isSelected)
    }
}

/// Maps raw track/addon language values ("en", "eng", "English") onto one
/// display name so both kinds group into a single Languages entry.
private enum SubtitleLanguageDisplay {
    static func name(for raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Unknown" }
        let code = trimmed.lowercased()
            .components(separatedBy: CharacterSet(charactersIn: "-_")).first ?? ""
        if code.count <= 3, code.allSatisfy(\.isLetter),
           let name = Locale.current.localizedString(forLanguageCode: code) {
            return name.prefix(1).uppercased() + name.dropFirst()
        }
        return trimmed.prefix(1).uppercased() + trimmed.dropFirst()
    }
}

/// Every pickable subtitle: mpv tracks first (embedded and orphaned
/// externals), then the stream's add-on subtitles. Add-on entries that mpv
/// has already loaded read their selection state off the matching track.
@MainActor
private func subtitlePanelOptions(for viewModel: PlayerViewModel) -> [SubtitlePanelOption] {
    let externalUrls = Set(viewModel.availableExternalSubtitles.map(\.url))
    var options: [SubtitlePanelOption] = []

    for track in viewModel.subtitles where track.id != "off" {
        // Loaded add-on subtitles are rendered from the add-on list below;
        // listing their mpv track too would duplicate the row.
        if !track.externalFilename.isEmpty, externalUrls.contains(track.externalFilename) { continue }
        let isExternal = !track.externalFilename.isEmpty
        let rawLanguage = track.language.isEmpty ? track.name : track.language
        options.append(SubtitlePanelOption(
            id: "track-\(track.id)",
            kind: .track(track),
            badge: isExternal ? "External" : "Built in",
            title: track.name,
            detail: nil,
            language: SubtitleLanguageDisplay.name(for: rawLanguage),
            isSelected: track.isSelected
        ))
    }

    for subtitle in viewModel.availableExternalSubtitles {
        let language = SubtitleLanguageDisplay.name(for: subtitle.language)
        let loadedTrack = viewModel.subtitles.first { $0.externalFilename == subtitle.url }
        let detail = subtitle.label.flatMap { label in
            label.caseInsensitiveCompare(language) == .orderedSame ? nil : label
        }
        options.append(SubtitlePanelOption(
            id: "ext-\(subtitle.url)",
            kind: .external(subtitle),
            badge: subtitle.source ?? "External",
            title: language,
            detail: detail,
            language: language,
            isSelected: loadedTrack?.isSelected ?? false
        ))
    }

    return options
}

struct PlayerSettingsPanel: View {
    @ObservedObject var viewModel: PlayerViewModel
    var onClose: () -> Void

    private enum Tab: String, CaseIterable, Hashable {
        case subtitles = "Subtitles"
        case audio = "Audio"
        case speed = "Speed"
        case picture = "Picture"
    }

    private enum StyleControl: Hashable {
        case delayMinus, delayPlus
        case aiTranslation
        case sizeMinus, sizePlus
        case bold
        case color(String)
        case opacityMinus, opacityPlus
        case outline
        case background
        case backgroundColor(String)
        case backgroundOpacityMinus, backgroundOpacityPlus
    }

    private enum AudioControl: Hashable {
        case delayMinus, delayPlus
        case ampMinus, ampPlus
    }

    private enum Focus: Hashable {
        case tab(Tab)
        case noneRow
        case language(String)
        case option(String)
        case audio(String)
        case audioControl(AudioControl)
        case speed(Float)
        case seekStep(Int)
        case seekPreview
        case debugOverlay
        case aspect(String)
        case style(StyleControl)
    }

    /// Swatches shown in the Text Color row (white, gray, yellow, blue, red, green).
    private static let palette = ["#FFFFFF", "#C7C7C7", "#F2C94C", "#56CCF2", "#EB5757", "#6FCF97"]
    private static let backgroundPalette = ["#000000", "#303030", "#FFFFFF", "#1F3A5F", "#5A1F2B", "#214D35"]

    @State private var tab: Tab = .subtitles
    @State private var selectedLanguage: String?
    @State private var style = SubtitleStyle.current
    @FocusState private var focus: Focus?

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(
                colors: [.black.opacity(0.92), .black.opacity(0.55)],
                startPoint: .leading,
                endPoint: .trailing
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 38) {
                tabBar

                switch tab {
                case .subtitles: subtitlesPage
                case .audio: audioPage
                case .speed: speedPage
                case .picture: picturePage
                }
            }
            .padding(.horizontal, 90)
            .padding(.top, 64)
            .padding(.bottom, 44)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear {
            style = SubtitleStyle.current
            viewModel.setControlsAutoHideSuspended(true)
            DispatchQueue.main.async {
                if let language = effectiveLanguage {
                    selectedLanguage = language
                    focus = .language(language)
                } else {
                    focus = .noneRow
                }
            }
        }
        .onDisappear {
            viewModel.setControlsAutoHideSuspended(false)
        }
        .onChange(of: focus) { _, newValue in
            // Focusing a language filters the middle column live.
            if case .language(let language) = newValue {
                selectedLanguage = language
            }
        }
        .focusSection()
        .onExitCommand { onClose() }
    }

    // MARK: Tabs

    private var tabBar: some View {
        HStack(spacing: 22) {
            ForEach(Tab.allCases, id: \.self) { item in
                let isFocused = focus == .tab(item)
                let isSelected = tab == item
                Button {
                    tab = item
                } label: {
                    Text(item.rawValue)
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundColor(isSelected || isFocused ? .black : .white.opacity(0.66))
                        .padding(.horizontal, 30)
                        .frame(height: 70)
                        .modifier(
                            TvDetailsGlassBackground(
                                filled: isSelected || isFocused,
                                shape: Capsule()
                            )
                        )
                }
                .buttonStyle(PosterCardButtonStyle())
                .focused($focus, equals: .tab(item))
                .focusEffectDisabledIfAvailable()
                .scaleEffect(isFocused ? 1.06 : 1)
                .animation(.easeOut(duration: 0.14), value: isFocused)
                .animation(.easeOut(duration: 0.14), value: isSelected)
            }
            Spacer()
        }
        .focusSection()
    }

    // MARK: Subtitles page

    private var subtitlesPage: some View {
        HStack(alignment: .top, spacing: 56) {
            languagesColumn
            subtitlesColumn
            styleColumn
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var allOptions: [SubtitlePanelOption] {
        subtitlePanelOptions(for: viewModel)
    }

    private var visibleOptions: [SubtitlePanelOption] {
        // Smart matching chooses/preloads preferred tracks; it must not hide
        // other languages from the manual player Settings browser.
        allOptions
    }

    /// Language groups for the left column: the user's preferred subtitle
    /// languages in saved priority order, then every other language alphabetically.
    private var languages: [(name: String, count: Int)] {
        languageGroups(in: visibleOptions)
    }

    private func languageGroups(
        in options: [SubtitlePanelOption]
    ) -> [(name: String, count: Int)] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for option in options {
            if counts[option.language] == nil { order.append(option.language) }
            counts[option.language, default: 0] += 1
        }
        let preferredLanguages = SubtitleLanguagePreferences.orderedFromDefaults()
        return order
            .map { (name: $0, count: counts[$0] ?? 0) }
            .sorted { lhs, rhs in
                let lhsRank = preferredLanguages.firstIndex {
                    SubtitleLanguagePreferences.matches(lhs.name, target: $0)
                }
                let rhsRank = preferredLanguages.firstIndex {
                    SubtitleLanguagePreferences.matches(rhs.name, target: $0)
                }
                switch (lhsRank, rhsRank) {
                case let (left?, right?) where left != right:
                    return left < right
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                default:
                    break
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    private var effectiveLanguage: String? {
        resolvedLanguage(in: visibleOptions)
    }

    private func resolvedLanguage(in options: [SubtitlePanelOption]) -> String? {
        if let selectedLanguage, options.contains(where: { $0.language == selectedLanguage }) {
            return selectedLanguage
        }
        if let selected = options.first(where: { $0.isSelected }) {
            return selected.language
        }
        // This fallback is used only before the panel establishes its selected
        // language on appear. Preserve the built-in-first ordering.
        return languageGroups(in: options).first?.name
    }

    private var subtitlesAreOff: Bool {
        viewModel.subtitles.first { $0.id == "off" }?.isSelected ?? true
    }

    private var languagesColumn: some View {
        VStack(alignment: .leading, spacing: 18) {
            columnHeader("Languages")
            ScrollView(showsIndicators: false) {
                VStack(spacing: 10) {
                    languageRow(title: "None", count: nil, showsCheck: subtitlesAreOff, focusKey: .noneRow) {
                        if let off = viewModel.subtitles.first(where: { $0.id == "off" }) {
                            viewModel.selectSubtitle(off)
                        }
                    }
                    ForEach(languages, id: \.name) { entry in
                        languageRow(title: entry.name, count: entry.count, showsCheck: false, focusKey: .language(entry.name)) {
                            selectedLanguage = entry.name
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            .focusSection()
        }
        .frame(width: 380, alignment: .leading)
    }

    private func languageRow(
        title: String,
        count: Int?,
        showsCheck: Bool,
        focusKey: Focus,
        action: @escaping () -> Void
    ) -> some View {
        let isFocused = focus == focusKey
        return Button(action: action) {
            HStack(spacing: 12) {
                Text(title)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundColor(isFocused ? .black : .white)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if showsCheck {
                    Image(systemName: "checkmark")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(isFocused ? .black : .white)
                } else if let count {
                    Text("\(count)")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundColor(isFocused ? .black.opacity(0.72) : .white.opacity(0.8))
                        .frame(minWidth: 38, minHeight: 38)
                        .background(
                            Circle().fill(isFocused ? Color.black.opacity(0.10) : Color.white.opacity(0.16))
                        )
                }
            }
            .padding(.horizontal, 24)
            .frame(height: 66)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isFocused ? Color.white : Color.clear)
            )
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($focus, equals: focusKey)
        .focusEffectDisabledIfAvailable()
    }

    private var subtitlesColumn: some View {
        // `effectiveLanguage` used to be evaluated once per option. Its getter
        // rebuilds/sorts the language list, producing O(n²) work on every focus
        // move and every player tick. Resolve one immutable snapshot instead.
        let optionsSnapshot = visibleOptions
        let language = resolvedLanguage(in: optionsSnapshot)
        let options = optionsSnapshot.filter { $0.language == language }
        return VStack(alignment: .leading, spacing: 18) {
            columnHeader("Subtitles")
            if viewModel.isLoadingExternalSubtitles {
                HStack(spacing: 12) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                    Text(L10n.string("player_fetching_addon_subtitles", fallback: "Fetching add-on subtitles…"))
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(.white.opacity(0.62))
                }
            }
            if options.isEmpty {
                Text(L10n.string("player_no_subtitles_available", fallback: "No subtitles available"))
                    .font(.system(size: 23, weight: .medium))
                    .foregroundColor(.white.opacity(0.45))
                    .padding(.top, 10)
                Spacer(minLength: 0)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 14) {
                        ForEach(options) { option in
                            optionCard(option)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .focusSection()
            }
        }
        .frame(width: 460, alignment: .leading)
    }

    private func optionCard(_ option: SubtitlePanelOption) -> some View {
        let isFocused = focus == .option(option.id)
        return Button {
            switch option.kind {
            case .track(let track):
                viewModel.selectSubtitle(track)
            case .external(let subtitle):
                viewModel.selectExternalSubtitle(subtitle)
            }
        } label: {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(option.badge)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(isFocused ? .black.opacity(0.66) : .white.opacity(0.72))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(isFocused ? Color.black.opacity(0.10) : Color.white.opacity(0.14))
                        )
                    Text(option.title)
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundColor(isFocused ? .black : .white)
                        .lineLimit(1)
                    if let detail = option.detail {
                        Text(detail)
                            .font(.system(size: 20, weight: .medium))
                            .foregroundColor(isFocused ? .black.opacity(0.52) : .white.opacity(0.5))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if option.isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 27, weight: .bold))
                        .foregroundColor(isFocused ? .black : .white)
                }
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(isFocused ? Color.white : Color.white.opacity(0.07))
            )
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($focus, equals: .option(option.id))
        .focusEffectDisabledIfAvailable()
    }

    // MARK: Subtitle style column

    private var styleColumn: some View {
        VStack(alignment: .leading, spacing: 18) {
            columnHeader(L10n.string("subtitle_style_title", fallback: "Subtitle Style"))
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 30) {
                    stepperRow(
                        title: L10n.string("subtitle_tab_delay", fallback: "Delay"),
                        value: "\(viewModel.subtitleDelayMs)ms",
                        minusKey: .delayMinus,
                        plusKey: .delayPlus,
                        onMinus: { viewModel.setSubtitleDelayMs(viewModel.subtitleDelayMs - 50) },
                        onPlus: { viewModel.setSubtitleDelayMs(viewModel.subtitleDelayMs + 50) }
                    )

                    if viewModel.canManuallyToggleAISubtitleTranslation {
                        toggleRow(
                            title: L10n.string("settings_ai_subtitles_action_title", fallback: "AI Subtitle Translation"),
                            isOn: viewModel.isAISubtitleTranslationManuallyEnabled,
                            focusKey: .aiTranslation
                        ) {
                            viewModel.setAISubtitleTranslationManuallyEnabled(
                                !viewModel.isAISubtitleTranslationManuallyEnabled
                            )
                        }
                    }

                    stepperRow(
                        title: L10n.string("subtitle_style_font_size", fallback: "Font Size"),
                        value: "\(style.textSize)%",
                        minusKey: .sizeMinus,
                        plusKey: .sizePlus,
                        onMinus: { updateStyle { $0.textSize = max($0.textSize - 5, 60) } },
                        onPlus: { updateStyle { $0.textSize = min($0.textSize + 5, 220) } }
                    )

                    toggleRow(title: L10n.string("subtitle_style_bold", fallback: "Bold"), isOn: style.bold, focusKey: .bold) {
                        updateStyle { $0.bold.toggle() }
                    }

                    colorRow

                    stepperRow(
                        title: L10n.string("subtitle_style_text_opacity", fallback: "Text Opacity"),
                        value: "\(style.textOpacity)%",
                        minusKey: .opacityMinus,
                        plusKey: .opacityPlus,
                        onMinus: { updateStyle { $0.textOpacity = max($0.textOpacity - 5, 20) } },
                        onPlus: { updateStyle { $0.textOpacity = min($0.textOpacity + 5, 100) } }
                    )

                    toggleRow(title: L10n.string("subtitle_style_outline", fallback: "Outline"), isOn: style.outlineEnabled, focusKey: .outline) {
                        updateStyle { $0.outlineEnabled.toggle() }
                    }

                    toggleRow(title: L10n.string("subtitle_background", fallback: "Background"), isOn: style.backgroundEnabled, focusKey: .background) {
                        updateStyle { $0.backgroundEnabled.toggle() }
                    }

                    backgroundColorRow
                        .opacity(style.backgroundEnabled ? 1 : 0.46)
                        .disabled(!style.backgroundEnabled)

                    stepperRow(
                        title: L10n.string("subtitle_background_opacity", fallback: "Background Opacity"),
                        value: "\(style.backgroundOpacity)%",
                        minusKey: .backgroundOpacityMinus,
                        plusKey: .backgroundOpacityPlus,
                        onMinus: { updateStyle { $0.backgroundOpacity = max($0.backgroundOpacity - 5, 10) } },
                        onPlus: { updateStyle { $0.backgroundOpacity = min($0.backgroundOpacity + 5, 100) } }
                    )
                    .opacity(style.backgroundEnabled ? 1 : 0.46)
                    .disabled(!style.backgroundEnabled)
                }
                .padding(.vertical, 6)
                .padding(.bottom, 26)
            }
            .focusSection()
            .scrollClipDisabledIfAvailable()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Mutates the local style, persists it to the profile's settings (the same
    /// keys Settings → Subtitle Style edits), and re-applies it to mpv live.
    private func updateStyle(_ mutate: (inout SubtitleStyle) -> Void) {
        mutate(&style)
        let defaults = ProfileSettings.current
        defaults.set(style.textSize, forKey: SubtitleStyleKey.textSize)
        defaults.set(style.bold, forKey: SubtitleStyleKey.bold)
        defaults.set(style.textColorHex, forKey: SubtitleStyleKey.textColor)
        defaults.set(style.textOpacity, forKey: SubtitleStyleKey.textOpacity)
        defaults.set(style.outlineEnabled, forKey: SubtitleStyleKey.outlineEnabled)
        defaults.set(style.outlineColorHex, forKey: SubtitleStyleKey.outlineColor)
        defaults.set(style.backgroundEnabled, forKey: SubtitleStyleKey.backgroundEnabled)
        defaults.set(style.backgroundColorHex, forKey: SubtitleStyleKey.backgroundColor)
        defaults.set(style.backgroundOpacity, forKey: SubtitleStyleKey.backgroundOpacity)
        viewModel.applySubtitleStyle()
    }

    private func stepperRow(
        title: String,
        value: String,
        minusKey: StyleControl,
        plusKey: StyleControl,
        onMinus: @escaping () -> Void,
        onPlus: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            styleLabel(title)
            HStack(spacing: 16) {
                stepButton("minus", focusKey: minusKey, action: onMinus)
                Text(value)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 132, height: 56)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.white.opacity(0.10))
                    )
                stepButton("plus", focusKey: plusKey, action: onPlus)
            }
        }
    }

    private func stepButton(_ systemName: String, focusKey: StyleControl, action: @escaping () -> Void) -> some View {
        let isFocused = focus == .style(focusKey)
        return Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 23, weight: .bold))
                .foregroundColor(isFocused ? .black : .white)
                .frame(width: 76, height: 56)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(isFocused ? Color.white : Color.white.opacity(0.10))
                )
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($focus, equals: .style(focusKey))
        .focusEffectDisabledIfAvailable()
    }

    private func toggleRow(title: String, isOn: Bool, focusKey: StyleControl, action: @escaping () -> Void) -> some View {
        let isFocused = focus == .style(focusKey)
        return VStack(alignment: .leading, spacing: 14) {
            styleLabel(title)
            Button(action: action) {
                Text(isOn
                     ? L10n.string("subtitle_style_on", fallback: "On")
                     : L10n.string("subtitle_style_off", fallback: "Off"))
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(isFocused ? .black : .white)
                    .frame(width: 112, height: 52)
                    .background(
                        Capsule().fill(isFocused ? Color.white : Color.white.opacity(0.10))
                    )
            }
            .buttonStyle(PosterCardButtonStyle())
            .focused($focus, equals: .style(focusKey))
            .focusEffectDisabledIfAvailable()
        }
    }

    private var colorRow: some View {
        VStack(alignment: .leading, spacing: 16) {
            styleLabel(L10n.string("subtitle_style_text_color", fallback: "Text Color"))
            HStack(spacing: 20) {
                ForEach(Self.palette, id: \.self) { hex in
                    colorSwatch(hex)
                }
            }
        }
    }

    private func colorSwatch(_ hex: String) -> some View {
        let isFocused = focus == .style(.color(hex))
        let isSelected = style.textColorHex.caseInsensitiveCompare(hex) == .orderedSame
        return Button {
            updateStyle { $0.textColorHex = hex }
        } label: {
            Circle()
                .fill(Color(hex: hex))
                .frame(width: 52, height: 52)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 1))
                .overlay(
                    Circle()
                        .strokeBorder(
                            isFocused ? Color.white : (isSelected ? Color.white.opacity(0.75) : .clear),
                            lineWidth: isFocused ? AppFocusOutline.width : 3
                        )
                        .padding(-6)
                )
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($focus, equals: .style(.color(hex)))
        .focusEffectDisabledIfAvailable()
        .scaleEffect(isFocused ? 1.14 : 1)
        .zIndex(isFocused ? 1 : 0)
        .animation(.easeOut(duration: 0.14), value: isFocused)
    }

    private var backgroundColorRow: some View {
        VStack(alignment: .leading, spacing: 16) {
            styleLabel(L10n.string("subtitle_background_color", fallback: "Background Color"))
            HStack(spacing: 20) {
                ForEach(Self.backgroundPalette, id: \.self) { hex in
                    backgroundColorSwatch(hex)
                }
            }
        }
    }

    private func backgroundColorSwatch(_ hex: String) -> some View {
        let isFocused = focus == .style(.backgroundColor(hex))
        let isSelected = style.backgroundColorHex.caseInsensitiveCompare(hex) == .orderedSame
        return Button {
            updateStyle { $0.backgroundColorHex = hex }
        } label: {
            Circle()
                .fill(Color(hex: hex))
                .frame(width: 52, height: 52)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 1))
                .overlay(
                    Circle()
                        .strokeBorder(
                            isFocused ? Color.white : (isSelected ? Color.white.opacity(0.75) : .clear),
                            lineWidth: isFocused ? AppFocusOutline.width : 3
                        )
                        .padding(-6)
                )
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($focus, equals: .style(.backgroundColor(hex)))
        .focusEffectDisabledIfAvailable()
        .scaleEffect(isFocused ? 1.14 : 1)
        .zIndex(isFocused ? 1 : 0)
        .animation(.easeOut(duration: 0.14), value: isFocused)
    }

    // MARK: Audio & Speed pages

    private var audioPage: some View {
        HStack(alignment: .top, spacing: 70) {
            audioTracksColumn
            audioAdjustmentsColumn
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var audioTracksColumn: some View {
        VStack(alignment: .leading, spacing: 18) {
            columnHeader("Audio Tracks")
            if viewModel.audioTracks.isEmpty {
                Text(L10n.string("player_no_audio_tracks_available", fallback: "No audio tracks available"))
                    .font(.system(size: 23, weight: .medium))
                    .foregroundColor(.white.opacity(0.45))
                    .padding(.top, 10)
                Spacer(minLength: 0)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 14) {
                        ForEach(orderedAudioTracks) { track in
                            audioTrackCard(track)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .focusSection()
            }
        }
        .frame(width: 840, alignment: .leading)
    }

    /// Preferred audio first, followed by the remaining languages
    /// alphabetically. Preserve the stream's original order within a language
    /// so commentary/Atmos/stereo variants do not jump around unexpectedly.
    private var orderedAudioTracks: [AudioTrack] {
        let preferred = SubtitleLanguagePreferences.preferredAudioLanguage()
        return viewModel.audioTracks.enumerated().sorted { lhs, rhs in
            let lhsPreferred = preferred.map { audioTrack(lhs.element, matches: $0) } ?? false
            let rhsPreferred = preferred.map { audioTrack(rhs.element, matches: $0) } ?? false
            if lhsPreferred != rhsPreferred { return lhsPreferred }

            let lhsLanguage = lhs.element.languageName.isEmpty ? lhs.element.name : lhs.element.languageName
            let rhsLanguage = rhs.element.languageName.isEmpty ? rhs.element.name : rhs.element.languageName
            let comparison = lhsLanguage.localizedCaseInsensitiveCompare(rhsLanguage)
            if comparison != .orderedSame { return comparison == .orderedAscending }
            return lhs.offset < rhs.offset
        }
        .map(\.element)
    }

    private func audioTrack(_ track: AudioTrack, matches language: String) -> Bool {
        SubtitleLanguagePreferences.matches(track.language, target: language) ||
        SubtitleLanguagePreferences.matches(track.languageName, target: language) ||
        SubtitleLanguagePreferences.matches(track.name, target: language)
    }

    private func audioTrackCard(_ track: AudioTrack) -> some View {
        let isFocused = focus == .audio(track.id)
        return Button {
            viewModel.selectAudio(track)
        } label: {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(track.name)
                        .font(.system(size: 27, weight: .semibold))
                        .foregroundColor(isFocused ? .black : .white)
                        .lineLimit(1)
                    if !track.languageName.isEmpty {
                        Text(track.languageName)
                            .font(.system(size: 20, weight: .medium))
                            .foregroundColor(isFocused ? .black.opacity(0.58) : .white.opacity(0.6))
                            .lineLimit(1)
                    }
                    if !track.detail.isEmpty {
                        Text(track.detail)
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(isFocused ? .black.opacity(0.44) : .white.opacity(0.4))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if track.isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 25, weight: .bold))
                        .foregroundColor(isFocused ? .black : .white)
                }
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(isFocused ? Color.white : Color.white.opacity(0.07))
            )
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($focus, equals: .audio(track.id))
        .focusEffectDisabledIfAvailable()
    }

    private var audioAdjustmentsColumn: some View {
        let aetherAmplificationUnavailable = viewModel.activeEngineKind == .aether
        return VStack(alignment: .leading, spacing: 28) {
            audioOutputSection

            audioStepper(
                title: L10n.string("player_audio_delay", fallback: "Audio Delay"),
                value: String(format: "%.3fs", Double(viewModel.audioDelayMs) / 1000.0),
                caption: L10n.string("player_audio_delay_range", fallback: "Range: -3.00s to 3.00s"),
                minusKey: .delayMinus,
                plusKey: .delayPlus,
                minusDisabled: viewModel.audioDelayMs <= -3000,
                plusDisabled: viewModel.audioDelayMs >= 3000,
                onMinus: { viewModel.setAudioDelayMs(viewModel.audioDelayMs - 50) },
                onPlus: { viewModel.setAudioDelayMs(viewModel.audioDelayMs + 50) }
            )

            audioStepper(
                title: L10n.string("player_audio_amplification", fallback: "Amplification (PCM)"),
                value: "\(viewModel.audioAmplificationDb) dB",
                caption: aetherAmplificationUnavailable
                    ? L10n.string("player_unavailable_with_aether", fallback: "Unavailable with Aether")
                    : L10n.string("player_amplification_range", fallback: "Range: 0 dB to 10 dB"),
                minusKey: .ampMinus,
                plusKey: .ampPlus,
                minusDisabled: aetherAmplificationUnavailable || viewModel.audioAmplificationDb <= 0,
                plusDisabled: aetherAmplificationUnavailable || viewModel.audioAmplificationDb >= 10,
                onMinus: { viewModel.setAudioAmplificationDb(viewModel.audioAmplificationDb - 1) },
                onPlus: { viewModel.setAudioAmplificationDb(viewModel.audioAmplificationDb + 1) }
            )

            Text(L10n.string("player_persist_between_sessions_off", fallback: "Persist between sessions: OFF"))
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white.opacity(0.42))
                .padding(.top, 4)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
    }

    private var audioOutputSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.string("player_audio_output", fallback: "Audio Output"))
                .font(.system(size: 27, weight: .semibold))
                .foregroundColor(.white)

            HStack(spacing: 16) {
                Image(systemName: "airplayaudio")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundColor(.white)

                VStack(alignment: .leading, spacing: 4) {
                    Text(viewModel.currentAudioRouteDescription)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)

                    Text(L10n.string(
                        "player_audio_output_hint",
                        fallback: "Control volume with Siri Remote ± or hold TV button"
                    ))
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                SystemAudioRoutePicker()
                    .frame(width: 80, height: 50)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(0.07))
            )
        }
    }

    private func audioStepper(
        title: String,
        value: String,
        caption: String,
        minusKey: AudioControl,
        plusKey: AudioControl,
        minusDisabled: Bool,
        plusDisabled: Bool,
        onMinus: @escaping () -> Void,
        onPlus: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            styleLabel(title)
            Text(value)
                .font(.system(size: 34, weight: .semibold))
                .foregroundColor(.white)
            HStack(spacing: 16) {
                audioStepButton("minus", focusKey: minusKey, disabled: minusDisabled, action: onMinus)
                audioStepButton("plus", focusKey: plusKey, disabled: plusDisabled, action: onPlus)
            }
            Text(caption)
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(.white.opacity(0.4))
        }
    }

    private func audioStepButton(
        _ systemName: String,
        focusKey: AudioControl,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let isFocused = focus == .audioControl(focusKey)
        return Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 23, weight: .bold))
                .foregroundColor(disabled ? .white.opacity(0.22) : (isFocused ? .black : .white))
                .frame(width: 96, height: 60)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(isFocused && !disabled ? Color.white : Color.white.opacity(0.10))
                )
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($focus, equals: .audioControl(focusKey))
        .focusEffectDisabledIfAvailable()
        .disabled(disabled)
    }

    private var speedPage: some View {
        HStack(alignment: .top, spacing: 56) {
            VStack(alignment: .leading, spacing: 18) {
                columnHeader("Playback Speed")
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 12) {
                        ForEach(PlaybackSpeed.allCases) { speed in
                            simpleRow(
                                title: speed.label,
                                isSelected: viewModel.playbackSpeed == speed,
                                focusKey: .speed(speed.rawValue)
                            ) {
                                viewModel.setSpeed(speed)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
                .focusSection()
            }
            .frame(width: 700, alignment: .leading)

            VStack(alignment: .leading, spacing: 18) {
                columnHeader("Seek Step")
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 12) {
                        ForEach(PlayerSeekSettings.validSteps, id: \.self) { seconds in
                            simpleRow(
                                title: "\(seconds)s",
                                isSelected: viewModel.seekStepSeconds == seconds,
                                focusKey: .seekStep(seconds)
                            ) {
                                viewModel.setSeekStepSeconds(seconds)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
                .focusSection()
            }
            .frame(width: 320, alignment: .leading)

            VStack(alignment: .leading, spacing: 18) {
                columnHeader(L10n.string("player_options", fallback: "Options"))
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 12) {
                        toggleRow(
                            title: L10n.string("tvos_settings_seeking_preview", fallback: "Seeking Preview"),
                            isOn: viewModel.isSeekPreviewEnabled,
                            focusKey: .seekPreview
                        ) {
                            viewModel.setSeekPreviewEnabled(!viewModel.isSeekPreviewEnabled)
                        }

                        simpleRow(
                            title: L10n.string("tvos_settings_playback_debug_overlay", fallback: "Playback Debug Overlay"),
                            isSelected: viewModel.isPlaybackDebugEnabled,
                            focusKey: .debugOverlay
                        ) {
                            viewModel.togglePlaybackDebugHUD()
                        }
                    }
                    .padding(.vertical, 6)
                }
                .focusSection()
            }
            .frame(width: 420, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var picturePage: some View {
        VStack(alignment: .leading, spacing: 18) {
            columnHeader("Aspect Ratio")
            Text(L10n.string("player_aspect_ratio_hint", fallback: "How the video fills the screen"))
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(.white.opacity(0.5))
            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    ForEach(PlayerAspectMode.allCases) { mode in
                        aspectRow(mode)
                    }
                }
                .padding(.vertical, 6)
            }
            .focusSection()
        }
        .frame(maxWidth: 720, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func aspectRow(_ mode: PlayerAspectMode) -> some View {
        let isFocused = focus == .aspect(mode.rawValue)
        let isSelected = viewModel.aspectMode == mode
        return Button {
            viewModel.setAspectMode(mode)
        } label: {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(mode.label)
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundColor(isFocused ? .black : .white)
                    Text(mode.detail)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(isFocused ? .black.opacity(0.55) : .white.opacity(0.5))
                }
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundColor(isFocused ? .black : .white)
                }
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 20)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(isFocused ? Color.white : Color.white.opacity(0.08))
            )
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($focus, equals: .aspect(mode.rawValue))
        .focusEffectDisabledIfAvailable()
    }

    private func simpleRow(
        title: String,
        isSelected: Bool,
        focusKey: Focus,
        action: @escaping () -> Void
    ) -> some View {
        let isFocused = focus == focusKey
        return Button(action: action) {
            HStack(spacing: 14) {
                Text(title)
                    .font(.system(size: 27, weight: .semibold))
                    .foregroundColor(isFocused ? .black : .white)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 25, weight: .bold))
                        .foregroundColor(isFocused ? .black : .white)
                }
            }
            .padding(.horizontal, 26)
            .frame(height: 68)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isFocused ? Color.white : Color.white.opacity(0.07))
            )
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($focus, equals: focusKey)
        .focusEffectDisabledIfAvailable()
    }

    private func toggleRow(
        title: String,
        isOn: Bool,
        focusKey: Focus,
        action: @escaping () -> Void
    ) -> some View {
        let isFocused = focus == focusKey
        return Button(action: action) {
            HStack(spacing: 14) {
                Text(title)
                    .font(.system(size: 27, weight: .semibold))
                    .foregroundColor(isFocused ? .black : .white)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(isOn ? "On" : "Off")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(isFocused ? .black.opacity(0.85) : .white.opacity(0.75))
                if isOn {
                    Image(systemName: "checkmark")
                        .font(.system(size: 23, weight: .bold))
                        .foregroundColor(isFocused ? .black : .white)
                }
            }
            .padding(.horizontal, 26)
            .frame(height: 68)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isFocused ? Color.white : Color.white.opacity(0.07))
            )
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($focus, equals: focusKey)
        .focusEffectDisabledIfAvailable()
    }

    private func columnHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 26, weight: .semibold))
            .foregroundColor(.white.opacity(0.45))
    }

    private func styleLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 26, weight: .semibold))
            .foregroundColor(.white)
    }
}

struct SystemAudioRoutePicker: UIViewRepresentable {
    var tintColor: UIColor = .white
    var activeTintColor: UIColor = .white

    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = false
        picker.tintColor = tintColor
        picker.activeTintColor = activeTintColor
        picker.backgroundColor = .clear
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        uiView.tintColor = tintColor
        uiView.activeTintColor = activeTintColor
    }
}
