import SwiftUI
import UIKit

/// Keeps a quick Back from sending the app to the Home screen.
///
/// Closing a panel or a native menu (subtitles, audio), leaving the player, or going back from
/// Details animates for a moment. A Back pressed then reaches no responder (the menu that took
/// the first one is on its way out, or nothing is focused yet), and tvOS takes it as "leave the
/// app". Installed once for the whole app, on every window: a Back is swallowed while nothing is
/// focused, or when it comes right after the one before it. If Back keeps coming, the next one
/// goes through, so the app can never hold the user in; at rest Back works as always.
struct RemoteBackGuard: UIViewRepresentable {
    func makeUIView(context: Context) -> BackGuardHostView {
        BackGuardHostView()
    }

    func updateUIView(_ uiView: BackGuardHostView, context: Context) {}

    static func dismantleUIView(_ uiView: BackGuardHostView, coordinator: ()) {
        uiView.removeRecognizers()
    }
}

final class BackGuardHostView: UIView, UIGestureRecognizerDelegate {
    /// After a swallowed Back, a further one this soon goes through.
    static let passAfterSwallowWithin: CFTimeInterval = 1.5
    /// A Back this soon after the previous one lands while what that one closed is still closing.
    static let closingWithin: CFTimeInterval = 1.0

    private var recognizers: [(window: UIWindow, tap: UITapGestureRecognizer)] = []
    private var windowObserver: NSObjectProtocol?
    private var lastBack: CFTimeInterval = -.infinity
    private var lastSwallow: CFTimeInterval = -.infinity

    /// Swallow a Back while nothing is focused or right after the previous Back, unless the
    /// previous one was itself just swallowed.
    static func shouldSwallow(nothingFocused: Bool, sincePreviousBack: CFTimeInterval, sinceLastSwallow: CFTimeInterval) -> Bool {
        (nothingFocused || sincePreviousBack < closingWithin) && sinceLastSwallow >= passAfterSwallowWithin
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        removeRecognizers()
        guard let window, let scene = window.windowScene else { return }
        for sceneWindow in scene.windows { guardWindow(sceneWindow) }
        // Menus and alerts can come in windows of their own.
        windowObserver = NotificationCenter.default.addObserver(
            forName: UIWindow.didBecomeVisibleNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let newWindow = note.object as? UIWindow,
                  newWindow.windowScene === self.window?.windowScene else { return }
            self.guardWindow(newWindow)
        }
    }

    private func guardWindow(_ window: UIWindow) {
        recognizers.removeAll { $0.window !== window && $0.window.windowScene == nil }
        guard !recognizers.contains(where: { $0.window === window }) else { return }
        let tap = UITapGestureRecognizer(target: self, action: #selector(swallowed(_:)))
        tap.allowedPressTypes = [NSNumber(value: UIPress.PressType.menu.rawValue)]
        tap.allowedTouchTypes = []
        tap.delegate = self
        window.addGestureRecognizer(tap)
        recognizers.append((window, tap))
    }

    func removeRecognizers() {
        for entry in recognizers { entry.window.removeGestureRecognizer(entry.tap) }
        recognizers.removeAll()
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
        windowObserver = nil
    }

    @objc private func swallowed(_ recognizer: UITapGestureRecognizer) {}

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive press: UIPress) -> Bool {
        guard press.type == .menu, let window = gestureRecognizer.view as? UIWindow else { return false }
        let now = CACurrentMediaTime()
        let focused = window.windowScene?.focusSystem?.focusedItem
        let sincePrevious = now - lastBack
        lastBack = now
        let swallow = Self.shouldSwallow(
            nothingFocused: focused == nil,
            sincePreviousBack: sincePrevious,
            sinceLastSwallow: now - lastSwallow
        )
        if swallow { lastSwallow = now }
        return swallow
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        false
    }
}
