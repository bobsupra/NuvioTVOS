import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Gestures with the controls shown: listens to the remote without taking the
/// focus, so the controls work as before, and passes on the gestures it recognizes. Which of them
/// do anything is the player's call (`PlayerGesturePassive`).
struct PlayerGestureObserver: UIViewRepresentable {
    let isActive: Bool
    let waitsForDouble: (RemoteGesture) -> Bool
    let onGesture: (RemoteGesture) -> Void
    let setPadObserver: (((Double, Double) -> Void)?) -> Void
    var tuning = RemoteGestureTuning()
    var customShapes: [CustomGestureShape] = []

    func makeUIView(context: Context) -> GestureObserverHostView {
        let view = GestureObserverHostView()
        view.configure(self)
        setPadObserver { [weak view] x, y in view?.padMoved(x: x, y: y) }
        return view
    }

    func updateUIView(_ uiView: GestureObserverHostView, context: Context) {
        uiView.configure(self)
    }

    static func dismantleUIView(_ uiView: GestureObserverHostView, coordinator: ()) {
        uiView.removeObserver()
        uiView.detachPadObserver?(nil)
    }
}

final class GestureObserverHostView: UIView {
    private let recognizer = RemoteGestureRecognizer()
    private var observer: RemoteInputObserverRecognizer?
    private weak var attachedWindow: UIWindow?
    private var displayLink: CADisplayLink?
    private var isActive = false
    private var onGesture: (RemoteGesture) -> Void = { _ in }
    fileprivate var detachPadObserver: ((((Double, Double) -> Void)?) -> Void)?
    private var touchOrigin: CGPoint?

    fileprivate func configure(_ observer: PlayerGestureObserver) {
        recognizer.waitsForDouble = observer.waitsForDouble
        if recognizer.tuning != observer.tuning {
            recognizer.tuning = observer.tuning
        }
        if recognizer.customShapes != observer.customShapes {
            recognizer.customShapes = observer.customShapes
        }
        onGesture = observer.onGesture
        detachPadObserver = observer.setPadObserver
        setActive(observer.isActive)
    }

    private func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        recognizer.reset()
        touchOrigin = nil
        observer?.isEnabled = active
        displayLink?.isPaused = !active
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        removeObserver()
        guard let window else { return }
        let observer = RemoteInputObserverRecognizer(target: nil, action: nil)
        observer.isEnabled = isActive
        observer.onTouchBegan = { [weak self] touch in self?.touchBegan(touch) }
        observer.onTouchMoved = { [weak self] touch in self?.reportTranslation(touch) }
        observer.onTouchEnded = { [weak self] touch in self?.touchEnded(touch) }
        observer.onPressBegan = { [weak self] press in
            guard let button = RemoteButton(pressType: press.type) else { return }
            self?.feed(.pressBegan(press.timestamp, button))
        }
        observer.onPressEnded = { [weak self] press in
            guard let button = RemoteButton(pressType: press.type) else { return }
            self?.feed(.pressEnded(press.timestamp, button))
        }
        window.addGestureRecognizer(observer)
        self.observer = observer
        attachedWindow = window
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.isPaused = !isActive
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func removeObserver() {
        if let attachedWindow, let observer {
            attachedWindow.removeGestureRecognizer(observer)
        }
        observer = nil
        attachedWindow = nil
        displayLink?.invalidate()
        displayLink = nil
        recognizer.reset()
    }

    func padMoved(x: Double, y: Double) {
        guard isActive else { return }
        feed(.touchMoved(ProcessInfo.processInfo.systemUptime, PadPoint(x: x, y: y)))
    }

    @objc private func tick() {
        guard isActive else { return }
        feed(.tick(ProcessInfo.processInfo.systemUptime))
    }

    private func touchBegan(_ touch: UITouch) {
        guard isActive else { return }
        touchOrigin = touch.location(in: attachedWindow)
        feed(.touchBegan(touch.timestamp))
    }

    private func touchEnded(_ touch: UITouch) {
        guard isActive else { return }
        reportTranslation(touch)
        touchOrigin = nil
        feed(.touchEnded(touch.timestamp))
    }

    private func reportTranslation(_ touch: UITouch) {
        guard isActive, let origin = touchOrigin else { return }
        let location = touch.location(in: attachedWindow)
        feed(.touchTranslation(touch.timestamp, dx: Double(location.x - origin.x), dy: Double(origin.y - location.y)))
    }

    private func feed(_ event: InputEvent) {
        for output in recognizer.handle(event) {
            if case let .gesture(gesture, _, _) = output {
                onGesture(gesture)
            }
        }
    }
}

/// Sees every touch and press of the remote and never recognizes anything: nothing is held back
/// or cancelled for the focused control.
final class RemoteInputObserverRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
    var onTouchBegan: ((UITouch) -> Void)?
    var onTouchMoved: ((UITouch) -> Void)?
    var onTouchEnded: ((UITouch) -> Void)?
    var onPressBegan: ((UIPress) -> Void)?
    var onPressEnded: ((UIPress) -> Void)?
    private var touches = 0
    private var presses = 0

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        let pressTypes: [UIPress.PressType] = [.select, .upArrow, .downArrow, .leftArrow, .rightArrow, .playPause]
        allowedPressTypes = pressTypes.map { NSNumber(value: $0.rawValue) }
        delegate = self
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        self.touches += touches.count
        touches.forEach { onTouchBegan?($0) }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        touches.forEach { onTouchMoved?($0) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        self.touches -= touches.count
        touches.forEach { onTouchEnded?($0) }
        failWhenIdle()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        touchesEnded(touches, with: event)
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        self.presses += presses.count
        presses.forEach { onPressBegan?($0) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        self.presses -= presses.count
        presses.forEach { onPressEnded?($0) }
        failWhenIdle()
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        pressesEnded(presses, with: event)
    }

    /// Only once nothing is down: failing earlier would stop the rest of a touch coming here.
    private func failWhenIdle() {
        if touches <= 0, presses <= 0 {
            state = .failed
        }
    }

    override func reset() {
        super.reset()
        touches = 0
        presses = 0
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }
}
