import SwiftUI

extension PlayerView {
    var layersWithRemoteCommands: some View {
        layersObservingFocus
            .onPlayPauseCommand {
                guard !isWakingFromBackground else { return }
                guard viewModel.currentErrorDiagnostic == nil else { return }
                viewModel.togglePlayPause()
            }
            .onMoveCommand { direction in
                guard !isWakingFromBackground else { return }
                // The Episodes/Sources sheet exclusively owns directional input.
                // Do not let list navigation also seek or reveal player controls.
                guard viewModel.sidePanel == nil, viewModel.currentErrorDiagnostic == nil else { return }

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
                    case .left, .right:
                        viewModel.revealControls()
                    default:
                        viewModel.revealControls()
                    }
                    return
                }

                guard !viewModel.showControls else { return }
                switch direction {
                case .left, .right:
                    if viewModel.status == .playing {
                        viewModel.handleMoveSeek(direction: direction)
                    }
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
