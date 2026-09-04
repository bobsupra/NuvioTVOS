# tvOS & SwiftUI Best Practices for NuvioTVOS

## Focus Engine & Navigation Lifecycle

- **Native Button Styles over Gestures**:
  - Always implement interactive cards (posters, folders, catalog items) using native `Button(action: ...)` with `PosterCardButtonStyle()`.
  - Avoid `.contentShape() + .focusable() + .onTapGesture()` on cards, as it bypasses the tvOS focus engine and prevents reliable `.onChange(of: isFocused)` transitions.

- **Overlay Transitions & Deferred Preparation**:
  - When opening full-screen overlays (Details, Collection Folder, Cloud Library, Browse), set `focusWork.defersOverlayPreparation = true` and track `pendingOverlayRestoreCardID` to avoid premature focus locking before transition completion.
  - Implement `.onDisappear` on all modal/browse views to increment dismissal counters (`detailsDidDisappearGeneration &+= 1`), ensuring Home receives the unmount signal and unfreezes focus.

- **Focus Lock Safety & Fallbacks**:
  - Keep overlay focus safety unlock timeouts short ($\le$ 0.5s, never 3.0s) to prevent Apple TV remote input from freezing if a callback is missed.
  - In `HomeView.onChange(of: focusedCardID)`, directly complete focus restoration when the target card gains focus.

## View Hierarchy & Performance

- **Lazy Layouts**:
  - Maintain stable element identities (`id`) in `LazyVStack` and `LazyHStack` to prevent focus jumping to the top of the row during re-renders.
  - Avoid heavy computations inside view body properties; offload to ViewModels on background actors.

- **Playback & Engine Integration**:
  - Keep `AetherEngine` and AVPlayer lifecycle handshakes responsive on main thread; ensure demux/mux operations remain on background dispatch queues.
