//
//  PosterCard.swift
//  NuvioTV
//
//  Created by Claude Code
//  Reusable poster card component for iOS/tvOS
//

import ImageIO
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Poster card component with focus animation (tvOS) and tap handling (iOS)
struct PosterCard: View {
    let meta: NuvioMeta
    var isLandscape: Bool = false
    var continueProgress: Double? = nil
    var continueRemainingText: String? = nil
    var continueEpisodeText: String? = nil
    var continueEpisodeTitleText: String? = nil
    /// The episode still is more useful than the series backdrop for an up-next
    /// card: it matches the episode title and the Android Continue Watching row.
    var continueEpisodeArtworkURL: String? = nil
    /// Fresh next-episode suggestion: the badge reads "Next Up" (or "New Episode"
    /// for a genuinely fresh drop) and the progress bar is hidden, since there's
    /// no real playback position yet.
    var continueIsUpNext: Bool = false
    var continueUpNextBadgeText: String? = nil
    var showsWatchedBadge: Bool = true
    var shouldRequestInitialFocus: Bool = false
    var onInitialFocusRequested: (() -> Void)? = nil
    var onFocus: ((NuvioMeta) -> Void)? = nil
    var onBlur: ((NuvioMeta) -> Void)? = nil
    /// Optional shared focus state so a parent can drive `.defaultFocus`
    /// restoration — e.g. returning to the exact card after the menu. Keyed by
    /// `externalFocusValue` (must be unique per card instance, since the same
    /// meta.id can appear in more than one row), falling back to meta.id.
    var externalFocus: FocusState<String?>.Binding? = nil
    var externalFocusValue: String? = nil
    /// Fired when the card is held (Siri Remote select press-and-hold), to raise
    /// the liquid-glass quick-actions menu. Nil disables the long-press.
    var onLongPress: ((NuvioMeta) -> Void)? = nil
    var layoutMode: String = "Modern"
    var showPosterLabels: Bool = false
    var smoothFocusAnimations: Bool = true
    var focusHighlighterEnabled: Bool = false
    /// Keeps the last-selected card visually outlined while an overlay owns
    /// tvOS focus. The parent supplies this for exactly one saved card.
    var retainFocusAppearance: Bool = false
    var isWatched: Bool? = nil
    let onClick: () -> Void

    private let landscapeTransitionDuration: TimeInterval = 0.3

    #if os(tvOS)
    @FocusState private var isFocused: Bool
    @State private var didRequestInitialFocus = false
    #endif

    var body: some View {
        #if os(tvOS)
        posterContent
            .contentShape(Rectangle())
            .focusable(true)
            .focused($isFocused)
            .modifier(ExternalFocusBinding(binding: externalFocus, id: externalFocusValue ?? meta.id))
            .nuvioFocusEffectDisabledIfAvailable()
            .onTapGesture(perform: onClick)
            // Press-and-hold the select button while the card is focused to
            // raise the liquid-glass quick-actions menu. Kept simultaneous so
            // a normal select still fires `onClick`.
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.45).onEnded { _ in
                    onLongPress?(meta)
                }
            )
            .onChange(of: isFocused) { focused in
                if focused {
                    onFocus?(meta)
                } else {
                    onBlur?(meta)
                }
            }
            .onAppear {
                guard shouldRequestInitialFocus, !didRequestInitialFocus else {
                    return
                }

                didRequestInitialFocus = true
                onInitialFocusRequested?()
                DispatchQueue.main.async {
                    isFocused = true
                }
            }
            // The row cell takes the full (landscape) width so neighbouring
            // cards are pushed aside rather than overlapped, while the focusable
            // surface stays portrait-width — keeping up/down navigation aligned.
            .frame(width: cardWidth, height: totalCardHeight, alignment: .topLeading)
            // Critically damped — no overshoot when expanding to landscape on Home.
            .animation(
                effectiveSmoothFocus
                    ? .spring(response: landscapeTransitionDuration, dampingFraction: 1.0)
                    : nil,
                value: isLandscape
            )
        #else
        Button(action: onClick) {
            posterContent
        }
        .buttonStyle(PosterCardButtonStyle())
        .frame(width: cardWidth, height: totalCardHeight, alignment: .topLeading)
        #endif
    }

    private var posterContent: some View {
        VStack(alignment: .leading, spacing: 9) {
            CachedPosterArtwork(
                urlString: imageUrl,
                width: cardWidth,
                height: cardHeight,
                minimumSwapDelay: isLandscape && effectiveSmoothFocus ? landscapeTransitionDuration : 0
            ) {
                placeholderView
            }
            .frame(width: cardWidth, height: cardHeight)
            .clipShape(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
            .overlay(alignment: .bottomLeading) {
                if isLandscape {
                    landscapeOverlay
                }
            }
            .overlay(alignment: .bottomLeading) {
                continueProgressOverlay
            }
            .overlay(alignment: .topTrailing) {
                continueBadge
            }
            .overlay(alignment: .topTrailing) {
                if showsWatchedBadge {
                    if let isWatched {
                        if isWatched {
                            WatchedCheckmarkIcon()
                        }
                    } else {
                        WatchedCheckmarkBadge(metaId: meta.id, type: meta.type)
                    }
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                    .stroke(focusedBorderColor, lineWidth: focusedBorderWidth)
            )
            .shadow(color: .black.opacity(shadowOpacity), radius: shadowRadius)

            if showsPosterTitle {
                Text(meta.name)
                    .font(.system(size: effectiveHomeLayout == "Compact" ? 18 : 20, weight: showsFocusedAppearance ? .semibold : .medium))
                    .foregroundColor(titleColor)
                    .lineLimit(1)
                    .frame(width: cardWidth, alignment: .leading)
            }
        }
        .frame(width: layoutWidth, height: totalCardHeight, alignment: .topLeading)
    }

    // MARK: - Helper Views

    private var placeholderView: some View {
        ZStack {
            Rectangle()
                .fill(Color.white.opacity(0.08))
            Image(systemName: "photo")
                .resizable()
                .scaledToFit()
                .frame(width: 42, height: 42)
                .foregroundColor(.white.opacity(0.38))
        }
    }

    @ViewBuilder
    private var landscapeOverlay: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(
                colors: [.clear, .black.opacity(0.78)],
                startPoint: .center,
                endPoint: .bottom
            )

            if continueEpisodeText != nil {
                continueLandscapeSummary
            } else if let logoUrl = meta.logoUrl {
                AsyncImage(url: URL(string: logoUrl)) { phase in
                    if case .success(let image) = phase {
                        image
                            .resizable()
                            .scaledToFit()
                    } else {
                        fallbackTitle
                    }
                }
                .frame(width: landscapeLogoWidth, height: landscapeLogoHeight, alignment: .leading)
                .padding(22)
            } else {
                fallbackTitle
                    .frame(maxWidth: cardWidth * 0.62, alignment: .leading)
                    .padding(22)
            }
        }
    }

    private var continueLandscapeSummary: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let continueEpisodeText {
                Text(continueEpisodeText)
                    .font(.system(size: 25, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
            }

            Text(meta.name)
                .font(.system(size: 28, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.82)

            if let continueEpisodeTitleText, !continueEpisodeTitleText.isEmpty {
                Text(continueEpisodeTitleText)
                    .font(.system(size: 23, weight: .medium))
                    .foregroundColor(.white.opacity(0.66))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
        }
        .frame(maxWidth: cardWidth * 0.70, alignment: .leading)
        .padding(EdgeInsets(top: 22, leading: 22, bottom: 54, trailing: 22))
    }

    private var fallbackTitle: some View {
        Text(meta.name)
            .font(.custom("Inter-Bold", size: 34))
            .foregroundColor(.white)
            .lineLimit(2)
    }

    @ViewBuilder
    private var continueBadge: some View {
        if let continueBadgeDisplayText {
            Text(continueBadgeDisplayText)
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.black.opacity(0.72))
            )
            .padding(16)
        }
    }

    private var continueBadgeDisplayText: String? {
        if continueIsUpNext { return continueUpNextBadgeText ?? "Next Up" }
        guard let continueRemainingText else { return nil }
        if let continueEpisodeText {
            return "\(continueEpisodeText) • \(continueRemainingText)"
        }
        return continueRemainingText
    }

    @ViewBuilder
    private var continueProgressOverlay: some View {
        if let continueProgress, !continueIsUpNext {
            let progress = CGFloat(min(max(continueProgress, 0), 1))
            GeometryReader { geo in
                let width = max(0, geo.size.width - 44)

                VStack {
                    Spacer()
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.38))
                            .frame(width: width, height: 8)

                        Capsule()
                            .fill(Color.white)
                            .frame(width: max(8, width * progress), height: 8)
                    }
                    .padding(.leading, 22)
                    .padding(.bottom, 16)
                }
            }
        }
    }

    // MARK: - Computed Properties

    #if os(tvOS)
    private var effectiveHomeLayout: String {
        layoutMode
    }

    private var effectivePosterLabels: Bool {
        showPosterLabels
    }

    private var effectiveSmoothFocus: Bool {
        smoothFocusAnimations
    }

    private var effectiveFocusHighlighter: Bool {
        focusHighlighterEnabled
    }

    private var cardWidth: CGFloat {
        if isLandscape {
            return 560
        }
        return effectiveHomeLayout == "Compact" ? 170 : 210
    }

    /// Width the card occupies in the row layout — and therefore its focus
    /// frame. Always the portrait width, even while the landscape art is shown,
    /// so a focused landscape card does NOT widen its focus region and bump
    /// vertical navigation onto the neighbouring column. The 560pt landscape art
    /// overflows this frame to the right and is drawn above siblings (zIndex).
    private var layoutWidth: CGFloat {
        effectiveHomeLayout == "Compact" ? 170 : 210
    }

    private var cardHeight: CGFloat {
        isLandscape ? 315 : (effectiveHomeLayout == "Compact" ? 255 : 315)
    }

    private var totalCardHeight: CGFloat {
        cardHeight + (showsPosterTitle ? 36 : 0)
    }

    private var landscapeLogoWidth: CGFloat {
        250
    }

    private var landscapeLogoHeight: CGFloat {
        76
    }

    private var cardCornerRadius: CGFloat {
        16
    }

    private var imageUrl: String? {
        if isLandscape, continueEpisodeText != nil,
           let continueEpisodeArtworkURL, !continueEpisodeArtworkURL.isEmpty {
            return continueEpisodeArtworkURL
        }
        return isLandscape ? (meta.backgroundUrl ?? meta.posterUrl) : meta.posterUrl
    }

    private var focusedBorderColor: Color {
        guard showsFocusedAppearance else { return .clear }
        return AppFocusOutline.color
    }

    private var focusedBorderWidth: CGFloat {
        showsFocusedAppearance ? (effectiveFocusHighlighter ? AppFocusOutline.emphasizedWidth : AppFocusOutline.width) : 0
    }

    private var shadowOpacity: Double {
        showsFocusedAppearance ? 0.24 : 0.12
    }

    private var shadowRadius: CGFloat {
        showsFocusedAppearance ? 10 : 4
    }

    private var titleColor: Color {
        showsFocusedAppearance ? .white : .white.opacity(0.55)
    }

    private var showsFocusedAppearance: Bool {
        isFocused || retainFocusAppearance
    }

    private var showsPosterTitle: Bool {
        effectivePosterLabels
    }
    #else
    private var cardWidth: CGFloat {
        150
    }

    private var layoutWidth: CGFloat {
        150
    }

    private var cardHeight: CGFloat {
        225
    }

    private var cardCornerRadius: CGFloat {
        8
    }

    private var landscapeLogoWidth: CGFloat {
        0
    }

    private var landscapeLogoHeight: CGFloat {
        0
    }

    private var imageUrl: String? {
        meta.posterUrl
    }

    private var focusedBorderColor: Color {
        .clear
    }

    private var focusedBorderWidth: CGFloat {
        0
    }

    private var shadowOpacity: Double {
        0.2
    }

    private var shadowRadius: CGFloat {
        4
    }

    private var titleColor: Color {
        .primary
    }

    private var totalCardHeight: CGFloat {
        cardHeight
    }

    private var showsPosterTitle: Bool {
        false
    }
    #endif
}

#if canImport(UIKit)
private struct CachedPosterArtwork<Placeholder: View>: View {
    let urlString: String?
    let width: CGFloat
    let height: CGFloat
    let minimumSwapDelay: TimeInterval
    @ViewBuilder let placeholder: Placeholder

    @State private var image: UIImage?
    @State private var loadedKey: String?
    /// Keep the preceding artwork variant alive while the card changes shape.
    /// A Home card swaps between poster and backdrop URLs; retaining both lets
    /// the poster reappear immediately and crop down with the width animation
    /// instead of flashing the placeholder for a frame.
    @State private var previousImage: UIImage?
    @State private var previousLoadedKey: String?

    private var maxPixelSize: Int {
        let displayScale = UIScreen.main.scale
        return max(160, Int(ceil(max(width, height) * displayScale)))
    }

    private var cacheKey: String {
        "\(urlString ?? "")#\(maxPixelSize)"
    }

    var body: some View {
        ZStack {
            if let image = displayedImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                placeholder
            }
        }
        .task(id: cacheKey) {
            await load()
        }
    }

    private var displayedImage: UIImage? {
        if loadedKey == cacheKey { return image }
        if previousLoadedKey == cacheKey { return previousImage }

        // While a brand-new variant is loading, keep real artwork on screen.
        // For landscape expansion this naturally starts with a zoomed poster;
        // for collapse the matching portrait is normally `previousImage`.
        return image ?? previousImage
    }

    @MainActor
    private func load() async {
        guard let urlString,
              let url = URL(string: urlString) else {
            image = nil
            loadedKey = nil
            previousImage = nil
            previousLoadedKey = nil
            return
        }

        let key = cacheKey
        let loadStartedAt = Date()
        if loadedKey == key { return }

        // Moving back from landscape to portrait should be synchronous. The
        // portrait was retained when the landscape artwork replaced it, so
        // promote it without waiting for even an in-memory actor lookup.
        if previousLoadedKey == key, let previousImage {
            image = previousImage
            loadedKey = key
            self.previousImage = nil
            previousLoadedKey = nil
            return
        }

        if let cached = await PosterArtworkCache.shared.image(for: url, maxPixelSize: maxPixelSize) {
            let remainingDelay = minimumSwapDelay - Date().timeIntervalSince(loadStartedAt)
            if remainingDelay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(remainingDelay * 1_000_000_000))
            }
            guard !Task.isCancelled, key == cacheKey else { return }
            previousImage = image
            previousLoadedKey = loadedKey
            image = cached
            loadedKey = key
        }
    }
}

private actor PosterArtworkCache {
    static let shared = PosterArtworkCache()

    private let cache = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    init() {
        cache.countLimit = 220
        cache.totalCostLimit = 140 * 1024 * 1024
    }

    func image(for url: URL, maxPixelSize: Int) async -> UIImage? {
        let boundedPixelSize = min(max(maxPixelSize, 160), 1400)
        let key = "\(url.absoluteString)#\(boundedPixelSize)" as NSString

        if let cached = cache.object(forKey: key) {
            return cached
        }

        if let task = inFlight[key as String] {
            return await task.value
        }

        let task = Task.detached(priority: .utility) { () -> UIImage? in
            guard let (data, _) = try? await URLSession.shared.data(from: url) else {
                return nil
            }
            return downsamplePosterImage(data: data, maxPixelSize: boundedPixelSize)
        }

        inFlight[key as String] = task
        let image = await task.value
        inFlight[key as String] = nil

        if let image {
            cache.setObject(image, forKey: key, cost: image.decodedByteCost)
        }
        return image
    }
}

private func downsamplePosterImage(data: Data, maxPixelSize: Int) -> UIImage? {
    let sourceOptions: [CFString: Any] = [
        kCGImageSourceShouldCache: false
    ]
    guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else {
        return UIImage(data: data)
    }

    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
    ]

    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
        return UIImage(data: data)
    }
    return UIImage(cgImage: cgImage)
}

private extension UIImage {
    var decodedByteCost: Int {
        guard let cgImage else { return 0 }
        return cgImage.bytesPerRow * cgImage.height
    }
}
#endif

private struct WatchedCheckmarkIcon: View {
    var size: CGFloat = 38

    var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: size * 0.48, weight: .bold))
            .foregroundColor(.white)
            .frame(width: size, height: size)
            .background(
                Circle()
                    .fill(Color(red: 0.10, green: 0.68, blue: 0.34))
            )
            .overlay(
                Circle()
                    .stroke(Color.white.opacity(0.45), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
            .padding(12)
    }
}

struct WatchedCheckmarkBadge: View {
    let metaId: String
    let type: String
    var size: CGFloat = 38

    @State private var isWatched = false

    var body: some View {
        Group {
            if isWatched {
                WatchedCheckmarkIcon(size: size)
            }
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: WatchedStore.changedNotification)) { _ in
            refresh()
        }
    }

    private func refresh() {
        // Series watched state lives on the episode cards inside Details; the
        // poster badge is movies-only.
        let isSeries = ["series", "tv", "show", "tvshow"].contains(type.lowercased())
        isWatched = !isSeries && WatchedStore.contains(metaId: metaId, type: type)
    }
}

/// Custom button style for poster cards
struct PosterCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            #if os(tvOS)
            .scaleEffect(configuration.isPressed ? 0.985 : 1.0)
            #else
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            #endif
            .animation(.easeInOut(duration: 0.2), value: configuration.isPressed)
    }
}

#if os(tvOS)
private extension View {
    @ViewBuilder
    func nuvioFocusEffectDisabledIfAvailable() -> some View {
        if #available(tvOS 17.0, *) {
            focusEffectDisabled()
        } else {
            self
        }
    }
}

/// Binds a view's focus to a shared `FocusState<String?>` (no-op when nil),
/// so a parent can track/restore which card is focused.
struct ExternalFocusBinding: ViewModifier {
    let binding: FocusState<String?>.Binding?
    let id: String

    func body(content: Content) -> some View {
        if let binding {
            content.focused(binding, equals: id)
        } else {
            content
        }
    }
}

extension View {
    /// `.defaultFocus` guarded for tvOS 17+ (no-op below). Lets a focus scope
    /// restore to a specific value when it regains focus (e.g. from the menu,
    /// or returning to a sidebar's selected item).
    @ViewBuilder
    func defaultFocusIfAvailable<V: Hashable>(_ binding: FocusState<V>.Binding, _ value: V) -> some View {
        if #available(tvOS 17.0, *) {
            self.defaultFocus(binding, value)
        } else {
            self
        }
    }
}
#endif

// MARK: - Preview

#if DEBUG
struct PosterCard_Previews: PreviewProvider {
    static var previews: some View {
        let sampleMeta = NuvioMeta(
            id: "1",
            name: "Sample Movie",
            description: "A sample movie description",
            posterUrl: "https://via.placeholder.com/300x450",
            backgroundUrl: nil,
            logoUrl: nil,
            imdbId: "tt1234567",
            tmdbId: nil,
            type: "movie",
            year: 2024,
            genres: ["Action", "Drama"],
            rating: 8.5,
            releaseInfo: nil,
            runtime: "120 min",
            cast: nil,
            director: nil,
            writer: nil,
            certification: nil,
            country: nil,
            released: nil
        )

        PosterCard(meta: sampleMeta) {
            print("Tapped!")
        }
        .previewLayout(.sizeThatFits)
        .padding()
        .background(Color.black)
    }
}
#endif

#if os(tvOS)
// MARK: - Card quick-actions menu

/// Full-screen dimmed overlay with a liquid-glass panel of quick actions for a
/// title (Go to details / Add to library / Mark as watched), raised by
/// long-pressing a poster card. Presented over the tab view like Details/Player,
/// so the app's existing focus-restore machinery returns focus to the
/// originating card on dismiss.
struct CardActionMenuOverlay: View {
    let meta: NuvioMeta
    let onDetails: () -> Void
    let onDismiss: () -> Void

    private enum Field: Hashable { case details, library, watched }

    @State private var inLibrary = false
    @State private var isWatched = false
    @FocusState private var focused: Field?

    var body: some View {
        ZStack {
            // No full-screen scrim: the panel is liquid glass floating over a
            // still-visible Home. A whisper of dim keeps the panel legible
            // without blacking out the surroundings.
            Color.black.opacity(0.14)
                .ignoresSafeArea()

            GlassControlsContainer {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(meta.name)
                            .font(.system(size: 30, weight: .bold))
                            .foregroundColor(.white)
                            .lineLimit(2)
                        Text("Title actions")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundColor(.white.opacity(0.55))
                    }
                    .padding(.bottom, 4)

                    CardActionMenuButton(
                        title: "Go to details",
                        systemImage: "info.circle",
                        isFocused: focused == .details,
                        action: onDetails
                    )
                    .focused($focused, equals: .details)

                    CardActionMenuButton(
                        title: inLibrary ? "Remove from library" : "Add to library",
                        systemImage: inLibrary ? "checkmark" : "plus",
                        isFocused: focused == .library,
                        action: toggleLibrary
                    )
                    .focused($focused, equals: .library)

                    CardActionMenuButton(
                        title: isWatched ? "Mark as unwatched" : "Mark as watched",
                        systemImage: isWatched ? "eye.slash" : "eye",
                        isFocused: focused == .watched,
                        action: { isWatched = WatchedStore.toggle(meta: meta) }
                    )
                    .focused($focused, equals: .watched)
                }
                .padding(26)
                .frame(width: 440, alignment: .leading)
                .glassRoundedRect(cornerRadius: 28)
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
                .focusSection()
            }
        }
        .onAppear {
            inLibrary = LibraryStore.contains(metaId: meta.id, type: meta.type)
            isWatched = WatchedStore.contains(metaId: meta.id, type: meta.type)
            // Seed focus on the first action once the overlay has taken over from
            // the (fading, unfocusable) tab view behind it.
            DispatchQueue.main.async { focused = .details }
        }
        // Re-grab focus if the engine drops it while the tab view fades out, so
        // the menu never ends up with nothing highlighted.
        .onChange(of: focused) { newValue in
            if newValue == nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    if focused == nil { focused = .details }
                }
            }
        }
        .onExitCommand(perform: onDismiss)
    }

    private func toggleLibrary() {
        guard TraktSettingsStore.librarySourceMode == .trakt else {
            inLibrary = LibraryStore.toggle(meta: meta)
            return
        }

        // Do not put an item into Nuvio Sync when the selected destination is
        // Trakt. A missing/expired Trakt session simply leaves the menu state
        // unchanged instead of creating a hidden local-only save.
        guard TraktAuthStore.state.isAuthenticated else { return }

        let desiredMembership = !inLibrary
        inLibrary = desiredMembership
        Task {
            let succeeded = await TraktLibraryService.setWatchlist(
                meta,
                isInWatchlist: desiredMembership
            )
            guard !Task.isCancelled else { return }
            if !succeeded {
                inLibrary = !desiredMembership
            }
        }
    }
}

private struct CardActionMenuButton: View {
    let title: String
    let systemImage: String
    let isFocused: Bool
    let action: () -> Void

    var body: some View {
        // Mirrors the profile page's TVProfileActionButton: the focused state is
        // a white-*tinted* glass (via loginGlassCapsule) that blends inside the
        // GlassEffectContainer, instead of an opaque white fill that bleeds a
        // glow/halo around itself.
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 26)
                Text(title)
                    .font(.system(size: 22, weight: .semibold))
                Spacer(minLength: 0)
            }
            .foregroundColor(isFocused ? .black : .white)
            .padding(.horizontal, 22)
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
            .loginGlassCapsule(highlighted: isFocused)
            .contentShape(Capsule())
            .scaleEffect(isFocused ? 1.03 : 1)
        }
        .buttonStyle(PosterCardButtonStyle())
        .focusEffectDisabledIfAvailable()
        .animation(.easeOut(duration: 0.12), value: isFocused)
    }
}
#endif
