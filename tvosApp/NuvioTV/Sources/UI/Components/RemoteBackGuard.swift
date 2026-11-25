import SwiftUI
import UIKit

/// Keeps a quick Back from sending the app to the Home screen.
///
/// Closing a panel or a native menu (subtitles, audio), leaving the player, or going back from
/// Details animates for a moment. A Back pressed then reaches no responder (the menu that took
/// the first one is on its way out, or nothing is focused yet — or UIKit still holds focus on
/// a dismissing `_UIContextMenuCell` whose container is already disabled/transparent), and tvOS
/// takes it as "leave the app". Installed once for the whole app, on every window: a Back is
/// swallowed while nothing interactive is focused, or when it comes right after the one before
/// it. On top-level Home (`allowsAppExit == true`), a repeated Back within 1.5s still goes
/// through so the user is never trapped; inside overlays (`allowsAppExit == false`), an
/// unusable-focus Back never exits the app.
struct RemoteBackGuard: UIViewRepresentable {
    var allowsAppExit: Bool = true

    func makeUIView(context: Context) -> BackGuardHostView {
        let view = BackGuardHostView()
        view.allowsAppExit = allowsAppExit
        return view
    }

    func updateUIView(_ uiView: BackGuardHostView, context: Context) {
        uiView.allowsAppExit = allowsAppExit
    }

    static func dismantleUIView(_ uiView: BackGuardHostView, coordinator: ()) {
        uiView.removeRecognizers()
    }
}

final class BackGuardHostView: UIView, UIGestureRecognizerDelegate {
    /// After a swallowed Back, a further one this soon goes through.
    static let passAfterSwallowWithin: CFTimeInterval = 1.5
    /// A Back this soon after the previous one lands while what that one closed is still closing.
    static let closingWithin: CFTimeInterval = 1.0

    /// A guarded window and its tap. The window is held weakly: tvOS shows a short-lived
    /// `_UISnapshotWindow` on every tab switch, and holding those strongly kept each one, with
    /// its ~40 MB of snapshots, alive for the life of the app.
    private struct Guarded {
        weak var window: UIWindow?
        let tap: UITapGestureRecognizer
    }

    var allowsAppExit: Bool = true
    private var recognizers: [Guarded] = []
    private var windowObserver: NSObjectProtocol?
    private var lastBack: CFTimeInterval = -.infinity
    private var lastSwallow: CFTimeInterval = -.infinity

    /// Swallow a Back while nothing interactive is focused or right after the previous Back,
    /// unless the previous one was itself just swallowed (except inside overlays when focus
    /// is missing/dismissing, where Back must never exit to Apple TV Home).
    static func shouldSwallow(
        nothingFocused: Bool,
        sincePreviousBack: CFTimeInterval,
        sinceLastSwallow: CFTimeInterval,
        allowsAppExit: Bool = true
    ) -> Bool {
        if nothingFocused {
            return !allowsAppExit || sinceLastSwallow >= passAfterSwallowWithin
        }
        return sincePreviousBack < closingWithin && sinceLastSwallow >= passAfterSwallowWithin
    }

    /// True when no focus item exists, or when the focused item sits inside a disabled, hidden,
    /// transparent, or dismissing view/controller (for example `_UIContextMenuCell` while UIKit
    /// animates the context menu away and ignores `.menu` presses).
    static func isFocusUnavailable(_ item: UIFocusItem?) -> Bool {
        guard let item else { return true }
        let startResponder: UIResponder? = (item as? UIResponder) ?? (item as? UIFocusGuide)?.owningView
        var cursor = startResponder
        while let current = cursor {
            if let view = current as? UIView {
                if !view.isUserInteractionEnabled || view.isHidden || view.alpha <= 0.01 {
                    return true
                }
                if view is UIWindow {
                    break
                }
            }
            if let controller = current as? UIViewController,
               controller.isBeingDismissed || controller.isMovingFromParent {
                return true
            }
            cursor = current.next
        }
        return false
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
        recognizers.removeAll { entry in
            guard let guarded = entry.window else { return true }
            return guarded !== window && guarded.windowScene == nil
        }
        guard !recognizers.contains(where: { $0.window === window }) else { return }
        let tap = UITapGestureRecognizer(target: self, action: #selector(swallowed(_:)))
        tap.allowedPressTypes = [NSNumber(value: UIPress.PressType.menu.rawValue)]
        tap.allowedTouchTypes = []
        tap.delegate = self
        window.addGestureRecognizer(tap)
        recognizers.append(Guarded(window: window, tap: tap))
    }

    func removeRecognizers() {
        for entry in recognizers { entry.window?.removeGestureRecognizer(entry.tap) }
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
            nothingFocused: Self.isFocusUnavailable(focused),
            sincePreviousBack: sincePrevious,
            sinceLastSwallow: now - lastSwallow,
            allowsAppExit: allowsAppExit
        )
        if swallow { lastSwallow = now }
        return swallow
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        false
    }
}
