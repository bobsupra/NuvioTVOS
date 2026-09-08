import SwiftUI

extension PlayerView {
    @ViewBuilder
    var miniPlayerReturnButton: some View {
        Button {
            viewModel.returnToPlayerFromPostPlay()
        } label: {
            ZStack {
                Color.clear
                if postPlayFocus == .miniPlayer {
                    VStack {
                        Spacer()
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 16, weight: .bold))
                            Text(L10n.string("player_return_to_video", fallback: "Return to Video"))
                                .font(.system(size: 16, weight: .semibold))
                        }
                        .foregroundColor(.black)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.95), in: Capsule())
                        .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                        .padding(.bottom, 14)
                    }
                    .transition(.opacity)
                }
            }
        }
        .buttonStyle(PosterCardButtonStyle())
        .focusEffectDisabledIfAvailable()
        .focused($postPlayFocus, equals: .miniPlayer)
        .onMoveCommand { direction in
            if direction == .down {
                postPlayFocus = .primaryAction
            }
        }
        .accessibilityLabel("Return to video")
    }

    @ViewBuilder
    var playerStatusOverlay: some View {
        if let startupError = viewModel.playbackStartupError {
            VStack(spacing: 18) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 48))
                    .foregroundColor(.yellow)
                Text(L10n.string("player_status_playback_failed", fallback: "Playback failed"))
                    .font(.title2.weight(.semibold))
                    .foregroundColor(.white)
                Text(startupError)
                    .font(.body)
                    .foregroundColor(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                Button(L10n.string("common_retry", fallback: "Retry")) {
                    viewModel.retryPlaybackStartup()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("player.retryStartup")
                .focused($startupRetryFocused)
                .onAppear {
                    remoteInputFocused = false
                    startupRetryFocused = true
                }
            }
            .padding(48)
            .glassRoundedRect(cornerRadius: 32)
        } else {
        switch viewModel.status {
        case .buffering, .idle:
            if viewModel.isSwitchingSource || viewModel.isReloadingStream || viewModel.didDetectReplacementStream {
                PlayerLoadingOverlay(
                    backdropUrl: meta.backgroundUrl ?? meta.posterUrl,
                    logoUrl: meta.logoUrl,
                    title: meta.name,
                    message: L10n.string("player_status_starting_stream", fallback: "Starting stream")
                )
                .transition(.opacity)
            } else if !didReportPlaybackStarted {
                PlayerLoadingOverlay(
                    backdropUrl: meta.backgroundUrl ?? meta.posterUrl,
                    logoUrl: meta.logoUrl,
                    title: meta.name,
                    message: L10n.string("player_status_starting_stream", fallback: "Starting stream")
                )
                .transition(.opacity)
            } else {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .scaleEffect(2)
                    .padding(48)
                    .glassCircle()
            }
        case .playing, .paused:
            if viewModel.isSwitchingSource || viewModel.isReloadingStream || viewModel.didDetectReplacementStream || !didReportPlaybackStarted {
                PlayerLoadingOverlay(
                    backdropUrl: meta.backgroundUrl ?? meta.posterUrl,
                    logoUrl: meta.logoUrl,
                    title: meta.name,
                    message: L10n.string("player_status_starting_stream", fallback: "Starting stream")
                )
                .transition(.opacity)
            }
        case .error(let message):
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 48))
                    .foregroundColor(.yellow)
                Text(L10n.string("player_status_playback_failed", fallback: "Playback failed"))
                    .font(.title2.weight(.semibold))
                    .foregroundColor(.white)
                Text(message)
                    .font(.body)
                    .foregroundColor(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 900)
            }
            .padding(48)
            .glassRoundedRect(cornerRadius: 32)
        default:
            EmptyView()
        }
        }
    }

    @ViewBuilder
    var debugOverlayLayer: some View {
        if viewModel.isPlaybackDebugHUDVisible,
           let info = viewModel.playbackDebugInfo {
            let dur = viewModel.clock.duration > 0 ? viewModel.clock.duration : viewModel.time.duration
            let pos = viewModel.clock.duration > 0 ? viewModel.clock.position : viewModel.time.current
            let remaining = dur > 0 ? max(0, dur - pos) : nil
            PlaybackDebugHUDView(
                info: info,
                reason: viewModel.playbackDebugReason,
                remainingSeconds: remaining
            )
            .transition(.opacity.combined(with: .move(edge: .top)))
            .zIndex(100)
        }
    }
}
