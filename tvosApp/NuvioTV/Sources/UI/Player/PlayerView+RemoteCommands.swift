import SwiftUI

extension PlayerView {
    var layersWithRemoteCommands: some View {
        layersObservingFocus
            .onPlayPauseCommand {
                let elapsedWake = Date().timeIntervalSince(lastBecameActiveAt)
                print("[ScreensaverDebug][Input] onPlayPauseCommand: isWakingFromBg=\(isWakingFromBackground) (elapsedWake=\(String(format: "%.3f", elapsedWake))s), status=\(viewModel.status), pos=\(viewModel.time.current)")
                guard !isWakingFromBackground else {
                    print("[ScreensaverDebug][Input] onPlayPauseCommand suppressed by isWakingFromBackground")
                    return
                }
                guard viewModel.currentErrorDiagnostic == nil else { return }
                viewModel.togglePlayPause()
            }
            .onExitCommand {
                if viewModel.isSceneDetailVisible {
                    viewModel.closeSceneDetail()
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
                    onBack()
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
                if viewModel.postPlayState.isTrailerPlaying {
                    viewModel.stopPostPlayTrailer()
                    return
                }
                if viewModel.postPlayState.isVisible {
                    let endGuard: Double = max(0, viewModel.time.duration - 3)
                    if viewModel.postPlayState.canReturnToPlayer,
                       viewModel.time.current < endGuard,
                       viewModel.status != .ended {
                        viewModel.returnToPlayerFromPostPlay()
                    } else {
                        onBack()
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
                onBack()
            }
    }
}
