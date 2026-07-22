import SwiftUI

private enum PlayerControlFocus: Hashable {
    case play
    case episodes
    case sources
    case settings
    case timeline
}

struct PlayerControls: View {
    @ObservedObject var viewModel: PlayerViewModel
    var isSkipSegmentFocused: Bool = false
    var isNextEpisodeFocused: Bool = false
    var onFocusSkipSegment: () -> Void = {}
    var onFocusNextEpisode: () -> Void = {}

    @FocusState private var focusedControl: PlayerControlFocus?

    private var progress: CGFloat {
        let duration = max(viewModel.clock.duration > 0 ? viewModel.clock.duration : viewModel.time.duration, 0.001)
        let position = (viewModel.clock.duration > 0 ? viewModel.clock.position : viewModel.time.current)
            + viewModel.pendingSeekDelta
        return CGFloat(min(max(position / duration, 0), 1))
    }

    private var isShowingPause: Bool {
        viewModel.status == .playing
    }

    private var displayCurrent: Double {
        let position = (viewModel.clock.duration > 0 ? viewModel.clock.position : viewModel.time.current)
            + viewModel.pendingSeekDelta
        let duration = viewModel.clock.duration > 0 ? viewModel.clock.duration : viewModel.time.duration
        return min(max(position, 0), max(duration, 0))
    }

    private var displayRemaining: Double {
        let duration = viewModel.clock.duration > 0 ? viewModel.clock.duration : viewModel.time.duration
        return max(0, duration - displayCurrent)
    }

    var body: some View {
        GlassControlsContainer {
            VStack {
                topBar
                Spacer()
                bottomControls
            }
        }
        .onChange(of: viewModel.showSettingsPanel) { isPresented in
            if !isPresented, viewModel.showControls {
                DispatchQueue.main.async { focusedControl = .settings }
            }
        }
        .onAppear {
            DispatchQueue.main.async { focusedControl = .timeline }
        }
        .onChange(of: viewModel.showControls) { isVisible in
            // Don't steal focus while the pause metadata sheet owns the remote.
            if isVisible,
               !viewModel.showPauseOverlay,
               !isSkipSegmentFocused,
               !isNextEpisodeFocused {
                DispatchQueue.main.async { focusedControl = .timeline }
            }
        }
        .onChange(of: viewModel.showPauseOverlay) { visible in
            if visible { focusedControl = nil }
        }
        .onChange(of: isSkipSegmentFocused) { isFocused in
            if isFocused { focusedControl = nil }
        }
        .onChange(of: isNextEpisodeFocused) { isFocused in
            if isFocused { focusedControl = nil }
        }
        .onChange(of: focusedControl) { newControl in
            // Keep this in lockstep with focus so hold-to-seek gating is correct
            // even before the next render cycle.
            viewModel.isTimelineFocused = (newControl == .timeline)
            // Keep chrome pinned while browsing buttons that open another
            // panel. Play/Pause behaves like the timeline and may auto-hide.
            if let newControl,
               newControl != .timeline,
               newControl != .play {
                viewModel.setControlsAutoHideSuspended(true)
            } else if newControl == .timeline || newControl == .play {
                viewModel.setControlsAutoHideSuspended(false)
                if viewModel.status == .playing {
                    viewModel.scheduleControlsHide()
                }
            }
        }
        .onDisappear {
            viewModel.isTimelineFocused = false
            viewModel.setControlsAutoHideSuspended(false)
        }
    }

    /// Transport + timeline are focusable whenever chrome is up. Do not gate on
    /// `focusedControl != .timeline` — toggling `.focusable` when moving between
    /// buttons left Select dead after visiting settings/episodes/sources.
    private var controlsInteractable: Bool {
        viewModel.showControls
            && !viewModel.showPauseOverlay
            && !viewModel.showSettingsPanel
            && viewModel.sidePanel == nil
    }

    /// Left-to-right order of currently visible transport buttons.
    private var transportFocusOrder: [PlayerControlFocus] {
        var order: [PlayerControlFocus] = [.play]
        if viewModel.canShowEpisodesPanel { order.append(.episodes) }
        if viewModel.canShowSourcesPanel { order.append(.sources) }
        order.append(.settings)
        return order
    }

    /// Settings-style flash prevention: while the progress bar owns focus, only
    /// Play stays focusable in the transport row. tvOS spatial focus lands on the
    /// geometric nearest *focusable* control — with a single candidate it goes
    /// straight to Play, so Episodes/Sources never receive a one-frame flash.
    /// Once any transport button is focused, every visible button is focusable
    /// again so left/right still walks the full row.
    private func isTransportButtonFocusable(_ key: PlayerControlFocus) -> Bool {
        guard controlsInteractable else { return false }
        if focusedControl == .timeline || focusedControl == nil {
            return key == .play
        }
        return true
    }

    private func moveFocus(to control: PlayerControlFocus) {
        // tvOS often applies spatial focus *before* `onMoveCommand` runs (and
        // may also apply it after). Force the intended control now and re-assert
        // on the next runloop so native geometry cannot keep a wrong target
        // (e.g. play → settings skipping streams).
        focusedControl = control
        DispatchQueue.main.async {
            focusedControl = control
        }
    }

    /// Navigate from the control that *received* the move — not `focusedControl`,
    /// which may already have been updated by the spatial focus engine.
    private func handleMove(_ direction: MoveCommandDirection, from origin: PlayerControlFocus) {
        guard !isSkipSegmentFocused, !isNextEpisodeFocused else { return }
        guard controlsInteractable else { return }

        switch direction {
        case .up:
            if origin == .timeline {
                moveFocus(to: .play)
            }
        case .down:
            if origin != .timeline {
                moveFocus(to: .timeline)
            }
        case .left:
            if origin == .timeline {
                viewModel.nudgeSeek(-Double(viewModel.seekStepSeconds))
                // Keep focus pinned while seeking / hold-to-seek.
                moveFocus(to: .timeline)
            } else if let index = transportFocusOrder.firstIndex(of: origin),
                      index > 0 {
                moveFocus(to: transportFocusOrder[index - 1])
            }
        case .right:
            if origin == .timeline {
                viewModel.nudgeSeek(Double(viewModel.seekStepSeconds))
                moveFocus(to: .timeline)
            } else if let index = transportFocusOrder.firstIndex(of: origin),
                      index < transportFocusOrder.count - 1 {
                moveFocus(to: transportFocusOrder[index + 1])
            }
        default:
            break
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(viewModel.title)
                        .font(.system(size: 38, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)

                    if !viewModel.subtitle.isEmpty {
                        Text(viewModel.subtitle)
                            .font(.system(size: 21, weight: .medium))
                            .foregroundColor(.white.opacity(0.68))
                            .lineLimit(1)
                    }
                }

                Spacer()
            }
        }
        .padding(.horizontal, 60)
        .padding(.top, 34)
        .shadow(color: .black.opacity(0.82), radius: 18, x: 0, y: 6)
    }

    // MARK: - Bottom controls

    private var bottomControls: some View {
        VStack(alignment: .leading, spacing: 18) {
            transportRow
            timelineBar
        }
        .padding(.horizontal, 60)
        .padding(.bottom, 54)
    }

    private var transportRow: some View {
        HStack(spacing: 18) {
            glassIconButton(
                size: 70,
                iconSize: 30,
                focusKey: .play,
                isFocused: focusedControl == .play,
                isEmphasized: isShowingPause
            ) {
                viewModel.togglePlayPause()
            } icon: {
                ZStack {
                    Image(systemName: "play.fill")
                        .opacity(isShowingPause ? 0 : 1)
                    Image(systemName: "pause.fill")
                        .opacity(isShowingPause ? 1 : 0)
                }
            }
            .id("play_pause_button")

            Spacer()

            if viewModel.canShowEpisodesPanel {
                glassIconButton(
                    size: 70,
                    iconSize: 28,
                    focusKey: .episodes,
                    isFocused: focusedControl == .episodes,
                    isEmphasized: false
                ) {
                    viewModel.openSidePanel(.episodes)
                } icon: {
                    Image(systemName: "list.bullet")
                }
                .id("episodes_button")
            }

            if viewModel.canShowSourcesPanel {
                glassIconButton(
                    size: 70,
                    iconSize: 28,
                    focusKey: .sources,
                    isFocused: focusedControl == .sources,
                    isEmphasized: false
                ) {
                    viewModel.openSidePanel(.sources)
                } icon: {
                    Image(systemName: "square.stack.3d.up")
                }
                .id("sources_button")
            }

            glassIconButton(
                size: 70,
                iconSize: 30,
                focusKey: .settings,
                isFocused: focusedControl == .settings,
                isEmphasized: false
            ) {
                viewModel.showSettingsPanel = true
            } icon: {
                Image(systemName: "ellipsis")
            }
            .id("settings_button")
        }
        .shadow(color: .black.opacity(0.74), radius: 20, x: 0, y: 8)
    }

    private func glassIconButton<Icon: View>(
        size: CGFloat,
        iconSize: CGFloat,
        focusKey: PlayerControlFocus,
        isFocused: Bool,
        isEmphasized: Bool,
        action: @escaping () -> Void,
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        // Use a real Button action for Siri Remote Select. Do not stack an extra
        // `.focusable(...)` on the Button — toggling that when focus leaves the
        // timeline (or moves settings → play) can leave the control visually
        // focused while Select no longer activates the action.
        //
        // Mirror Settings category pills: `.disabled` removes a button from the
        // spatial focus graph without changing appearance (PosterCardButtonStyle
        // ignores isEnabled). That prevents the Episodes flash on up-from-timeline.
        Button {
            focusedControl = focusKey
            action()
        } label: {
            icon()
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundColor(isFocused ? .black : .white)
                .frame(width: size, height: size)
                .modifier(PlayerGlassCircleButtonBackground(filled: isFocused))
                .shadow(color: .black.opacity(0.82), radius: 14, x: 0, y: 7)
                .frame(width: size, height: size)
                .clipShape(Circle())
                .contentShape(Circle())
                .shadow(
                    color: .white.opacity(isEmphasized ? 0.74 : 0.42),
                    radius: isFocused ? 18 : 10,
                    x: 0,
                    y: 0
                )
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($focusedControl, equals: focusKey)
        .disabled(!isTransportButtonFocusable(focusKey))
        .focusEffectDisabledIfAvailable()
        .onMoveCommand { direction in
            // Route from this button's key so a native spatial jump across the
            // row Spacer cannot make us advance from the wrong origin (which
            // skipped sources / never returned up-to-play).
            handleMove(direction, from: focusKey)
        }
        .scaleEffect(isFocused ? 1.06 : 1.0)
        .animation(.easeOut(duration: 0.14), value: isFocused)
    }

    // MARK: - Timeline

    private var isTimelineFocused: Bool {
        focusedControl == .timeline
    }

    private var timelineBar: some View {
        VStack(spacing: 8) {
            let duration = max(viewModel.clock.duration > 0 ? viewModel.clock.duration : viewModel.time.duration, 0.001)
            let buffered = viewModel.clock.buffered
            PlayerProgressTrack(
                played: Double(progress),
                buffered: buffered / duration,
                height: isTimelineFocused ? 10 : 7,
                showThumb: isTimelineFocused,
                emphasized: isTimelineFocused,
                glassTrack: true
            )
            .frame(height: 14)

            HStack {
                Text(PlayerTime.formatted(time: displayCurrent))
                if viewModel.pendingSeekDelta != 0 {
                    Text(PlayerTimeFormat.signedDelta(viewModel.pendingSeekDelta))
                        .foregroundColor(.white.opacity(0.85))
                }
                Spacer()
                Text("-" + PlayerTime.formatted(time: displayRemaining))
            }
            .font(.system(size: 22, weight: .bold))
            .foregroundColor(.white.opacity(isTimelineFocused ? 0.82 : 0.54))
        }
        .focusable(
            viewModel.showControls
                && !viewModel.showSettingsPanel
                && !viewModel.isScrubbing
                && !viewModel.showPauseOverlay
        )
        .focused($focusedControl, equals: .timeline)
        .focusEffectDisabledIfAvailable()
        .onTapGesture { viewModel.beginScrub() }
        .onMoveCommand { direction in
            // Timeline owns move while focused so hold-to-seek cannot promote
            // focus onto the transport buttons. Always route from `.timeline`
            // even if spatial focus already hopped to a transport button.
            handleMove(direction, from: .timeline)
        }
        .shadow(color: .black.opacity(0.82), radius: 16, x: 0, y: 7)
        .animation(.easeOut(duration: 0.14), value: focusedControl)
        .animation(.easeOut(duration: 0.12), value: viewModel.pendingSeekDelta)
    }
}

// MARK: - Liquid glass appearance

extension Animation {
    /// Fluid spring that drives the player controls materialize / dematerialize.
    static var playerControls: Animation {
        .spring(response: 0.42, dampingFraction: 0.86)
    }
}

// MARK: - Liquid Glass helpers
//
// Liquid Glass (`glassEffect`, `GlassEffectContainer`) ships in tvOS 26+. The app
// deploys back to tvOS 15.1, so every use is availability-gated with an
// `.ultraThinMaterial` fallback that keeps the same shapes on older systems.

/// Wraps content in a `GlassEffectContainer` on tvOS 26+ so adjacent glass
/// surfaces blend/morph together; a plain passthrough otherwise.
struct GlassControlsContainer<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        if #available(tvOS 26.0, *) {
            GlassEffectContainer(spacing: 28) { content }
        } else {
            content
        }
    }
}

extension View {
    @ViewBuilder
    func glassCircle() -> some View {
        if #available(tvOS 26.0, *) {
            glassEffect(.regular.interactive(), in: .circle)
        } else {
            background(.ultraThinMaterial, in: Circle())
        }
    }

    @ViewBuilder
    func glassCircleSurface() -> some View {
        if #available(tvOS 26.0, *) {
            glassEffect(.regular, in: .circle)
        } else {
            background(.ultraThinMaterial, in: Circle())
        }
    }

    @ViewBuilder
    func glassCapsule() -> some View {
        if #available(tvOS 26.0, *) {
            glassEffect(.regular.interactive(), in: .capsule)
        } else {
            background(.ultraThinMaterial, in: Capsule())
        }
    }

    @ViewBuilder
    func glassRoundedRect(cornerRadius: CGFloat) -> some View {
        if #available(tvOS 26.0, *) {
            glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }

}

// MARK: - Next episode card
//
// Netflix-style auto-play prompt shown near the end of an episode. Liquid Glass
// card with the upcoming episode's thumbnail, a live countdown when auto-play is
// armed, and a Play button that advances immediately.
struct NextEpisodeOverlay: View {
    let episode: NuvioVideo
    /// Seconds left on the auto-play countdown; nil when the timer is off or was
    /// cancelled by a fast-forward (manual Play only).
    let countdown: Int?
    let isAdvancing: Bool
    var isFocused: Bool

    private var episodeLine: String {
        "S\(episode.season) E\(episode.episode) • \(episode.title)"
    }

    private var isPlayable: Bool {
        EpisodeReleasePolicy.hasAired(episode.released)
    }

    private var airDateText: String {
        EpisodeReleasePolicy.airDateText(for: episode.released).map { "Airs \($0)" } ?? "Upcoming"
    }

    var body: some View {
        HStack(spacing: 22) {
            thumbnail

            VStack(alignment: .leading, spacing: 4) {
                Text("Next Episode")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundColor(.white.opacity(0.62))
                Text(episodeLine)
                    .font(.system(size: 29, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                if !isPlayable {
                    Text(airDateText)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                } else if let countdown, !isAdvancing {
                    Text("Playing in \(countdown)s")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                        .contentTransition(.numericText())
                }
            }

            Spacer(minLength: 20)

            playButton
        }
        .padding(18)
        .frame(width: 780)
        .glassRoundedRect(cornerRadius: 26)
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(isFocused ? AppFocusOutline.color : Color.white.opacity(0.14), lineWidth: isFocused ? AppFocusOutline.width : 1)
        )
        .shadow(color: .black.opacity(0.55), radius: 22, x: 0, y: 10)
        .animation(.easeInOut(duration: 0.18), value: isFocused)
        .animation(.easeInOut(duration: 0.2), value: countdown)
    }

    private var thumbnail: some View {
        ZStack {
            Color.white.opacity(0.06)
            if let thumb = episode.thumbnail, let url = URL(string: thumb) {
                AsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Image(systemName: "play.rectangle")
                        .font(.system(size: 30))
                        .foregroundColor(.white.opacity(0.4))
                }
            } else {
                Image(systemName: "play.rectangle")
                    .font(.system(size: 30))
                    .foregroundColor(.white.opacity(0.4))
            }
        }
        .frame(width: 158, height: 90)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var playButton: some View {
        HStack(spacing: 12) {
            if isAdvancing {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: isFocused ? .black : .white))
                    .scaleEffect(0.9)
                Text("Starting…")
            } else {
                Image(systemName: isPlayable ? "play.fill" : "calendar")
                    .font(.system(size: 22, weight: .bold))
                Text(isPlayable ? (countdown != nil ? "Play Now" : "Play") : "Not Yet")
            }
        }
        .font(.system(size: 24, weight: .semibold))
        .foregroundColor(isFocused && isPlayable ? .black : .white)
        .padding(.horizontal, 30)
        .padding(.vertical, 16)
        .background {
            if isFocused && isPlayable {
                Capsule().fill(Color.white)
            } else {
                Capsule().fill(Color.white.opacity(0.14))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.4), lineWidth: 1))
            }
        }
    }
}

struct SkipSegmentOverlay: View {
    let interval: SkipInterval
    let countdown: Int?
    var isFocused: Bool

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "forward.end.fill")
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(isFocused ? .black : .white)
                .frame(width: 46, height: 46)
                .background {
                    Circle().fill(isFocused ? Color.white : Color.white.opacity(0.14))
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(interval.label)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(.white)
                Text(detailText)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.white.opacity(0.62))
                    .contentTransition(.numericText())
            }

            Spacer(minLength: 10)
        }
        .padding(.leading, 18)
        .padding(.trailing, 20)
        .padding(.vertical, 14)
        .frame(width: 330)
        .glassRoundedRect(cornerRadius: 24)
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(isFocused ? AppFocusOutline.color : Color.white.opacity(0.14), lineWidth: isFocused ? AppFocusOutline.width : 1)
        )
        .shadow(color: .black.opacity(0.55), radius: 22, x: 0, y: 10)
        .animation(.easeInOut(duration: 0.18), value: isFocused)
        .animation(.easeInOut(duration: 0.18), value: countdown)
    }

    private var detailText: String {
        return "Ends at \(PlayerTime.formatted(time: interval.endTime))"
    }
}

private struct PlayerGlassCircleButtonBackground: ViewModifier {
    let filled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if filled {
            content.background(Color.white, in: Circle())
        } else if #available(tvOS 26.0, *) {
            content.glassEffect(.regular, in: Circle())
        } else {
            content.background(.ultraThinMaterial, in: Circle())
        }
    }
}

// MARK: - Player settings panel
//
// Full-screen overlay opened from the controls' ellipsis button. Three pages:
// Subtitles (default — languages / tracks / style, mirroring the iOS app's
// player subtitle screen), Audio, and Speed. Renders over the dimmed video so
// style changes are visible live on the captions behind it.

/// One row of the panel's Subtitles column — an mpv track (embedded or
/// already-loaded external) or an add-on subtitle that loads on demand.
private struct SubtitlePanelOption: Identifiable {
    enum Kind {
        case track(SubtitleTrack)
        case external(NuvioSubtitle)
    }

    let id: String
    let kind: Kind
    let badge: String
    let title: String
    let detail: String?
    let language: String
    let isSelected: Bool
}

/// Maps raw track/addon language values ("en", "eng", "English") onto one
/// display name so both kinds group into a single Languages entry.
private enum SubtitleLanguageDisplay {
    static func name(for raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Unknown" }
        let code = trimmed.lowercased()
            .components(separatedBy: CharacterSet(charactersIn: "-_")).first ?? ""
        if code.count <= 3, code.allSatisfy(\.isLetter),
           let name = Locale.current.localizedString(forLanguageCode: code) {
            return name.prefix(1).uppercased() + name.dropFirst()
        }
        return trimmed.prefix(1).uppercased() + trimmed.dropFirst()
    }
}

struct PlayerSettingsPanel: View {
    @ObservedObject var viewModel: PlayerViewModel
    var onClose: () -> Void

    private enum Tab: String, CaseIterable, Hashable {
        case subtitles = "Subtitles"
        case audio = "Audio"
        case speed = "Speed"
        // Picture / aspect modes temporarily disabled.
        // case picture = "Picture"
    }

    private enum StyleControl: Hashable {
        case delayMinus, delayPlus
        case sizeMinus, sizePlus
        case bold
        case color(String)
        case opacityMinus, opacityPlus
        case outline
    }

    private enum AudioControl: Hashable {
        case delayMinus, delayPlus
        case ampMinus, ampPlus
    }

    private enum Focus: Hashable {
        case tab(Tab)
        case noneRow
        case language(String)
        case option(String)
        case audio(String)
        case audioControl(AudioControl)
        case speed(Float)
        case seekStep(Int)
        case aspect(String)
        case style(StyleControl)
    }

    /// Swatches shown in the Text Color row (white, gray, yellow, blue, red, green).
    private static let palette = ["#FFFFFF", "#C7C7C7", "#F2C94C", "#56CCF2", "#EB5757", "#6FCF97"]

    @State private var tab: Tab = .subtitles
    @State private var selectedLanguage: String?
    @State private var style = SubtitleStyle.current
    @FocusState private var focus: Focus?

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(
                colors: [.black.opacity(0.92), .black.opacity(0.55)],
                startPoint: .leading,
                endPoint: .trailing
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 38) {
                tabBar

                switch tab {
                case .subtitles: subtitlesPage
                case .audio: audioPage
                case .speed: speedPage
                }
            }
            .padding(.horizontal, 90)
            .padding(.top, 64)
            .padding(.bottom, 44)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear {
            style = SubtitleStyle.current
            viewModel.setControlsAutoHideSuspended(true)
            DispatchQueue.main.async {
                if let language = effectiveLanguage {
                    selectedLanguage = language
                    focus = .language(language)
                } else {
                    focus = .noneRow
                }
            }
        }
        .onDisappear {
            viewModel.setControlsAutoHideSuspended(false)
        }
        .onChange(of: focus) { newValue in
            // Focusing a language filters the middle column live.
            if case .language(let language) = newValue {
                selectedLanguage = language
            }
        }
        .focusSection()
        .onExitCommand { onClose() }
    }

    // MARK: Tabs

    private var tabBar: some View {
        HStack(spacing: 22) {
            ForEach(Tab.allCases, id: \.self) { item in
                let isFocused = focus == .tab(item)
                let isSelected = tab == item
                Button {
                    tab = item
                } label: {
                    Text(item.rawValue)
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundColor(isSelected || isFocused ? .black : .white.opacity(0.66))
                        .padding(.horizontal, 30)
                        .frame(height: 70)
                        .modifier(
                            TvDetailsGlassBackground(
                                filled: isSelected || isFocused,
                                shape: Capsule()
                            )
                        )
                }
                .buttonStyle(PosterCardButtonStyle())
                .focused($focus, equals: .tab(item))
                .focusEffectDisabledIfAvailable()
                .scaleEffect(isFocused ? 1.06 : 1)
                .animation(.easeOut(duration: 0.14), value: isFocused)
                .animation(.easeOut(duration: 0.14), value: isSelected)
            }
            Spacer()
        }
        .focusSection()
    }

    // MARK: Subtitles page

    private var subtitlesPage: some View {
        HStack(alignment: .top, spacing: 56) {
            languagesColumn
            subtitlesColumn
            styleColumn
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// Every pickable subtitle: mpv tracks first (embedded and orphaned
    /// externals), then the stream's add-on subtitles. Add-on entries that mpv
    /// has already loaded read their selection state off the matching track.
    private var allOptions: [SubtitlePanelOption] {
        let externalUrls = Set(viewModel.availableExternalSubtitles.map(\.url))
        var options: [SubtitlePanelOption] = []

        for track in viewModel.subtitles where track.id != "off" {
            // Loaded add-on subtitles are rendered from the add-on list below;
            // listing their mpv track too would duplicate the row.
            if !track.externalFilename.isEmpty, externalUrls.contains(track.externalFilename) { continue }
            let isExternal = !track.externalFilename.isEmpty
            // Untagged tracks often carry a language-like title ("English",
            // "SDH"); grouping by it beats a catch-all "Unknown" bucket.
            let rawLanguage = track.language.isEmpty ? track.name : track.language
            options.append(SubtitlePanelOption(
                id: "track-\(track.id)",
                kind: .track(track),
                badge: isExternal ? "External" : "Built in",
                title: track.name,
                detail: nil,
                language: SubtitleLanguageDisplay.name(for: rawLanguage),
                isSelected: track.isSelected
            ))
        }

        for subtitle in viewModel.availableExternalSubtitles {
            let language = SubtitleLanguageDisplay.name(for: subtitle.language)
            let loadedTrack = viewModel.subtitles.first { $0.externalFilename == subtitle.url }
            let detail = subtitle.label.flatMap { label in
                label.caseInsensitiveCompare(language) == .orderedSame ? nil : label
            }
            options.append(SubtitlePanelOption(
                id: "ext-\(subtitle.url)",
                kind: .external(subtitle),
                badge: subtitle.source ?? "External",
                title: language,
                detail: detail,
                language: language,
                isSelected: loadedTrack?.isSelected ?? false
            ))
        }

        return options
    }

    private var visibleOptions: [SubtitlePanelOption] {
        // Smart matching chooses/preloads preferred tracks; it must not hide
        // other languages from the manual player Settings browser.
        allOptions
    }

    /// Language groups for the left column: the user's preferred subtitle
    /// languages in saved priority order, then every other language alphabetically.
    private var languages: [(name: String, count: Int)] {
        languageGroups(in: visibleOptions)
    }

    private func languageGroups(
        in options: [SubtitlePanelOption]
    ) -> [(name: String, count: Int)] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for option in options {
            if counts[option.language] == nil { order.append(option.language) }
            counts[option.language, default: 0] += 1
        }
        let preferredLanguages = SubtitleLanguagePreferences.orderedFromDefaults()
        return order
            .map { (name: $0, count: counts[$0] ?? 0) }
            .sorted { lhs, rhs in
                let lhsRank = preferredLanguages.firstIndex {
                    SubtitleLanguagePreferences.matches(lhs.name, target: $0)
                }
                let rhsRank = preferredLanguages.firstIndex {
                    SubtitleLanguagePreferences.matches(rhs.name, target: $0)
                }
                switch (lhsRank, rhsRank) {
                case let (left?, right?) where left != right:
                    return left < right
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                default:
                    break
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    private var effectiveLanguage: String? {
        resolvedLanguage(in: visibleOptions)
    }

    private func resolvedLanguage(in options: [SubtitlePanelOption]) -> String? {
        if let selectedLanguage, options.contains(where: { $0.language == selectedLanguage }) {
            return selectedLanguage
        }
        if let selected = options.first(where: { $0.isSelected }) {
            return selected.language
        }
        // This fallback is used only before the panel establishes its selected
        // language on appear. Preserve the built-in-first ordering.
        return languageGroups(in: options).first?.name
    }

    private var subtitlesAreOff: Bool {
        viewModel.subtitles.first { $0.id == "off" }?.isSelected ?? true
    }

    private var languagesColumn: some View {
        VStack(alignment: .leading, spacing: 18) {
            columnHeader("Languages")
            ScrollView(showsIndicators: false) {
                VStack(spacing: 10) {
                    languageRow(title: "None", count: nil, showsCheck: subtitlesAreOff, focusKey: .noneRow) {
                        if let off = viewModel.subtitles.first(where: { $0.id == "off" }) {
                            viewModel.selectSubtitle(off)
                        }
                    }
                    ForEach(languages, id: \.name) { entry in
                        languageRow(title: entry.name, count: entry.count, showsCheck: false, focusKey: .language(entry.name)) {
                            selectedLanguage = entry.name
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            .focusSection()
        }
        .frame(width: 380, alignment: .leading)
    }

    private func languageRow(
        title: String,
        count: Int?,
        showsCheck: Bool,
        focusKey: Focus,
        action: @escaping () -> Void
    ) -> some View {
        let isFocused = focus == focusKey
        return Button(action: action) {
            HStack(spacing: 12) {
                Text(title)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundColor(isFocused ? .black : .white)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if showsCheck {
                    Image(systemName: "checkmark")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(isFocused ? .black : .white)
                } else if let count {
                    Text("\(count)")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundColor(isFocused ? .black.opacity(0.72) : .white.opacity(0.8))
                        .frame(minWidth: 38, minHeight: 38)
                        .background(
                            Circle().fill(isFocused ? Color.black.opacity(0.10) : Color.white.opacity(0.16))
                        )
                }
            }
            .padding(.horizontal, 24)
            .frame(height: 66)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isFocused ? Color.white : Color.clear)
            )
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($focus, equals: focusKey)
        .focusEffectDisabledIfAvailable()
    }

    private var subtitlesColumn: some View {
        // `effectiveLanguage` used to be evaluated once per option. Its getter
        // rebuilds/sorts the language list, producing O(n²) work on every focus
        // move and every player tick. Resolve one immutable snapshot instead.
        let optionsSnapshot = visibleOptions
        let language = resolvedLanguage(in: optionsSnapshot)
        let options = optionsSnapshot.filter { $0.language == language }
        return VStack(alignment: .leading, spacing: 18) {
            columnHeader("Subtitles")
            if viewModel.isLoadingExternalSubtitles {
                HStack(spacing: 12) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                    Text("Fetching add-on subtitles…")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(.white.opacity(0.62))
                }
            }
            if options.isEmpty {
                Text("No subtitles available")
                    .font(.system(size: 23, weight: .medium))
                    .foregroundColor(.white.opacity(0.45))
                    .padding(.top, 10)
                Spacer(minLength: 0)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 14) {
                        ForEach(options) { option in
                            optionCard(option)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .focusSection()
            }
        }
        .frame(width: 460, alignment: .leading)
    }

    private func optionCard(_ option: SubtitlePanelOption) -> some View {
        let isFocused = focus == .option(option.id)
        return Button {
            switch option.kind {
            case .track(let track):
                viewModel.selectSubtitle(track)
            case .external(let subtitle):
                viewModel.selectExternalSubtitle(subtitle)
            }
        } label: {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(option.badge)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(isFocused ? .black.opacity(0.66) : .white.opacity(0.72))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(isFocused ? Color.black.opacity(0.10) : Color.white.opacity(0.14))
                        )
                    Text(option.title)
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundColor(isFocused ? .black : .white)
                        .lineLimit(1)
                    if let detail = option.detail {
                        Text(detail)
                            .font(.system(size: 20, weight: .medium))
                            .foregroundColor(isFocused ? .black.opacity(0.52) : .white.opacity(0.5))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if option.isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 27, weight: .bold))
                        .foregroundColor(isFocused ? .black : .white)
                }
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(isFocused ? Color.white : Color.white.opacity(0.07))
            )
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($focus, equals: .option(option.id))
        .focusEffectDisabledIfAvailable()
    }

    // MARK: Subtitle style column

    private var styleColumn: some View {
        VStack(alignment: .leading, spacing: 18) {
            columnHeader("Subtitle Style")
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 30) {
                    stepperRow(
                        title: "Delay",
                        value: "\(viewModel.subtitleDelayMs)ms",
                        minusKey: .delayMinus,
                        plusKey: .delayPlus,
                        onMinus: { viewModel.setSubtitleDelayMs(viewModel.subtitleDelayMs - 50) },
                        onPlus: { viewModel.setSubtitleDelayMs(viewModel.subtitleDelayMs + 50) }
                    )

                    stepperRow(
                        title: "Font Size",
                        value: "\(style.textSize)%",
                        minusKey: .sizeMinus,
                        plusKey: .sizePlus,
                        onMinus: { updateStyle { $0.textSize = max($0.textSize - 5, 60) } },
                        onPlus: { updateStyle { $0.textSize = min($0.textSize + 5, 220) } }
                    )

                    toggleRow(title: "Bold", isOn: style.bold, focusKey: .bold) {
                        updateStyle { $0.bold.toggle() }
                    }

                    colorRow

                    stepperRow(
                        title: "Text Opacity",
                        value: "\(style.textOpacity)%",
                        minusKey: .opacityMinus,
                        plusKey: .opacityPlus,
                        onMinus: { updateStyle { $0.textOpacity = max($0.textOpacity - 5, 20) } },
                        onPlus: { updateStyle { $0.textOpacity = min($0.textOpacity + 5, 100) } }
                    )

                    toggleRow(title: "Outline", isOn: style.outlineEnabled, focusKey: .outline) {
                        updateStyle { $0.outlineEnabled.toggle() }
                    }
                }
                .padding(.vertical, 6)
                .padding(.bottom, 26)
            }
            .focusSection()
            .scrollClipDisabledIfAvailable()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Mutates the local style, persists it to the profile's settings (the same
    /// keys Settings → Subtitle Style edits), and re-applies it to mpv live.
    private func updateStyle(_ mutate: (inout SubtitleStyle) -> Void) {
        mutate(&style)
        let defaults = ProfileSettings.current
        defaults.set(style.textSize, forKey: SubtitleStyleKey.textSize)
        defaults.set(style.bold, forKey: SubtitleStyleKey.bold)
        defaults.set(style.textColorHex, forKey: SubtitleStyleKey.textColor)
        defaults.set(style.textOpacity, forKey: SubtitleStyleKey.textOpacity)
        defaults.set(style.outlineEnabled, forKey: SubtitleStyleKey.outlineEnabled)
        viewModel.applySubtitleStyle()
    }

    private func stepperRow(
        title: String,
        value: String,
        minusKey: StyleControl,
        plusKey: StyleControl,
        onMinus: @escaping () -> Void,
        onPlus: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            styleLabel(title)
            HStack(spacing: 16) {
                stepButton("minus", focusKey: minusKey, action: onMinus)
                Text(value)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 132, height: 56)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.white.opacity(0.10))
                    )
                stepButton("plus", focusKey: plusKey, action: onPlus)
            }
        }
    }

    private func stepButton(_ systemName: String, focusKey: StyleControl, action: @escaping () -> Void) -> some View {
        let isFocused = focus == .style(focusKey)
        return Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 23, weight: .bold))
                .foregroundColor(isFocused ? .black : .white)
                .frame(width: 76, height: 56)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(isFocused ? Color.white : Color.white.opacity(0.10))
                )
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($focus, equals: .style(focusKey))
        .focusEffectDisabledIfAvailable()
    }

    private func toggleRow(title: String, isOn: Bool, focusKey: StyleControl, action: @escaping () -> Void) -> some View {
        let isFocused = focus == .style(focusKey)
        return VStack(alignment: .leading, spacing: 14) {
            styleLabel(title)
            Button(action: action) {
                Text(isOn ? "On" : "Off")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(isFocused ? .black : .white)
                    .frame(width: 112, height: 52)
                    .background(
                        Capsule().fill(isFocused ? Color.white : Color.white.opacity(0.10))
                    )
            }
            .buttonStyle(PosterCardButtonStyle())
            .focused($focus, equals: .style(focusKey))
            .focusEffectDisabledIfAvailable()
        }
    }

    private var colorRow: some View {
        VStack(alignment: .leading, spacing: 16) {
            styleLabel("Text Color")
            HStack(spacing: 20) {
                ForEach(Self.palette, id: \.self) { hex in
                    colorSwatch(hex)
                }
            }
        }
    }

    private func colorSwatch(_ hex: String) -> some View {
        let isFocused = focus == .style(.color(hex))
        let isSelected = style.textColorHex.caseInsensitiveCompare(hex) == .orderedSame
        return Button {
            updateStyle { $0.textColorHex = hex }
        } label: {
            Circle()
                .fill(Color(hex: hex))
                .frame(width: 52, height: 52)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 1))
                .overlay(
                    Circle()
                        .strokeBorder(
                            isFocused ? Color.white : (isSelected ? Color.white.opacity(0.75) : .clear),
                            lineWidth: isFocused ? AppFocusOutline.width : 3
                        )
                        .padding(-6)
                )
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($focus, equals: .style(.color(hex)))
        .focusEffectDisabledIfAvailable()
        .scaleEffect(isFocused ? 1.14 : 1)
        .zIndex(isFocused ? 1 : 0)
        .animation(.easeOut(duration: 0.14), value: isFocused)
    }

    // MARK: Audio & Speed pages

    private var audioPage: some View {
        HStack(alignment: .top, spacing: 70) {
            audioTracksColumn
            audioAdjustmentsColumn
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var audioTracksColumn: some View {
        VStack(alignment: .leading, spacing: 18) {
            columnHeader("Audio Tracks")
            if viewModel.audioTracks.isEmpty {
                Text("No audio tracks available")
                    .font(.system(size: 23, weight: .medium))
                    .foregroundColor(.white.opacity(0.45))
                    .padding(.top, 10)
                Spacer(minLength: 0)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 14) {
                        ForEach(orderedAudioTracks) { track in
                            audioTrackCard(track)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .focusSection()
            }
        }
        .frame(width: 840, alignment: .leading)
    }

    /// Preferred audio first, followed by the remaining languages
    /// alphabetically. Preserve the stream's original order within a language
    /// so commentary/Atmos/stereo variants do not jump around unexpectedly.
    private var orderedAudioTracks: [AudioTrack] {
        let preferred = SubtitleLanguagePreferences.preferredAudioLanguage()
        return viewModel.audioTracks.enumerated().sorted { lhs, rhs in
            let lhsPreferred = preferred.map { audioTrack(lhs.element, matches: $0) } ?? false
            let rhsPreferred = preferred.map { audioTrack(rhs.element, matches: $0) } ?? false
            if lhsPreferred != rhsPreferred { return lhsPreferred }

            let lhsLanguage = lhs.element.languageName.isEmpty ? lhs.element.name : lhs.element.languageName
            let rhsLanguage = rhs.element.languageName.isEmpty ? rhs.element.name : rhs.element.languageName
            let comparison = lhsLanguage.localizedCaseInsensitiveCompare(rhsLanguage)
            if comparison != .orderedSame { return comparison == .orderedAscending }
            return lhs.offset < rhs.offset
        }
        .map(\.element)
    }

    private func audioTrack(_ track: AudioTrack, matches language: String) -> Bool {
        SubtitleLanguagePreferences.matches(track.language, target: language) ||
        SubtitleLanguagePreferences.matches(track.languageName, target: language) ||
        SubtitleLanguagePreferences.matches(track.name, target: language)
    }

    private func audioTrackCard(_ track: AudioTrack) -> some View {
        let isFocused = focus == .audio(track.id)
        return Button {
            viewModel.selectAudio(track)
        } label: {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(track.name)
                        .font(.system(size: 27, weight: .semibold))
                        .foregroundColor(isFocused ? .black : .white)
                        .lineLimit(1)
                    if !track.languageName.isEmpty {
                        Text(track.languageName)
                            .font(.system(size: 20, weight: .medium))
                            .foregroundColor(isFocused ? .black.opacity(0.58) : .white.opacity(0.6))
                            .lineLimit(1)
                    }
                    if !track.detail.isEmpty {
                        Text(track.detail)
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(isFocused ? .black.opacity(0.44) : .white.opacity(0.4))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if track.isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 25, weight: .bold))
                        .foregroundColor(isFocused ? .black : .white)
                }
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(isFocused ? Color.white : Color.white.opacity(0.07))
            )
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($focus, equals: .audio(track.id))
        .focusEffectDisabledIfAvailable()
    }

    private var audioAdjustmentsColumn: some View {
        let aetherAudioAdjustmentsUnavailable = viewModel.activeEngineKind == .aether
        return VStack(alignment: .leading, spacing: 34) {
            audioStepper(
                title: "Audio Delay",
                value: String(format: "%.3fs", Double(viewModel.audioDelayMs) / 1000.0),
                caption: aetherAudioAdjustmentsUnavailable
                    ? "Unavailable with Aether"
                    : "Range: -3.00s to 3.00s",
                minusKey: .delayMinus,
                plusKey: .delayPlus,
                minusDisabled: aetherAudioAdjustmentsUnavailable || viewModel.audioDelayMs <= -3000,
                plusDisabled: aetherAudioAdjustmentsUnavailable || viewModel.audioDelayMs >= 3000,
                onMinus: { viewModel.setAudioDelayMs(viewModel.audioDelayMs - 50) },
                onPlus: { viewModel.setAudioDelayMs(viewModel.audioDelayMs + 50) }
            )

            audioStepper(
                title: "Amplification (PCM)",
                value: "\(viewModel.audioAmplificationDb) dB",
                caption: aetherAudioAdjustmentsUnavailable
                    ? "Unavailable with Aether"
                    : "Range: 0 dB to 10 dB",
                minusKey: .ampMinus,
                plusKey: .ampPlus,
                minusDisabled: aetherAudioAdjustmentsUnavailable || viewModel.audioAmplificationDb <= 0,
                plusDisabled: aetherAudioAdjustmentsUnavailable || viewModel.audioAmplificationDb >= 10,
                onMinus: { viewModel.setAudioAmplificationDb(viewModel.audioAmplificationDb - 1) },
                onPlus: { viewModel.setAudioAmplificationDb(viewModel.audioAmplificationDb + 1) }
            )

            Text("Persist between sessions: OFF")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white.opacity(0.42))
                .padding(.top, 4)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
    }

    private func audioStepper(
        title: String,
        value: String,
        caption: String,
        minusKey: AudioControl,
        plusKey: AudioControl,
        minusDisabled: Bool,
        plusDisabled: Bool,
        onMinus: @escaping () -> Void,
        onPlus: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            styleLabel(title)
            Text(value)
                .font(.system(size: 34, weight: .semibold))
                .foregroundColor(.white)
            HStack(spacing: 16) {
                audioStepButton("minus", focusKey: minusKey, disabled: minusDisabled, action: onMinus)
                audioStepButton("plus", focusKey: plusKey, disabled: plusDisabled, action: onPlus)
            }
            Text(caption)
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(.white.opacity(0.4))
        }
    }

    private func audioStepButton(
        _ systemName: String,
        focusKey: AudioControl,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let isFocused = focus == .audioControl(focusKey)
        return Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 23, weight: .bold))
                .foregroundColor(disabled ? .white.opacity(0.22) : (isFocused ? .black : .white))
                .frame(width: 96, height: 60)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(isFocused && !disabled ? Color.white : Color.white.opacity(0.10))
                )
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($focus, equals: .audioControl(focusKey))
        .focusEffectDisabledIfAvailable()
        .disabled(disabled)
    }

    private var speedPage: some View {
        HStack(alignment: .top, spacing: 56) {
            VStack(alignment: .leading, spacing: 18) {
                columnHeader("Playback Speed")
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 12) {
                        ForEach(PlaybackSpeed.allCases) { speed in
                            simpleRow(
                                title: speed.label,
                                isSelected: viewModel.playbackSpeed == speed,
                                focusKey: .speed(speed.rawValue)
                            ) {
                                viewModel.setSpeed(speed)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
                .focusSection()
            }
            .frame(width: 700, alignment: .leading)

            VStack(alignment: .leading, spacing: 18) {
                columnHeader("Seek Step")
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 12) {
                        ForEach(PlayerSeekSettings.validSteps, id: \.self) { seconds in
                            simpleRow(
                                title: "\(seconds)s",
                                isSelected: viewModel.seekStepSeconds == seconds,
                                focusKey: .seekStep(seconds)
                            ) {
                                viewModel.setSeekStepSeconds(seconds)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
                .focusSection()
            }
            .frame(width: 420, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var picturePage: some View {
        VStack(alignment: .leading, spacing: 18) {
            columnHeader("Aspect Ratio")
            Text("How the video fills the screen")
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(.white.opacity(0.5))
            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    ForEach(PlayerAspectMode.allCases) { mode in
                        aspectRow(mode)
                    }
                }
                .padding(.vertical, 6)
            }
            .focusSection()
        }
        .frame(maxWidth: 720, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func aspectRow(_ mode: PlayerAspectMode) -> some View {
        let isFocused = focus == .aspect(mode.rawValue)
        let isSelected = viewModel.aspectMode == mode
        return Button {
            viewModel.setAspectMode(mode)
        } label: {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(mode.label)
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundColor(isFocused ? .black : .white)
                    Text(mode.detail)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(isFocused ? .black.opacity(0.55) : .white.opacity(0.5))
                }
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundColor(isFocused ? .black : .white)
                }
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 20)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(isFocused ? Color.white : Color.white.opacity(0.08))
            )
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($focus, equals: .aspect(mode.rawValue))
        .focusEffectDisabledIfAvailable()
    }

    private func simpleRow(
        title: String,
        isSelected: Bool,
        focusKey: Focus,
        action: @escaping () -> Void
    ) -> some View {
        let isFocused = focus == focusKey
        return Button(action: action) {
            HStack(spacing: 14) {
                Text(title)
                    .font(.system(size: 27, weight: .semibold))
                    .foregroundColor(isFocused ? .black : .white)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 25, weight: .bold))
                        .foregroundColor(isFocused ? .black : .white)
                }
            }
            .padding(.horizontal, 26)
            .frame(height: 68)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isFocused ? Color.white : Color.white.opacity(0.07))
            )
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($focus, equals: focusKey)
        .focusEffectDisabledIfAvailable()
    }

    private func columnHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 26, weight: .semibold))
            .foregroundColor(.white.opacity(0.45))
    }

    private func styleLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 26, weight: .semibold))
            .foregroundColor(.white)
    }
}
