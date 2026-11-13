import SwiftUI
import UIKit

/// A static clock in the system tab bar's leading accessory area. The system
/// owns the bar and decides how much space is available for its accessories.
struct NativeTopBarClock: View {
    let enabled: Bool
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(SettingsKey.sidebarClockFormat) private var format = SidebarClockFormat.automatic.rawValue

    var body: some View {
        // Ticks on each minute boundary, like the sidebar clock, instead of up to 30 s late.
        TimelineView(.everyMinute) { context in
            let text = SidebarClockFormat.fromStored(format).formatter().string(from: context.date)
            NativeTopBarClockMarker(text: text, enabled: enabled && scenePhase == .active)
        }
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct NativeTopBarClockMarker: UIViewRepresentable {
    let text: String
    let enabled: Bool

    func makeUIView(context: Context) -> Marker { Marker() }

    func updateUIView(_ view: Marker, context: Context) {
        view.configure(text: text, enabled: enabled)
    }

    static func dismantleUIView(_ view: Marker, coordinator: ()) {
        view.dismantle()
    }

    /// Reports when the system moves the label in or out of the window, so the marker can
    /// put it back after a tab change, a profile switch or a rebuilt accessory area.
    final class ClockLabel: UILabel {
        var onWindowChange: (() -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            onWindowChange?()
        }
    }

    final class Marker: UIView {
        private let clockLabel = ClockLabel()
        private weak var accessory: UIView?
        private var wantsClock = false
        private var retryGeneration = 0

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            backgroundColor = .clear
            clockLabel.font = .monospacedDigitSystemFont(ofSize: 22, weight: .medium)
            clockLabel.textColor = UIColor.white.withAlphaComponent(0.8)
            clockLabel.textAlignment = .center
            clockLabel.adjustsFontSizeToFitWidth = true
            clockLabel.minimumScaleFactor = 0.75
            clockLabel.isUserInteractionEnabled = false
            clockLabel.isAccessibilityElement = true
            clockLabel.accessibilityTraits = .staticText
            clockLabel.onWindowChange = { [weak self] in self?.clockLabelWindowChanged() }
        }

        required init?(coder: NSCoder) { return nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { removeClock(); return }
            scheduleAttach()
        }

        func configure(text: String, enabled: Bool) {
            clockLabel.text = text
            clockLabel.accessibilityLabel = text
            if wantsClock != enabled {
                wantsClock = enabled
                if !enabled { removeClock(); return }
            }
            if enabled && !isAttached { scheduleAttach() }
        }

        /// The system can rebuild or empty the bar's accessory area (the bar hiding while
        /// content scrolls, a tab change), which takes the label out of the window while the
        /// weak reference to the old accessory may still be set. Attached means on screen.
        private var isAttached: Bool {
            guard let accessory else { return false }
            return clockLabel.superview === accessory && clockLabel.window != nil
        }

        private var isRetrying = false

        override func layoutSubviews() {
            super.layoutSubviews()
            // Layout passes come with tab and bar changes: reattach then, not only on the next minute.
            if wantsClock, !isAttached, !isRetrying { scheduleAttach() }
        }

        /// The label left the window while the marker is still on screen: the system took it
        /// out with the bar's old accessory area. Put it back in the current one.
        private func clockLabelWindowChanged() {
            guard wantsClock, window != nil, clockLabel.window == nil, !isRetrying else { return }
            scheduleAttach()
        }

        func dismantle() {
            wantsClock = false
            removeClock()
        }

        func removeClock() {
            retryGeneration += 1
            clockLabel.removeFromSuperview()
            accessory = nil
        }

        private func scheduleAttach() {
            guard wantsClock else { return }
            retryGeneration += 1
            let generation = retryGeneration
            isRetrying = true
            attemptAttach(generation: generation, attemptsRemaining: Self.fastAttempts + Self.slowAttempts)
        }

        private func attemptAttach(generation: Int, attemptsRemaining: Int) {
            guard wantsClock, generation == retryGeneration else { isRetrying = false; return }
            guard let window, let root = window.rootViewController else { isRetrying = false; return }
            let bars = Self.visibleTabBars(in: root, window: window)
            if bars.count == 1, let bar = bars.first {
                let target = bar.leadingAccessoryView
                if clockLabel.superview !== target || clockLabel.window == nil {
                    clockLabel.removeFromSuperview()
                    target.addSubview(clockLabel)
                    clockLabel.translatesAutoresizingMaskIntoConstraints = false
                    NSLayoutConstraint.activate([
                        clockLabel.centerXAnchor.constraint(equalTo: target.centerXAnchor),
                        clockLabel.centerYAnchor.constraint(equalTo: target.centerYAnchor),
                        clockLabel.leadingAnchor.constraint(greaterThanOrEqualTo: target.leadingAnchor),
                        clockLabel.trailingAnchor.constraint(lessThanOrEqualTo: target.trailingAnchor)
                    ])
                    accessory = target
                }
                isRetrying = false
                return
            }
            guard attemptsRemaining > 0 else { isRetrying = false; return }
            // Retry quickly at first, then slowly: after a profile switch the bar can take a
            // few seconds to come back, longer than the fast retries alone cover.
            let delay = attemptsRemaining > Self.slowAttempts ? 0.2 : 1.0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.attemptAttach(generation: generation, attemptsRemaining: attemptsRemaining - 1)
            }
        }

        private static let fastAttempts = 10
        private static let slowAttempts = 30

        private static func visibleTabBars(in root: UIViewController, window: UIWindow) -> [UITabBar] {
            var result: [UITabBar] = []
            var visited = Set<ObjectIdentifier>()
            func visit(_ controller: UIViewController) {
                guard visited.insert(ObjectIdentifier(controller)).inserted else { return }
                if let tab = controller as? UITabBarController,
                   tab.tabBar.window === window, !tab.tabBar.isHidden {
                    result.append(tab.tabBar)
                }
                for child in controller.children { visit(child) }
                if let presented = controller.presentedViewController { visit(presented) }
            }
            visit(root)
            return result
        }
    }
}
