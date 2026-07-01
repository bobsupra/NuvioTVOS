import SwiftUI
import UIKit

struct PlayerView: View {
    @StateObject private var viewModel = PlayerViewModel()

    let url: URL
    let meta: NuvioMeta
    let subtitle: String
    let externalSubtitles: [NuvioSubtitle]
    let resumeFrom: Double?
    var onFinished: (() -> Void)? = nil
    var onBack: () -> Void

    @State private var didHandleFinished = false
    @FocusState private var remoteInputFocused: Bool

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // libmpv renders into the Metal layer owned by this controller.
            MPVVideoSurface(controller: viewModel.playerController)
                .ignoresSafeArea()

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

            if !viewModel.showControls {
                Button(action: viewModel.revealControls) {
                    Color.clear
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focused($remoteInputFocused)
                .focusEffectDisabledIfAvailable()
                .frame(width: 1, height: 1)
                .opacity(0.001)
                .accessibilityHidden(true)
                .onAppear(perform: focusRemoteInput)
            }

            // Kept mounted (not gated by an `if`) so the hide animates too: removing
            // a view that holds tvOS focus makes the focus engine finalize the
            // removal before the transition can play, so only the appear would
            // animate. Animating opacity/scale on a mounted view sidesteps that —
            // focusability is gated inside PlayerControls so focus still hands off
            // cleanly to the remote-input overlay when hidden.
            PlayerControls(viewModel: viewModel)
                .opacity(viewModel.showControls ? 1 : 0)
                .scaleEffect(viewModel.showControls ? 1 : 0.95)
                .allowsHitTesting(viewModel.showControls)
                .animation(.playerControls, value: viewModel.showControls)
        }
        .onAppear {
            viewModel.load(url: url, meta: meta, subtitle: subtitle, externalSubtitles: externalSubtitles, resumeFrom: resumeFrom)
        }
        .onDisappear {
            viewModel.shutdown()
        }
        .onChange(of: viewModel.status) { status in
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
            } else {
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
            remoteInputFocused = false
            onBack()
        }
    }

    private func focusRemoteInput() {
        DispatchQueue.main.async {
            remoteInputFocused = true
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
