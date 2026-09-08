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


struct RemoteSeekPressCatcher: UIViewControllerRepresentable {
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

// Internal rather than private: RemoteSeekPressCatcher is consumed from
// PlayerView+Layers.swift, so neither it nor its view-controller type can be
// file-scoped any more.
final class RemoteSeekPressViewController: UIViewController {
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
