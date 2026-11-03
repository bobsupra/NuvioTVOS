import SwiftUI
import UIKit

/// Takes the remote's touches and clicks while active and turns them into gestures. Touches and presses go to the focused view, so while active this view
/// takes the focus; the pad's absolute positions come from the player's GameController handler.
/// Menu / Back is never a gesture: it goes to `onBack`.
struct PlayerGestureCapture: UIViewRepresentable {
    let isActive: Bool
    /// Whether a single click or tap has to wait for its double (only when the double is bound).
    let waitsForDouble: (RemoteGesture) -> Bool
    let onGesture: (RemoteGesture) -> Void
    /// Every release, also of a long press that already went out as a gesture (it ends a hold seek).
    var onPressEnded: (RemoteButton) -> Void = { _ in }
    let onBack: () -> Void
    /// Hands the pad feed to the GameController handler (nil when this view goes away).
    let setPadObserver: (((Double, Double) -> Void)?) -> Void
    /// Every input as the recognizer gets it (no ticks), and how each touch went: for a live drawing.
    var onInput: ((InputEvent) -> Void)?
    var onTouchSummary: ((TouchSummary) -> Void)?
    /// The sensitivity chosen in the Gestures tab.
    var tuning = RemoteGestureTuning()
    /// Shapes of one's own to look for.
    var customShapes: [CustomGestureShape] = []

    func makeUIView(context: Context) -> GestureCaptureView {
        let view = GestureCaptureView()
        view.configure(self)
        setPadObserver { [weak view] x, y in view?.padMoved(x: x, y: y) }
        return view
    }

    func updateUIView(_ uiView: GestureCaptureView, context: Context) {
        uiView.configure(self)
    }

    static func dismantleUIView(_ uiView: GestureCaptureView, coordinator: ()) {
        uiView.stop()
        uiView.detachPadObserver?(nil)
    }
}

final class GestureCaptureView: UIView {
    private let recognizer = RemoteGestureRecognizer()
    private var isActive = false
    private var onGesture: (RemoteGesture) -> Void = { _ in }
    private var onPressEnded: (RemoteButton) -> Void = { _ in }
    private var onBack: () -> Void = {}
    private var onInput: ((InputEvent) -> Void)?
    private var onTouchSummary: ((TouchSummary) -> Void)?
    /// When the focus was last asked for, so a lost focus is asked for again (not every frame).
    private var lastFocusRequest: CFTimeInterval = 0
    fileprivate var detachPadObserver: ((((Double, Double) -> Void)?) -> Void)?
    private var touchOrigin: CGPoint?
    private var displayLink: CADisplayLink?

    override var canBecomeFocused: Bool { isActive }

    fileprivate func configure(_ capture: PlayerGestureCapture) {
        recognizer.waitsForDouble = capture.waitsForDouble
        if recognizer.tuning != capture.tuning {
            recognizer.tuning = capture.tuning
        }
        if recognizer.customShapes != capture.customShapes {
            recognizer.customShapes = capture.customShapes
        }
        onGesture = capture.onGesture
        onPressEnded = capture.onPressEnded
        onBack = capture.onBack
        onInput = capture.onInput
        onTouchSummary = capture.onTouchSummary
        detachPadObserver = capture.setPadObserver
        setActive(capture.isActive)
    }

    private func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        recognizer.reset()
        touchOrigin = nil
        displayLink?.isPaused = !active
        if active {
            // Take the focus, so the remote's touches and presses come here.
            DispatchQueue.main.async { [weak self] in
                self?.takeFocus()
            }
        }
    }

    private func takeFocus() {
        guard isActive, window != nil, !isFocused else { return }
        lastFocusRequest = CACurrentMediaTime()
        UIFocusSystem.focusSystem(for: self)?.requestFocusUpdate(to: self)
        UIFocusSystem.focusSystem(for: self)?.updateFocusIfNeeded()
    }

    /// tvOS also turns touchpad swipes into focus moves: while capturing, a swipe must not carry
    /// the focus off to whatever is focusable that way (it would take the remote with it). Moves
    /// asked for in code (the controls or a panel taking over) have no heading and still go through.
    override func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool {
        if isActive, (context.previouslyFocusedItem as? UIView) === self, !context.focusHeading.isEmpty {
            return false
        }
        return super.shouldUpdateFocus(in: context)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        displayLink?.invalidate()
        displayLink = nil
        guard window != nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.isPaused = !isActive
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        isActive = false
        recognizer.reset()
    }

    // MARK: Input

    func padMoved(x: Double, y: Double) {
        guard isActive else { return }
        feed(.touchMoved(ProcessInfo.processInfo.systemUptime, PadPoint(x: x, y: y)))
    }

    @objc private func tick() {
        guard isActive else { return }
        // Whatever took the focus while this was supposed to hold the remote, take it back.
        if !isFocused, CACurrentMediaTime() - lastFocusRequest > Self.focusRetryInterval {
            takeFocus()
        }
        feed(.tick(ProcessInfo.processInfo.systemUptime))
    }

    static let focusRetryInterval: CFTimeInterval = 0.3

    private func feed(_ event: InputEvent) {
        if case .tick = event {} else { onInput?(event) }
        for output in recognizer.handle(event) {
            switch output {
            case let .gesture(gesture, _, _):
                onGesture(gesture)
            case let .touchSummary(summary):
                onTouchSummary?(summary)
            }
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard isActive else { return super.touchesBegan(touches, with: event) }
        touchOrigin = touches.first?.location(in: self)
        feed(.touchBegan(touches.first?.timestamp ?? ProcessInfo.processInfo.systemUptime))
    }

    /// UIKit's movement is relative and filtered: swipes are measured with it.
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard isActive else { return super.touchesMoved(touches, with: event) }
        reportTranslation(touches)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard isActive else { return super.touchesEnded(touches, with: event) }
        reportTranslation(touches)
        touchOrigin = nil
        feed(.touchEnded(touches.first?.timestamp ?? ProcessInfo.processInfo.systemUptime))
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard isActive else { return super.touchesCancelled(touches, with: event) }
        touchOrigin = nil
        feed(.touchEnded(touches.first?.timestamp ?? ProcessInfo.processInfo.systemUptime))
    }

    private func reportTranslation(_ touches: Set<UITouch>) {
        guard let touch = touches.first, let origin = touchOrigin else { return }
        let location = touch.location(in: self)
        // y up, as the pad positions.
        feed(.touchTranslation(touch.timestamp, dx: Double(location.x - origin.x), dy: Double(origin.y - location.y)))
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard isActive else { return super.pressesBegan(presses, with: event) }
        var others = Set<UIPress>()
        for press in presses {
            if press.type == .menu { continue }
            if let button = RemoteButton(pressType: press.type) {
                feed(.pressBegan(press.timestamp, button))
            } else {
                others.insert(press)
            }
        }
        if !others.isEmpty { super.pressesBegan(others, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard isActive else { return super.pressesEnded(presses, with: event) }
        var others = Set<UIPress>()
        for press in presses {
            if press.type == .menu {
                onBack()
                continue
            }
            if let button = RemoteButton(pressType: press.type) {
                feed(.pressEnded(press.timestamp, button))
                onPressEnded(button)
            } else {
                others.insert(press)
            }
        }
        if !others.isEmpty { super.pressesEnded(others, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard isActive else { return super.pressesCancelled(presses, with: event) }
        for press in presses {
            if let button = RemoteButton(pressType: press.type) {
                feed(.pressEnded(press.timestamp, button))
                onPressEnded(button)
            }
        }
    }
}

extension RemoteButton {
    init?(pressType: UIPress.PressType) {
        switch pressType {
        case .select: self = .select
        case .upArrow: self = .up
        case .downArrow: self = .down
        case .leftArrow: self = .left
        case .rightArrow: self = .right
        case .playPause: self = .playPause
        default: return nil
        }
    }
}
