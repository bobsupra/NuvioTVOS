import SwiftUI
import UIKit

struct PlayerView: View {
    @StateObject private var viewModel = PlayerViewModel()

    let url: URL
    let meta: NuvioMeta
    let subtitle: String
    let externalSubtitles: [NuvioSubtitle]
    let resumeFrom: Double?
    /// Episode context for the Netflix-style auto-play. Empty for movies/trailers.
    var episodes: [NuvioVideo] = []
    var currentEpisode: NuvioVideo? = nil
    var autoPlayNextEnabled: Bool = true
    /// Resolves a next episode into a ready-to-play stream (add-on fetch + smart
    /// selection), supplied by the app layer. Nil disables auto-advance.
    var resolveNextStream: ((NuvioVideo) async -> PreparedNextStream?)? = nil
    /// Re-resolves a fresh stream for the *current* title/episode, used to
    /// silently recover from an expired link. Nil disables auto-reload.
    var reloadCurrentStream: (() async -> PreparedNextStream?)? = nil
    var onFinished: (() -> Void)? = nil
    var onBack: () -> Void

    @State private var didHandleFinished = false
    @FocusState private var remoteInputFocused: Bool
    @FocusState private var nextEpisodeFocused: Bool
    @FocusState private var skipSegmentFocused: Bool

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // libmpv renders into the Metal layer owned by this controller.
            MPVVideoSurface(controller: viewModel.playerController)
                .ignoresSafeArea()

            RemoteSeekPressCatcher(
                // Active when the controls are hidden, or when they're up and the
                // timeline scrubber holds focus — so a held left/right keeps
                // seeking until release in both states. Never while the play/
                // settings buttons are focused (there left/right navigates) or
                // the settings panel is open. Passed as a plain Bool (not a
                // closure) so `updateUIViewController` runs on every change and
                // the catcher can re-grab first responder — the SwiftUI focus
                // engine hands first responder to the focused control otherwise,
                // and a sibling controller would silently stop receiving presses.
                isActive: !viewModel.showSettingsPanel
                    && (!viewModel.showControls || viewModel.isTimelineFocused),
                onBeginBackward: { viewModel.beginRepeatingSkipBackward() },
                onBeginForward: { viewModel.beginRepeatingSkipForward() },
                onEnd: { viewModel.stopRepeatingSkip() }
            )
            .frame(width: 1, height: 1)
            .accessibilityHidden(true)

            switch viewModel.status {
            case .buffering, .idle:
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .scaleEffect(2)
                    .padding(48)
                    .glassCircle()
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
                .focusable(!viewModel.showControls && !viewModel.showNextEpisodeCard && !viewModel.showSkipSegmentCard)
                .focused($remoteInputFocused)
                .onTapGesture { viewModel.revealControls() }
                .accessibilityHidden(true)

            if viewModel.showSkipSegmentCard, let interval = viewModel.activeSkipInterval {
                SkipSegmentOverlay(
                    interval: interval,
                    countdown: viewModel.skipSegmentCountdown,
                    isFocused: skipSegmentFocused,
                    onSkip: { viewModel.skipActiveInterval() }
                )
                .onTapGesture { viewModel.skipActiveInterval() }
                .focusable(true)
                .focused($skipSegmentFocused)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(.leading, 60)
                .padding(.bottom, viewModel.showControls ? 200 : 54)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(3)
            }

            // Netflix-style next-episode prompt, shown near the end. Visible even
            // when the transport controls are up (raised above them); focusable
            // only when the controls are down so it doesn't fight them for focus.
            // Left/Right still fast-forward, which cancels the countdown.
            if viewModel.showNextEpisodeCard, let next = viewModel.nextEpisode {
                NextEpisodeOverlay(
                    episode: next,
                    countdown: viewModel.nextEpisodeCountdown,
                    isAdvancing: viewModel.isAdvancingEpisode,
                    isFocused: nextEpisodeFocused,
                    onPlay: { viewModel.playNextEpisode() }
                )
                .focusable(true)
                .focused($nextEpisodeFocused)
                .onTapGesture { viewModel.playNextEpisode() }
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
                .opacity(viewModel.showControls && !viewModel.showSettingsPanel ? 1 : 0)
                .scaleEffect(viewModel.showControls ? 1 : 0.95)
                .allowsHitTesting(viewModel.showControls && !viewModel.showSettingsPanel)
                .animation(.playerControls, value: viewModel.showControls)
                .animation(.playerControls, value: viewModel.showSettingsPanel)

            // Settings panel (subtitles / audio / speed), over the dimmed video.
            if viewModel.showSettingsPanel {
                PlayerSettingsPanel(viewModel: viewModel) {
                    viewModel.showSettingsPanel = false
                }
                .transition(.opacity)
                .zIndex(2)
            }
        }
        .animation(.playerControls, value: viewModel.showSettingsPanel)
        .animation(.playerControls, value: viewModel.showNextEpisodeCard)
        .animation(.playerControls, value: viewModel.showSkipSegmentCard)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            viewModel.load(url: url, meta: meta, subtitle: subtitle, externalSubtitles: externalSubtitles, resumeFrom: resumeFrom)
            if subtitle != PlaybackMarkers.trailerSubtitle {
                viewModel.fetchExternalSubtitles(
                    contentId: subtitleContentId,
                    type: meta.isSeries ? "series" : meta.type
                )
            }
            viewModel.reloadCurrentStream = reloadCurrentStream
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
            UIApplication.shared.isIdleTimerDisabled = false
            viewModel.shutdown()
        }
        .onChange(of: viewModel.status) { status in
            UIApplication.shared.isIdleTimerDisabled = (status == .playing || status == .buffering)
            guard status == .ended,
                  !didHandleFinished,
                  let onFinished else {
                return
            }
            didHandleFinished = true
            onFinished()
        }
        .onChange(of: viewModel.showControls) { isVisible in
            if isVisible {
                remoteInputFocused = false
                nextEpisodeFocused = false
                skipSegmentFocused = false
            } else if viewModel.showNextEpisodeCard {
                focusNextEpisode()
            } else if viewModel.showSkipSegmentCard {
                focusSkipSegment()
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
            guard !viewModel.showControls else { return }
            switch direction {
            case .left:
                viewModel.skipBackward()
            case .right:
                viewModel.skipForward()
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
            remoteInputFocused = false
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

// Hosts the libmpv UIViewController (owns the CAMetalLayer surface).
struct MPVVideoSurface: UIViewControllerRepresentable {
    let controller: MPVPlayerViewController

    func makeUIViewController(context: Context) -> MPVPlayerViewController {
        controller
    }

    func updateUIViewController(_ uiViewController: MPVPlayerViewController, context: Context) {}
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
        // Re-assert on every SwiftUI update: when a control gains focus the focus
        // engine takes first responder, so a sibling catcher has to grab it back
        // to keep receiving the held left/right presses on the device.
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
    private var isActive = false

    override var canBecomeFirstResponder: Bool { isActive }

    /// Enable/disable seek interception and (re)claim first responder so held
    /// directional presses route here instead of the focused SwiftUI control.
    func setActive(_ active: Bool) {
        isActive = active
        if active {
            if !isFirstResponder { becomeFirstResponder() }
        } else {
            if activeDirection != nil {
                activeDirection = nil
                onEnd()
            }
            if isFirstResponder { resignFirstResponder() }
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if isActive { becomeFirstResponder() }
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        if parent != nil, isActive {
            becomeFirstResponder()
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard activeDirection == nil,
              isActive,
              let direction = seekDirection(in: presses) else {
            super.pressesBegan(presses, with: event)
            return
        }

        activeDirection = direction
        switch direction {
        case .backward: onBeginBackward()
        case .forward: onBeginForward()
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if activeDirection != nil, seekDirection(in: presses) != nil {
            activeDirection = nil
            onEnd()
        } else {
            super.pressesEnded(presses, with: event)
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if activeDirection != nil {
            activeDirection = nil
            onEnd()
        } else {
            super.pressesCancelled(presses, with: event)
        }
    }

    private func seekDirection(in presses: Set<UIPress>) -> Direction? {
        if presses.contains(where: { $0.type == .leftArrow }) { return .backward }
        if presses.contains(where: { $0.type == .rightArrow }) { return .forward }
        return nil
    }
}
