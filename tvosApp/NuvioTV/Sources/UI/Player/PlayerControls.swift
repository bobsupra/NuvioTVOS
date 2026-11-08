import SwiftUI
import AVKit
import CoreGraphics

enum PlayerControlFocus: Hashable {
    case pip
    case episodes
    case sources
    case subtitles
    case audio
    case speed
    case settings
    case timeline
    case firstTransportButton
}

private extension TVPlayerButton {
    var focusKey: PlayerControlFocus {
        switch self {
        case .pip: return .pip
        case .episodes: return .episodes
        case .sources: return .sources
        case .subtitles: return .subtitles
        case .audio: return .audio
        case .speed: return .speed
        }
    }
}

struct PlayerControls: View {
    @ObservedObject var viewModel: PlayerViewModel
    var didReportPlaybackStarted: Bool = false
    var isSkipSegmentFocused: Bool = false
    var isNextEpisodeFocused: Bool = false
    @Binding var requestedFocus: PlayerControlFocus?
    var onFocusSkipSegment: () -> Void = {}
    var onFocusNextEpisode: () -> Void = {}

    @FocusState private var focusedControl: PlayerControlFocus?
    @State private var isAuxiliaryCardFocusActive = false
    @State private var playerButtonOrder = TVPlayerButtonOrder.currentOrder()
    @State private var isNamingSubtitlePreset = false
    @State private var presetNameToSave = ""
    @State private var renamingPresetID: String?

    @AppStorage(SettingsKey.playerShowPiP) private var playerShowPiP = true
    @AppStorage(SettingsKey.playerShowEpisodes) private var playerShowEpisodes = true
    @AppStorage(SettingsKey.playerShowSources) private var playerShowSources = true
    @AppStorage(SettingsKey.playerShowSubtitles) private var playerShowSubtitles = true
    @AppStorage(SettingsKey.playerShowAudio) private var playerShowAudio = true
    @AppStorage(SettingsKey.playerShowSpeed) private var playerShowSpeed = true

    var body: some View {
        ZStack {
            GlassControlsContainer {
                VStack {
                    Spacer(minLength: 0)
                    bottomControls
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onExitCommand(perform: handleExit)
            }
            .disabled(isNamingSubtitlePreset)

            if isNamingSubtitlePreset {
                PlayerPresetNameDialog(
                    title: renamingPresetID != nil
                        ? L10n.string("subtitle_style_rename_title", fallback: "Rename Subtitle Preset")
                        : L10n.string("subtitle_style_save_title", fallback: "Save Subtitle Preset"),
                    text: $presetNameToSave,
                    onSave: { customName in
                        isNamingSubtitlePreset = false
                        if let renamingPresetID {
                            SubtitleStylePresetStore.shared.renameCustomPreset(id: renamingPresetID, newName: customName)
                            self.renamingPresetID = nil
                            viewModel.applySubtitleStyle()
                            viewModel.showPlayerToast(L10n.format("subtitle_style_renamed_toast", fallback: "Renamed preset: %@", customName))
                        } else {
                            let newPreset = SubtitleStylePresetStore.shared.saveCurrentAsPreset(name: customName)
                            viewModel.applySubtitleStyle()
                            viewModel.showPlayerToast(L10n.format("subtitle_style_saved_toast", fallback: "Saved preset: %@", newPreset.name))
                        }
                        viewModel.setControlsAutoHideSuspended(false)
                        viewModel.scheduleControlsHide(after: 10.0)
                    },
                    onCancel: {
                        isNamingSubtitlePreset = false
                        renamingPresetID = nil
                        viewModel.setControlsAutoHideSuspended(false)
                        viewModel.scheduleControlsHide(after: 10.0)
                    }
                )
                .transition(.opacity)
            }
        }
        .onExitCommand(perform: handleExit)
        .onChange(of: requestedFocus) { _, target in
            guard let target,
                  viewModel.showControls,
                  !viewModel.controlsAutoHideSuspended || isAuxiliaryCardFocusActive else { return }
            DispatchQueue.main.async {
                let resolvedTarget: PlayerControlFocus
                if target == .firstTransportButton {
                    resolvedTarget = transportFocusOrder.first ?? .settings
                } else if target == .timeline && !didReportPlaybackStarted {
                    resolvedTarget = .settings
                } else {
                    resolvedTarget = target
                }
                if resolvedTarget == .timeline {
                    focusedControl = .timeline
                } else {
                    focusedControl = isTransportButtonFocusable(resolvedTarget) ? resolvedTarget : (transportFocusOrder.first ?? .settings)
                }
                requestedFocus = nil
            }
        }
        .onChange(of: isSkipSegmentFocused || isNextEpisodeFocused, initial: true) { _, isCardFocused in
            if isCardFocused {
                isAuxiliaryCardFocusActive = true
                viewModel.setControlsAutoHideSuspended(false)
            } else if focusedControl != nil {
                isAuxiliaryCardFocusActive = false
            }
        }
        .onChange(of: viewModel.showSettingsPanel) { _, isPresented in
            if !isPresented, viewModel.showControls {
                DispatchQueue.main.async { focusedControl = .settings }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: TVPlayerButtonOrder.changedNotification).receive(on: RunLoop.main)) { _ in
            reloadPlayerButtonOrder()
        }
        .onReceive(NotificationCenter.default.publisher(for: ProfileSettings.settingsChangedNotification).receive(on: RunLoop.main)) { _ in
            reloadPlayerButtonOrder()
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: RunLoop.main)) { _ in
            reloadPlayerButtonOrder()
        }
        .onAppear {
            reloadPlayerButtonOrder()
            if (viewModel.showControls || viewModel.isScrubbing),
               !viewModel.showPauseOverlay,
               !viewModel.postPlayState.isVisible,
               !isSkipSegmentFocused,
               !isNextEpisodeFocused {
                DispatchQueue.main.async {
                    focusedControl = initialFocusControl
                }
            }
        }
        .onChange(of: viewModel.status) { _, status in
            guard !viewModel.controlsAutoHideSuspended else { return }
            if status == .paused,
               viewModel.showControls,
               !viewModel.showPauseOverlay,
               !viewModel.postPlayState.isVisible,
               !isSkipSegmentFocused,
               !isNextEpisodeFocused {
                DispatchQueue.main.async {
                    focusedControl = initialFocusControl
                }
            } else if status == .playing,
               viewModel.showControls,
               !viewModel.showPauseOverlay,
               !viewModel.postPlayState.isVisible,
               !isSkipSegmentFocused,
               !isNextEpisodeFocused,
               focusedControl == nil {
                DispatchQueue.main.async {
                    focusedControl = initialFocusControl
                }
            }
        }
        .onChange(of: viewModel.showControls) { _, isVisible in
            guard !viewModel.controlsAutoHideSuspended else { return }
            // Don't steal focus while the pause metadata sheet, loading, or post play owns the remote.
            if isVisible,
               !viewModel.isSwitchingSource,
               !viewModel.isAwaitingStreamStart,
               !viewModel.isReloadingStream,
               !viewModel.isAdvancingEpisode,
               !viewModel.showPauseOverlay,
               !viewModel.postPlayState.isVisible,
               !isSkipSegmentFocused,
               !isNextEpisodeFocused {
                DispatchQueue.main.async {
                    focusedControl = initialFocusControl
                }
            } else if !isVisible {
                focusedControl = nil
            }
        }
        .onChange(of: viewModel.isSwitchingSource) { _, isSwitching in
            guard !isSwitching,
                  viewModel.showControls,
                  !viewModel.isAwaitingStreamStart,
                  !viewModel.isReloadingStream,
                  !viewModel.isAdvancingEpisode,
                  !viewModel.controlsAutoHideSuspended,
                  !viewModel.showSettingsPanel,
                  !viewModel.showScenePanel,
                  !viewModel.isSceneDetailVisible,
                  viewModel.sidePanel == nil,
                  !viewModel.postPlayState.isVisible,
                  !viewModel.showPauseOverlay,
                  !isSkipSegmentFocused,
                  !isNextEpisodeFocused else { return }
            DispatchQueue.main.async {
                focusedControl = initialFocusControl
            }
        }
        .onChange(of: viewModel.isAwaitingStreamStart) { _, isAwaiting in
            guard !isAwaiting,
                  viewModel.showControls,
                  !viewModel.isSwitchingSource,
                  !viewModel.isReloadingStream,
                  !viewModel.isAdvancingEpisode,
                  !viewModel.controlsAutoHideSuspended,
                  !viewModel.showSettingsPanel,
                  !viewModel.showScenePanel,
                  !viewModel.isSceneDetailVisible,
                  viewModel.sidePanel == nil,
                  !viewModel.postPlayState.isVisible,
                  !viewModel.showPauseOverlay,
                  !isSkipSegmentFocused,
                  !isNextEpisodeFocused else { return }
            DispatchQueue.main.async {
                focusedControl = initialFocusControl
            }
        }
        .onChange(of: viewModel.isTimelineFocused) { _, isTimelineFocused in
            guard !viewModel.controlsAutoHideSuspended else { return }
            if isTimelineFocused,
               viewModel.showControls,
               !viewModel.showPauseOverlay,
               !viewModel.postPlayState.isVisible,
               !isSkipSegmentFocused,
               !isNextEpisodeFocused,
               focusedControl != .timeline {
                DispatchQueue.main.async {
                    focusedControl = initialFocusControl
                }
            }
        }
        .onChange(of: viewModel.isLiveStream) { _, isLive in
            if isLive, focusedControl == .timeline {
                DispatchQueue.main.async { focusedControl = initialFocusControl }
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
            if isFocused {
                focusedControl = nil
            } else if canRestoreFocusAfterNextEpisode {
                DispatchQueue.main.async {
                    guard canRestoreFocusAfterNextEpisode else { return }
                    focusedControl = initialFocusControl
                }
            }
        }
        .onChange(of: viewModel.isHoldingSeek) { _, isHolding in
            guard didReportPlaybackStarted, !viewModel.controlsAutoHideSuspended else { return }
            if isHolding, viewModel.showControls {
                DispatchQueue.main.async {
                    focusedControl = .timeline
                }
            }
        }
        .onChange(of: focusedControl) { oldControl, newControl in
            if newControl != nil {
                isAuxiliaryCardFocusActive = false
            }
            // Keep this in lockstep with focus so hold-to-seek gating is correct
            // even before the next render cycle.
            let onTimeline = (newControl == .timeline)
            viewModel.setTimelineFocused(onTimeline)
            // Opt-in breadcrumbs only: native Menu has no explicit presentation binding.
            // These record focus transitions, not confirmed menu-open/menu-close events.
            if newControl == nil {
                if oldControl == .audio {
                    PlaybackTimelineRecorder.record(.audioMenuFocusLeft, engine: viewModel.activeEngineKind)
                } else if oldControl == .subtitles {
                    PlaybackTimelineRecorder.record(.subtitleMenuFocusLeft, engine: viewModel.activeEngineKind)
                }
            } else if oldControl == nil {
                if newControl == .audio {
                    PlaybackTimelineRecorder.record(.audioMenuFocusReturned, engine: viewModel.activeEngineKind)
                } else if newControl == .subtitles {
                    PlaybackTimelineRecorder.record(.subtitleMenuFocusReturned, engine: viewModel.activeEngineKind)
                }
            }
            if onTimeline {
                viewModel.setControlsAutoHideSuspended(false)
                viewModel.scheduleControlsHide(after: 5.0)
            } else if newControl != nil {
                // A focused Menu button is not an open menu. Returning to it
                // after selecting or cancelling must resume the hide timer.
                viewModel.setControlsAutoHideSuspended(false)
                viewModel.scheduleControlsHide(after: 10.0)
            } else if viewModel.showControls,
                      !isAuxiliaryCardFocusActive,
                      let old = oldControl, old == .subtitles || old == .audio {
                // Focus transitioned from a native Menu button into the presented menu items.
                // Losing focus because controls were hidden must not suspend
                // auto-hide and block a later revealControls() call.
                DispatchQueue.main.async {
                    // Card focus bindings update asynchronously with the focus handoff.
                    guard focusedControl == nil,
                          viewModel.showControls,
                          !isAuxiliaryCardFocusActive,
                          !isSkipSegmentFocused,
                          !isNextEpisodeFocused else { return }
                    viewModel.setControlsAutoHideSuspended(true)
                }
            }
        }
        .onDisappear {
            viewModel.setTimelineFocused(false)
            viewModel.setControlsAutoHideSuspended(false)
            isAuxiliaryCardFocusActive = false
        }
    }

    private func handleExit() {
        if isNamingSubtitlePreset {
            isNamingSubtitlePreset = false
            renamingPresetID = nil
            return
        }
        PlaybackTimelineRecorder.record(.controlsExitReceived, engine: viewModel.activeEngineKind)
        if viewModel.isScrubbing {
            viewModel.cancelScrub()
        } else if focusedControl == nil,
                  viewModel.showControls,
                  viewModel.controlsAutoHideSuspended,
                  !isAuxiliaryCardFocusActive,
                  !isSkipSegmentFocused,
                  !isNextEpisodeFocused {
            // Native Menu owns focus until Back dismisses it.
            return
        } else {
            viewModel.hideControls()
        }
    }

    private var isPlaybackStarted: Bool {
        viewModel.status == .playing || viewModel.status == .paused || viewModel.time.duration > 0 || viewModel.isLiveStream || viewModel.hasRenderedFirstFrame
    }

    private var initialFocusControl: PlayerControlFocus {
        guard didReportPlaybackStarted else { return .settings }
        return viewModel.isLiveStream ? (transportFocusOrder.first ?? .settings) : .timeline
    }

    /// Transport + timeline are focusable whenever chrome is up. Do not gate on
    /// `focusedControl != .timeline` — toggling `.focusable` when moving between
    /// buttons left Select dead after visiting settings/episodes/sources.
    private var controlsInteractable: Bool {
        (viewModel.showControls || viewModel.isScrubbing)
            && !viewModel.isSwitchingSource
            && !viewModel.isAwaitingStreamStart
            && !viewModel.isReloadingStream
            && !viewModel.isAdvancingEpisode
            && !viewModel.showPauseOverlay
            && !viewModel.showSettingsPanel
            && !viewModel.showScenePanel
            && !viewModel.isSceneDetailVisible
            && !viewModel.postPlayState.isVisible
            && viewModel.sidePanel == nil
    }

    private var canRestoreFocusAfterNextEpisode: Bool {
        controlsInteractable
            && focusedControl == nil
            && requestedFocus == nil
            && !viewModel.controlsAutoHideSuspended
            && !isSkipSegmentFocused
            && !isNextEpisodeFocused
    }

    /// Left-to-right order of currently visible transport buttons.
    private var transportFocusOrder: [PlayerControlFocus] {
        availableTransportButtons.map(\.focusKey) + [.settings]
    }

    private var availableTransportButtons: [TVPlayerButton] {
        playerButtonOrder.filter { button in
            switch button {
            case .pip:
                return didReportPlaybackStarted && viewModel.isPictureInPictureSupported && playerShowPiP
            case .episodes:
                return viewModel.canShowEpisodesPanel && playerShowEpisodes
            case .sources:
                return viewModel.canShowSourcesPanel && playerShowSources
            case .subtitles:
                return didReportPlaybackStarted && canShowSubtitlePicker && playerShowSubtitles
            case .audio:
                return didReportPlaybackStarted && canShowAudioPicker && playerShowAudio
            case .speed:
                return didReportPlaybackStarted && playerShowSpeed
            }
        }
    }

    private func reloadPlayerButtonOrder() {
        let order = TVPlayerButtonOrder.currentOrder()
        guard playerButtonOrder != order else { return }
        playerButtonOrder = order
    }

    private var canShowSubtitlePicker: Bool {
        !subtitlePanelOptions(for: viewModel).isEmpty
    }

    private var canShowAudioPicker: Bool {
        !viewModel.audioTracks.isEmpty || isPlaybackStarted
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

    private func isTransportButtonFocusable(_ key: PlayerControlFocus) -> Bool {
        guard controlsInteractable else { return false }
        guard key != .pip || didReportPlaybackStarted else { return false }
        return true
    }

    private func moveFocus(to control: PlayerControlFocus) {
        focusedControl = control
    }

    /// Navigate from the control that *received* the move — not `focusedControl`,
    /// which may already have been updated by the spatial focus engine.
    private func handleMove(_ direction: MoveCommandDirection, from origin: PlayerControlFocus) {
        guard !isSkipSegmentFocused, !isNextEpisodeFocused else { return }
        guard controlsInteractable else { return }
        guard origin != .timeline || didReportPlaybackStarted else { return }
        guard focusedControl != nil, !viewModel.controlsAutoHideSuspended else { return }

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
            } else if viewModel.showSkipSegmentCard {
                onFocusSkipSegment()
            } else {
                moveFocus(to: origin)
            }
        case .down:
            viewModel.cancelMoveSeekTracking()
            if origin != .timeline, !viewModel.isLiveStream {
                if didReportPlaybackStarted {
                    moveFocus(to: .timeline)
                }
            } else if origin == .timeline, viewModel.isSceneEnabled {
                viewModel.openScene()
            }
        case .left:
            if origin == .timeline, !viewModel.isLiveStream {
                if viewModel.isScrubbing {
                    viewModel.scrubJump(-Double(max(viewModel.seekStepSeconds * 4, 60)))
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

    // MARK: - Playback title

    private var playbackTitle: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let subtitle = playbackSubtitle {
                Text(subtitle)
                    .font(.system(size: 21, weight: .medium))
                    .foregroundColor(.white.opacity(0.76))
                    .lineLimit(1)
            }

            Text(viewModel.title)
                .font(.system(size: 38, weight: .bold))
                .foregroundColor(.white)
                .lineLimit(1)
        }
    }

    private var playbackSubtitle: String? {
        let subtitle = viewModel.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !subtitle.isEmpty, subtitle != PlaybackMarkers.trailerSubtitle else { return nil }
        return subtitle
            .replacingOccurrences(of: " · E", with: ", E")
            .replacingOccurrences(of: " · ", with: " • ")
    }

    // MARK: - Bottom controls

    private var bottomControls: some View {
        VStack(alignment: .leading, spacing: 24) {
            if !viewModel.isScrubbing {
                HStack(alignment: .bottom, spacing: 24) {
                    playbackTitle
                    Spacer(minLength: 24)
                    transportRow
                }
                    .transition(.opacity)
            }
            timelineBar
        }
        .padding(.horizontal, 60)
        .padding(.bottom, 54)
        .animation(.playerControls, value: viewModel.isScrubbing)
    }

    private var transportRow: some View {
        HStack(spacing: 18) {
            ForEach(availableTransportButtons) { button in
                transportButton(button)
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
        .focusSection()
    }

    @ViewBuilder
    private func transportButton(_ button: TVPlayerButton) -> some View {
        switch button {
        case .pip:
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

        case .episodes:
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

        case .sources:
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

        case .subtitles:
            let activeAddonSubtitle = viewModel.activeAddonSubtitle
            let autoSyncState = activeAddonSubtitle.flatMap { viewModel.subtitleAutoSyncStates[$0.url] }
            let isSubtitleAutoSyncUsingOriginal = activeAddonSubtitle.map {
                viewModel.isSubtitleAutoSyncUsingOriginal($0.url)
            } ?? false
            let syncActionTitle: String = {
                switch autoSyncState {
                case .checking?:
                    return L10n.string("player_autosync_running", fallback: "Checking…")
                case .synced?:
                    return L10n.string(
                        isSubtitleAutoSyncUsingOriginal
                            ? "player_subtitle_autosync_original"
                            : "player_autosync_subtitle_synced",
                        fallback: isSubtitleAutoSyncUsingOriginal ? "Original Timing" : "Subtitle Synced"
                    )
                case .kept(.inSync)?:
                    return L10n.string("player_subtitle_autosync_in_sync_short", fallback: "In Sync")
                default:
                    return L10n.string("player_autosync_sync_subtitle", fallback: "Sync Subtitle")
                }
            }()
            let audioSyncStatus = viewModel.audioSyncStatus.flatMap {
                $0.subtitleURL == activeAddonSubtitle?.url ? $0 : nil
            }
            let audioSyncTimingStatus = viewModel.audioSyncTimingStatusForCurrentSubtitle
            let isAudioSyncRunningForSelectedSubtitle = viewModel.isAudioSyncRunning
                && audioSyncStatus?.isRunning == true
            let isAudioSyncAppliedForSelectedSubtitle = audioSyncTimingStatus != nil
            let isAudioSyncUsingOriginalTiming = audioSyncTimingStatus?.isOriginalTimingSelected ?? false
            let canToggleAudioSyncTiming = audioSyncTimingStatus.map {
                $0.originalDelayMs != $0.syncedDelayMs
            } ?? false
            PlayerSubtitleMenuButton(
                noneOption: subtitleNoneOption,
                languageGroups: subtitleLanguageGroups,
                isFocused: focusedControl == .subtitles,
                autoSyncState: autoSyncState,
                syncActionTitle: syncActionTitle,
                isSubtitleAutoSyncUsingOriginal: isSubtitleAutoSyncUsingOriginal,
                hasActiveAddonSubtitle: activeAddonSubtitle != nil,
                isAudioSyncRunningForSelectedSubtitle: isAudioSyncRunningForSelectedSubtitle,
                isAudioSyncAppliedForSelectedSubtitle: isAudioSyncAppliedForSelectedSubtitle,
                isAudioSyncUsingOriginalTiming: isAudioSyncUsingOriginalTiming,
                canToggleAudioSyncTiming: canToggleAudioSyncTiming,
                canToggleAudioSync: activeAddonSubtitle != nil
                    && (isAudioSyncRunningForSelectedSubtitle || viewModel.activeEngineKind == .aether),
                activeStylePresetTitle: SubtitleStylePresetStore.shared.activePresetTitle(for: viewModel.subtitleStyle),
                activeStylePresetID: SubtitleStylePresetStore.shared.activePreset(for: viewModel.subtitleStyle)?.id,
                stylePresets: SubtitleStylePresetStore.shared.allPresets(),
                onSelect: { selectSubtitlePickerOption($0) },
                onRunAutoSync: {
                    guard let activeAddonSubtitle = viewModel.activeAddonSubtitle else { return }
                    switch viewModel.subtitleAutoSyncStates[activeAddonSubtitle.url] {
                    case .checking?, .synced?, .kept(.inSync)?:
                        return
                    default:
                        viewModel.runSubtitleAutoSyncNow()
                    }
                },
                onToggleSubtitleTiming: {
                    guard let activeAddonSubtitle = viewModel.activeAddonSubtitle,
                          case .synced? = viewModel.subtitleAutoSyncStates[activeAddonSubtitle.url] else {
                        return
                    }
                    viewModel.toggleSubtitleAutoSyncTiming()
                },
                onToggleAudioSync: {
                    if viewModel.isAudioSyncRunning,
                       let activeAddonSubtitle,
                       viewModel.audioSyncStatus?.subtitleURL != activeAddonSubtitle.url {
                        viewModel.startAudioSync()
                    } else {
                        viewModel.toggleAudioSync()
                    }
                    viewModel.setControlsAutoHideSuspended(false)
                    viewModel.scheduleControlsHide(after: 10.0)
                },
                onToggleAudioSyncTiming: {
                    viewModel.toggleAudioSyncTiming()
                },
                onSelectPreset: { preset in
                    SubtitleStylePresetStore.shared.applyPreset(preset)
                    viewModel.applySubtitleStyle()
                    viewModel.showPlayerToast(L10n.format("subtitle_style_applied_toast", fallback: "Style: %@", preset.name))
                    viewModel.setControlsAutoHideSuspended(false)
                    viewModel.scheduleControlsHide(after: 10.0)
                },
                onSaveCurrentAsPreset: {
                    presetNameToSave = SubtitleStylePresetStore.shared.suggestedCustomPresetName()
                    renamingPresetID = nil
                    isNamingSubtitlePreset = true
                    viewModel.setControlsAutoHideSuspended(true)
                },
                onRenameCustomPreset: { preset in
                    presetNameToSave = preset.name
                    renamingPresetID = preset.id
                    isNamingSubtitlePreset = true
                    viewModel.setControlsAutoHideSuspended(true)
                },
                onDeleteCustomPreset: { preset in
                    SubtitleStylePresetStore.shared.deleteCustomPreset(id: preset.id)
                    viewModel.applySubtitleStyle()
                    viewModel.showPlayerToast(L10n.format("subtitle_style_deleted_toast", fallback: "Deleted preset: %@", preset.name))
                    viewModel.setControlsAutoHideSuspended(false)
                    viewModel.scheduleControlsHide(after: 10.0)
                }
            )
            .equatable()
            .focused($focusedControl, equals: .subtitles)
            .disabled(!isTransportButtonFocusable(.subtitles))
            .onExitCommand(perform: handleExit)
            .onMoveCommand { direction in
                handleMove(direction, from: .subtitles)
            }

        case .audio:
            PlayerAudioMenuButton(
                orderedTracks: orderedAudioTracks,
                supportsAudioProcessing: viewModel.supportsAudioProcessing,
                enhanceDialogueMode: viewModel.supportsAudioProcessing ? viewModel.enhanceDialogueMode : .off,
                isReduceLoudSoundsActive: viewModel.supportsAudioProcessing && viewModel.isReduceLoudSoundsActive,
                isFocused: focusedControl == .audio,
                onSelectTrack: { track in
                    viewModel.selectAudio(track)
                    viewModel.setControlsAutoHideSuspended(false)
                    viewModel.scheduleControlsHide(after: 10.0)
                },
                onSetEnhanceDialogueMode: { mode in
                    viewModel.setEnhanceDialogueMode(mode)
                    viewModel.setControlsAutoHideSuspended(false)
                    viewModel.scheduleControlsHide(after: 10.0)
                },
                onToggleReduceLoudSounds: {
                    viewModel.toggleReduceLoudSounds()
                    viewModel.setControlsAutoHideSuspended(false)
                    viewModel.scheduleControlsHide(after: 10.0)
                }
            )
            .equatable()
            .focused($focusedControl, equals: .audio)
            .disabled(!isTransportButtonFocusable(.audio))
            .onExitCommand(perform: handleExit)
            .onMoveCommand { direction in
                handleMove(direction, from: .audio)
            }

        case .speed:
            PlayerSpeedMenuButton(
                currentSpeed: viewModel.playbackSpeed,
                isFocused: focusedControl == .speed,
                onSelectSpeed: { speed in
                    viewModel.setSpeed(speed)
                    viewModel.showPlayerToast("Speed \(speed.label)")
                    viewModel.setControlsAutoHideSuspended(false)
                    viewModel.scheduleControlsHide(after: 10.0)
                }
            )
            .equatable()
            .focused($focusedControl, equals: .speed)
            .disabled(!isTransportButtonFocusable(.speed))
            .onExitCommand(perform: handleExit)
            .onMoveCommand { direction in
                handleMove(direction, from: .speed)
            }
        }
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
                .frame(width: size, height: size)
                .clipShape(Circle())
                .contentShape(Circle())
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($focusedControl, equals: focusKey)
        .disabled(!isTransportButtonFocusable(focusKey))
        .focusEffectDisabledIfAvailable()
        .onExitCommand(perform: handleExit)
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

    private func selectSubtitlePickerOption(_ option: SubtitlePanelOption) {
        switch option.kind {
        case .track(let track):
            viewModel.selectSubtitle(track)
        case .external(let subtitle):
            viewModel.selectExternalSubtitle(subtitle)
        }
        viewModel.setControlsAutoHideSuspended(false)
        viewModel.scheduleControlsHide(after: 10.0)
    }

    private var orderedAudioTracks: [AudioTrack] {
        let preferred = SubtitleLanguagePreferences.preferredAudioLanguage(meta: viewModel.activeMeta)
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

    // MARK: - Timeline

    private var isTimelineFocused: Bool {
        didReportPlaybackStarted && (focusedControl == .timeline || viewModel.isHoldingSeek)
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
            Text(L10n.string("player_live", fallback: "LIVE"))
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(.white.opacity(0.9))
            Spacer()
        }
        .frame(height: 44)
    }

    private var finiteTimelineBar: some View {
        PlayerTimelineBar(
            clock: viewModel.clock,
            isTimelineFocused: isTimelineFocused,
            isScrubbing: viewModel.isScrubbing,
            isHoldingSeek: viewModel.isHoldingSeek,
            pendingSeekDelta: viewModel.pendingSeekDelta,
            speedMultiplier: viewModel.seekSpeedMultiplier,
            seekStepSeconds: viewModel.seekStepSeconds,
            chapters: viewModel.chapters,
            skipSegments: viewModel.skipSegments
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
                isStale: viewModel.scrubThumbnailIsStale,
                naturalSize: viewModel.videoNaturalSize,
                speedMultiplier: viewModel.seekSpeedMultiplier,
                wheelEngaged: viewModel.wheelEngaged
            )
            .offset(y: -(270 + 16))
            .allowsHitTesting(false)
            .transaction { transaction in transaction.animation = nil }
        }
        .focusable(
            didReportPlaybackStarted
                && (viewModel.showControls || viewModel.isScrubbing)
                && !viewModel.showSettingsPanel
                && !viewModel.showPauseOverlay
                && !viewModel.showScenePanel
                && !viewModel.isSceneDetailVisible
        )
        .focused($focusedControl, equals: .timeline)
        .allowsHitTesting(didReportPlaybackStarted)
        .focusEffectDisabledIfAvailable()
        .onExitCommand(perform: handleExit)
        .onTapGesture {
            if didReportPlaybackStarted {
                viewModel.handleSelectTap()
            }
        }
        .onMoveCommand { direction in
            // Timeline owns move while focused so hold-to-seek cannot promote
            // focus onto the transport buttons. Always route from `.timeline`
            // even if spatial focus already hopped to a transport button.
            handleMove(direction, from: .timeline)
        }
        .animation(.easeOut(duration: 0.14), value: focusedControl)
        .animation(.easeOut(duration: 0.12), value: viewModel.pendingSeekDelta)
        .animation(.easeOut(duration: 0.16), value: viewModel.isScrubbing)
    }
}

// MARK: - Native Subtitle & Audio Menu Buttons (Isolated EquatableViews)

private struct PlayerSubtitleMenuButton: View, Equatable {
    let noneOption: SubtitlePanelOption?
    let languageGroups: [SubtitleLanguageGroup]
    let isFocused: Bool
    let autoSyncState: SubtitleAutoSyncState?
    let syncActionTitle: String
    let isSubtitleAutoSyncUsingOriginal: Bool
    let hasActiveAddonSubtitle: Bool
    let isAudioSyncRunningForSelectedSubtitle: Bool
    let isAudioSyncAppliedForSelectedSubtitle: Bool
    let isAudioSyncUsingOriginalTiming: Bool
    let canToggleAudioSyncTiming: Bool
    let canToggleAudioSync: Bool
    let activeStylePresetTitle: String
    let activeStylePresetID: String?
    let stylePresets: [SubtitleStylePreset]
    let onSelect: (SubtitlePanelOption) -> Void
    let onRunAutoSync: () -> Void
    let onToggleSubtitleTiming: () -> Void
    let onToggleAudioSync: () -> Void
    let onToggleAudioSyncTiming: () -> Void
    let onSelectPreset: (SubtitleStylePreset) -> Void
    let onSaveCurrentAsPreset: () -> Void
    let onRenameCustomPreset: (SubtitleStylePreset) -> Void
    let onDeleteCustomPreset: (SubtitleStylePreset) -> Void

    static func == (lhs: PlayerSubtitleMenuButton, rhs: PlayerSubtitleMenuButton) -> Bool {
        lhs.isFocused == rhs.isFocused
            && lhs.noneOption == rhs.noneOption
            && lhs.languageGroups == rhs.languageGroups
            && lhs.autoSyncState == rhs.autoSyncState
            && lhs.syncActionTitle == rhs.syncActionTitle
            && lhs.isSubtitleAutoSyncUsingOriginal == rhs.isSubtitleAutoSyncUsingOriginal
            && lhs.hasActiveAddonSubtitle == rhs.hasActiveAddonSubtitle
            && lhs.isAudioSyncRunningForSelectedSubtitle == rhs.isAudioSyncRunningForSelectedSubtitle
            && lhs.isAudioSyncAppliedForSelectedSubtitle == rhs.isAudioSyncAppliedForSelectedSubtitle
            && lhs.isAudioSyncUsingOriginalTiming == rhs.isAudioSyncUsingOriginalTiming
            && lhs.canToggleAudioSyncTiming == rhs.canToggleAudioSyncTiming
            && lhs.canToggleAudioSync == rhs.canToggleAudioSync
            && lhs.activeStylePresetTitle == rhs.activeStylePresetTitle
            && lhs.activeStylePresetID == rhs.activeStylePresetID
            && lhs.stylePresets == rhs.stylePresets
    }

    var body: some View {
        Menu {
            Section(L10n.string("playback_section_subtitles", fallback: "Subtitles")) {
                switch autoSyncState {
                case .synced?:
                    Button {} label: {
                        Label(
                            syncActionTitle,
                            systemImage: isSubtitleAutoSyncUsingOriginal ? "clock" : "checkmark.circle"
                        )
                    }
                    .disabled(true)

                    Button {
                        onToggleSubtitleTiming()
                    } label: {
                        Label(
                            L10n.string(
                                isSubtitleAutoSyncUsingOriginal
                                    ? "player_autosync_use_synced"
                                    : "player_subtitle_autosync_original",
                                fallback: isSubtitleAutoSyncUsingOriginal ? "Synced Timing" : "Original Timing"
                            ),
                            systemImage: isSubtitleAutoSyncUsingOriginal ? "checkmark.circle" : "arrow.uturn.backward"
                        )
                    }
                    .menuActionDismissBehavior(.disabled)

                case .kept(.inSync)?:
                    Button {} label: {
                        Label(syncActionTitle, systemImage: "checkmark.circle")
                    }
                    .disabled(true)

                case .checking?, nil:
                    Button {
                        onRunAutoSync()
                    } label: {
                        Label(syncActionTitle, systemImage: "arrow.triangle.2.circlepath")
                    }
                    .menuActionDismissBehavior(.disabled)
                    .disabled(!hasActiveAddonSubtitle)

                default:
                    Button {
                        onRunAutoSync()
                    } label: {
                        Label(syncActionTitle, systemImage: "arrow.triangle.2.circlepath")
                    }
                    .menuActionDismissBehavior(.disabled)
                    .disabled(!hasActiveAddonSubtitle)
                }

                if isAudioSyncAppliedForSelectedSubtitle {
                    Button {} label: {
                        Label(
                            L10n.string(
                                isAudioSyncUsingOriginalTiming
                                    ? "player_subtitle_autosync_original"
                                    : "player_autosync_audio_synced",
                                fallback: isAudioSyncUsingOriginalTiming ? "Original Timing" : "Synced by Audio"
                            ),
                            systemImage: isAudioSyncUsingOriginalTiming ? "clock" : "checkmark.circle"
                        )
                    }
                    .disabled(true)

                    if canToggleAudioSyncTiming {
                        Button {
                            onToggleAudioSyncTiming()
                        } label: {
                            Label(
                                L10n.string(
                                    isAudioSyncUsingOriginalTiming
                                        ? "player_autosync_use_synced"
                                        : "player_subtitle_autosync_original",
                                    fallback: isAudioSyncUsingOriginalTiming ? "Synced Timing" : "Original Timing"
                                ),
                                systemImage: isAudioSyncUsingOriginalTiming ? "checkmark.circle" : "arrow.uturn.backward"
                            )
                        }
                        .menuActionDismissBehavior(.disabled)
                    }
                } else {
                    Button {
                        onToggleAudioSync()
                    } label: {
                        Label(
                            L10n.string(
                                isAudioSyncRunningForSelectedSubtitle ? "player_autosync_audio_stop" : "player_autosync_audio",
                                fallback: isAudioSyncRunningForSelectedSubtitle ? "Stop Listening" : "Sync by Audio"
                            ),
                            systemImage: isAudioSyncRunningForSelectedSubtitle ? "stop.circle" : "waveform"
                        )
                    }
                    .disabled(!canToggleAudioSync)
                }

                Menu {
                    ForEach(stylePresets.filter(\.isBuiltIn)) { preset in
                        Button {
                            onSelectPreset(preset)
                        } label: {
                            subtitleMenuItem(
                                title: preset.name,
                                isSelected: activeStylePresetID == preset.id
                            )
                        }
                    }

                    let customPresets = stylePresets.filter { !$0.isBuiltIn }
                    if !customPresets.isEmpty {
                        Section(L10n.string("subtitle_style_presets_custom", fallback: "Custom Styles")) {
                            ForEach(customPresets) { preset in
                                Button {
                                    onSelectPreset(preset)
                                } label: {
                                    subtitleMenuItem(
                                        title: preset.name,
                                        isSelected: activeStylePresetID == preset.id
                                    )
                                }
                            }
                        }
                    }

                    Section {
                        Button {
                            onSaveCurrentAsPreset()
                        } label: {
                            Label(
                                L10n.string("subtitle_style_save_preset", fallback: "Save Current Style as Preset"),
                                systemImage: "plus.circle"
                            )
                        }

                        if !customPresets.isEmpty {
                            Menu(L10n.string("subtitle_style_rename_preset", fallback: "Rename Custom Style")) {
                                ForEach(customPresets) { preset in
                                    Button {
                                        onRenameCustomPreset(preset)
                                    } label: {
                                        Text(preset.name)
                                    }
                                }
                            }

                            Menu(L10n.string("subtitle_style_delete_preset", fallback: "Delete Custom Style")) {
                                ForEach(customPresets) { preset in
                                    Button(role: .destructive) {
                                        onDeleteCustomPreset(preset)
                                    } label: {
                                        Text(preset.name)
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    HStack {
                        Label(
                            L10n.string("subtitle_style_title", fallback: "Subtitle Style"),
                            systemImage: "textformat"
                        )
                        Spacer()
                        Text(activeStylePresetTitle)
                    }
                }

                Divider()

                if let none = noneOption {
                    Button {
                        onSelect(none)
                    } label: {
                        subtitleMenuItem(
                            title: L10n.string("action_none", fallback: "None"),
                            isSelected: none.isSelected
                        )
                    }
                }

                ForEach(languageGroups) { group in
                    Menu {
                        if !group.builtInOptions.isEmpty {
                            Section(L10n.string("tvos_settings_option_built_in", fallback: "Built-In")) {
                                ForEach(group.builtInOptions) { option in
                                    let labels = SubtitleMenuFormatter.builtInMenuLabels(option: option)
                                    Button {
                                        onSelect(option)
                                    } label: {
                                        subtitleMenuItem(
                                            title: labels.title,
                                            subtitle: labels.subtitle,
                                            isSelected: option.isSelected
                                        )
                                    }
                                }
                            }
                        }

                        if !group.externalOptions.isEmpty {
                            Section(L10n.string("player_external_subtitles", fallback: "External Subtitles")) {
                                ForEach(group.externalOptions) { option in
                                    let labels = SubtitleMenuFormatter.groupedExternalMenuLabels(option: option)
                                    Button {
                                        onSelect(option)
                                    } label: {
                                        subtitleMenuItem(
                                            title: labels.title,
                                            subtitle: labels.subtitle,
                                            isSelected: option.isSelected
                                        )
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack {
                            if let selected = group.selectedOption {
                                let selectedTitle = SubtitleMenuFormatter.optionDisplayTitle(for: selected)
                                if !selectedTitle.isEmpty && selectedTitle.caseInsensitiveCompare(group.language) != .orderedSame {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(group.language)
                                        Text(selectedTitle)
                                    }
                                } else {
                                    Text(group.language)
                                }
                            } else {
                                Text(group.language)
                            }
                            Spacer()
                            if group.hasSelected {
                                Image(systemName: "checkmark")
                            }
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
                .frame(width: 70, height: 70)
                .clipShape(Circle())
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .focusEffectDisabledIfAvailable()
        .scaleEffect(isFocused ? 1.06 : 1.0)
        .animation(.easeOut(duration: 0.14), value: isFocused)
        .id("subtitles_button")
    }

    @ViewBuilder
    private func subtitleMenuItem(
        title: String,
        subtitle: String? = nil,
        isSelected: Bool
    ) -> some View {
        Text(title)
        if let subtitle, !subtitle.isEmpty {
            Text(subtitle)
        }
        if isSelected {
            Image(systemName: "checkmark")
        }
    }
}

private struct PlayerAudioMenuButton: View, Equatable {
    let orderedTracks: [AudioTrack]
    let supportsAudioProcessing: Bool
    let enhanceDialogueMode: EnhanceDialogueMode
    let isReduceLoudSoundsActive: Bool
    let isFocused: Bool
    let onSelectTrack: (AudioTrack) -> Void
    let onSetEnhanceDialogueMode: (EnhanceDialogueMode) -> Void
    let onToggleReduceLoudSounds: () -> Void

    static func == (lhs: PlayerAudioMenuButton, rhs: PlayerAudioMenuButton) -> Bool {
        lhs.isFocused == rhs.isFocused
            && lhs.supportsAudioProcessing == rhs.supportsAudioProcessing
            && lhs.enhanceDialogueMode == rhs.enhanceDialogueMode
            && lhs.isReduceLoudSoundsActive == rhs.isReduceLoudSoundsActive
            && lhs.orderedTracks == rhs.orderedTracks
    }

    var body: some View {
        Menu {
            if supportsAudioProcessing {
                Section(L10n.string("player_audio_adjustments", fallback: "Audio Adjustments")) {
                    Menu {
                        ForEach(EnhanceDialogueMode.allCases) { mode in
                            Button {
                                onSetEnhanceDialogueMode(mode)
                            } label: {
                                audioMenuItem(
                                    title: mode.title,
                                    isSelected: enhanceDialogueMode == mode
                                )
                            }
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.string("player_enhance_dialogue", fallback: "Enhance Dialogue"))
                            Text(enhanceDialogueMode.title)
                        }
                    }

                    Button {
                        onToggleReduceLoudSounds()
                    } label: {
                        audioMenuItem(
                            title: L10n.string("player_reduce_loud_sounds", fallback: "Reduce Loud Sounds"),
                            isSelected: isReduceLoudSoundsActive
                        )
                    }
                }
            }

            if !orderedTracks.isEmpty {
                Section(L10n.string("player_audio_tracks", fallback: "Audio Tracks")) {
                    ForEach(orderedTracks) { track in
                        Button {
                            onSelectTrack(track)
                        } label: {
                            audioMenuItem(
                                title: audioMenuTrackTitle(for: track),
                                isSelected: track.isSelected
                            )
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "waveform")
                .font(.system(size: 28, weight: .semibold))
                .foregroundColor(isFocused ? .black : .white)
                .frame(width: 70, height: 70)
                .modifier(PlayerGlassCircleButtonBackground(filled: isFocused))
                .frame(width: 70, height: 70)
                .clipShape(Circle())
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .focusEffectDisabledIfAvailable()
        .scaleEffect(isFocused ? 1.06 : 1.0)
        .animation(.easeOut(duration: 0.14), value: isFocused)
        .id("audio_button")
    }

    private func audioMenuItem(title: String, isSelected: Bool) -> some View {
        HStack {
            Text(title)
            Spacer()
            if isSelected {
                Image(systemName: "checkmark")
            }
        }
    }

    private func audioMenuTrackTitle(for track: AudioTrack) -> String {
        let rawName = track.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawLang = track.language.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawLangName = track.languageName.trimmingCharacters(in: .whitespacesAndNewlines)

        let langIdentifier = !rawLang.isEmpty ? rawLang : rawLangName
        let humanLanguage = SubtitleLanguagePreferences.humanLanguageName(from: langIdentifier)

        // 1. If name is completely empty or just generic "Track 1" / "Track 2"
        let isGenericTrack = rawName.isEmpty || rawName.range(of: #"^Track\s*\d+$"#, options: [.regularExpression, .caseInsensitive]) != nil
        if isGenericTrack {
            if !humanLanguage.isEmpty {
                return humanLanguage
            }
            return rawName.isEmpty ? L10n.format("player_track_format", fallback: "Track %d", track.id) : rawName
        }

        // 2. If name is just the language code (e.g. "eng", "en", "fra", "nob")
        if (!rawLang.isEmpty && rawName.caseInsensitiveCompare(rawLang) == .orderedSame) ||
           (!rawLangName.isEmpty && rawName.caseInsensitiveCompare(rawLangName) == .orderedSame) {
            return !humanLanguage.isEmpty ? humanLanguage : rawName.capitalized
        }

        // 3. If name starts with the language code (e.g. "eng (DTS-HD MA 5.1)", "eng [Original]", "eng - 5.1")
        if !humanLanguage.isEmpty {
            let codeToCheck = !rawLang.isEmpty ? rawLang : rawLangName
            if !codeToCheck.isEmpty {
                let pattern = #"^"# + NSRegularExpression.escapedPattern(for: codeToCheck) + #"\b[\s:_\-]*"#
                if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                    let range = NSRange(rawName.startIndex..<rawName.endIndex, in: rawName)
                    if let match = regex.firstMatch(in: rawName, options: [], range: range) {
                        let startIndex = rawName.index(rawName.startIndex, offsetBy: match.range.length)
                        let suffix = String(rawName[startIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
                        if suffix.isEmpty {
                            return humanLanguage
                        } else if suffix.hasPrefix("(") || suffix.hasPrefix("[") {
                            return "\(humanLanguage) \(suffix)"
                        } else {
                            return "\(humanLanguage) (\(suffix))"
                        }
                    }
                }
            }

            // 4. If name already contains the full language name (e.g. "English (Original)")
            if rawName.localizedCaseInsensitiveContains(humanLanguage) {
                return rawName
            }

            // 5. If name is another descriptor without language (e.g. "Director's Commentary" or "DTS 5.1")
            return "\(humanLanguage) (\(rawName))"
        }

        return rawName
    }
}

private struct PlayerSpeedMenuButton: View, Equatable {
    let currentSpeed: PlaybackSpeed
    let isFocused: Bool
    let onSelectSpeed: (PlaybackSpeed) -> Void

    static func == (lhs: PlayerSpeedMenuButton, rhs: PlayerSpeedMenuButton) -> Bool {
        lhs.isFocused == rhs.isFocused
            && lhs.currentSpeed == rhs.currentSpeed
    }

    var body: some View {
        Menu {
            Section(L10n.string("player_speed_title", fallback: "Playback Speed")) {
                ForEach(PlaybackSpeed.allCases) { speed in
                    Button {
                        onSelectSpeed(speed)
                    } label: {
                        speedMenuItem(
                            title: speedTitle(for: speed),
                            isSelected: currentSpeed == speed
                        )
                    }
                }
            }
        } label: {
            Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                .font(.system(size: 28, weight: .semibold))
                .foregroundColor(isFocused ? .black : .white)
                .frame(width: 70, height: 70)
                .modifier(PlayerGlassCircleButtonBackground(filled: isFocused))
                .frame(width: 70, height: 70)
                .clipShape(Circle())
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .focusEffectDisabledIfAvailable()
        .scaleEffect(isFocused ? 1.06 : 1.0)
        .animation(.easeOut(duration: 0.14), value: isFocused)
        .id("speed_button")
    }

    private func speedMenuItem(title: String, isSelected: Bool) -> some View {
        HStack {
            Text(title)
            Spacer()
            if isSelected {
                Image(systemName: "checkmark")
            }
        }
    }

    private func speedTitle(for speed: PlaybackSpeed) -> String {
        if speed == .normal {
            return "\(speed.label) (\(L10n.string("player_speed_normal", fallback: "Normal")))"
        }
        return speed.label
    }
}

private struct SeekPreviewTimelineCard: View {
    @ObservedObject var clock: PlaybackClock
    let isScrubbing: Bool
    var isHoldingSeek: Bool = false
    let pendingSeekDelta: Double
    let image: CGImage?
    var isStale: Bool = false
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
                SeekPreviewCard(image: image, width: width, naturalSize: naturalSize, isStale: isStale)
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
    /// Chapters of the file: marks on the track and the chapter's name by the time.
    var chapters: [PlaybackChapter] = []
    /// Opening and ending (IntroDB or chapters), colored on the track.
    var skipSegments: [SkipInterval] = []

    private var duration: Double {
        max(clock.duration, 0.001)
    }

    /// The name of the chapter at `seconds`, if the file has chapters.
    private func chapterName(at seconds: Double) -> String? {
        guard let index = PlaybackChapters.index(at: seconds, in: chapters) else { return nil }
        return PlaybackChapters.displayName(chapters[index], index: index)
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
                let trackHeight: CGFloat = 10
                let h: CGFloat = (isTimelineFocused || isSeekingOrScrubbing) ? trackHeight + 2 : trackHeight
                let needleHeight: CGFloat = 22
                let originalProgress = CGFloat(min(max(clock.position / duration, 0), 1))
                let originalX = min(max(w * originalProgress, 0), w)
                let bottomOfTrack = geo.size.height / 2 + h / 2
                let markers = PlaybackChapters.markers(chapters, duration: clock.duration)
                // The opening and the ending, colored unless that is off in Settings → Player.
                let segments = PlaybackChapters.showsSegmentsOnTimeline(in: ProfileSettings.current)
                    ? PlaybackChapters.timelineSegments(skipSegments, duration: clock.duration).map {
                        PlayerTrackSegment(start: $0.start, end: $0.end, color: $0.kind.color)
                    }
                    : []

                ZStack(alignment: .leading) {
                    PlayerProgressTrack(
                        played: Double(progress),
                        buffered: clock.buffered / duration,
                        height: trackHeight,
                        showThumb: false,
                        emphasized: isTimelineFocused || isSeekingOrScrubbing,
                        glassTrack: true,
                        markers: markers,
                        segments: segments
                    )

                    if isScrubbing || isHoldingSeek {
                        // Ghost tick: original paused playback position flush within track
                        if abs(targetX - originalX) > 3 {
                            Rectangle()
                                .fill(Color.white)
                                .frame(width: 2, height: h)
                                .position(x: originalX, y: geo.size.height / 2)
                        }

                        // Active scrub/seek needle: extends upwards toward preview card and is flush at bottom of track
                        Rectangle()
                            .fill(Color.white)
                            .frame(width: 2, height: needleHeight)
                            .position(x: targetX, y: bottomOfTrack - needleHeight / 2)
                    }
                }
            }
            .frame(height: 16)

            // Timestamps: when seeking or scrubbing, center the time and direction/speed directly beneath the needle
            if isSeekingOrScrubbing {
                GeometryReader { geo in
                    let w = geo.size.width
                    let targetChapter = chapterName(at: targetPosition)
                    let timeText = PlayerTime.formatted(time: targetPosition)
                    let chapterText = targetChapter.map { "· " + $0 }
                    let timeWidth = CGFloat(timeText.count) * 13
                    let chapterWidth = chapterText.map { min(CGFloat($0.count) * 12, 320) } ?? 0
                    let seekAccessoryWidth: CGFloat = (isHoldingSeek || speedMultiplier != nil)
                        ? 34 + (speedMultiplier.map { CGFloat(String($0).count) * 14 + 8 } ?? 0)
                        : (pendingSeekDelta != 0 ? 28 : 0)
                    let labelWidth = timeWidth
                        + (chapterWidth > 0 ? chapterWidth + 8 : 0)
                        + seekAccessoryWidth
                    let edgeInset = labelWidth / 2 + 8
                    let targetX = min(max(w * progress, edgeInset), max(edgeInset, w - edgeInset))
                    HStack(spacing: 8) {
                        Text(timeText)
                            .font(.system(size: 22, weight: .bold).monospacedDigit())
                            .foregroundColor(.white)
                        if let chapterText {
                            Text(chapterText)
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundColor(.white.opacity(0.85))
                                .lineLimit(1)
                                .frame(maxWidth: 320)
                                .fixedSize(horizontal: true, vertical: false)
                        }

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
                    .position(x: targetX, y: 14)
                }
                .frame(height: 28)
            } else {
                GeometryReader { geo in
                    // The chapter's name rides with the elapsed time (shortened to stay on the bar).
                    let chapter = chapterName(at: targetPosition).map { name in
                        name.count > 32 ? String(name.prefix(31)) + "…" : name
                    }
                    let elapsed = PlayerTime.formatted(time: targetPosition) + (chapter.map { " · " + $0 } ?? "")
                    let remaining = "-" + PlayerTime.formatted(time: max(0, duration - targetPosition))
                    let elapsedHalfWidth = CGFloat(elapsed.count) * 6.5
                    let remainingWidth = CGFloat(remaining.count) * 13
                    let elapsedX = min(
                        max(geo.size.width * progress, elapsedHalfWidth),
                        max(elapsedHalfWidth, geo.size.width - elapsedHalfWidth - remainingWidth - 12)
                    )

                    ZStack {
                        HStack {
                            Spacer(minLength: 0)
                            Text(remaining)
                                .fixedSize()
                        }
                        Text(elapsed)
                            .fixedSize()
                            .position(x: elapsedX, y: 14)
                    }
                    .frame(width: geo.size.width, height: 28)
                }
                .frame(height: 28)
                .font(.system(size: 22, weight: .bold).monospacedDigit())
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

/// Translucent "liquid glass" fill used by interactive cards (matching DetailsScreen).
struct TvCardGlassBackground<S: InsettableShape>: ViewModifier {
    let isFocused: Bool
    let shape: S

    @ViewBuilder
    func body(content: Content) -> some View {
        if isFocused {
            content
                .background(Color.white.opacity(0.28), in: shape)
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(Color.white, lineWidth: 2.5))
        } else {
            if #available(tvOS 26.0, *) {
                content
                    .background(Color.black.opacity(0.25), in: shape)
                    .background(Color.white.opacity(0.08), in: shape)
                    .glassEffect(.regular, in: shape)
                    .overlay(shape.stroke(Color.white.opacity(0.18), lineWidth: 1))
            } else {
                content
                    .background(.ultraThinMaterial, in: shape)
                    .background(Color.black.opacity(0.30), in: shape)
                    .overlay(shape.stroke(Color.white.opacity(0.18), lineWidth: 1))
            }
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
    @AppStorage(SettingsKey.blurUnwatchedEpisodes) private var blurUnwatchedEpisodes = false
    @AppStorage(SettingsKey.hideUnwatchedEpisodeTitles) private var hideUnwatchedEpisodeTitles = false

    private var overlayCornerRadius: CGFloat {
        max(14, AppCardStyle.episodeCornerRadius(for: cardCornerRadiusSetting))
    }

    private var thumbCornerRadius: CGFloat {
        max(6, AppCardStyle.cornerRadius(for: cardCornerRadiusSetting, fallback: 16) * 0.75)
    }

    private var episodeLine: String {
        if hideUnwatchedEpisodeTitles {
            return "S\(episode.season) E\(episode.episode)"
        }
        return "S\(episode.season) E\(episode.episode) • \(episode.title)"
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
        .scaleEffect(blurUnwatchedEpisodes ? 1.08 : 1.0)
        .blur(radius: blurUnwatchedEpisodes ? 14 : 0)
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
    var targetsPostCredits: Bool = false

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
                Text(interval.label(targetsPostCredits: targetsPostCredits))
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

struct PlayerGlassCircleButtonBackground: ViewModifier {
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

struct PlayerBottomFade: View {
    var body: some View {
        LinearGradient(
            stops: [
                .init(color: .black.opacity(0.48), location: 0),
                .init(color: .black.opacity(0.36), location: 0.36),
                .init(color: .clear, location: 0.5),
                .init(color: .clear, location: 1)
            ],
            startPoint: .bottom,
            endPoint: .top
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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
struct SubtitlePanelOption: Identifiable, Equatable {
    enum Kind: Equatable {
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

struct SubtitleLanguageGroup: Identifiable, Equatable {
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
    var selectedOption: SubtitlePanelOption? {
        options.first(where: \.isSelected)
    }
}

/// Maps raw track/addon language values ("en", "eng", "English") onto one
/// display name so both kinds group into a single Languages entry.
enum SubtitleLanguageDisplay {
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

enum SubtitleMenuFormatter {
    static func sanitizeSubtitleLabel(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if raw.hasPrefix("v3_") || raw.hasPrefix("sub_") || raw.hasPrefix("sub-") || raw.contains("AfAB") {
            return nil
        }
        if UUID(uuidString: raw) != nil {
            return nil
        }
        if raw.range(of: #"^[0-9a-fA-F]{24,}$"#, options: .regularExpression) != nil {
            return nil
        }
        if raw.range(of: #"^\d{5,}$"#, options: .regularExpression) != nil {
            return nil
        }
        let stripped = raw.replacingOccurrences(
            of: #"\b\d{5,}\b|[_\-]\d{5,}"#,
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: CharacterSet(charactersIn: " -_()[]"))
        return stripped.isEmpty ? nil : stripped
    }

    static func builtInMenuLabels(option: SubtitlePanelOption) -> (title: String, subtitle: String?) {
        let title = option.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanLabel = sanitizeSubtitleLabel(option.detail)
        let displayTitle = title.isEmpty ? option.language : title
        if let cleanLabel,
           cleanLabel.caseInsensitiveCompare(displayTitle) != .orderedSame,
           cleanLabel.caseInsensitiveCompare(option.language) != .orderedSame {
            return (title: displayTitle, subtitle: cleanLabel)
        }
        return (title: displayTitle, subtitle: nil)
    }

    static func groupedExternalMenuLabels(option: SubtitlePanelOption) -> (title: String, subtitle: String?) {
        let addon = option.badge.isEmpty ? "External" : option.badge
        let cleanLabel = sanitizeSubtitleLabel(option.detail)

        if let cleanLabel, cleanLabel.caseInsensitiveCompare(option.language) != .orderedSame {
            if cleanLabel.caseInsensitiveCompare(addon) == .orderedSame
                || addon.localizedCaseInsensitiveContains(cleanLabel)
                || cleanLabel.localizedCaseInsensitiveContains(addon) {
                return (title: addon, subtitle: nil)
            }
            return (title: cleanLabel, subtitle: addon)
        }

        let title = option.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty,
           title.caseInsensitiveCompare(option.language) != .orderedSame {
            if title.caseInsensitiveCompare(addon) == .orderedSame
                || addon.localizedCaseInsensitiveContains(title)
                || title.localizedCaseInsensitiveContains(addon) {
                return (title: addon, subtitle: nil)
            }
            return (title: title, subtitle: addon)
        }

        return (title: addon, subtitle: nil)
    }

    static func optionDisplayTitle(for option: SubtitlePanelOption) -> String {
        switch option.kind {
        case .track(let track):
            if track.externalFilename.isEmpty {
                let labels = builtInMenuLabels(option: option)
                if let subtitle = labels.subtitle {
                    return "\(labels.title) (\(subtitle))"
                }
                return labels.title
            } else {
                let labels = groupedExternalMenuLabels(option: option)
                return labels.title
            }
        case .external:
            let labels = groupedExternalMenuLabels(option: option)
            return labels.title
        }
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
        let label = subtitle.label.flatMap { label in
            label.caseInsensitiveCompare(language) == .orderedSame ? nil : label
        }
        let notes = [label, viewModel.subtitleAutoSyncNote(for: subtitle.url)].compactMap { $0 }
        let detail = notes.isEmpty ? nil : notes.joined(separator: " · ")
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
    let didReportPlaybackStarted: Bool
    var onClose: () -> Void

    private enum Tab: String, CaseIterable, Hashable {
        case titles = "Titles"
        case subtitles = "Subtitles"
        case audio = "Audio"
        case speed = "Speed"
        case picture = "Picture"
        case gestures = "Gestures"
    }

    private enum StyleControl: Hashable {
        case preset
        case savePreset
        case updatePreset
        case renamePreset
        case deletePreset
        case delayMinus, delayPlus
        case autoSync
        case aiTranslation
        case font
        case sizeMinus, sizePlus
        case heightMinus, heightPlus
        case bold
        case position
        case color(String)
        case opacityMinus, opacityPlus
        case outline
        case outlineWidthMinus, outlineWidthPlus
        case background
        case backgroundColor(String)
        case backgroundOpacityMinus, backgroundOpacityPlus
    }

    private enum AudioControl: Hashable {
        case delayMinus, delayPlus
        case ampMinus, ampPlus
        case persist
    }

    private enum Focus: Hashable {
        case tab(Tab)
        case discTitle(Int)
        case noneRow
        case language(String)
        case option(String)
        case audio(String)
        case audioControl(AudioControl)
        case speed(Float)
        case seekStep(Int)
        case seekPreview
        case loadingStatus
        case debugOverlay
        case aspect(String)
        case style(StyleControl)
        /// A font in the Font list: a built-in option's name, or "custom:" and an added family.
        case fontChoice(String)
        case gesturesSwitch
        case gestureReset
        case gestureAction(String)
        case gestureClear(String)
        case gestureGallery
        case gestureSensitivity(String)
        case gestureNewCustom
        case gestureCustomDelete(String)
        case gestureExpert
    }

    /// Swatches shown in the Text Color row (white, gray, yellow, blue, red, green).
    private static let palette = ["#FFFFFF", "#C7C7C7", "#F2C94C", "#56CCF2", "#EB5757", "#6FCF97"]
    private static let backgroundPalette = ["#000000", "#303030", "#FFFFFF", "#1F3A5F", "#5A1F2B", "#214D35"]

    @State private var tab: Tab = .subtitles
    /// Gestures tab: the bindings, the action being recorded, and what the last change did.
    @State private var gestureBindings = PlayerGestureSettings.bindings()
    @State private var recordingGestureAction: PlayerGestureAction?
    @State private var gestureNote: String?
    @State private var isShowingGestureGallery = false
    @State private var isMakingCustomGesture = false
    @State private var gestureSensitivity = PlayerGestureSettings.sensitivity()
    @State private var selectedLanguage: String?
    @State private var style = SubtitleStyle.current
    @State private var isNamingPreset = false
    @State private var presetNameToSave = ""
    @State private var renamingPresetID: String?
    /// The style column shows the list of fonts instead (Font pressed); Back returns.
    @State private var isPickingFont = false
    @ObservedObject private var fontLibrary = SubtitleFontLibrary.shared
    @FocusState private var focus: Focus?

    private var visibleTabs: [Tab] {
        var tabs: [Tab] = []
        if !viewModel.discTitles.isEmpty {
            tabs.append(.titles)
        }
        tabs.append(contentsOf: [.subtitles, .audio, .speed, .picture, .gestures])
        return tabs
    }

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
                case .titles: titlesPage
                case .subtitles: subtitlesPage
                case .audio: audioPage
                case .speed: speedPage
                case .picture: picturePage
                case .gestures: gesturesPage
                }
            }
            .padding(.horizontal, 90)
            .padding(.top, 64)
            .padding(.bottom, 44)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // Recording or the overview: nothing behind can take the focus (a swipe moved it there).
            .disabled(recordingGestureAction != nil || isShowingGestureGallery || isMakingCustomGesture || isNamingPreset)

            if isNamingPreset {
                PlayerPresetNameDialog(
                    title: renamingPresetID != nil
                        ? L10n.string("subtitle_style_rename_title", fallback: "Rename Subtitle Preset")
                        : L10n.string("subtitle_style_save_title", fallback: "Save Subtitle Preset"),
                    text: $presetNameToSave,
                    onSave: { customName in
                        isNamingPreset = false
                        if let renamingPresetID {
                            SubtitleStylePresetStore.shared.renameCustomPreset(id: renamingPresetID, newName: customName)
                            self.renamingPresetID = nil
                            viewModel.applySubtitleStyle()
                            viewModel.showPlayerToast(L10n.format("subtitle_style_renamed_toast", fallback: "Renamed preset: %@", customName))
                        } else {
                            let newPreset = SubtitleStylePresetStore.shared.saveCurrentAsPreset(name: customName)
                            viewModel.applySubtitleStyle()
                            viewModel.showPlayerToast(L10n.format("subtitle_style_saved_toast", fallback: "Saved preset: %@", newPreset.name))
                        }
                    },
                    onCancel: {
                        isNamingPreset = false
                        renamingPresetID = nil
                    }
                )
                .transition(.opacity)
            }

            if let action = recordingGestureAction {
                PlayerGestureRecorderView(
                    action: action,
                    bindings: gestureBindings,
                    tuning: gestureSensitivity.tuning,
                    setPadObserver: { observer in
                        viewModel.gesturePadObservers["recorder"] = observer
                    },
                    onSave: { gesture in finishRecording(gesture, for: action) },
                    onCancel: { endRecording(action) },
                    customShapes: viewModel.customGestureShapes
                )
            }

            if isMakingCustomGesture {
                PlayerCustomGestureMakerView(
                    existing: viewModel.customGestureShapes,
                    tuning: gestureSensitivity.tuning,
                    setPadObserver: { observer in
                        viewModel.gesturePadObservers["recorder"] = observer
                    },
                    onSave: { shape in
                        viewModel.setCustomGestureShapes(viewModel.customGestureShapes + [shape])
                        isMakingCustomGesture = false
                        gestureNote = "\(shape.name) saved: pick an action on the right and draw it"
                        DispatchQueue.main.async {
                            focus = .gestureAction(PlayerGestureAction.allCases[0].rawValue)
                        }
                    },
                    onCancel: {
                        isMakingCustomGesture = false
                        DispatchQueue.main.async { focus = .gestureNewCustom }
                    }
                )
            }

            if isShowingGestureGallery {
                PlayerGestureGalleryView(bindings: viewModel.isGestureExpert ? gestureBindings : .defaults) {
                    isShowingGestureGallery = false
                    DispatchQueue.main.async { focus = .gestureGallery }
                }
            }
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
        .onChange(of: tab) { _, newTab in
            if newTab == .audio && orderedAudioTracks.isEmpty {
                focus = .audioControl(.delayMinus)
            } else if newTab == .titles, let first = viewModel.discTitles.first {
                focus = .discTitle(viewModel.selectedDiscTitleId ?? first.id)
            } else if newTab == .gestures {
                gestureBindings = PlayerGestureSettings.bindings()
                gestureSensitivity = PlayerGestureSettings.sensitivity()
            }
        }
        .focusSection()
        .onExitCommand {
            if isNamingPreset {
                isNamingPreset = false
                renamingPresetID = nil
            } else if isPickingFont {
                closeFontPicker()
            } else {
                onClose()
            }
        }
    }

    // MARK: Tabs

    private var tabBar: some View {
        HStack(spacing: 22) {
            ForEach(visibleTabs, id: \.self) { item in
                let isFocused = focus == .tab(item)
                let isSelected = tab == item
                Button {
                    tab = item
                    if item == .audio && orderedAudioTracks.isEmpty {
                        focus = .audioControl(.delayMinus)
                    } else if item == .titles, let first = viewModel.discTitles.first {
                        focus = .discTitle(viewModel.selectedDiscTitleId ?? first.id)
                    }
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

    // MARK: Disc Titles page

    private var titlesPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            columnHeader("Disc Titles")
            if viewModel.discTitles.isEmpty {
                Text("No disc titles available")
                    .font(.system(size: 23, weight: .medium))
                    .foregroundColor(.white.opacity(0.45))
                    .padding(.top, 10)
                Spacer(minLength: 0)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 14) {
                        ForEach(viewModel.discTitles) { title in
                            discTitleCard(title)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .focusSection()
            }
        }
        .frame(width: 840, alignment: .leading)
    }

    private func discTitleCard(_ title: PlaybackDiscTitleInfo) -> some View {
        let isFocused = focus == .discTitle(title.id)
        let isSelected = viewModel.selectedDiscTitleId == title.id
        let durationFormatted = formatTitleDuration(title.durationSeconds)
        let chapterText = title.chapterCount > 0 ? "\(title.chapterCount) chapters" : ""
        let detail = [durationFormatted, chapterText].filter { !$0.isEmpty }.joined(separator: " • ")

        return Button {
            viewModel.selectDiscTitle(title.id)
        } label: {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title.name)
                        .font(.system(size: 27, weight: .semibold))
                        .foregroundColor(isFocused ? .black : .white)
                        .lineLimit(1)
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 20, weight: .medium))
                            .foregroundColor(isFocused ? .black.opacity(0.58) : .white.opacity(0.6))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if isSelected {
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
        .focused($focus, equals: .discTitle(title.id))
        .focusEffectDisabledIfAvailable()
    }

    private func formatTitleDuration(_ seconds: Double) -> String {
        guard seconds > 0, seconds.isFinite else { return "" }
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%d:%02d", minutes, secs)
        }
    }

    // MARK: Subtitles page

    private var subtitlesPage: some View {
        HStack(alignment: .top, spacing: 56) {
            languagesColumn
            subtitlesColumn
            if isPickingFont {
                fontPickerColumn
            } else {
                styleColumn
            }
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
        .frame(width: 360, alignment: .leading)
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
                .scrollClipDisabledIfAvailable()
            }
        }
        .frame(width: 580, alignment: .leading)
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
            HStack(alignment: .center, spacing: 14) {
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
                        .multilineTextAlignment(.leading)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail = option.detail {
                        Text(detail)
                            .font(.system(size: 20, weight: .medium))
                            .foregroundColor(isFocused ? .black.opacity(0.52) : .white.opacity(0.5))
                            .multilineTextAlignment(.leading)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

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

    /// The Auto Sync row's value: the correction (press for the original timing and back), or
    /// what kept the subtitle as it is (press to try again).
    private func autoSyncValue(_ state: SubtitleAutoSyncState, usingOriginal: Bool) -> String {
        switch state {
        case .checking:
            return L10n.string("player_subtitle_autosync_checking", fallback: "Checking…")
        case .synced(let result):
            return usingOriginal
                ? L10n.string("player_subtitle_autosync_original", fallback: "Original timing")
                : result.shortLabel
        case .kept(.inSync):
            return L10n.string("player_subtitle_autosync_in_sync_short", fallback: "In sync")
        case .kept:
            return L10n.string("player_subtitle_autosync_not_synced", fallback: "Not synced")
        }
    }

    private var styleColumn: some View {
        VStack(alignment: .leading, spacing: 18) {
            columnHeader(L10n.string("subtitle_style_title", fallback: "Subtitle Style"))
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 30) {
                    cycleRow(
                        title: L10n.string("subtitle_style_preset", fallback: "Preset Style"),
                        value: SubtitleStylePresetStore.shared.activePresetTitle(for: style),
                        focusKey: .preset
                    ) {
                        let presets = SubtitleStylePresetStore.shared.allPresets()
                        let currentID = SubtitleStylePresetStore.shared.activePreset(for: style)?.id
                        let currentIndex = presets.firstIndex(where: { $0.id == currentID }) ?? -1
                        let nextIndex = (currentIndex + 1) % presets.count
                        let nextPreset = presets[nextIndex]
                        SubtitleStylePresetStore.shared.applyPreset(nextPreset)
                        style = nextPreset.style
                        viewModel.applySubtitleStyle()
                    }

                    if let activePreset = SubtitleStylePresetStore.shared.activePreset(for: style), !activePreset.isBuiltIn {
                        if !activePreset.style.matches(style) {
                            cycleRow(
                                title: L10n.format("subtitle_style_update_preset", fallback: "Update '%@'", activePreset.name),
                                value: L10n.string("common_update", fallback: "Update Style"),
                                focusKey: .updatePreset
                            ) {
                                SubtitleStylePresetStore.shared.updateCustomPresetStyle(id: activePreset.id, style: style)
                                viewModel.applySubtitleStyle()
                                viewModel.showPlayerToast(L10n.format("subtitle_style_updated_toast", fallback: "Updated preset: %@", activePreset.name))
                            }
                        }

                        cycleRow(
                            title: L10n.string("subtitle_style_rename_preset", fallback: "Rename Style"),
                            value: activePreset.name,
                            focusKey: .renamePreset
                        ) {
                            presetNameToSave = activePreset.name
                            renamingPresetID = activePreset.id
                            isNamingPreset = true
                        }

                        cycleRow(
                            title: L10n.string("subtitle_style_delete_preset", fallback: "Delete Style"),
                            value: L10n.string("common_delete", fallback: "Delete"),
                            focusKey: .deletePreset
                        ) {
                            SubtitleStylePresetStore.shared.deleteCustomPreset(id: activePreset.id)
                            viewModel.applySubtitleStyle()
                            viewModel.showPlayerToast(L10n.format("subtitle_style_deleted_toast", fallback: "Deleted preset: %@", activePreset.name))
                        }

                        cycleRow(
                            title: L10n.string("subtitle_style_save_preset", fallback: "Save New"),
                            value: L10n.string("common_create", fallback: "Save as New"),
                            focusKey: .savePreset
                        ) {
                            presetNameToSave = SubtitleStylePresetStore.shared.suggestedCustomPresetName()
                            renamingPresetID = nil
                            isNamingPreset = true
                        }
                    } else if SubtitleStylePresetStore.shared.activePreset(for: style) == nil {
                        cycleRow(
                            title: L10n.string("subtitle_style_save_preset", fallback: "Save Style"),
                            value: L10n.string("common_save", fallback: "Save as Preset"),
                            focusKey: .savePreset
                        ) {
                            presetNameToSave = SubtitleStylePresetStore.shared.suggestedCustomPresetName()
                            renamingPresetID = nil
                            isNamingPreset = true
                        }
                    }

                    stepperRow(
                        title: L10n.string("subtitle_tab_delay", fallback: "Delay"),
                        value: "\(viewModel.subtitleDelayMs)ms",
                        minusKey: .delayMinus,
                        plusKey: .delayPlus,
                        onMinus: { viewModel.setSubtitleDelayMs(viewModel.subtitleDelayMs - 50) },
                        onPlus: { viewModel.setSubtitleDelayMs(viewModel.subtitleDelayMs + 50) }
                    )

                    if let subtitle = viewModel.activeAddonSubtitle,
                       let state = viewModel.subtitleAutoSyncStates[subtitle.url] {
                        cycleRow(
                            title: L10n.string("player_subtitle_autosync", fallback: "AutoSubSync"),
                            value: autoSyncValue(state, usingOriginal: viewModel.isSubtitleAutoSyncUsingOriginal(subtitle.url)),
                            focusKey: .autoSync
                        ) {
                            if case .synced = state {
                                viewModel.toggleSubtitleAutoSyncTiming()
                            } else {
                                viewModel.runSubtitleAutoSyncNow()
                            }
                        }
                    }

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
                        onMinus: { updateStyle { $0.textSize = max($0.textSize - 5, 5) } },
                        onPlus: { updateStyle { $0.textSize = min($0.textSize + 5, 220) } }
                    )

                    stepperRow(
                        title: L10n.string("tvos_settings_vertical_position", fallback: "Vertical Position"),
                        value: "\(style.bottomOffset)",
                        minusKey: .heightMinus,
                        plusKey: .heightPlus,
                        onMinus: {
                            updateStyle {
                                $0.bottomOffset = max($0.bottomOffset - 4, SubtitleStyleDefaults.bottomOffsetRange.lowerBound)
                            }
                        },
                        onPlus: {
                            updateStyle {
                                $0.bottomOffset = min($0.bottomOffset + 4, SubtitleStyleDefaults.bottomOffsetRange.upperBound)
                            }
                        }
                    )

                    cycleRow(
                        title: L10n.string("subtitle_font", fallback: "Font"),
                        value: style.fontName,
                        focusKey: .font
                    ) {
                        isPickingFont = true
                    }

                    toggleRow(title: L10n.string("subtitle_style_bold", fallback: "Bold"), isOn: style.bold, focusKey: .bold) {
                        updateStyle { $0.bold.toggle() }
                    }

                    toggleRow(
                        title: L10n.string("subtitle_position", fallback: "Position"),
                        isOn: style.verticalAlignment.caseInsensitiveCompare("Top") == .orderedSame,
                        onLabel: L10n.string("subtitle_position_top", fallback: "Top"),
                        offLabel: L10n.string("subtitle_position_bottom", fallback: "Bottom"),
                        focusKey: .position
                    ) {
                        updateStyle {
                            $0.verticalAlignment = ($0.verticalAlignment.caseInsensitiveCompare("Top") == .orderedSame) ? "Bottom" : "Top"
                        }
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

                    stepperRow(
                        title: L10n.string("subtitle_outline_width", fallback: "Outline Thickness"),
                        value: "\(style.outlineWidth)pt",
                        minusKey: .outlineWidthMinus,
                        plusKey: .outlineWidthPlus,
                        onMinus: { updateStyle { $0.outlineWidth = max($0.outlineWidth - 1, 1) } },
                        onPlus: { updateStyle { $0.outlineWidth = min($0.outlineWidth + 1, 6) } }
                    )
                    .opacity(style.outlineEnabled ? 1 : 0.46)
                    .disabled(!style.outlineEnabled)

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
        style.applyToDefaults(defaults)
        viewModel.applySubtitleStyle()
    }

    // MARK: Font list

    /// Every font for subtitles: the built-in ones, then the ones added in Settings → Subtitles →
    /// Custom Fonts, marked as uploaded. Each name is written in its own font.
    private var fontPickerColumn: some View {
        VStack(alignment: .leading, spacing: 18) {
            columnHeader(L10n.string("subtitle_font", fallback: "Font"))
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(SubtitleFontOption.allCases) { option in
                        fontChoiceRow(name: option.rawValue, title: option.displayName, isUploaded: false)
                    }

                    if !fontLibrary.familyNames.isEmpty {
                        styleLabel(L10n.string("subtitle_custom_fonts_yours", fallback: "Your Fonts"))
                            .padding(.top, 16)
                        ForEach(fontLibrary.familyNames, id: \.self) { family in
                            fontChoiceRow(name: family, title: family, isUploaded: true)
                        }
                    }
                }
                .padding(.vertical, 6)
                .padding(.bottom, 26)
            }
            .focusSection()
            .scrollClipDisabledIfAvailable()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            DispatchQueue.main.async { focus = .fontChoice(currentFontChoiceKey) }
        }
    }

    /// The list key of the chosen font: an added family when it isn't a built-in name.
    private var currentFontChoiceKey: String {
        let builtIn = SubtitleFontOption.allCases.map(\.rawValue)
        if builtIn.contains(style.fontName) { return style.fontName }
        if fontLibrary.familyNames.contains(style.fontName) { return "custom:" + style.fontName }
        return SubtitleFontOption.system.rawValue
    }

    private func fontChoiceRow(name: String, title: String, isUploaded: Bool) -> some View {
        let key = isUploaded ? "custom:" + name : name
        let isFocused = focus == .fontChoice(key)
        let isSelected = currentFontChoiceKey == key
        return Button {
            updateStyle { $0.fontName = name }
            closeFontPicker()
        } label: {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(title)
                        .font(SubtitleStyle(fontName: name).font(size: 28, weight: .semibold))
                        .foregroundColor(isFocused ? .black : .white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    if isUploaded {
                        Text(L10n.string("player_subtitle_font_uploaded", fallback: "Uploaded"))
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(isFocused ? .black.opacity(0.66) : .white.opacity(0.72))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                            .background(
                                Capsule().fill(isFocused ? Color.black.opacity(0.10) : Color.white.opacity(0.14))
                            )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 27, weight: .bold))
                        .foregroundColor(isFocused ? .black : .white)
                }
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(isFocused ? Color.white : Color.white.opacity(0.07))
            )
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($focus, equals: .fontChoice(key))
        .focusEffectDisabledIfAvailable()
    }

    private func closeFontPicker() {
        isPickingFont = false
        DispatchQueue.main.async { focus = .style(.font) }
    }

    private func cycleRow(title: String, value: String, focusKey: StyleControl, action: @escaping () -> Void) -> some View {
        let isFocused = focus == .style(focusKey)
        return VStack(alignment: .leading, spacing: 14) {
            styleLabel(title)
            Button(action: action) {
                HStack(spacing: 8) {
                    Text(value)
                        .font(.system(size: 20, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 15, weight: .bold))
                }
                .foregroundColor(isFocused ? .black : .white)
                .padding(.horizontal, 20)
                .frame(minWidth: 140)
                .frame(height: 52)
                .background(
                    Capsule().fill(isFocused ? Color.white : Color.white.opacity(0.10))
                )
            }
            .buttonStyle(PosterCardButtonStyle())
            .focused($focus, equals: .style(focusKey))
            .focusEffectDisabledIfAvailable()
        }
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

    private func toggleRow(
        title: String,
        isOn: Bool,
        onLabel: String = L10n.string("subtitle_style_on", fallback: "On"),
        offLabel: String = L10n.string("subtitle_style_off", fallback: "Off"),
        focusKey: StyleControl,
        action: @escaping () -> Void
    ) -> some View {
        let isFocused = focus == .style(focusKey)
        return VStack(alignment: .leading, spacing: 14) {
            styleLabel(title)
            Button(action: action) {
                Text(isOn ? onLabel : offLabel)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(isFocused ? .black : .white)
                    .frame(minWidth: 112)
                    .frame(height: 52)
                    .padding(.horizontal, 16)
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
            columnHeader(L10n.string("player_audio_tracks", fallback: "Audio Tracks"))
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
        let preferred = SubtitleLanguagePreferences.preferredAudioLanguage(meta: viewModel.activeMeta)
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
        return VStack(alignment: .leading, spacing: 18) {
            columnHeader(L10n.string("player_audio_adjustments", fallback: "Audio Adjustments"))
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 28) {
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

                    toggleRow(
                        title: L10n.string("player_persist_between_sessions", fallback: "Persist between sessions"),
                        isOn: viewModel.isAudioDelayPersistEnabled,
                        focusKey: .audioControl(.persist)
                    ) {
                        viewModel.setAudioDelayPersistEnabled(!viewModel.isAudioDelayPersistEnabled)
                    }

                    audioOutputSection
                }
                .padding(.vertical, 6)
                .padding(.bottom, 26)
            }
            .focusSection()
            .scrollClipDisabledIfAvailable()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                            title: L10n.string("playback_show_loading_status", fallback: "Show loading status"),
                            isOn: viewModel.isShowLoadingStatusEnabled,
                            focusKey: .loadingStatus
                        ) {
                            viewModel.setShowLoadingStatusEnabled(!viewModel.isShowLoadingStatusEnabled)
                        }

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

    // MARK: Gestures

    private var gesturesPage: some View {
        HStack(alignment: .top, spacing: 56) {
            VStack(alignment: .leading, spacing: 18) {
                columnHeader("Remote gestures")
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 12) {
                        toggleRow(
                            title: "Gestures during playback",
                            isOn: viewModel.areGesturesEnabled,
                            focusKey: .gesturesSwitch
                        ) {
                            viewModel.setGesturesEnabled(!viewModel.areGesturesEnabled)
                        }

                        toggleRow(
                            title: "Expert mode",
                            isOn: viewModel.isGestureExpert,
                            focusKey: .gestureExpert
                        ) {
                            gestureNote = nil
                            viewModel.setGestureExpert(!viewModel.isGestureExpert)
                        }

                        simpleRow(title: "Gesture overview", isSelected: false, focusKey: .gestureGallery) {
                            isShowingGestureGallery = true
                        }

                        if viewModel.isGestureExpert {
                            simpleRow(title: "New custom gesture", isSelected: false, focusKey: .gestureNewCustom) {
                                gestureNote = nil
                                isMakingCustomGesture = true
                            }

                            ForEach(viewModel.customGestureShapes) { shape in
                                customShapeRow(shape)
                            }

                            simpleRow(title: "Reset to defaults", isSelected: false, focusKey: .gestureReset) {
                                gestureBindings = .defaults
                                PlayerGestureSettings.save(.defaults)
                                gestureSensitivity = PlayerGestureSensitivity()
                                viewModel.setGestureSensitivity(gestureSensitivity)
                                gestureNote = "The ready-made gestures and the default sensitivity"
                            }
                        }

                        Text(viewModel.isGestureExpert
                             ? "With the controls hidden, a gesture with an action replaces what the player does with it (like click right = seek). With the controls shown or paused, a gesture with an action does it on top of what the controls do. With a double click or tap set, a single one waits to see whether a second one follows."
                             : "Ready-made gestures that keep clear of what the player does itself. Turn on Expert mode to change them, draw your own and tune the sensitivity.")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundColor(.white.opacity(0.5))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 8)

                        if let gestureNote {
                            Text(gestureNote)
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundColor(Color(red: 1.0, green: 0.82, blue: 0.55))
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if viewModel.isGestureExpert {
                            Text("Sensitivity")
                                .font(.system(size: 22, weight: .bold))
                                .foregroundColor(.white.opacity(0.55))
                                .padding(.top, 14)

                            ForEach(PlayerGestureSensitivityKnob.allCases) { knob in
                                gestureSensitivityRow(knob)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
                .focusSection()
            }
            .frame(width: 520, alignment: .leading)

            VStack(alignment: .leading, spacing: 18) {
                if viewModel.isGestureExpert {
                    columnHeader("Actions · press to record a gesture")
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 12) {
                            ForEach(PlayerGestureAction.allCases) { action in
                                gestureActionRow(action)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .focusSection()
                } else {
                    columnHeader("Ready-made gestures")
                    VStack(spacing: 12) {
                        ForEach(PlayerGestureBindings.defaults.bindings, id: \.action) { binding in
                            readyMadeGestureRow(binding)
                        }
                    }
                    .padding(.vertical, 6)
                    Text("The player's own clicks, taps and swipes stay as they are: click or tap a side = ±10 s, hold a side = rewind / fast forward, swipe up = controls, swipe down = InSight.")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: 900, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
    }

    /// A ready-made gesture (Expert mode off): what it does and how it goes; not to be changed.
    private func readyMadeGestureRow(_ binding: PlayerGestureBinding) -> some View {
        HStack(spacing: 16) {
            AnimatedGesturePad(gesture: binding.gesture)
                .frame(width: 44, height: 44 * RemotePadCanvas.aspect)
            Text(binding.action.title)
                .font(.system(size: 25, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(binding.gesture.title)
                .font(.system(size: 21, weight: .bold))
                .foregroundColor(.white.opacity(0.75))
                .lineLimit(1)
        }
        .padding(.leading, 18)
        .padding(.trailing, 26)
        .frame(height: 62)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.07))
        )
    }

    /// A shape of one's own: what it does, and a button that deletes it (and what it did).
    private func customShapeRow(_ shape: CustomGestureShape) -> some View {
        let key = Focus.gestureCustomDelete(shape.id)
        let isFocused = focus == key
        let meaning = PlayerGestureMeaning(of: .custom(shape.id), in: gestureBindings)
        return Button {
            var shapes = viewModel.customGestureShapes
            shapes.removeAll { $0.id == shape.id }
            viewModel.setCustomGestureShapes(shapes)
            gestureBindings.unbind(gesture: .custom(shape.id))
            PlayerGestureSettings.save(gestureBindings)
            gestureNote = "\(shape.name) deleted"
            DispatchQueue.main.async { focus = .gestureNewCustom }
        } label: {
            HStack(spacing: 12) {
                if let drawing = shape.drawings.first {
                    RemotePadCanvas(frame: GestureAnimation.still(drawing))
                        .frame(width: 40, height: 40 * RemotePadCanvas.aspect)
                }
                Text(shape.name)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(isFocused ? .black : .white)
                    .lineLimit(1)
                Text(meaning.title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(isFocused ? .black.opacity(0.6) : .white.opacity(0.5))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 8)
                Image(systemName: "trash")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(isFocused ? .black : .white.opacity(0.6))
            }
            .padding(.horizontal, 22)
            .frame(height: 64)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isFocused ? Color.white : Color.white.opacity(0.07))
            )
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($focus, equals: key)
        .focusEffectDisabledIfAvailable()
    }

    /// A press moves to the next step; it applies at once (and the recorder shows the zones).
    private func gestureSensitivityRow(_ knob: PlayerGestureSensitivityKnob) -> some View {
        let key = Focus.gestureSensitivity(knob.rawValue)
        let isFocused = focus == key
        return Button {
            gestureSensitivity.cycle(knob)
            viewModel.setGestureSensitivity(gestureSensitivity)
        } label: {
            HStack(spacing: 12) {
                Text(knob.title)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(isFocused ? .black : .white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 8)
                Text(knob.steps[gestureSensitivity.step(knob)])
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(isFocused ? .black.opacity(0.75) : .white.opacity(0.7))
                    .lineLimit(1)
            }
            .padding(.horizontal, 22)
            .frame(height: 58)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isFocused ? Color.white : Color.white.opacity(0.07))
            )
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($focus, equals: key)
        .focusEffectDisabledIfAvailable()
    }

    private func gestureActionRow(_ action: PlayerGestureAction) -> some View {
        let isFocused = focus == .gestureAction(action.rawValue)
        let gesture = gestureBindings.gesture(for: action)
        let isClearFocused = focus == .gestureClear(action.rawValue)
        return HStack(spacing: 12) {
            Button {
                gestureNote = nil
                recordingGestureAction = action
            } label: {
                HStack(spacing: 14) {
                    Text(action.title)
                        .font(.system(size: 25, weight: .semibold))
                        .foregroundColor(isFocused ? .black : .white)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(gesture?.title ?? "—")
                        .font(.system(size: 21, weight: .bold))
                        .foregroundColor(isFocused ? .black.opacity(0.8) : .white.opacity(gesture == nil ? 0.35 : 0.75))
                        .lineLimit(1)
                }
                .padding(.horizontal, 26)
                .frame(height: 62)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(isFocused ? Color.white : Color.white.opacity(0.07))
                )
            }
            .buttonStyle(PosterCardButtonStyle())
            .focused($focus, equals: .gestureAction(action.rawValue))
            .focusEffectDisabledIfAvailable()

            Button {
                gestureBindings.unbind(action)
                PlayerGestureSettings.save(gestureBindings)
                gestureNote = "\(action.title): no gesture"
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(isClearFocused ? .black : .white.opacity(gesture == nil ? 0.25 : 0.8))
                    .frame(width: 62, height: 62)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(isClearFocused ? Color.white : Color.white.opacity(0.07))
                    )
            }
            .buttonStyle(PosterCardButtonStyle())
            .focused($focus, equals: .gestureClear(action.rawValue))
            .focusEffectDisabledIfAvailable()
            .disabled(gesture == nil)
        }
    }

    private func finishRecording(_ gesture: RemoteGesture, for action: PlayerGestureAction) {
        let builtIn = PlayerBuiltInGesture.action(for: gesture)
        let previous = gestureBindings.bind(gesture, to: action)
        PlayerGestureSettings.save(gestureBindings)
        var parts = ["\(gesture.title) → \(action.title)"]
        if let previous { parts.append("\(previous.title) no longer has a gesture") }
        if let builtIn { parts.append("replaces: \(builtIn.title)") }
        gestureNote = parts.joined(separator: " · ")
        endRecording(action)
    }

    private func endRecording(_ action: PlayerGestureAction) {
        recordingGestureAction = nil
        DispatchQueue.main.async {
            focus = .gestureAction(action.rawValue)
        }
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
                Text(isOn
                     ? L10n.string("subtitle_style_on", fallback: "On")
                     : L10n.string("subtitle_style_off", fallback: "Off"))
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

private struct PlaybackLogsPage: View {
    @State private var entries: [PlaybackDiagnosticLogEntry] = []
    @State private var isRefreshPaused = false
    @State private var didScrollToLatest = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 20) {
                Text("Recent playback events · \(entries.count)")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(.white.opacity(0.78))

                Button(isRefreshPaused ? "Resume refresh" : "Pause refresh") {
                    isRefreshPaused.toggle()
                }
                .buttonStyle(PosterCardButtonStyle())

                Button("Clear logs") {
                    PlaybackDiagnosticLogStore.shared.clear()
                    entries = []
                }
                .buttonStyle(PosterCardButtonStyle())
            }

            Text("Recent playback events are shown here. For crash details, collect the Apple TV unified log in Console (subsystem com.pyksel.nuviotvos, category playback-diagnostics).")
                .font(.system(size: 20))
                .foregroundColor(.white.opacity(0.55))

            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if entries.isEmpty {
                            Text("No playback events captured yet.")
                                .font(.system(size: 20, design: .monospaced))
                                .foregroundColor(.white.opacity(0.55))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        ForEach(entries) { entry in
                            Text("[\(entry.timestamp.formatted(date: .omitted, time: .standard))] [\(entry.source)] \(entry.message)")
                                .font(.system(size: 19, design: .monospaced))
                                .foregroundColor(.white.opacity(0.88))
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 6)
                                .id(entry.id)
                        }
                    }
                    .padding(18)
                }
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
                .focusable()
                .focusSection()
                .accessibilityLabel("Playback event log")
                .onChange(of: entries.count) { _, _ in
                    guard !didScrollToLatest, let latestID = entries.last?.id else { return }
                    didScrollToLatest = true
                    proxy.scrollTo(latestID, anchor: .bottom)
                }
                .task {
                    while !Task.isCancelled {
                        if !isRefreshPaused {
                            entries = PlaybackDiagnosticLogStore.shared.snapshot()
                        }
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct PlayerPresetNameDialog: View {
    var title: String = L10n.string("subtitle_style_name_dialog_title", fallback: "Subtitle Style Name")
    @Binding var text: String
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @FocusState private var focusedField: DialogFocus?
    @State private var isEditing = false

    private enum DialogFocus: Hashable {
        case textField
        case cancel
        case save
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.65)
                .ignoresSafeArea()
                .onTapGesture {
                    onCancel()
                }

            VStack(spacing: 28) {
                VStack(spacing: 10) {
                    Text(title)
                        .font(.system(size: 32, weight: .bold))
                        .foregroundColor(.white)

                    Text(L10n.string("subtitle_style_name_dialog_desc", fallback: "Enter a custom name for this subtitle preset"))
                        .font(.system(size: 20, weight: .regular))
                        .foregroundColor(.white.opacity(0.65))
                }

                Button {
                    isEditing = true
                } label: {
                    SettingsGlassTextField(
                        text: $text,
                        placeholder: SubtitleStylePresetStore.shared.suggestedCustomPresetName(),
                        focused: focusedField == .textField,
                        isEditing: $isEditing,
                        fieldWidth: 500,
                        centerDisplayText: true,
                        onCommit: {
                            isEditing = false
                            save()
                        }
                    )
                }
                .buttonStyle(PosterCardButtonStyle())
                .focused($focusedField, equals: .textField)
                .focusEffectDisabledIfAvailable()

                HStack(spacing: 24) {
                    Button(action: onCancel) {
                        Text(L10n.string("common_cancel", fallback: "Cancel"))
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundColor(focusedField == .cancel ? .black : .white)
                            .frame(width: 238, height: 60)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(focusedField == .cancel ? Color.white : Color.white.opacity(0.12))
                            )
                    }
                    .buttonStyle(PosterCardButtonStyle())
                    .focused($focusedField, equals: .cancel)
                    .focusEffectDisabledIfAvailable()

                    Button(action: save) {
                        Text(L10n.string("common_save", fallback: "Save"))
                            .font(.system(size: 22, weight: .bold))
                            .foregroundColor(focusedField == .save ? .black : .white)
                            .frame(width: 238, height: 60)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(focusedField == .save ? Color.white : Color.white.opacity(0.12))
                            )
                    }
                    .buttonStyle(PosterCardButtonStyle())
                    .focused($focusedField, equals: .save)
                    .focusEffectDisabledIfAvailable()
                }
            }
            .padding(40)
            .background(
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .fill(Color(white: 0.14).opacity(0.95))
                    .overlay(
                        RoundedRectangle(cornerRadius: 32, style: .continuous)
                            .stroke(Color.white.opacity(0.18), lineWidth: 1)
                    )
            )
            .frame(maxWidth: 620)
        }
        .onExitCommand(perform: onCancel)
        .onAppear {
            focusedField = .textField
        }
    }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = trimmed.isEmpty ? SubtitleStylePresetStore.shared.suggestedCustomPresetName() : trimmed
        onSave(resolved)
    }
}
