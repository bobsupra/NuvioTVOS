import SwiftUI
import UIKit

/// A static clock in the system tab bar's trailing accessory area. The system
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

/// A non-selectable profile placeholder in the system tab bar's leading accessory area.
struct NativeTopBarProfilePlaceholder: View {
    let enabled: Bool
    let title: String
    let avatar: UIImage?
    let avatarSymbol: String
    let needsReauth: Bool

    var body: some View {
        NativeTopBarProfileMarker(
            enabled: enabled,
            title: title,
            avatar: avatar,
            avatarSymbol: avatarSymbol,
            needsReauth: needsReauth
        )
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

enum TVTabBarAppearanceConfigurator {
    static func configure(tabBar: UITabBar) {
        let appearance = UITabBarAppearance(barAppearance: tabBar.standardAppearance)
        appearance.configureWithTransparentBackground()

        appearance.inlineLayoutAppearance.focused.iconColor = .black
        appearance.inlineLayoutAppearance.focused.titleTextAttributes = [.foregroundColor: UIColor.black]
        appearance.stackedLayoutAppearance.focused.iconColor = .black
        appearance.stackedLayoutAppearance.focused.titleTextAttributes = [.foregroundColor: UIColor.black]
        appearance.compactInlineLayoutAppearance.focused.iconColor = .black
        appearance.compactInlineLayoutAppearance.focused.titleTextAttributes = [.foregroundColor: UIColor.black]

        tabBar.standardAppearance = appearance
        tabBar.scrollEdgeAppearance = appearance

        if let items = tabBar.items {
            for item in items {
                if let image = item.image, image.renderingMode != .alwaysTemplate {
                    item.image = image.withRenderingMode(.alwaysTemplate)
                }
                if let selected = item.selectedImage, selected.renderingMode != .alwaysTemplate {
                    item.selectedImage = selected.withRenderingMode(.alwaysTemplate)
                }
            }
        }
    }
}

private struct NativeTopBarProfileMarker: UIViewRepresentable {
    let enabled: Bool
    let title: String
    let avatar: UIImage?
    let avatarSymbol: String
    let needsReauth: Bool

    func makeUIView(context: Context) -> Marker { Marker() }

    func updateUIView(_ view: Marker, context: Context) {
        view.configure(
            enabled: enabled,
            title: title,
            avatar: avatar,
            avatarSymbol: avatarSymbol,
            needsReauth: needsReauth
        )
    }

    static func dismantleUIView(_ view: Marker, coordinator: ()) {
        view.dismantle()
    }

    final class PlaceholderContainer: UIView {
        var onWindowChange: (() -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            onWindowChange?()
        }

        override var canBecomeFocused: Bool { false }
    }

    final class Marker: UIView {
        private let container = PlaceholderContainer()
        private let avatarImageView = UIImageView()
        private let nameLabel = UILabel()
        private weak var accessory: UIView?
        private var wantsPlaceholder = false
        private var retryGeneration = 0
        private var isRetrying = false

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            backgroundColor = .clear

            container.isUserInteractionEnabled = false
            container.backgroundColor = .clear

            avatarImageView.contentMode = .scaleAspectFill
            avatarImageView.clipsToBounds = true
            avatarImageView.layer.cornerRadius = 14
            avatarImageView.translatesAutoresizingMaskIntoConstraints = false
            avatarImageView.tintColor = UIColor.white.withAlphaComponent(0.85)

            nameLabel.font = .systemFont(ofSize: 20, weight: .semibold)
            nameLabel.textColor = UIColor.white.withAlphaComponent(0.85)
            nameLabel.translatesAutoresizingMaskIntoConstraints = false

            container.addSubview(avatarImageView)
            container.addSubview(nameLabel)

            NSLayoutConstraint.activate([
                avatarImageView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                avatarImageView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                avatarImageView.widthAnchor.constraint(equalToConstant: 28),
                avatarImageView.heightAnchor.constraint(equalToConstant: 28),

                nameLabel.leadingAnchor.constraint(equalTo: avatarImageView.trailingAnchor, constant: 10),
                nameLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                nameLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor)
            ])

            container.onWindowChange = { [weak self] in self?.containerWindowChanged() }
        }

        required init?(coder: NSCoder) { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { removePlaceholder(); return }
            scheduleAttach()
        }

        func configure(enabled: Bool, title: String, avatar: UIImage?, avatarSymbol: String, needsReauth: Bool) {
            nameLabel.text = title
            if needsReauth {
                avatarImageView.image = UIImage(systemName: "person.crop.circle.badge.exclamationmark")
            } else if let avatar {
                avatarImageView.image = avatar
            } else {
                avatarImageView.image = UIImage(systemName: avatarSymbol)
            }

            if wantsPlaceholder != enabled {
                wantsPlaceholder = enabled
                if !enabled { removePlaceholder(); return }
            }
            if enabled && !isAttached { scheduleAttach() }
        }

        private var isAttached: Bool {
            guard let accessory else { return false }
            return container.superview === accessory && container.window != nil
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            if wantsPlaceholder, !isAttached, !isRetrying { scheduleAttach() }
        }

        private func containerWindowChanged() {
            guard wantsPlaceholder, window != nil, container.window == nil, !isRetrying else { return }
            scheduleAttach()
        }

        func dismantle() {
            wantsPlaceholder = false
            removePlaceholder()
        }

        func removePlaceholder() {
            retryGeneration += 1
            container.removeFromSuperview()
            accessory = nil
        }

        private func scheduleAttach() {
            guard wantsPlaceholder else { return }
            retryGeneration += 1
            let generation = retryGeneration
            isRetrying = true
            attemptAttach(generation: generation, attemptsRemaining: Self.fastAttempts + Self.slowAttempts)
        }

        private func attemptAttach(generation: Int, attemptsRemaining: Int) {
            guard wantsPlaceholder, generation == retryGeneration else { isRetrying = false; return }
            guard let window, let root = window.rootViewController else { isRetrying = false; return }
            let bars = NativeTopBarClockMarker.Marker.visibleTabBars(in: root, window: window)
            if bars.count == 1, let bar = bars.first {
                TVTabBarAppearanceConfigurator.configure(tabBar: bar)
                let target = bar.leadingAccessoryView
                if container.superview !== target || container.window == nil {
                    container.removeFromSuperview()
                    target.addSubview(container)
                    container.translatesAutoresizingMaskIntoConstraints = false
                    NSLayoutConstraint.activate([
                        container.leadingAnchor.constraint(equalTo: target.leadingAnchor, constant: 14),
                        container.centerYAnchor.constraint(equalTo: target.centerYAnchor),
                        container.trailingAnchor.constraint(lessThanOrEqualTo: target.trailingAnchor)
                    ])
                    accessory = target
                }
                isRetrying = false
                return
            }
            guard attemptsRemaining > 0 else { isRetrying = false; return }
            let delay = attemptsRemaining > Self.slowAttempts ? 0.2 : 1.0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.attemptAttach(generation: generation, attemptsRemaining: attemptsRemaining - 1)
            }
        }

        private static let fastAttempts = 10
        private static let slowAttempts = 30
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
                TVTabBarAppearanceConfigurator.configure(tabBar: bar)
                let target = bar.trailingAccessoryView
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

        static func visibleTabBars(in root: UIViewController, window: UIWindow) -> [UITabBar] {
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
