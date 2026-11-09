import SwiftUI

extension AnyTransition {
    /// A full-screen screen (Details, the player, a browse view) fades in and out as before,
    /// but stops taking focus the moment it starts to leave.
    ///
    /// While a leaving screen faded out it stayed focusable. tvOS could then move focus onto
    /// one of its items just as SwiftUI removed it at the end of the fade, and UIKit ends the
    /// app for that ("The newly focused item or one of its parent environments is getting
    /// removed from the hierarchy"). Going back from Details to Home crashed this way now and
    /// then. Disabled, the leaving screen gives up focus at once, before it is removed.
    static var leavingScreen: AnyTransition {
        .asymmetric(
            insertion: .opacity,
            removal: .opacity.combined(
                with: .modifier(
                    active: LeavingScreenModifier(isLeaving: true),
                    identity: LeavingScreenModifier(isLeaving: false)
                )
            )
        )
    }
}

/// Takes a leaving screen out of focus (see `AnyTransition.leavingScreen`).
struct LeavingScreenModifier: ViewModifier {
    let isLeaving: Bool

    func body(content: Content) -> some View {
        content.disabled(isLeaving)
    }
}
