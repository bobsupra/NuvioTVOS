import SwiftUI
import UIKit

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
        controller.rebindSurface()
        PictureInPictureManager.shared.fullscreenSurfaceDidRebind()
        return controller
    }

    func updateUIViewController(_ uiViewController: AetherPlaybackController, context: Context) {
        uiViewController.rebindSurface()
        PictureInPictureManager.shared.fullscreenSurfaceDidRebind()
    }
}


struct RemoteSeekPressCatcher: UIViewRepresentable {
    let isActive: Bool
    let onBeginBackward: () -> Void
    let onBeginForward: () -> Void
    let onEnd: () -> Void

    func makeUIView(context: Context) -> SeekPressHostView {
        let view = SeekPressHostView()
        view.configure(
            isActive: isActive,
            onBeginBackward: onBeginBackward,
            onBeginForward: onBeginForward,
            onEnd: onEnd
        )
        return view
    }

    func updateUIView(_ uiView: SeekPressHostView, context: Context) {
        uiView.configure(
            isActive: isActive,
            onBeginBackward: onBeginBackward,
            onBeginForward: onBeginForward,
            onEnd: onEnd
        )
    }

    static func dismantleUIView(_ uiView: SeekPressHostView, coordinator: ()) {
        uiView.removeRecognizers()
    }
}

final class SeekPressHostView: UIView, UIGestureRecognizerDelegate {
    enum Direction {
        case backward
        case forward
    }

    private var onBeginBackward: () -> Void = {}
    private var onBeginForward: () -> Void = {}
    private var onEnd: () -> Void = {}

    private var activeDirection: Direction?
    private var isActive = false
    private weak var attachedWindow: UIWindow?
    private var backwardHoldRecognizer: UILongPressGestureRecognizer?
    private var forwardHoldRecognizer: UILongPressGestureRecognizer?

    func configure(
        isActive: Bool,
        onBeginBackward: @escaping () -> Void,
        onBeginForward: @escaping () -> Void,
        onEnd: @escaping () -> Void
    ) {
        self.isActive = isActive
        self.onBeginBackward = onBeginBackward
        self.onBeginForward = onBeginForward
        self.onEnd = onEnd
        updateRecognizerState()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        removeRecognizers()
        guard let window else { return }

        let backwardHold = makeHoldRecognizer(
            pressType: .leftArrow,
            action: #selector(handleBackwardHold(_:))
        )
        let forwardHold = makeHoldRecognizer(
            pressType: .rightArrow,
            action: #selector(handleForwardHold(_:))
        )

        window.addGestureRecognizer(backwardHold)
        window.addGestureRecognizer(forwardHold)

        backwardHoldRecognizer = backwardHold
        forwardHoldRecognizer = forwardHold
        attachedWindow = window
        updateRecognizerState()
    }

    func removeRecognizers() {
        if activeDirection != nil {
            activeDirection = nil
            onEnd()
        }
        if let attachedWindow {
            if let backwardHoldRecognizer {
                attachedWindow.removeGestureRecognizer(backwardHoldRecognizer)
            }
            if let forwardHoldRecognizer {
                attachedWindow.removeGestureRecognizer(forwardHoldRecognizer)
            }
        }
        backwardHoldRecognizer = nil
        forwardHoldRecognizer = nil
        attachedWindow = nil
    }

    private func makeHoldRecognizer(pressType: UIPress.PressType, action: Selector) -> UILongPressGestureRecognizer {
        let recognizer = UILongPressGestureRecognizer(target: self, action: action)
        recognizer.allowedPressTypes = [NSNumber(value: pressType.rawValue)]
        recognizer.minimumPressDuration = 0.35
        recognizer.cancelsTouchesInView = false
        recognizer.delegate = self
        recognizer.isEnabled = false
        return recognizer
    }

    private func updateRecognizerState() {
        let enabled = isActive || activeDirection != nil
        backwardHoldRecognizer?.isEnabled = enabled
        forwardHoldRecognizer?.isEnabled = enabled
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
            guard isActive, activeDirection == nil else { return }
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

    // MARK: - UIGestureRecognizerDelegate

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        if otherGestureRecognizer is UIPanGestureRecognizer {
            return false
        }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive press: UIPress) -> Bool {
        isActive || activeDirection != nil
    }
}
