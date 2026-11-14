import SwiftUI

extension PlayerView {
    @ViewBuilder
    var contentWarningsOverlayLayer: some View {
        if viewModel.showContentWarnings, !viewModel.contentWarnings.isEmpty {
            ContentWarningsOverlayView(warnings: viewModel.contentWarnings) {
                viewModel.contentWarningsDidDismiss()
            }
            .transition(.opacity)
        }
    }

    var isLoadingOverlayVisible: Bool {
        viewModel.isSwitchingSource
            || viewModel.isReloadingStream
            || viewModel.didDetectReplacementStream
            || viewModel.isAdvancingEpisode
            || viewModel.isAwaitingStreamStart
            || !didReportPlaybackStarted
            || (!viewModel.hasRenderedFirstFrame && !viewModel.isLiveStream)
    }

    private var loadingOverlayFocusEnabled: Bool {
        (!viewModel.showControls || isLoadingOverlayVisible)
            && !viewModel.showSettingsPanel
            && !viewModel.showScenePanel
            && !viewModel.isSceneDetailVisible
            && viewModel.sidePanel == nil
    }

    private func handleLoadingOverlayMove(_ direction: MoveCommandDirection) {
        switch direction {
        case .up:
            break
        case .down:
            if viewModel.isSceneEnabled && !isLoadingOverlayVisible {
                viewModel.openScene()
            }
        default:
            break
        }
    }

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
            PlaybackErrorOverlayView(
                diagnostic: diagnostic,
                supportReport: PlaybackErrorSupportReport(
                    httpStatusCode: diagnostic.httpStatusCode,
                    engine: viewModel.activeEngineKind,
                    appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                    buildNumber: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
                    renderedFirstFrame: viewModel.hasRenderedFirstFrame
                ),
                showSources: onRequestSources != nil || (diagnostic.isHostingIssue && (viewModel.availableSources.count > 1 || fetchPlaybackSources != nil)),
                onSources: {
                    if let onRequestSources {
                        onRequestSources(viewModel.currentEpisodeVideo)
                    } else {
                        viewModel.openSidePanel(.sources)
                    }
                },
                onRetry: {
                    viewModel.retryCurrentPlayback()
                },
                onClose: {
                    onBack()
                },
                onRemoteBack: onRemoteBack
            )
            .transition(.opacity)
        } else {
            switch viewModel.status {
            case .buffering, .idle:
                if isLoadingOverlayVisible {
                    PlayerLoadingOverlay(
                        backdropUrl: meta.backgroundUrl ?? meta.landscapePosterUrl ?? meta.posterUrl,
                        logoUrl: meta.logoUrl,
                        title: meta.name,
                        message: viewModel.loadingStepMessage,
                        startTime: PlaybackStartupTiming.requestDate(for: viewModel.startupBenchmarkToken),
                        onDismiss: onRemoteBack,
                        focusEnabled: loadingOverlayFocusEnabled,
                        onSelect: { revealControlsAndFocusSettings() },
                        onMove: handleLoadingOverlayMove
                    )
                    .id(viewModel.startupBenchmarkToken)
                    .transition(.opacity)
                } else if !viewModel.hasRenderedFirstFrame {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(2)
                        .padding(48)
                        .glassCircle()
                }
            case .playing, .paused:
                if isLoadingOverlayVisible {
                    PlayerLoadingOverlay(
                        backdropUrl: meta.backgroundUrl ?? meta.landscapePosterUrl ?? meta.posterUrl,
                        logoUrl: meta.logoUrl,
                        title: meta.name,
                        message: viewModel.loadingStepMessage,
                        startTime: PlaybackStartupTiming.requestDate(for: viewModel.startupBenchmarkToken),
                        onDismiss: onRemoteBack,
                        focusEnabled: loadingOverlayFocusEnabled,
                        onSelect: { revealControlsAndFocusSettings() },
                        onMove: handleLoadingOverlayMove
                    )
                    .id(viewModel.startupBenchmarkToken)
                    .transition(.opacity)
                }
            default:
                EmptyView()
            }
        }
    }

struct PlaybackErrorOverlayView: View {
    let diagnostic: PlaybackErrorDiagnostic
    let supportReport: PlaybackErrorSupportReport?
    let showSources: Bool
    let onSources: () -> Void
    let onRetry: () -> Void
    let onClose: () -> Void
    let onRemoteBack: () -> Void

    enum FocusItem: Hashable {
        case sources
        case retry
        case close
    }

    @FocusState private var focusedItem: FocusItem?
    @State private var didInitializeFocus = false

    var body: some View {
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

            if let supportReport {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.string("player_support_details_header", fallback: "SUPPORT DETAILS"))
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(Color.white.opacity(0.65))

                    Text(supportReport.statusLine)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)

                    Text(supportReport.playbackLine)
                        .font(.system(size: 14, weight: .regular))
                        .foregroundColor(Color.white.opacity(0.82))

                    Text(supportReport.sharingPrompt)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundColor(Color.white.opacity(0.68))
                }
                .frame(maxWidth: 620, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                .accessibilityElement(children: .combine)
            }

            // Action Buttons
            HStack(spacing: 20) {
                if showSources {
                    let isSourcesFocused = focusedItem == .sources
                    Button(action: onSources) {
                        HStack(spacing: 8) {
                            Image(systemName: "list.bullet.rectangle.portrait")
                                .font(.system(size: 15, weight: .bold))
                            Text(L10n.string("player_sources_title", fallback: "Other Sources"))
                                .font(.system(size: 16, weight: .semibold))
                        }
                        .foregroundColor(isSourcesFocused ? .black : .white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(isSourcesFocused ? Color.white : Color.white.opacity(0.18), in: Capsule())
                        .scaleEffect(isSourcesFocused ? 1.06 : 1.0)
                        .shadow(color: .black.opacity(isSourcesFocused ? 0.35 : 0), radius: isSourcesFocused ? 10 : 0, y: 4)
                        .animation(.easeOut(duration: 0.14), value: isSourcesFocused)
                    }
                    .buttonStyle(PosterCardButtonStyle())
                    .focusEffectDisabledIfAvailable()
                    .focused($focusedItem, equals: .sources)
                }

                let isRetryFocused = focusedItem == .retry
                Button(action: onRetry) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 15, weight: .bold))
                        Text(L10n.string("common_retry", fallback: "Retry"))
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .foregroundColor(isRetryFocused ? .black : .white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(isRetryFocused ? Color.white : Color.white.opacity(0.18), in: Capsule())
                    .scaleEffect(isRetryFocused ? 1.06 : 1.0)
                    .shadow(color: .black.opacity(isRetryFocused ? 0.35 : 0), radius: isRetryFocused ? 10 : 0, y: 4)
                    .animation(.easeOut(duration: 0.14), value: isRetryFocused)
                }
                .buttonStyle(PosterCardButtonStyle())
                .focusEffectDisabledIfAvailable()
                .accessibilityIdentifier("player.retryStartup")
                .focused($focusedItem, equals: .retry)

                let isCloseFocused = focusedItem == .close
                Button(action: onClose) {
                    HStack(spacing: 8) {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .bold))
                        Text(L10n.string("common_close", fallback: "Close"))
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .foregroundColor(isCloseFocused ? .black : .white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(isCloseFocused ? Color.white : Color.white.opacity(0.18), in: Capsule())
                    .scaleEffect(isCloseFocused ? 1.06 : 1.0)
                    .shadow(color: .black.opacity(isCloseFocused ? 0.35 : 0), radius: isCloseFocused ? 10 : 0, y: 4)
                    .animation(.easeOut(duration: 0.14), value: isCloseFocused)
                }
                .buttonStyle(PosterCardButtonStyle())
                .focusEffectDisabledIfAvailable()
                .focused($focusedItem, equals: .close)
            }
            .padding(.top, 6)
        }
        .padding(.horizontal, 50)
        .padding(.vertical, 38)
        .glassRoundedRect(cornerRadius: 28)
        .shadow(color: .black.opacity(0.7), radius: 24, y: 8)
        .focusSection()
        .onExitCommand(perform: onRemoteBack)
        .onAppear {
            if !didInitializeFocus {
                didInitializeFocus = true
                DispatchQueue.main.async {
                    focusedItem = .retry
                }
            }
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
}

private struct ContentWarningsOverlayView: View {
    let warnings: [PlayerContentWarning]
    let onDismiss: () -> Void

    @State private var isContainerVisible = false
    @State private var isAccentExpanded = false
    @State private var visibleRowCount = 0

    private let rowHeight: CGFloat = 25
    private let rowGap: CGFloat = 3

    private var fullHeight: CGFloat {
        CGFloat(warnings.count) * rowHeight + CGFloat(max(0, warnings.count - 1)) * rowGap
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Capsule()
                .fill(Color.accentColor)
                .frame(width: 4, height: isAccentExpanded ? fullHeight : 0, alignment: .top)

            VStack(alignment: .leading, spacing: rowGap) {
                ForEach(Array(warnings.enumerated()), id: \.element.id) { index, warning in
                    warningRow(warning)
                        .frame(height: rowHeight, alignment: .leading)
                        .opacity(index < visibleRowCount ? 1 : 0)
                }
            }
        }
        .opacity(isContainerVisible ? 1 : 0)
        .padding(.leading, 64)
        .padding(.top, 44)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .task {
            guard !warnings.isEmpty else {
                onDismiss()
                return
            }

            withAnimation(.easeOut(duration: 0.3)) {
                isContainerVisible = true
            }
            guard await pause(nanoseconds: 300_000_000) else { return }
            withAnimation(.easeInOut(duration: 0.4)) {
                isAccentExpanded = true
            }
            guard await pause(nanoseconds: 400_000_000) else { return }

            for index in warnings.indices {
                guard await pause(nanoseconds: 80_000_000) else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    visibleRowCount = index + 1
                }
                guard await pause(nanoseconds: 200_000_000) else { return }
            }

            guard await pause(nanoseconds: 5_000_000_000) else { return }
            for remainingRows in stride(from: warnings.count - 1, through: 0, by: -1) {
                guard await pause(nanoseconds: 60_000_000) else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    visibleRowCount = remainingRows
                }
                guard await pause(nanoseconds: 150_000_000) else { return }
            }

            guard await pause(nanoseconds: 100_000_000) else { return }
            withAnimation(.easeInOut(duration: 0.3)) {
                isAccentExpanded = false
            }
            guard await pause(nanoseconds: 300_000_000) else { return }
            guard await pause(nanoseconds: 200_000_000) else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                isContainerVisible = false
            }
            guard await pause(nanoseconds: 200_000_000) else { return }
            onDismiss()
        }
    }

    private func warningRow(_ warning: PlayerContentWarning) -> some View {
        HStack(spacing: 4) {
            Text(L10n.string(warning.category.localizationKey, fallback: warning.category.fallbackLabel))
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white.opacity(0.85))
            Text("·")
                .font(.system(size: 18))
                .foregroundColor(.white.opacity(0.4))
            Text(warning.severityLocalizationKey.map {
                L10n.string($0, fallback: warning.severity.capitalized)
            } ?? warning.severity.capitalized)
                .font(.system(size: 18))
                .foregroundColor(.white.opacity(0.5))
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func pause(nanoseconds: UInt64) async -> Bool {
        do {
            try await Task.sleep(nanoseconds: nanoseconds)
            return !Task.isCancelled
        } catch {
            return false
        }
    }
}

    @ViewBuilder
    var debugOverlayLayer: some View {
        if viewModel.isPlaybackDebugHUDVisible,
           viewModel.currentErrorDiagnostic?.httpStatusCode != 403,
           let info = viewModel.playbackDebugInfo {
            PlaybackDebugHUDView(
                info: info,
                reason: viewModel.playbackDebugReason
            )
            .transition(.opacity.combined(with: .move(edge: .trailing)))
            .zIndex(1)
        }
    }
}
