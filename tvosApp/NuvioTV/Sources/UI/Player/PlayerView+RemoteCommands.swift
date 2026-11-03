import SwiftUI

extension PlayerView {
    var layersWithRemoteCommands: some View {
        layersObservingFocus
            .onPlayPauseCommand {
                let elapsedWake = Date().timeIntervalSince(lastBecameActiveAt)
                screensaverDebugLog("[ScreensaverDebug][Input] onPlayPauseCommand: isWakingFromBg=\(isWakingFromBackground) (elapsedWake=\(String(format: "%.3f", elapsedWake))s), status=\(viewModel.status), pos=\(viewModel.time.current)")
                guard !isWakingFromBackground else {
                    screensaverDebugLog("[ScreensaverDebug][Input] onPlayPauseCommand suppressed by isWakingFromBackground")
                    return
                }
                guard viewModel.currentErrorDiagnostic == nil else { return }
                guard didReportPlaybackStarted else {
                    revealControlsAndFocusSettings()
                    return
                }
                viewModel.togglePlayPause()
            }
            .onExitCommand(perform: handleRemoteBack)
    }

    /// Back / Menu during playback (also from the remote-gesture layer, which takes the remote).
    func handleRemoteBack() {
        PlaybackTimelineRecorder.record(.backPressed, engine: viewModel.activeEngineKind)
        if viewModel.isSceneDetailVisible {
            withAnimation(.easeInOut(duration: 0.2)) {
                viewModel.closeSceneDetail()
            }
            return
        }
        if viewModel.showScenePanel {
            viewModel.closeScene()
            focusRemoteInput()
            return
        }
        // The panel handles its own exit; this fallback covers the frame
        // where focus hasn't landed inside it yet.
        if viewModel.showSettingsPanel {
            viewModel.showSettingsPanel = false
            return
        }
        if viewModel.sidePanel != nil {
            viewModel.closeSidePanel()
            return
        }
        if viewModel.currentErrorDiagnostic != nil {
            onRemoteBack()
            return
        }
        if viewModel.isScrubbing {
            viewModel.cancelScrub()
            return
        }
        if viewModel.showPauseOverlay {
            viewModel.dismissPauseOverlay()
            viewModel.revealControls()
            return
        }
        if viewModel.postPlayState.isVisible {
            if viewModel.postPlayState.isTrailerPlaying {
                viewModel.stopPostPlayTrailer()
            }
            let endGuard: Double = max(0, viewModel.time.duration - 3)
            if viewModel.postPlayState.canReturnToPlayer,
               viewModel.time.current < endGuard,
               viewModel.status != .ended {
                viewModel.returnToPlayerFromPostPlay()
            } else {
                onRemoteBack()
            }
            return
        }
        if viewModel.showNextEpisodeCard && !viewModel.showControls {
            viewModel.dismissNextEpisodeCard()
            nextEpisodeFocused = false
            cancelAutoPlayFocused = false
            focusRemoteInput()
            return
        }
        if viewModel.showSkipSegmentCard && !viewModel.showControls {
            viewModel.dismissActiveInterval()
            skipSegmentFocused = false
            focusRemoteInput()
            return
        }
        if viewModel.showControls {
            viewModel.hideControls()
            return
        }
        onRemoteBack()
    }
}
