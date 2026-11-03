import SwiftUI

/// Remote gestures during playback: while playing with the controls hidden, the
/// gesture layer holds the remote. A bound gesture does its action; any other gesture does what
/// the player does with it anyway (± seek, hold seek, pause, controls, InSight, peek).
extension PlayerView {
    /// When the focus sink owns the remote (controls hidden, nothing else up).
    var isFocusSinkEligible: Bool {
        didReportPlaybackStarted
            && (!viewModel.showControls || viewModel.isSwitchingSource || viewModel.showPauseOverlay)
            && !viewModel.isScrubbing
            && !viewModel.isHoldingSeek
            && viewModel.currentErrorDiagnostic == nil
            && !viewModel.showNextEpisodeCard
            && !viewModel.showSkipSegmentCard
            && !viewModel.showSettingsPanel
            && !viewModel.showScenePanel
            && !viewModel.isSceneDetailVisible
            && !viewModel.postPlayState.isVisible
            && viewModel.sidePanel == nil
    }

    /// Gestures on, playing, the controls hidden and nothing else on screen. A hold seek the
    /// layer started keeps it until the button is released. The short wait after a seek (a
    /// chapter jump) keeps it too: dropping it there handed the remote to the focus sink.
    var isGestureCaptureActive: Bool {
        viewModel.areGesturesEnabled
            && didReportPlaybackStarted
            && !isWakingFromBackground
            && !isLoadingOverlayVisible
            && PlayerGestureCaptureStatus.keepsCapture(viewModel.status)
            && !viewModel.showControls
            && !viewModel.showPauseOverlay
            && !viewModel.isScrubbing
            && !viewModel.isSwitchingSource
            && viewModel.currentErrorDiagnostic == nil
            && !viewModel.showNextEpisodeCard
            && !viewModel.showSkipSegmentCard
            && !viewModel.showSettingsPanel
            && !viewModel.showScenePanel
            && !viewModel.isSceneDetailVisible
            && !viewModel.postPlayState.isVisible
            && viewModel.sidePanel == nil
    }

    var gestureCaptureLayer: some View {
        PlayerGestureCapture(
            isActive: isGestureCaptureActive,
            waitsForDouble: { double in
                PlayerGestureSettings.activeBindings().action(for: double) != nil
            },
            onGesture: handleRemoteGesture,
            onPressEnded: handleRemoteGesturePressEnded,
            onBack: handleRemoteBack,
            setPadObserver: { observer in
                viewModel.gesturePadObservers["player"] = observer
            },
            tuning: viewModel.gestureTuning,
            customShapes: viewModel.customGestureShapes
        )
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .onAppear {
            viewModel.isGestureCaptureActive = isGestureCaptureActive
        }
        .onChange(of: isGestureCaptureActive) { _, active in
            viewModel.isGestureCaptureActive = active
            if active {
                // The sink can't be focused now; a pending request for it would fight this layer.
                remoteInputFocused = false
            } else if isFocusSinkEligible, !viewModel.showControls {
                // Paused or otherwise left with nothing to take the remote: the sink takes it again.
                focusRemoteInput()
            }
        }
    }

    /// Whenever the gesture layer doesn't hold the remote (the controls shown, paused) and no
    /// panel or menu is up: bound gestures are still heard, without taking the remote, so the
    /// controls work as before and the gesture's action comes on top.
    var isPassiveGestureActive: Bool {
        viewModel.areGesturesEnabled
            && didReportPlaybackStarted
            && !isWakingFromBackground
            && !isLoadingOverlayVisible
            && !isGestureCaptureActive
            && !viewModel.controlsAutoHideSuspended
            && !viewModel.isScrubbing
            && !viewModel.isHoldingSeek
            && !viewModel.isSwitchingSource
            && viewModel.currentErrorDiagnostic == nil
            && !viewModel.showSettingsPanel
            && !viewModel.showScenePanel
            && !viewModel.isSceneDetailVisible
            && !viewModel.postPlayState.isVisible
            && viewModel.sidePanel == nil
    }

    var gestureObserverLayer: some View {
        PlayerGestureObserver(
            isActive: isPassiveGestureActive,
            waitsForDouble: { double in
                PlayerGestureSettings.activeBindings().action(for: double) != nil
            },
            onGesture: handlePassiveGesture,
            setPadObserver: { observer in
                viewModel.gesturePadObservers["passive"] = observer
            },
            tuning: viewModel.gestureTuning,
            customShapes: viewModel.customGestureShapes
        )
        .allowsHitTesting(false)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
        .onAppear { syncPassiveTapSides(isPassiveGestureActive) }
        .onChange(of: isPassiveGestureActive) { _, active in syncPassiveTapSides(active) }
    }

    private func syncPassiveTapSides(_ active: Bool) {
        viewModel.passiveGestureTapSides = active
            ? PlayerGesturePassive.waitingTapSides(PlayerGestureSettings.activeBindings())
            : []
    }

    func handlePassiveGesture(_ gesture: RemoteGesture) {
        if let action = PlayerGestureSettings.activeBindings().action(for: gesture) {
            viewModel.performGestureAction(action)
            return
        }
        // A tap on a side whose double tap is bound waited for it: now it seeks, as the tap does.
        if case let .tap(side, double: false) = gesture, viewModel.passiveGestureTapSides.contains(side) {
            viewModel.handleMoveSeek(direction: side == .left ? .left : .right)
        }
    }

    func handleRemoteGesture(_ gesture: RemoteGesture) {
        if let action = PlayerGestureSettings.activeBindings().action(for: gesture) {
            viewModel.performGestureAction(action)
            return
        }
        switch PlayerBuiltInGesture.action(for: gesture) {
        case .seekBack:
            viewModel.handleMoveSeek(direction: .left)
        case .seekForward:
            viewModel.handleMoveSeek(direction: .right)
        case .holdSeekBack:
            viewModel.gestureHoldSeekButton = .left
            viewModel.beginRepeatingSkipBackward()
        case .holdSeekForward:
            viewModel.gestureHoldSeekButton = .right
            viewModel.beginRepeatingSkipForward()
        case .select:
            viewModel.handleSelectTap()
        case .playPause:
            viewModel.togglePlayPause()
        case .revealControls:
            viewModel.revealControls()
        case .openPanel:
            if viewModel.isSceneEnabled {
                viewModel.openScene()
            } else {
                viewModel.revealControls()
            }
        case .peek:
            viewModel.showPeek()
        case nil:
            break
        }
    }

    func handleRemoteGesturePressEnded(_ button: RemoteButton) {
        guard viewModel.gestureHoldSeekButton == button else { return }
        viewModel.gestureHoldSeekButton = nil
        viewModel.stopRepeatingSkip()
    }
}

/// Gestures with the controls shown: every bound one does its action, on top of what the
/// controls do with it.
enum PlayerGesturePassive {
    /// The sides whose tap seeks on the timeline and whose double tap is bound: there the tap
    /// waits to see whether a second one follows, and the gesture layer seeks.
    static func waitingTapSides(_ bindings: PlayerGestureBindings) -> Set<PadSide> {
        Set([PadSide.left, .right].filter { bindings.action(for: .tap($0, double: true)) != nil })
    }
}

/// Which playback states the gesture layer holds the remote in.
enum PlayerGestureCaptureStatus {
    /// Playing, or the brief buffering after a seek. Paused, ended or failed hand the remote back.
    static func keepsCapture(_ status: PlayerStatus) -> Bool {
        switch status {
        case .playing, .buffering: return true
        case .idle, .paused, .ended, .error: return false
        }
    }
}
