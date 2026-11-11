import SwiftUI
import UIKit

/// A static clock in the system tab bar's leading accessory area. The system
/// owns the bar and decides how much space is available for its accessories.
struct NativeTopBarClock: View {
    let enabled: Bool
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(SettingsKey.sidebarClockFormat) private var format = SidebarClockFormat.automatic.rawValue

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
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
        view.removeClock()
    }

    final class Marker: UIView {
        private let clockLabel = UILabel()
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
            if enabled && accessory == nil { scheduleAttach() }
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
            attemptAttach(generation: generation, attemptsRemaining: 10)
        }

        private func attemptAttach(generation: Int, attemptsRemaining: Int) {
            guard wantsClock, generation == retryGeneration else { return }
            guard let window, let root = window.rootViewController else { return }
            let bars = Self.visibleTabBars(in: root, window: window)
            if bars.count == 1, let bar = bars.first {
                let target = bar.leadingAccessoryView
                if accessory !== target {
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
                return
            }
            guard attemptsRemaining > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.attemptAttach(generation: generation, attemptsRemaining: attemptsRemaining - 1)
            }
        }

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
