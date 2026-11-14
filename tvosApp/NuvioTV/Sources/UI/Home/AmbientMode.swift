import SwiftUI
import UIKit

/// Ambient Mode: after a couple of minutes without remote input on Home, a
/// full-screen slideshow of backdrops from the user's catalogs fades in. Any
/// press or swipe dismisses it, and that input does nothing else.
///
/// It never holds off the tvOS screensaver: the system idle timer is left
/// alone, so the screensaver still starts at the time set in Settings.
@MainActor
final class UserActivityMonitor: ObservableObject {
    static let shared = UserActivityMonitor()

    private(set) var lastActivity = Date()
    /// When set, the next remote input is consumed and handed here instead of
    /// reaching the app (used to dismiss Ambient Mode).
    var interceptNextInput: (() -> Void)?

    fileprivate func noteInput() -> Bool {
        lastActivity = Date()
        guard let intercept = interceptNextInput else { return false }
        interceptNextInput = nil
        intercept()
        return true
    }

    func secondsSinceLastActivity(now: Date = Date()) -> TimeInterval {
        now.timeIntervalSince(lastActivity)
    }

    fileprivate weak var installedWindow: UIWindow?

    fileprivate func install(on window: UIWindow) {
        guard installedWindow !== window else { return }
        installedWindow = window
        window.addGestureRecognizer(ActivityGestureRecognizer(monitor: self))
    }
}

/// Watches every press and touch on the window without taking part in normal
/// handling: it fails straight away, unless Ambient Mode is showing, when it
/// recognizes the input so the views below never receive it.
@MainActor
private final class ActivityGestureRecognizer: UIGestureRecognizer {
    private weak var monitor: UserActivityMonitor?

    init(monitor: UserActivityMonitor) {
        self.monitor = monitor
        super.init(target: nil, action: nil)
        cancelsTouchesInView = true
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        allowedPressTypes = [
            UIPress.PressType.select, .menu, .playPause,
            .upArrow, .downArrow, .leftArrow, .rightArrow,
        ].map { NSNumber(value: $0.rawValue) }
        allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
    }

    private func handleInput() {
        let consumed = monitor?.noteInput() ?? false
        state = consumed ? .recognized : .failed
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        handleInput()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        handleInput()
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
        state == .recognized
    }

    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }
}

/// Installs the activity monitor on the window that hosts it.
struct UserActivityMonitorInstaller: UIViewRepresentable {
    func makeUIView(context: Context) -> InstallerView { InstallerView() }
    func updateUIView(_ uiView: InstallerView, context: Context) {}

    final class InstallerView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let window else { return }
            UserActivityMonitor.shared.install(on: window)
        }
    }
}

struct AmbientModeOverlay: View {
    struct Slide: Equatable, Identifiable {
        let id: String
        let title: String
        let backdropURL: URL
        let logoURL: URL?
    }

    /// Whether Home is on screen with nothing presented over it.
    let isEligible: Bool
    let slides: [Slide]

    static let idleDelay: TimeInterval = 120
    static let slideDuration: TimeInterval = 9

    @AppStorage(SettingsKey.ambientMode) private var ambientModeEnabled = false
    @State private var isShowing = false
    @State private var index = 0

    var body: some View {
        ZStack {
            if isShowing, !slides.isEmpty {
                slideshow
                    .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 1.2), value: isShowing)
        .task(id: isEligible && ambientModeEnabled && !slides.isEmpty) {
            guard isEligible, ambientModeEnabled, !slides.isEmpty else {
                hide()
                return
            }
            await watchForIdle()
        }
        .onDisappear { hide() }
    }

    private var slideshow: some View {
        let slide = slides[index % slides.count]
        return ZStack(alignment: .bottomLeading) {
            Color.black
            AsyncImage(url: slide.backdropURL) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    Color.black
                }
            }
            .id(slide.id)
            .transition(.opacity)
            .clipped()

            LinearGradient(
                colors: [.clear, .black.opacity(0.75)],
                startPoint: .center,
                endPoint: .bottom
            )

            Group {
                if let logoURL = slide.logoURL {
                    AsyncImage(url: logoURL) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFit()
                        } else {
                            Text(slide.title)
                        }
                    }
                    .frame(maxWidth: 520, maxHeight: 160, alignment: .bottomLeading)
                } else {
                    Text(slide.title)
                }
            }
            .font(.system(size: 48, weight: .bold))
            .foregroundColor(.white)
            .shadow(radius: 12)
            .padding(.leading, 90)
            .padding(.bottom, 80)
            .id("title-\(slide.id)")
            .transition(.opacity)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 1.5), value: slide.id)
    }

    private func watchForIdle() async {
        while !Task.isCancelled {
            if isShowing {
                try? await Task.sleep(nanoseconds: UInt64(Self.slideDuration * 1_000_000_000))
                guard !Task.isCancelled, isShowing else { continue }
                index = (index + 1) % max(slides.count, 1)
            } else {
                let idle = UserActivityMonitor.shared.secondsSinceLastActivity()
                if idle >= Self.idleDelay {
                    show()
                } else {
                    let wait = min(max(Self.idleDelay - idle, 1), 15)
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                }
            }
        }
        hide()
    }

    private func show() {
        index = Int.random(in: 0..<max(slides.count, 1))
        isShowing = true
        UserActivityMonitor.shared.interceptNextInput = {
            isShowing = false
        }
    }

    private func hide() {
        isShowing = false
        UserActivityMonitor.shared.interceptNextInput = nil
    }

    /// Up to 40 titles with backdrops, from the rows on Home, without repeats.
    static func slides(from metas: [NuvioMeta], backdropURL: (NuvioMeta) -> String?) -> [Slide] {
        var seen = Set<String>()
        var result: [Slide] = []
        for meta in metas {
            guard result.count < 40, seen.insert(meta.id).inserted,
                  let raw = backdropURL(meta), let url = URL(string: raw) else { continue }
            result.append(Slide(
                id: meta.id,
                title: meta.name,
                backdropURL: url,
                logoURL: meta.logoUrl.flatMap(URL.init(string:))
            ))
        }
        return result
    }
}
