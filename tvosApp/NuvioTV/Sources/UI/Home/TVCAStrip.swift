import SwiftUI
import UIKit

/// A row of cards that tvOS doesn't scroll: Core Animation moves it so the card at `index` is
/// where the first card is at rest (under the row's title), as Home's rows. The move runs in the
/// render server, so it stays smooth while the main thread builds what focus brought.
///
/// `step`: from one card's start to the next one's. The cards draw past the row's edges, and
/// there is room after the last card for it to come to the start.
struct TVCAStrip<Content: View>: View {
    let index: Int
    let step: CGFloat
    var animated: Bool = true
    @ViewBuilder let content: () -> Content

    @State private var box = TVScrollViewBox()

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            content()
                .padding(.trailing, UIScreen.main.bounds.width)
                .background {
                    TVScrollViewFinder(box: box)
                        .frame(width: 1, height: 1)
                        .allowsHitTesting(false)
                }
        }
        .scrollDisabled(true)
        .scrollClipDisabledIfAvailable()
        .onChange(of: index) { _, index in
            move(to: index, animated: animated)
        }
        .onAppear {
            moveOnceFound(to: index)
        }
    }

    @discardableResult
    private func move(to index: Int, animated: Bool) -> Bool {
        guard let scrollView = box.scrollView else { return false }
        TVScrollMove.move(
            scrollView,
            to: CGPoint(x: CGFloat(index) * step, y: scrollView.contentOffset.y),
            animated: animated
        )
        return true
    }

    /// Where the row was left (focus coming back to it), once SwiftUI has made its scroll view.
    private func moveOnceFound(to index: Int, attempt: Int = 0) {
        guard index > 0, !move(to: index, animated: false), attempt < 6 else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(30))
            moveOnceFound(to: index, attempt: attempt + 1)
        }
    }
}

/// Stops the UIKit scroll view this sits in from scrolling for focus: tvOS still moves focus to
/// what is off screen in it, and the screen moves the scroll view there by Core Animation.
struct TVScrollLock: UIViewRepresentable {
    let locked: Bool

    final class LockView: UIView {
        var locked = false
        private weak var lockedScrollView: UIScrollView?
        private var scrollEnabledObservation: NSKeyValueObservation?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            apply()
        }

        func apply() {
            // After SwiftUI's own update of the scroll view.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil else { return }
                var current = self.superview
                while let candidate = current, !(candidate is UIScrollView) { current = candidate.superview }
                guard let scrollView = current as? UIScrollView else { return }
                if self.locked {
                    self.lock(scrollView)
                } else if let lockedScrollView = self.lockedScrollView {
                    self.scrollEnabledObservation = nil
                    self.lockedScrollView = nil
                    lockedScrollView.isScrollEnabled = true
                }
            }
        }

        private func lock(_ scrollView: UIScrollView) {
            scrollView.isScrollEnabled = false
            guard lockedScrollView !== scrollView else { return }
            lockedScrollView = scrollView
            // SwiftUI sets its scroll view scrolling again in some of its updates (Details'
            // content disabled and enabled again around the stream list), which needn't update
            // this view: tvOS then scrolled for focus as well, its scroll and the Core Animation
            // move added up, and Details went far past its ends. Turned off again at once.
            scrollEnabledObservation = scrollView.observe(\.isScrollEnabled, options: [.new]) { scrollView, change in
                guard change.newValue == true else { return }
                MainActor.assumeIsolated { scrollView.isScrollEnabled = false }
            }
        }
    }

    func makeUIView(context: Context) -> LockView {
        let view = LockView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.locked = locked
        return view
    }

    func updateUIView(_ uiView: LockView, context: Context) {
        uiView.locked = locked
        uiView.apply()
    }
}

/// A page's UIKit scroll view, and where each of its parts starts in its content, so the page
/// can move to a part by Core Animation (with `TVScrollLock`, tvOS doesn't scroll it).
///
/// The page goes on following the part it was last asked to move to: asked before the part was
/// laid out (metadata still loading, the main thread held up), it moves once the part's place is
/// known; if the part moves later (the content above it changed), it moves with it.
final class TVScrollTops {
    let scrollBox = TVScrollViewBox()
    private(set) var tops: [String: CGFloat] = [:]
    private var target: Target?

    private struct Target {
        let key: String
        let margin: CGFloat
        let toTop: Bool
    }

    init() {
        // The page's content put in another scroll view: that one goes where the page was.
        scrollBox.onReplaced = { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, let target = self.target else { return }
                self.apply(target)
            }
        }
    }

    /// The page's scroll view, while it is on screen.
    var scrollView: UIScrollView? {
        guard let scrollView = scrollBox.scrollView, scrollView.window != nil else { return nil }
        return scrollView
    }

    /// `contentMinY`: where the part starts in the page's content (`TVScrollTopReader`, in a
    /// space on the content itself, so it doesn't change as the page scrolls).
    func record(_ key: String, contentMinY: CGFloat) {
        guard tops[key] != contentMinY else { return }
        tops[key] = contentMinY
        if let target, target.key == key, !target.toTop {
            apply(target)
        }
    }

    /// Moves the page so part `key` starts `margin` below the top of the screen, or to the very
    /// top (`toTop`, the page's first part). False while the page's scroll view, or the part's
    /// place, isn't known yet: the move is made once the part's place comes.
    @discardableResult
    func move(to key: String, margin: CGFloat, toTop: Bool) -> Bool {
        let target = Target(key: key, margin: margin, toTop: toTop)
        self.target = target
        return apply(target)
    }

    @discardableResult
    private func apply(_ target: Target) -> Bool {
        guard let scrollView else { return false }
        let inset = scrollView.adjustedContentInset
        let y: CGFloat
        if target.toTop {
            y = -inset.top
        } else {
            guard let top = tops[target.key] else { return false }
            y = top - target.margin - inset.top
        }
        // A scroll UIKit may be running (tvOS's for focus, were it ever on) stops where it is, so
        // it doesn't add up with the move.
        scrollView.setContentOffset(scrollView.contentOffset, animated: false)
        let current = scrollView.contentOffset
        let maxY = max(-inset.top, scrollView.contentSize.height + inset.bottom - scrollView.bounds.height)
        // Already there (or going there: the move sets where the scroll ends at once).
        guard abs(current.y - min(max(y, -inset.top), maxY)) >= 1 else { return true }
        TVScrollMove.move(scrollView, to: CGPoint(x: current.x, y: y), animated: true)
        return true
    }
}

/// Records where the view starts in `space`, a coordinate space on the page's content (put on
/// the outermost view inside the scroll view), for `TVScrollTops`.
struct TVScrollTopReader: ViewModifier {
    let key: String
    let tops: TVScrollTops
    let space: String

    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGFloat.self) { proxy in
            proxy.frame(in: .named(space)).minY
        } action: { minY in
            tops.record(key, contentMinY: minY)
        }
    }
}
