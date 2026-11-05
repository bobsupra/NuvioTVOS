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

/// Keeps the native player surface at its viewport size while presenting a
/// compositor-scaled version in the post-play mini window.
struct StablePlayerSurfacePresentation<Content: View>: View {
    let viewportSize: CGSize
    let presentationSize: CGSize
    private let content: Content

    init(
        viewportSize: CGSize,
        presentationSize: CGSize,
        @ViewBuilder content: () -> Content
    ) {
        self.viewportSize = viewportSize
        self.presentationSize = presentationSize
        self.content = content()
    }

    private var fitScale: CGFloat {
        guard viewportSize.width > 0, viewportSize.height > 0 else { return 1 }
        return min(presentationSize.width / viewportSize.width, presentationSize.height / viewportSize.height)
    }

    var body: some View {
        content
            .frame(width: viewportSize.width, height: viewportSize.height)
            .scaleEffect(fitScale)
            .frame(width: presentationSize.width, height: presentationSize.height)
            .clipped()
    }
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
    var onTapBackward: () -> Void = {}
    var onTapForward: () -> Void = {}
    let onBeginBackward: () -> Void
    let onBeginForward: () -> Void
    let onEnd: () -> Void
    var canRevealControls: () -> Bool = { false }
    var canHandleUp: () -> Bool = { false }
    var onTapUp: () -> Void = {}

    func makeUIView(context: Context) -> SeekPressHostView {
        let view = SeekPressHostView()
        view.configure(
            isActive: isActive,
            onTapBackward: onTapBackward,
            onTapForward: onTapForward,
            onBeginBackward: onBeginBackward,
            onBeginForward: onBeginForward,
            onEnd: onEnd,
            canRevealControls: canRevealControls,
            canHandleUp: canHandleUp,
            onTapUp: onTapUp
        )
        return view
    }

    func updateUIView(_ uiView: SeekPressHostView, context: Context) {
        uiView.configure(
            isActive: isActive,
            onTapBackward: onTapBackward,
            onTapForward: onTapForward,
            onBeginBackward: onBeginBackward,
            onBeginForward: onBeginForward,
            onEnd: onEnd,
            canRevealControls: canRevealControls,
            canHandleUp: canHandleUp,
            onTapUp: onTapUp
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

    private var onTapBackward: () -> Void = {}
    private var onTapForward: () -> Void = {}
    private var onBeginBackward: () -> Void = {}
    private var onBeginForward: () -> Void = {}
    private var onEnd: () -> Void = {}
    private var canRevealControls: () -> Bool = { false }
    private var canHandleUp: () -> Bool = { false }
    private var onTapUp: () -> Void = {}

    private var activeDirection: Direction?
    private var isActive = false
    private weak var attachedWindow: UIWindow?
    private var backwardHoldRecognizer: UILongPressGestureRecognizer?
    private var forwardHoldRecognizer: UILongPressGestureRecognizer?
    private var backwardTapRecognizer: UITapGestureRecognizer?
    private var forwardTapRecognizer: UITapGestureRecognizer?
    private var upTapRecognizer: UITapGestureRecognizer?

    func configure(
        isActive: Bool,
        onTapBackward: @escaping () -> Void,
        onTapForward: @escaping () -> Void,
        onBeginBackward: @escaping () -> Void,
        onBeginForward: @escaping () -> Void,
        onEnd: @escaping () -> Void,
        canRevealControls: @escaping () -> Bool,
        canHandleUp: @escaping () -> Bool = { false },
        onTapUp: @escaping () -> Void
    ) {
        self.isActive = isActive
        self.onTapBackward = onTapBackward
        self.onTapForward = onTapForward
        self.onBeginBackward = onBeginBackward
        self.onBeginForward = onBeginForward
        self.onEnd = onEnd
        self.canRevealControls = canRevealControls
        self.canHandleUp = canHandleUp
        self.onTapUp = onTapUp
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

        let backwardTap = makeTapRecognizer(
            pressType: .leftArrow,
            action: #selector(handleBackwardTap(_:))
        )
        let forwardTap = makeTapRecognizer(
            pressType: .rightArrow,
            action: #selector(handleForwardTap(_:))
        )
        let upTap = makeTapRecognizer(
            pressType: .upArrow,
            action: #selector(handleUpTap(_:))
        )
        upTap.allowedTouchTypes = []
        upTap.isEnabled = true

        backwardTap.require(toFail: backwardHold)
        forwardTap.require(toFail: forwardHold)

        window.addGestureRecognizer(backwardTap)
        window.addGestureRecognizer(forwardTap)
        window.addGestureRecognizer(upTap)
        window.addGestureRecognizer(backwardHold)
        window.addGestureRecognizer(forwardHold)

        backwardTapRecognizer = backwardTap
        forwardTapRecognizer = forwardTap
        upTapRecognizer = upTap
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
            if let backwardTapRecognizer {
                attachedWindow.removeGestureRecognizer(backwardTapRecognizer)
            }
            if let forwardTapRecognizer {
                attachedWindow.removeGestureRecognizer(forwardTapRecognizer)
            }
            if let upTapRecognizer {
                attachedWindow.removeGestureRecognizer(upTapRecognizer)
            }
            if let backwardHoldRecognizer {
                attachedWindow.removeGestureRecognizer(backwardHoldRecognizer)
            }
            if let forwardHoldRecognizer {
                attachedWindow.removeGestureRecognizer(forwardHoldRecognizer)
            }
        }
        backwardTapRecognizer = nil
        forwardTapRecognizer = nil
        upTapRecognizer = nil
        backwardHoldRecognizer = nil
        forwardHoldRecognizer = nil
        attachedWindow = nil
    }

    private func makeTapRecognizer(pressType: UIPress.PressType, action: Selector) -> UITapGestureRecognizer {
        let recognizer = UITapGestureRecognizer(target: self, action: action)
        recognizer.allowedPressTypes = [NSNumber(value: pressType.rawValue)]
        recognizer.cancelsTouchesInView = false
        recognizer.delegate = self
        recognizer.isEnabled = false
        return recognizer
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
        backwardTapRecognizer?.isEnabled = isActive && activeDirection == nil
        forwardTapRecognizer?.isEnabled = isActive && activeDirection == nil
        // Keep the Up catcher installed; its live closure suppresses presses
        // whenever playback state says controls should stay hidden.
        upTapRecognizer?.isEnabled = true
    }

    @objc private func handleBackwardTap(_ recognizer: UITapGestureRecognizer) {
        guard isActive, activeDirection == nil else { return }
        onTapBackward()
    }

    @objc private func handleForwardTap(_ recognizer: UITapGestureRecognizer) {
        guard isActive, activeDirection == nil else { return }
        onTapForward()
    }

    private func shouldHandleUpPress() -> Bool {
        canHandleUp() || canRevealControls()
    }

    @objc private func handleUpTap(_ recognizer: UITapGestureRecognizer) {
        guard shouldHandleUpPress() else { return }
        onTapUp()
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
        if gestureRecognizer === upTapRecognizer {
            return shouldHandleUpPress()
        }
        return isActive || activeDirection != nil
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        gestureRecognizer !== upTapRecognizer
    }
}
