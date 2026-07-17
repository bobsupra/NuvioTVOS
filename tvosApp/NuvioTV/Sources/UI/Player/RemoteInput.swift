import SwiftUI
import UIKit

/// Window-level Siri Remote trackpad capture. Uses a `UIPanGestureRecognizer`
/// restricted to `.indirect` touches so the focus engine does not swallow pans.
/// Active only while the player needs it (bare video / scrubbing).
struct RemoteTouchCatcher: UIViewRepresentable {
    let isActive: () -> Bool
    let onBegan: () -> Void
    let onMoved: (CGFloat, CGFloat) -> Void
    let onEnded: (CGFloat, CGFloat) -> Void

    func makeUIView(context: Context) -> TouchHostView {
        let view = TouchHostView()
        view.configure(isActive: isActive, onBegan: onBegan, onMoved: onMoved, onEnded: onEnded)
        return view
    }

    func updateUIView(_ uiView: TouchHostView, context: Context) {
        uiView.configure(isActive: isActive, onBegan: onBegan, onMoved: onMoved, onEnded: onEnded)
    }

    static func dismantleUIView(_ uiView: TouchHostView, coordinator: ()) {
        uiView.removeRecognizers()
    }
}

final class TouchHostView: UIView, UIGestureRecognizerDelegate {
    private var pan: UIPanGestureRecognizer?
    private weak var attachedWindow: UIWindow?

    private var isActive: () -> Bool = { false }
    private var onBegan: () -> Void = {}
    private var onMoved: (CGFloat, CGFloat) -> Void = { _, _ in }
    private var onEnded: (CGFloat, CGFloat) -> Void = { _, _ in }

    func configure(
        isActive: @escaping () -> Bool,
        onBegan: @escaping () -> Void,
        onMoved: @escaping (CGFloat, CGFloat) -> Void,
        onEnded: @escaping (CGFloat, CGFloat) -> Void
    ) {
        self.isActive = isActive
        self.onBegan = onBegan
        self.onMoved = onMoved
        self.onEnded = onEnded
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        removeRecognizers()
        guard let window else { return }
        let p = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        p.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        p.cancelsTouchesInView = false
        p.delegate = self
        window.addGestureRecognizer(p)
        pan = p
        attachedWindow = window
    }

    func removeRecognizers() {
        if let attachedWindow, let pan {
            attachedWindow.removeGestureRecognizer(pan)
        }
        pan = nil
        attachedWindow = nil
    }

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        guard isActive() else { return }
        let t = g.translation(in: g.view)
        switch g.state {
        case .began: onBegan()
        case .changed: onMoved(t.x, t.y)
        case .ended, .cancelled, .failed: onEnded(t.x, t.y)
        default: break
        }
    }

    func gestureRecognizer(
        _ g: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        true
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        isActive()
    }
}
