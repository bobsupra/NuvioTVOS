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
        if let diagnostic = viewModel.currentErrorDiagnostic {
            playbackErrorOverlay(diagnostic: diagnostic)
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
                } else if !viewModel.hasRenderedFirstFrame {
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
            default:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private func playbackErrorOverlay(diagnostic: PlaybackErrorDiagnostic) -> some View {
        VStack(spacing: 24) {
            // Icon
            Image(systemName: diagnostic.badgeIconName)
                .font(.system(size: 48, weight: .medium))
                .foregroundColor(badgeForegroundColor(for: diagnostic.origin))
                .shadow(color: badgeForegroundColor(for: diagnostic.origin).opacity(0.3), radius: 12)

            // Title & Description
            VStack(spacing: 10) {
                Text(diagnostic.title)
                    .font(.system(size: 30, weight: .bold))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)

                Text(diagnostic.message)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundColor(Color.white.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .frame(maxWidth: 620)
            }

            // Action Buttons
            HStack(spacing: 20) {
                if diagnostic.isHostingIssue && (viewModel.availableSources.count > 1 || fetchPlaybackSources != nil) {
                    Button {
                        viewModel.sidePanel = .sources
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "list.bullet.rectangle.portrait")
                                .font(.system(size: 15, weight: .bold))
                            Text(L10n.string("player_sources_title", fallback: "Other Sources"))
                                .font(.system(size: 16, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(Color.white.opacity(0.18), in: Capsule())
                    }
                    .buttonStyle(PosterCardButtonStyle())
                    .focused($errorFocus, equals: .sources)
                }

                Button {
                    viewModel.retryCurrentPlayback()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 15, weight: .bold))
                        Text(L10n.string("common_retry", fallback: "Retry"))
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Color.white.opacity(0.18), in: Capsule())
                }
                .buttonStyle(PosterCardButtonStyle())
                .accessibilityIdentifier("player.retryStartup")
                .focused($errorFocus, equals: .retry)
                .focused($startupRetryFocused)

                Button {
                    onBack()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .bold))
                        Text(L10n.string("common_close", fallback: "Close"))
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Color.white.opacity(0.18), in: Capsule())
                }
                .buttonStyle(PosterCardButtonStyle())
                .focused($errorFocus, equals: .close)
            }
            .padding(.top, 6)
        }
        .padding(.horizontal, 50)
        .padding(.vertical, 38)
        .glassRoundedRect(cornerRadius: 28)
        .shadow(color: .black.opacity(0.7), radius: 24, y: 8)
        .onAppear {
            remoteInputFocused = false
            errorFocus = .retry
            startupRetryFocused = true
        }
    }

    private func badgeForegroundColor(for origin: PlaybackErrorOrigin) -> Color {
        switch origin {
        case .hostingProvider: return Color(red: 1.0, green: 0.72, blue: 0.25)
        case .network: return Color(red: 1.0, green: 0.40, blue: 0.40)
        case .compatibility: return Color(red: 0.75, green: 0.65, blue: 1.0)
        case .playerEngine: return Color(red: 1.0, green: 0.85, blue: 0.3)
        }
    }

    private func badgeBackgroundColor(for origin: PlaybackErrorOrigin) -> Color {
        switch origin {
        case .hostingProvider: return Color(red: 1.0, green: 0.60, blue: 0.1).opacity(0.20)
        case .network: return Color(red: 0.9, green: 0.2, blue: 0.2).opacity(0.20)
        case .compatibility: return Color(red: 0.6, green: 0.4, blue: 0.9).opacity(0.20)
        case .playerEngine: return Color(red: 0.9, green: 0.7, blue: 0.1).opacity(0.20)
        }
    }

    private func badgeBorderColor(for origin: PlaybackErrorOrigin) -> Color {
        switch origin {
        case .hostingProvider: return Color(red: 1.0, green: 0.60, blue: 0.1).opacity(0.45)
        case .network: return Color(red: 0.9, green: 0.2, blue: 0.2).opacity(0.45)
        case .compatibility: return Color(red: 0.6, green: 0.4, blue: 0.9).opacity(0.45)
        case .playerEngine: return Color(red: 0.9, green: 0.7, blue: 0.1).opacity(0.45)
        }
    }

    @ViewBuilder
    var debugOverlayLayer: some View {
        if viewModel.isPlaybackDebugHUDVisible,
           let info = viewModel.playbackDebugInfo {
            PlaybackDebugHUDView(
                info: info,
                reason: viewModel.playbackDebugReason
            )
            .transition(.opacity.combined(with: .move(edge: .top)))
            .zIndex(100)
        }
    }
}
