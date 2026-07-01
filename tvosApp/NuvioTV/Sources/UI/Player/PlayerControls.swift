import SwiftUI

private enum PlayerControlFocus: Hashable {
    case play
    case settings
    case timeline
}

struct PlayerControls: View {
    @ObservedObject var viewModel: PlayerViewModel

    @State private var showSettings = false
    @FocusState private var focusedControl: PlayerControlFocus?

    private var progress: CGFloat {
        CGFloat(min(max(viewModel.time.progress, 0), 1))
    }

    private var isShowingPause: Bool {
        viewModel.status == .playing
    }

    var body: some View {
        GlassControlsContainer {
            VStack {
                topBar
                Spacer()
                bottomControls
            }
        }
        .sheet(isPresented: $showSettings) {
            PlayerSettingsSheetView(viewModel: viewModel)
        }
        .onChange(of: showSettings) { isPresented in
            viewModel.setControlsAutoHideSuspended(isPresented)
        }
        .onAppear {
            DispatchQueue.main.async {
                focusedControl = .timeline
            }
        }
        .onChange(of: viewModel.showControls) { isVisible in
            // Controls stay mounted, so re-grab focus each time they reappear.
            if isVisible {
                DispatchQueue.main.async { focusedControl = .timeline }
            }
        }
        .onDisappear {
            viewModel.setControlsAutoHideSuspended(false)
        }
        .onMoveCommand { direction in
            switch direction {
            case .up:
                focusedControl = .play
            case .down:
                focusedControl = .timeline
            case .left:
                if focusedControl == .settings {
                    focusedControl = .play
                } else if focusedControl == .timeline {
                    viewModel.skipBackward()
                }
            case .right:
                if focusedControl == .play {
                    focusedControl = .settings
                } else if focusedControl == .timeline {
                    viewModel.skipForward()
                }
            default:
                break
            }
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
        HStack {
            glassIconButton(
                systemName: isShowingPause ? "pause.fill" : "play.fill",
                size: 70,
                iconSize: 30,
                isFocused: focusedControl == .play,
                isEmphasized: isShowingPause
            ) {
                viewModel.togglePlayPause()
            }
            .focused($focusedControl, equals: .play)

            Spacer()

            glassIconButton(
                systemName: "ellipsis",
                size: 70,
                iconSize: 30,
                isFocused: focusedControl == .settings,
                isEmphasized: false
            ) {
                showSettings = true
            }
            .focused($focusedControl, equals: .settings)
        }
        .shadow(color: .black.opacity(0.74), radius: 20, x: 0, y: 8)
        // Not focusable while hidden so the focus engine hands off to the
        // remote-input overlay (the controls view itself stays mounted).
        .disabled(!viewModel.showControls)
    }

    private func glassIconButton(
        systemName: String,
        size: CGFloat,
        iconSize: CGFloat,
        isFocused: Bool,
        isEmphasized: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
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
        .focusEffectDisabledIfAvailable()
        .scaleEffect(isFocused ? 1.06 : 1.0)
        .animation(.easeOut(duration: 0.14), value: isFocused)
    }

    // MARK: - Timeline

    private var isTimelineFocused: Bool {
        focusedControl == .timeline
    }

    private var timelineBar: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(isTimelineFocused ? 0.50 : 0.34))
                        .frame(height: isTimelineFocused ? 10 : 7)

                    Capsule()
                        .fill(Color.white.opacity(0.95))
                        .frame(width: geo.size.width * progress, height: isTimelineFocused ? 10 : 7)
                        .shadow(color: .white.opacity(isTimelineFocused ? 0.85 : 0.55), radius: isTimelineFocused ? 5 : 2, x: 0, y: 0)
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 14)

            HStack {
                Text(PlayerTime.formatted(time: viewModel.time.current))
                Spacer()
                Text("-" + PlayerTime.formatted(time: viewModel.time.remaining))
            }
            .font(.system(size: 22, weight: .bold))
            .foregroundColor(.white.opacity(isTimelineFocused ? 0.82 : 0.54))
        }
        .focusable(viewModel.showControls)
        .focused($focusedControl, equals: .timeline)
        .focusEffectDisabledIfAvailable()
        .shadow(color: .black.opacity(0.82), radius: 16, x: 0, y: 7)
        .animation(.easeOut(duration: 0.14), value: focusedControl)
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

struct PlayerSettingsSheetView: View {
    @ObservedObject var viewModel: PlayerViewModel
    @Environment(\.presentationMode) var presentationMode

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("Audio")) {
                    ForEach(viewModel.audioTracks) { track in
                        GlassSettingsRow(label: track.name, isSelected: track.isSelected) {
                            viewModel.selectAudio(track)
                        }
                    }
                }

                Section(header: Text("Subtitles")) {
                    ForEach(viewModel.subtitles) { track in
                        GlassSettingsRow(label: track.name, isSelected: track.isSelected) {
                            viewModel.selectSubtitle(track)
                        }
                    }
                }

                Section(header: Text("Speed")) {
                    ForEach(PlaybackSpeed.allCases) { speed in
                        GlassSettingsRow(label: speed.label, isSelected: viewModel.playbackSpeed == speed) {
                            viewModel.setSpeed(speed)
                        }
                    }
                }
            }
            .navigationTitle("Playback Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
        }
    }
}

/// A settings list row whose label sits on a Liquid Glass capsule (tvOS 26+),
/// falling back to a material capsule on older systems.
struct GlassSettingsRow: View {
    let label: String
    let isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(label)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundColor(.white)
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 24)
            .glassCapsule()
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
    }
}
