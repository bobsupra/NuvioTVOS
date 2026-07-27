import SwiftUI
import UIKit

struct PlayerView: View {
    @StateObject private var viewModel = PlayerViewModel()
    @Environment(\.scenePhase) private var scenePhase

    let url: URL
    let meta: NuvioMeta
    let subtitle: String
    let externalSubtitles: [NuvioSubtitle]
    let resumeFrom: Double?
    /// Episode context for the in-player Next Episode card. Empty for movies/trailers.
    var episodes: [NuvioVideo] = []
    var currentEpisode: NuvioVideo? = nil
    var autoPlayNextEnabled: Bool = true
    /// Resolves a next episode into a ready-to-play stream (add-on fetch + smart
    /// selection), supplied by the app layer. Nil disables auto-advance.
    var resolveNextStream: ((NuvioVideo) async -> PreparedNextStream?)? = nil
    /// Re-resolves a fresh stream for the *current* title/episode, used to
    /// recover from an expired link, load timeout, or playback error.
    /// `excludedURLs` are sources already tried this session. Nil disables failover.
    var reloadCurrentStream: ((_ excludedURLs: [String]) async -> PreparedNextStream?)? = nil
    /// Lists alternate streams for the Sources side panel.
    var fetchPlaybackSources: ((_ contentId: String, _ type: String) async -> [NuvioStream])? = nil
    /// Resolves a user-selected source for mid-playback switching.
    var resolvePlaybackStream: ((
        _ stream: NuvioStream,
        _ contentId: String,
        _ subtitleLine: String
    ) async -> PreparedNextStream?)? = nil
    var onFinished: (() -> Void)? = nil
    var onPlaybackStarted: (() -> Void)? = nil
    var onBack: () -> Void

    @State private var didHandleFinished = false
    @State private var didReportPlaybackStarted = false
    @FocusState private var remoteInputFocused: Bool
    @FocusState private var nextEpisodeFocused: Bool
    @FocusState private var skipSegmentFocused: Bool

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Aether is primary; MPV owns the one-way compatibility fallback.
            Group {
                switch viewModel.activeEngineKind {
                case .aether:
                    AetherPlayerSurface(controller: viewModel.aetherController)
                case .mpv:
                    MPVVideoSurface(controller: viewModel.playerController)
                }
            }
            .ignoresSafeArea()

            // Host subtitle overlay for Aether (MPV renders its own subs).
            if viewModel.activeEngineKind == .aether {
                PlayerSubtitleOverlay(
                    playback: viewModel.aetherController.subtitleOverlayState,
                    subtitleDelaySeconds: Double(viewModel.subtitleDelayMs) / 1000.0,
                    videoNaturalSize: viewModel.videoNaturalSize,
                    aspectMode: viewModel.aspectMode,
                    style: viewModel.subtitleStyle
                )
                .ignoresSafeArea()
            }

            // Window-level trackpad capture for Infuse-style scrubbing / peek.
            RemoteTouchCatcher(
                isActive: {
                    !viewModel.showSettingsPanel
                        && viewModel.sidePanel == nil
                        && (viewModel.isScrubbing
                            || (!viewModel.showControls && !viewModel.showNextEpisodeCard))
                },
                onBegan: { viewModel.remoteTouchBegan() },
                onMoved: { dx, dy in viewModel.remoteTouchMoved(dx: dx, dy: dy) },
                onEnded: { dx, dy in viewModel.remoteTouchEnded(dx: dx, dy: dy) }
            )
            .allowsHitTesting(false)
            .frame(width: 0, height: 0)

            RemoteSeekPressCatcher(
                // Hold left/right continuous seek when controls are hidden, or
                // when the timeline is focused. (Arrow holds are unreliable while
                // a focused progress bar owns the focus engine — hide chrome to
                // hold-seek.)
                isActive: !viewModel.showSettingsPanel
                    && viewModel.sidePanel == nil
                    && !viewModel.isScrubbing
                    && (!viewModel.showControls || viewModel.isTimelineFocused),
                onBeginBackward: { viewModel.beginRepeatingSkipBackward() },
                onBeginForward: { viewModel.beginRepeatingSkipForward() },
                onEnd: { viewModel.stopRepeatingSkip() }
            )
            .frame(width: 1, height: 1)
            .accessibilityHidden(true)

            switch viewModel.status {
            case .buffering, .idle:
                // A switch keeps this up for the whole round trip (resolve, then
                // the new stream opening), labelled with what it's waiting on.
                if viewModel.isSwitchingSource {
                    VStack(spacing: 14) {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(1.3)
                        Text(viewModel.switchingSourceMessage)
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundColor(.white.opacity(0.9))
                    }
                    .padding(.horizontal, 36)
                    .padding(.vertical, 28)
                    .glassRoundedRect(cornerRadius: 24)
                    .transition(.opacity)
                } else {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(2)
                        .padding(48)
                        .glassCircle()
                }
            case .error(let message):
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 48))
                        .foregroundColor(.yellow)
                    Text("Playback failed")
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

            if let toast = viewModel.playerToast {
                VStack {
                    Text(toast)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 14)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.top, 48)
                    Spacer()
                }
                .transition(.opacity)
                .allowsHitTesting(false)
                .zIndex(6)
            }

            // Focus sink for when the controls are hidden. tvOS routes the Menu
            // button to the system (which quits the app) and drops directional
            // input whenever no view holds focus, so something must always own it
            // while the controls are down. A bare focusable `Color.clear` is used
            // deliberately, not a Button: a Button draws a white full-screen focus
            // glow on tvOS 26+ (even with `.buttonStyle(.plain)` + focus effect
            // disabled), and dropping its opacity to hide that glow also makes the
            // focus engine skip it entirely — so `up` produced no move command.
            // A focusable Color draws no highlight yet stays reliably focusable at
            // full opacity. Kept mounted full-time (mounting it only when the
            // controls hide raced the timeline losing focusability, leaving focus in
            // a void); non-focusable while the controls are up so focus hands cleanly
            // to the timeline, focusable again the instant they hide. `up`/`down`
            // reveal via the PlayerView `onMoveCommand`; the select click reveals via
            // the tap gesture.
            Color.clear
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .focusable(
                    (!viewModel.showControls || viewModel.isScrubbing || viewModel.showPauseOverlay)
                        && !viewModel.showNextEpisodeCard
                        && !viewModel.showSkipSegmentCard
                        && !viewModel.showSettingsPanel
                        && viewModel.sidePanel == nil
                )
                .focused($remoteInputFocused)
                .onTapGesture {
                    if viewModel.isScrubbing {
                        viewModel.commitScrub()
                    } else if viewModel.showPauseOverlay {
                        viewModel.play()
                    } else if viewModel.peekVisible {
                        viewModel.beginScrub()
                    } else {
                        viewModel.revealControls()
                    }
                }
                .accessibilityHidden(true)

            // Light-tap peek timeline (no full chrome).
            if viewModel.peekVisible, !viewModel.showControls, !viewModel.isScrubbing {
                PeekBar(clock: viewModel.clock)
                    .transition(.opacity)
                    .zIndex(1)
            }

            // Infuse scrub HUD (trackpad / D-pad fine seek).
            if viewModel.isScrubbing {
                InfuseScrubHUD(
                    clock: viewModel.clock,
                    title: viewModel.title,
                    episodeLine: viewModel.subtitle.isEmpty ? nil : viewModel.subtitle,
                    wheelEngaged: viewModel.wheelEngaged
                )
                .transition(.opacity)
                .zIndex(4)
            }

            // Accumulated D-pad skip preview over bare video.
            if viewModel.pendingSeekDelta != 0, !viewModel.showControls, !viewModel.isScrubbing {
                SeekHUD(clock: viewModel.clock, delta: viewModel.pendingSeekDelta)
                    .transition(.opacity)
                    .zIndex(4)
            }

            // Pause metadata sheet ("You're watching…").
            if viewModel.showPauseOverlay {
                PauseOverlayView(
                    title: viewModel.title,
                    episodeLine: viewModel.pauseOverlayEpisodeLine,
                    year: viewModel.pauseOverlayYear,
                    description: viewModel.pauseOverlayDescription,
                    cast: viewModel.pauseOverlayCast,
                    logoURL: viewModel.pauseOverlayLogoURL
                )
                .transition(.opacity)
                .zIndex(2)
            }

            if viewModel.showSkipSegmentCard, let interval = viewModel.activeSkipInterval {
                Button(action: { viewModel.skipActiveInterval() }) {
                    SkipSegmentOverlay(
                        interval: interval,
                        countdown: viewModel.skipSegmentCountdown,
                        isFocused: skipSegmentFocused
                    )
                }
                .buttonStyle(PosterCardButtonStyle())
                .focusEffectDisabledIfAvailable()
                .focused($skipSegmentFocused)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(.leading, 60)
                .padding(.bottom, viewModel.showControls ? 200 : 54)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(3)
            }

            // Next-episode prompt, shown near the end. It auto-hides like the skip
            // card, returns with the transport controls, and advances only when
            // the user selects it.
            if viewModel.showNextEpisodeCard, let next = viewModel.nextEpisode {
                Button(action: { viewModel.playNextEpisode() }) {
                    NextEpisodeOverlay(
                        episode: next,
                        countdown: viewModel.nextEpisodeCountdown,
                        isAdvancing: viewModel.isAdvancingEpisode,
                        isFocused: nextEpisodeFocused
                    )
                }
                .buttonStyle(PosterCardButtonStyle())
                .focusEffectDisabledIfAvailable()
                .focused($nextEpisodeFocused)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(.trailing, 60)
                .padding(.bottom, viewModel.showControls ? 200 : 54)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(3)
            }

            // Kept mounted (not gated by an `if`) so the hide animates too: removing
            // a view that holds tvOS focus makes the focus engine finalize the
            // removal before the transition can play, so only the appear would
            // animate. Animating opacity/scale on a mounted view sidesteps that —
            // focusability is gated inside PlayerControls so focus still hands off
            // cleanly to the remote-input overlay when hidden.
            PlayerControls(
                viewModel: viewModel,
                isSkipSegmentFocused: skipSegmentFocused,
                isNextEpisodeFocused: nextEpisodeFocused,
                onFocusSkipSegment: { focusSkipSegment() },
                onFocusNextEpisode: { focusNextEpisode() }
            )
                .opacity(viewModel.showControls && !viewModel.showSettingsPanel && !viewModel.isScrubbing && !viewModel.showPauseOverlay ? 1 : 0)
                .scaleEffect(viewModel.showControls && !viewModel.isScrubbing && !viewModel.showPauseOverlay ? 1 : 0.95)
                .allowsHitTesting(viewModel.showControls && !viewModel.showSettingsPanel && !viewModel.isScrubbing && !viewModel.showPauseOverlay)
                .animation(.playerControls, value: viewModel.showControls)
                .animation(.playerControls, value: viewModel.showSettingsPanel)
                .animation(.playerControls, value: viewModel.isScrubbing)
                .animation(.playerControls, value: viewModel.showPauseOverlay)

            // Settings panel (subtitles / audio / speed), over the dimmed video.
            if viewModel.showSettingsPanel {
                PlayerSettingsPanel(viewModel: viewModel) {
                    viewModel.showSettingsPanel = false
                }
                .transition(.opacity)
                .zIndex(2)
            }

            // Episodes / Sources side panels.
            if viewModel.sidePanel == .episodes {
                PlayerEpisodesPanel(viewModel: viewModel)
                    .zIndex(7)
            } else if viewModel.sidePanel == .sources {
                PlayerSourcesPanel(viewModel: viewModel)
                    .zIndex(7)
            }

            #if DEBUG
            if viewModel.isPlaybackDebugHUDVisible,
               let info = viewModel.playbackDebugInfo {
                PlaybackDebugHUD(
                    info: info,
                    reason: viewModel.playbackDebugReason
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
                .zIndex(100)
            }
            #endif
        }
        .animation(.playerControls, value: viewModel.showSettingsPanel)
        .animation(.playerControls, value: viewModel.showNextEpisodeCard)
        .animation(.playerControls, value: viewModel.showSkipSegmentCard)
        .animation(.easeOut(duration: 0.16), value: viewModel.isScrubbing)
        .animation(.easeOut(duration: 0.16), value: viewModel.peekVisible)
        .animation(.easeOut(duration: 0.16), value: viewModel.pendingSeekDelta != 0)
        .animation(.easeOut(duration: 0.2), value: viewModel.isSwitchingSource)
        .animation(.easeOut(duration: 0.2), value: viewModel.playerToast)
        .animation(.easeOut(duration: 0.22), value: viewModel.showPauseOverlay)
        .animation(.easeOut(duration: 0.22), value: viewModel.sidePanel)
        .onAppear {
            // Hold for the full player session (not only .playing/.buffering).
            // Status flicker previously re-enabled Sleep After mid-watch.
            PlaybackWakeLock.acquire()
            viewModel.load(url: url, meta: meta, subtitle: subtitle, externalSubtitles: externalSubtitles, resumeFrom: resumeFrom)
            if subtitle != PlaybackMarkers.trailerSubtitle {
                viewModel.fetchExternalSubtitles(
                    contentId: subtitleContentId,
                    type: meta.isSeries ? "series" : meta.type
                )
            }
            viewModel.reloadCurrentStream = reloadCurrentStream
            viewModel.fetchPlaybackSources = fetchPlaybackSources
            viewModel.resolvePlaybackStream = resolvePlaybackStream
            if let resolveNextStream {
                viewModel.configureNextEpisode(
                    episodes: episodes,
                    current: currentEpisode,
                    autoPlayEnabled: autoPlayNextEnabled,
                    resolver: resolveNextStream
                )
            }
        }
        .onDisappear {
            PlaybackWakeLock.release()
            viewModel.shutdown()
        }
        .onChange(of: viewModel.status) { status in
            // Keep reasserting while the player is up — never re-enable sleep
            // based on transient status (pause/buffer/error) mid-session.
            PlaybackWakeLock.reassert()
            if status == .playing, !didReportPlaybackStarted {
                didReportPlaybackStarted = true
                onPlaybackStarted?()
            }
            guard status == .ended,
                  !didHandleFinished,
                  let onFinished else {
                return
            }
            didHandleFinished = true
            onFinished()
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                PlaybackWakeLock.reassert()
            }
        }
        .onChange(of: viewModel.showControls) { isVisible in
            if viewModel.sidePanel != nil {
                remoteInputFocused = false
                nextEpisodeFocused = false
                skipSegmentFocused = false
                return
            }
            if isVisible, !viewModel.isScrubbing, !viewModel.showPauseOverlay {
                remoteInputFocused = false
                nextEpisodeFocused = false
                skipSegmentFocused = false
            } else if viewModel.isScrubbing || viewModel.showPauseOverlay {
                focusRemoteInput()
            } else if viewModel.showNextEpisodeCard {
                focusNextEpisode()
            } else if viewModel.showSkipSegmentCard {
                focusSkipSegment()
            } else {
                focusRemoteInput()
            }
        }
        .onChange(of: viewModel.sidePanel) { panel in
            if panel != nil {
                remoteInputFocused = false
                nextEpisodeFocused = false
                skipSegmentFocused = false
            }
        }
        .onChange(of: viewModel.showPauseOverlay) { visible in
            if visible {
                nextEpisodeFocused = false
                skipSegmentFocused = false
                focusRemoteInput()
            }
        }
        .onChange(of: viewModel.isScrubbing) { scrubbing in
            if scrubbing {
                nextEpisodeFocused = false
                skipSegmentFocused = false
                focusRemoteInput()
            } else if viewModel.showControls {
                remoteInputFocused = false
            } else {
                focusRemoteInput()
            }
        }
        .onChange(of: viewModel.showNextEpisodeCard) { visible in
            guard !viewModel.showControls else { return }
            if visible {
                focusNextEpisode()
            } else if viewModel.showSkipSegmentCard {
                focusSkipSegment()
            } else {
                focusRemoteInput()
            }
        }
        .onChange(of: viewModel.showSkipSegmentCard) { visible in
            guard !viewModel.showControls, !viewModel.showNextEpisodeCard else { return }
            if visible {
                focusSkipSegment()
            } else {
                skipSegmentFocused = false
                focusRemoteInput()
            }
        }
        .onPlayPauseCommand {
            viewModel.togglePlayPause()
        }
        .onMoveCommand { direction in
            // The Episodes/Sources sheet exclusively owns directional input.
            // Do not let list navigation also seek or reveal player controls.
            guard viewModel.sidePanel == nil else { return }

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
            onBack()
        }
    }

    private var subtitleContentId: String {
        if let currentEpisode { return currentEpisode.id }
        if meta.isSeries, let numbers = EpisodeTagResolver.episodeNumbers(in: subtitle) {
            return "\(meta.id):\(numbers.season):\(numbers.episode)"
        }
        return meta.id
    }

    private func focusRemoteInput() {
        DispatchQueue.main.async {
            remoteInputFocused = true
        }
    }

    private func focusNextEpisode() {
        DispatchQueue.main.async {
            nextEpisodeFocused = true
        }
    }

    private func focusSkipSegment() {
        DispatchQueue.main.async {
            skipSegmentFocused = true
        }
    }
}

#if DEBUG
private struct PlaybackDebugHUD: View {
    let info: PlaybackDebugInfo
    let reason: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 9) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 10, height: 10)
                Text("PLAYBACK DEBUG")
                    .font(.system(size: 22, weight: .bold, design: .monospaced))
                    .foregroundStyle(.green)
            }

            ForEach(info.screenLines, id: \.self) { line in
                Text(line)
                    .font(.system(size: 19, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
            }

            if !reason.isEmpty {
                Text("POLICY   \(reason)")
                    .font(.system(size: 17, weight: .medium, design: .monospaced))
                    .foregroundStyle(.yellow)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .frame(maxWidth: 920, alignment: .leading)
        .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(.white.opacity(0.18), lineWidth: 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.leading, 54)
        .padding(.top, 42)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Playback debug information")
    }
}
#endif

// Hosts the libmpv UIViewController (owns the CAMetalLayer surface).
struct MPVVideoSurface: UIViewControllerRepresentable {
    let controller: MPVPlayerViewController

    func makeUIViewController(context: Context) -> MPVPlayerViewController {
        controller
    }

    func updateUIViewController(_ uiViewController: MPVPlayerViewController, context: Context) {}
}

/// Hosts AetherEngine's `AetherPlayerView` for native / software decode.
struct AetherPlayerSurface: UIViewControllerRepresentable {
    let controller: AetherPlaybackController

    func makeUIViewController(context: Context) -> AetherPlaybackController {
        controller
    }

    func updateUIViewController(_ uiViewController: AetherPlaybackController, context: Context) {}
}

private struct RemoteSeekPressCatcher: UIViewControllerRepresentable {
    let isActive: Bool
    let onBeginBackward: () -> Void
    let onBeginForward: () -> Void
    let onEnd: () -> Void

    func makeUIViewController(context: Context) -> RemoteSeekPressViewController {
        let controller = RemoteSeekPressViewController()
        controller.onBeginBackward = onBeginBackward
        controller.onBeginForward = onBeginForward
        controller.onEnd = onEnd
        controller.setActive(isActive)
        return controller
    }

    func updateUIViewController(_ controller: RemoteSeekPressViewController, context: Context) {
        controller.onBeginBackward = onBeginBackward
        controller.onBeginForward = onBeginForward
        controller.onEnd = onEnd
        controller.setActive(isActive)
    }
}

private final class RemoteSeekPressViewController: UIViewController {
    enum Direction {
        case backward
        case forward
    }

    var onBeginBackward: () -> Void = {}
    var onBeginForward: () -> Void = {}
    var onEnd: () -> Void = {}

    private var activeDirection: Direction?
    private var acceptsNewHolds = false
    private weak var gestureWindow: UIWindow?
    private lazy var backwardHoldRecognizer = makeHoldRecognizer(
        pressType: .leftArrow,
        action: #selector(handleBackwardHold(_:))
    )
    private lazy var forwardHoldRecognizer = makeHoldRecognizer(
        pressType: .rightArrow,
        action: #selector(handleForwardHold(_:))
    )

    /// Window-level press recognizers receive Siri Remote holds even when a
    /// focused SwiftUI view owns the responder chain. A sibling view controller's
    /// `pressesBegan` is not guaranteed to receive those presses.
    func setActive(_ active: Bool) {
        acceptsNewHolds = active
        updateRecognizerState()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        installRecognizersIfNeeded()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        uninstallRecognizers()
    }

    private func makeHoldRecognizer(pressType: UIPress.PressType, action: Selector) -> UILongPressGestureRecognizer {
        let recognizer = UILongPressGestureRecognizer(target: self, action: action)
        recognizer.allowedPressTypes = [NSNumber(value: pressType.rawValue)]
        recognizer.minimumPressDuration = 0.35
        recognizer.cancelsTouchesInView = true
        recognizer.isEnabled = false
        return recognizer
    }

    private func installRecognizersIfNeeded() {
        guard let window = view.window, gestureWindow !== window else { return }
        uninstallRecognizers()
        window.addGestureRecognizer(backwardHoldRecognizer)
        window.addGestureRecognizer(forwardHoldRecognizer)
        gestureWindow = window
        updateRecognizerState()
    }

    private func uninstallRecognizers() {
        if activeDirection != nil {
            activeDirection = nil
            onEnd()
        }
        gestureWindow?.removeGestureRecognizer(backwardHoldRecognizer)
        gestureWindow?.removeGestureRecognizer(forwardHoldRecognizer)
        gestureWindow = nil
    }

    private func updateRecognizerState() {
        // Once a hold starts, keep its recognizer alive through the brief focus
        // handoff that occurs when seeking reveals the controls.
        let enabled = acceptsNewHolds || activeDirection != nil
        backwardHoldRecognizer.isEnabled = enabled
        forwardHoldRecognizer.isEnabled = enabled
    }

    @objc private func handleBackwardHold(_ recognizer: UILongPressGestureRecognizer) {
        handleHold(recognizer, direction: .backward)
    }

    @objc private func handleForwardHold(_ recognizer: UILongPressGestureRecognizer) {
        handleHold(recognizer, direction: .forward)
    }

    private func handleHold(_ recognizer: UILongPressGestureRecognizer, direction: Direction) {
        switch recognizer.state {
        case .began:
            guard acceptsNewHolds, activeDirection == nil else { return }
            activeDirection = direction
            switch direction {
            case .backward: onBeginBackward()
            case .forward: onBeginForward()
            }
        case .ended, .cancelled, .failed:
            guard activeDirection == direction else { return }
            activeDirection = nil
            onEnd()
            updateRecognizerState()
        default:
            break
        }
    }
}
