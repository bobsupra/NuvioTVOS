import SwiftUI

extension PlayerView {
    var layersWithRemoteCommands: some View {
        layersObservingFocus
            .onPlayPauseCommand {
                guard viewModel.playbackStartupError == nil else { return }
                viewModel.togglePlayPause()
            }
            .onMoveCommand { direction in
                // The Episodes/Sources sheet exclusively owns directional input.
                // Do not let list navigation also seek or reveal player controls.
                guard viewModel.sidePanel == nil, viewModel.playbackStartupError == nil else { return }

                // Trackpad swipes also emit move commands; the pan recognizer sets
                // moveSuppressed so a swipe does not double-fire as a skip.
                if viewModel.moveSuppressed { return }

                if viewModel.isScrubbing {
                    switch direction {
                    case .left:
                        viewModel.scrubJump(-Double(max(viewModel.seekStepSeconds * 4, 60)))
                    case .right:
                        viewModel.scrubJump(Double(max(viewModel.seekStepSeconds * 4, 60)))
                    default:
                        viewModel.cancelScrub()
                    }
                    return
                }

                if viewModel.showPauseOverlay {
                    switch direction {
                    case .left:
                        viewModel.nudgeSeek(-Double(viewModel.seekStepSeconds))
                    case .right:
                        viewModel.nudgeSeek(Double(viewModel.seekStepSeconds))
                    default:
                        viewModel.revealControls()
                    }
                    return
                }

                guard !viewModel.showControls else { return }
                switch direction {
                case .left:
                    viewModel.nudgeSeek(-Double(viewModel.seekStepSeconds))
                case .right:
                    viewModel.nudgeSeek(Double(viewModel.seekStepSeconds))
                default:
                    viewModel.revealControls()
                }
            }
            .onExitCommand {
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
                if viewModel.isScrubbing {
                    viewModel.cancelScrub()
                    return
                }
                if viewModel.showPauseOverlay {
                    viewModel.dismissPauseOverlay()
                    viewModel.revealControls()
                    return
                }
                if viewModel.peekVisible {
                    viewModel.hidePeek()
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
                if viewModel.showControls {
                    viewModel.hideControls()
                    return
                }
                onBack()
            }
    }
}
