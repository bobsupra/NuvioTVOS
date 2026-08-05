//
//  PosterCard.swift
//  NuvioTV
//
//  Reusable poster card component for iOS/tvOS
//

import CryptoKit
import ImageIO
import SwiftUI
#if os(tvOS)
import AVKit
#endif
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
    @State private var landscapeArtworkPrepared = false
    @AppStorage(SettingsKey.trailersEnabled) private var trailersEnabled = true
    @AppStorage(SettingsKey.trailerDelay) private var trailerDelay = 7
    @State private var isTrailerPreviewActive = false
    @State private var isTrailerPreviewReady = false
    @State private var didFinishTrailerPreview = false
    /// Rapid navigation should not start a separate backdrop/episode-art decode
    /// for every card passed over. Arm that preload only after focus has settled,
    /// matching Home's hero debounce.
    @State private var landscapePreloadArmed = false
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
                    didFinishTrailerPreview = false
                } else {
                    landscapePreloadArmed = false
                    cancelTrailerPreview()
                    onBlur?(meta)
                }
            }
            // A task keyed to the real rendered state cannot miss the landscape
            // transition. It is cancelled automatically if focus/landscape or
            // the setting changes before the full delay has elapsed.
            .task(id: trailerActivationIdentity) {
                await activateTrailerPreviewAfterDelay()
            }
            .onDisappear(perform: cancelTrailerPreview)
            .task(id: isFocused) {
                guard isFocused else { return }
                do {
                    try await Task.sleep(nanoseconds: 300_000_000)
                } catch {
                    return
                }
                guard !Task.isCancelled, isFocused else { return }
                landscapePreloadArmed = true
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
                value: effectiveLandscape
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
                preloadURLString: landscapePreloadURL,
                width: cardWidth,
                height: cardHeight,
                maximumWidth: artworkDecodeWidth,
                minimumSwapDelay: 0,
                onPreloadFinished: {
                    #if os(tvOS)
                    landscapeArtworkPrepared = true
                    #endif
                }
            ) {
                placeholderView
            }
            .frame(width: cardWidth, height: cardHeight)
            .clipShape(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
            #if os(tvOS)
            // Cross-fade the landscape artwork away only once the resolved
            // trailer is ready to draw, avoiding a black frame on slow links.
            .opacity(isTrailerPreviewVisible ? 0 : 1)
            .overlay {
                if isFocused && trailersEnabled && !didFinishTrailerPreview {
                    TrailerPreviewPlayer(
                        meta: meta,
                        isActive: effectiveLandscape && isTrailerPreviewActive,
                        onPlaybackReady: {
                            guard isTrailerPreviewActive else { return }
                            isTrailerPreviewReady = true
                        },
                        onPlaybackFinished: finishTrailerPreview
                    )
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.32), value: isTrailerPreviewVisible)
            .animation(.easeInOut(duration: 0.32), value: didFinishTrailerPreview)
            #endif
            .overlay(alignment: .bottomLeading) {
                if effectiveLandscape {
                    landscapeOverlay
                        #if os(tvOS)
                        .opacity(isTrailerPreviewVisible ? 0 : 1)
                        #endif
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
                        WatchedCheckmarkBadge(meta: meta)
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
        ArtworkPlaceholder(
            hasArtworkURL: imageUrl?.isEmpty == false,
            cornerRadius: cardCornerRadius
        )
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
            let width = max(0, cardWidth - 44)

            VStack {
                Spacer(minLength: 0)
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
            .frame(width: cardWidth, height: cardHeight, alignment: .bottomLeading)
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

    private var effectiveLandscape: Bool {
        isLandscape && (landscapeArtworkPrepared || landscapeArtworkURL == nil)
    }

    private var cardWidth: CGFloat {
        if effectiveLandscape {
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
        effectiveLandscape ? 315 : (effectiveHomeLayout == "Compact" ? 255 : 315)
    }

    private var totalCardHeight: CGFloat {
        cardHeight + (showsPosterTitle ? 36 : 0)
    }

    private var landscapeLogoWidth: CGFloat {
        275
    }

    private var landscapeLogoHeight: CGFloat {
        84
    }

    private var cardCornerRadius: CGFloat {
        16
    }

    private var landscapeArtworkURL: String? {
        if continueEpisodeText != nil,
           let continueEpisodeArtworkURL, !continueEpisodeArtworkURL.isEmpty {
            return continueEpisodeArtworkURL
        }
        return meta.backgroundUrl ?? meta.posterUrl
    }

    private var imageUrl: String? {
        effectiveLandscape ? landscapeArtworkURL : meta.posterUrl
    }

    private var landscapePreloadURL: String? {
        landscapePreloadArmed || isLandscape ? landscapeArtworkURL : nil
    }

    private var artworkDecodeWidth: CGFloat {
        560
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

    private var trailerActivationIdentity: String {
        "\(isFocused)\u{1f}\(effectiveLandscape)\u{1f}\(trailersEnabled)\u{1f}\(trailerDelay)"
    }

    private var isTrailerPreviewVisible: Bool {
        isTrailerPreviewActive && isTrailerPreviewReady && !didFinishTrailerPreview
    }

    @MainActor
    private func activateTrailerPreviewAfterDelay() async {
        isTrailerPreviewActive = false
        isTrailerPreviewReady = false
        didFinishTrailerPreview = false
        guard isFocused, effectiveLandscape, trailersEnabled else { return }

        let delay = max(1, trailerDelay)
        do {
            try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
        } catch {
            return
        }
        guard !Task.isCancelled, isFocused, effectiveLandscape, trailersEnabled else { return }
        isTrailerPreviewActive = true
    }

    private func cancelTrailerPreview() {
        isTrailerPreviewActive = false
        isTrailerPreviewReady = false
    }

    private func finishTrailerPreview() {
        isTrailerPreviewActive = false
        isTrailerPreviewReady = false
        didFinishTrailerPreview = true
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

    private var landscapePreloadURL: String? {
        nil
    }

    private var artworkDecodeWidth: CGFloat {
        cardWidth
    }

    private var effectiveLandscape: Bool {
        false
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

#if os(tvOS)
/// Video preview for a settled, landscape Home card. The player is
/// created only after the configured trailer delay and is released as soon as
/// focus leaves, so scrolling never leaves background trailer audio or decoders.
private struct TrailerPreviewPlayer: View {
    let meta: NuvioMeta
    /// Resolution begins as soon as the card gains focus; playback waits for
    /// Home's configured delay to promote the card to landscape.
    let isActive: Bool
    let onPlaybackReady: () -> Void
    let onPlaybackFinished: () -> Void

    @State private var player = AVPlayer()
    @State private var hasResolvedPreview = false
    @AppStorage(SettingsKey.trailerPreviewSound) private var trailerPreviewSound = false
    private let resolver = YouTubeTrailerResolver()

    var body: some View {
        VideoPlayer(player: player)
            // Keep the landscape artwork visible while the trailer URL is
            // resolving, rather than replacing it with an empty black player.
            .opacity(isVisible ? 1 : 0)
            .animation(.easeInOut(duration: 0.32), value: isVisible)
            .allowsHitTesting(false)
            .task(id: previewIdentity) {
                await startPreview()
            }
            .onChange(of: isActive) { active in
                if active {
                    player.play()
                    if hasResolvedPreview { onPlaybackReady() }
                } else {
                    player.pause()
                }
            }
            .onChange(of: trailerPreviewSound) { soundEnabled in
                applySoundPreference(soundEnabled)
            }
            .onReceive(
                NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)
            ) { notification in
                guard let item = notification.object as? AVPlayerItem,
                      item == player.currentItem else {
                    return
                }
                onPlaybackFinished()
            }
            .onDisappear {
                hasResolvedPreview = false
                player.pause()
                player.replaceCurrentItem(with: nil)
            }
    }

    private var previewIdentity: String {
        "\(meta.id)\u{1f}\(meta.trailerYtIds?.joined(separator: ",") ?? "")"
    }

    private var isVisible: Bool {
        isActive && hasResolvedPreview
    }

    private func startPreview() async {
        hasResolvedPreview = false
        let trailerMeta: NuvioMeta
        if meta.trailerYtIds?.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) == true {
            trailerMeta = meta
        } else if let refreshed = try? await CinemetaCatalogRepository().refreshMetadata(
            id: meta.id,
            type: meta.type
        ) {
            trailerMeta = refreshed
        } else {
            return
        }

        guard let youtubeVideoId = trailerMeta.trailerYtIds?
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty }),
            let streamURL = await resolver.resolvePreview(
                youtubeVideoId: youtubeVideoId,
                title: trailerMeta.name,
                year: trailerMeta.year.map(String.init)
            ),
            let url = URL(string: streamURL),
            !Task.isCancelled else {
            return
        }

        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        applySoundPreference(trailerPreviewSound)
        hasResolvedPreview = true
        if isActive {
            onPlaybackReady()
            player.play()
        }
    }

    private func applySoundPreference(_ soundEnabled: Bool) {
        player.isMuted = !soundEnabled
        player.volume = soundEnabled ? 1 : 0
        guard soundEnabled else { return }

        // Home previews do not pass through PlayerView, which normally
        // activates the movie-playback audio session for full-screen video.
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
    }
}

/// Poster tile for the full-width grids — Search results and the Grid Home
/// previews — so both read as one card: art that lifts and outlines on focus,
/// plus the two-line title/subtitle pair when poster labels are on.
///
/// Distinct from `PosterCard`, which is the row-strip card: that one also has to
/// expand to landscape artwork, carry Continue Watching progress, and stay
/// cheap while a whole strip of it is mounted, so it deliberately stays flatter.
struct PosterGridCard: View {
    let meta: NuvioMeta
    var width: CGFloat = 210
    var height: CGFloat = 315
    var externalFocus: FocusState<String?>.Binding? = nil
    /// Defaults to `meta.id`. Home passes a section-scoped key, since the same
    /// title can appear in more than one catalog.
    var focusValue: String? = nil
    var retainFocusAppearance = false
    /// Pre-resolved watched state; `nil` lets the badge look it up itself.
    var isWatched: Bool? = nil
    var shouldRequestInitialFocus = false
    var onInitialFocusRequested: (() -> Void)? = nil
    var onFocus: ((NuvioMeta) -> Void)? = nil
    var onLongPress: (() -> Void)? = nil
    let action: () -> Void

    @FocusState private var focused: Bool
    @State private var didRequestInitialFocus = false
    @AppStorage(SettingsKey.posterLabels) private var posterLabels = false
    @AppStorage(SettingsKey.smoothFocus) private var smoothFocus = true
    @AppStorage(SettingsKey.focusHighlighter) private var focusHighlighter = false

    private var showsFocusedAppearance: Bool { focused || retainFocusAppearance }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                CachedPosterArtwork(
                    urlString: meta.posterUrl,
                    preloadURLString: nil,
                    width: width,
                    height: height,
                    maximumWidth: width,
                    minimumSwapDelay: 0,
                    onPreloadFinished: {}
                ) {
                    placeholder
                }
                .frame(width: width, height: height)
                .clipShape(shape)
                .overlay(alignment: .topTrailing) {
                    if let isWatched {
                        if isWatched { WatchedCheckmarkIcon() }
                    } else {
                        WatchedCheckmarkBadge(meta: meta)
                    }
                }
                .overlay(
                    shape.stroke(
                        showsFocusedAppearance ? AppFocusOutline.color : .clear,
                        lineWidth: focusHighlighter ? AppFocusOutline.emphasizedWidth : AppFocusOutline.width
                    )
                )
                .shadow(
                    color: .black.opacity(showsFocusedAppearance ? 0.5 : 0.2),
                    radius: showsFocusedAppearance ? 16 : 6
                )

                if posterLabels {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(meta.name)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(showsFocusedAppearance ? .white : .white.opacity(0.78))
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.white.opacity(0.45))
                            .lineLimit(1)
                    }
                    .frame(width: width, alignment: .leading)
                }
            }
            .scaleEffect(showsFocusedAppearance ? 1.06 : 1.0)
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($focused)
        .modifier(ExternalFocusBinding(binding: externalFocus, id: focusValue ?? meta.id))
        .focusEffectDisabledIfAvailable()
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.45).onEnded { _ in onLongPress?() }
        )
        .onChange(of: focused) { isFocused in
            if isFocused { onFocus?(meta) }
        }
        .onAppear {
            guard shouldRequestInitialFocus, !didRequestInitialFocus else { return }
            didRequestInitialFocus = true
            onInitialFocusRequested?()
            DispatchQueue.main.async { focused = true }
        }
        .animation(
            smoothFocus ? .spring(response: 0.28, dampingFraction: 0.75) : nil,
            value: showsFocusedAppearance
        )
    }

    private var placeholder: some View {
        ZStack {
            Rectangle().fill(Color.white.opacity(0.07))
            Image(systemName: meta.type == "series" ? "tv" : "film")
                .font(.system(size: 40))
                .foregroundColor(.white.opacity(0.25))
        }
    }

    private var subtitle: String {
        let typeLabel = meta.type == "series"
            ? L10n.string("type_series", fallback: "Series")
            : L10n.string("type_movie", fallback: "Movie")
        var parts: [String] = [typeLabel]
        if let year = meta.year { parts.append(String(year)) }
        if let rating = meta.rating, rating > 0 { parts.append(String(format: "★ %.1f", rating)) }
        return parts.joined(separator: "  ·  ")
    }
}
#endif

#if canImport(UIKit)
/// Liquid Glass surface shared by collection folder covers and loading cards, so
/// the two cannot drift apart. tvOS 26+ uses real `glassEffect`; older systems
/// get frosted material.
struct LiquidGlassSurface: ViewModifier {
    let cornerRadius: CGFloat
    var prominent: Bool = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(tvOS 26.0, *) {
            content
                .background(Color.white.opacity(prominent ? 0.14 : 0.08), in: shape)
                .glassEffect(.regular, in: shape)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .background(Color.white.opacity(prominent ? 0.12 : 0.06), in: shape)
        }
    }
}

/// A card standing in for one whose row has no data yet.
///
/// This is the one place a spinner still belongs: the row's catalog request is
/// genuinely outstanding and will either answer or fail, unlike a single poster
/// URL that can hang forever with nothing left to report. Shares the glass
/// surface with `ArtworkPlaceholder` so a loading row and a loaded one read as
/// the same material.
struct LoadingPosterCard: View {
    let width: CGFloat
    let height: CGFloat
    var cornerRadius: CGFloat = 16

    var body: some View {
        ZStack {
            Color.clear

            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white.opacity(0.55))
        }
        .frame(width: width, height: height)
        .modifier(LiquidGlassSurface(cornerRadius: cornerRadius))
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// What a card shows when it has no artwork on screen.
///
/// Matches the Android app, where `AsyncImage` is given the same flat card
/// painter for `placeholder`, `error` and `fallback`: loading and failed look
/// identical, so a poster that never arrives is a quiet empty card rather than
/// a spinner with no exit. An add-on that generates art on demand answers some
/// titles in milliseconds and others never, and only the card knows which — a
/// progress indicator promises an arrival nothing can guarantee.
///
/// A title with no artwork URL at all keeps the glyph, the same distinction
/// Android draws with `MonochromePosterPlaceholder`.
private struct ArtworkPlaceholder: View {
    let hasArtworkURL: Bool
    let cornerRadius: CGFloat

    var body: some View {
        ZStack {
            // Fills the card, then takes the glass treatment on that footprint —
            // the same surface a collection folder cover uses.
            Color.clear

            if !hasArtworkURL {
                Image(systemName: "photo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 42, height: 42)
                    .foregroundColor(.white.opacity(0.38))
            }
        }
        .modifier(LiquidGlassSurface(cornerRadius: cornerRadius))
    }
}

private struct CachedPosterArtwork<Placeholder: View>: View {
    let urlString: String?
    let preloadURLString: String?
    let width: CGFloat
    let height: CGFloat
    let maximumWidth: CGFloat
    let minimumSwapDelay: TimeInterval
    let onPreloadFinished: () -> Void
    @ViewBuilder let placeholder: Placeholder

    @State private var image: UIImage?
    @State private var loadedKey: String?
    /// Keep the preceding artwork variant alive while the card changes shape.
    /// A Home card swaps between poster and backdrop URLs; retaining both lets
    /// the poster reappear immediately and crop down with the width animation
    /// instead of flashing the placeholder for a frame.
    @State private var previousImage: UIImage?
    @State private var previousLoadedKey: String?
    @State private var preloadedImage: UIImage?
    @State private var preloadedKey: String?

    private var maxPixelSize: Int {
        let displayScale = UIScreen.main.scale
        return max(160, Int(ceil(max(maximumWidth, height) * displayScale)))
    }

    private var cacheKey: String {
        "\(urlString ?? "")#\(maxPixelSize)"
    }

    private var preloadCacheKey: String {
        "\(preloadURLString ?? "")#\(maxPixelSize)"
    }

    var body: some View {
        ZStack(alignment: .center) {
            if let image = displayedImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: width, height: height, alignment: .center)
                    .clipped()
            } else {
                placeholder
            }
        }
        .task(id: cacheKey) {
            await load()
        }
        .task(id: preloadCacheKey) {
            await preload()
        }
    }

    private var displayedImage: UIImage? {
        if loadedKey == cacheKey { return image }
        if preloadedKey == cacheKey { return preloadedImage }
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

        if preloadedKey == key, let preloadedImage {
            previousImage = image
            previousLoadedKey = loadedKey
            image = preloadedImage
            loadedKey = key
            return
        }

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

    @MainActor
    private func preload() async {
        guard let preloadURLString,
              let url = URL(string: preloadURLString) else {
            return
        }

        let key = preloadCacheKey
        if loadedKey == key, let image {
            preloadedImage = image
            preloadedKey = key
            onPreloadFinished()
            return
        }
        if preloadedKey == key {
            onPreloadFinished()
            return
        }

        if let cached = await PosterArtworkCache.shared.image(
            for: url,
            maxPixelSize: maxPixelSize
        ) {
            guard !Task.isCancelled, key == preloadCacheKey else { return }
            preloadedImage = cached
            preloadedKey = key
        }
        onPreloadFinished()
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
            // Disk before network, like Coil. The bytes are keyed by URL alone,
            // so one stored poster serves every size a card asks for.
            if let stored = await PosterDiskCache.shared.data(for: url),
               let image = await PosterDecodeLimiter.shared.image(
                   from: stored,
                   maxPixelSize: boundedPixelSize
               ) {
                return image
            }

            guard let data = await downloadPosterData(url: url) else { return nil }
            await PosterDiskCache.shared.store(data, for: url)
            return await PosterDecodeLimiter.shared.image(
                from: data,
                maxPixelSize: boundedPixelSize
            )
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

/// Coil naturally keeps decode work bounded. Match that behavior so mounting a
/// newly visible Home shelf cannot fan out into a burst of AppleJPEG workers.
private actor PosterDecodeLimiter {
    static let shared = PosterDecodeLimiter(maxConcurrentDecodes: 3)

    private let maxConcurrentDecodes: Int
    private var activeDecodes = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(maxConcurrentDecodes: Int) {
        self.maxConcurrentDecodes = max(1, maxConcurrentDecodes)
    }

    func image(from data: Data, maxPixelSize: Int) async -> UIImage? {
        await acquire()
        defer { release() }

        guard !Task.isCancelled else { return nil }
        return await Task.detached(priority: .utility) {
            downsamplePosterImage(data: data, maxPixelSize: maxPixelSize)
        }.value
    }

    private func acquire() async {
        if activeDecodes < maxConcurrentDecodes {
            activeDecodes += 1
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        if waiters.isEmpty {
            activeDecodes -= 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// Poster bytes that survive relaunch, mirroring the Android image loader's
/// 200 MB Coil disk cache.
///
/// tvOS gives `URLCache` no disk store, so without this every cold start
/// re-requests every poster. Against an add-on that renders art on demand that
/// also re-triggers every slow generation, which is why the same Home looks
/// worse on Apple TV than on Android for identical add-ons. Stored raw and
/// keyed by URL alone — decoding happens per card, at that card's size.
private actor PosterDiskCache {
    static let shared = PosterDiskCache()

    private let directory: URL
    private let maximumBytes = 200 * 1024 * 1024
    private let fileManager = FileManager.default
    /// Walking the directory on every write would cost more than the eviction
    /// saves, so the sweep runs once per batch of new artwork.
    private var bytesWrittenSinceTrim = 0
    private let trimInterval = 20 * 1024 * 1024

    init() {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = caches.appendingPathComponent("poster_artwork", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func data(for url: URL) -> Data? {
        let file = fileURL(for: url)
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return nil }
        // Touch on read so eviction keeps what is actually being looked at
        // rather than merely what was fetched most recently.
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return data
    }

    func store(_ data: Data, for url: URL) {
        try? data.write(to: fileURL(for: url), options: .atomic)

        bytesWrittenSinceTrim += data.count
        guard bytesWrittenSinceTrim >= trimInterval else { return }
        bytesWrittenSinceTrim = 0
        trim()
    }

    private func fileURL(for url: URL) -> URL {
        // A poster URL can carry query parameters and characters a file name
        // cannot, so hash it rather than sanitising it.
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return directory.appendingPathComponent(digest.map { String(format: "%02x", $0) }.joined())
    }

    private func trim() {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys
        ) else {
            return
        }

        var entries: [(url: URL, modified: Date, size: Int)] = []
        var total = 0
        for file in files {
            guard let values = try? file.resourceValues(forKeys: Set(keys)),
                  let size = values.fileSize else { continue }
            entries.append((file, values.contentModificationDate ?? .distantPast, size))
            total += size
        }

        guard total > maximumBytes else { return }
        for entry in entries.sorted(by: { $0.modified < $1.modified }) {
            guard total > maximumBytes else { break }
            try? fileManager.removeItem(at: entry.url)
            total -= entry.size
        }
    }
}

/// Matches what the Android loader gets from OkHttp's defaults: a 10s ceiling
/// instead of `URLSession`'s 60s, and a non-2xx response treated as a failure
/// instead of being handed to the decoder as if it were image bytes.
private func downloadPosterData(url: URL) async -> Data? {
    var request = URLRequest(url: url)
    request.timeoutInterval = 10

    guard let (data, response) = try? await URLSession.shared.data(for: request) else {
        return nil
    }
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
        return nil
    }
    return data.isEmpty ? nil : data
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

struct WatchedCheckmarkIcon: View {
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
    let meta: NuvioMeta?
    var size: CGFloat = 38

    @State private var isWatched = false

    init(metaId: String, type: String, size: CGFloat = 38) {
        self.metaId = metaId
        self.type = type
        self.meta = nil
        self.size = size
    }

    init(meta: NuvioMeta, size: CGFloat = 38) {
        self.metaId = meta.id
        self.type = meta.type
        self.meta = meta
        self.size = size
    }

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
        isWatched = !isSeries && (meta.map { WatchedStore.contains(meta: $0) }
            ?? WatchedStore.contains(metaId: metaId, type: type))
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
            isWatched = WatchedStore.contains(meta: meta)
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
        guard TraktSettingsStore.librarySourceMode != .local else {
            inLibrary = LibraryStore.toggle(meta: meta)
            return
        }

        // Do not put an item into Nuvio Sync when the selected destination is
        // Trakt. A missing/expired Trakt session simply leaves the menu state
        // unchanged instead of creating a hidden local-only save.
        guard SelectedLibraryService.isSelectedAndAuthenticated else { return }

        let desiredMembership = !inLibrary
        inLibrary = desiredMembership
        Task {
            let succeeded = await SelectedLibraryService.setWatchlist(
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

/// Quick actions for a Continue Watching card, which are about the *resume*
/// rather than the title: pick a stream by hand, restart the episode, or drop
/// the card. Same glass panel as `CardActionMenuOverlay`, but a long press on a
/// Continue Watching card raises this one instead — library/watched toggles are
/// meaningless for something already in progress.
struct ContinueWatchingActionMenuOverlay: View {
    let item: ContinueWatchingItem
    let onDetails: () -> Void
    let onPlayManually: () -> Void
    let onStartFromBeginning: () -> Void
    let onRemove: () -> Void
    let onDismiss: () -> Void

    private enum Field: Hashable { case details, manual, restart, remove }

    @FocusState private var focused: Field?

    /// A Next Up card is a suggestion for an episode that has never been played,
    /// so there is no progress to restart from — matching the phone's sheet.
    private var showsStartFromBeginning: Bool { !item.isUpNextEntry }

    var body: some View {
        ZStack {
            Color.black.opacity(0.14)
                .ignoresSafeArea()

            GlassControlsContainer {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.meta.name)
                            .font(.system(size: 30, weight: .bold))
                            .foregroundColor(.white)
                            .lineLimit(2)
                        Text(item.episodeDisplayLine ?? "Continue watching")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundColor(.white.opacity(0.55))
                            .lineLimit(1)
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
                        title: "Play manually",
                        systemImage: "play.fill",
                        isFocused: focused == .manual,
                        action: onPlayManually
                    )
                    .focused($focused, equals: .manual)

                    if showsStartFromBeginning {
                        CardActionMenuButton(
                            title: "Start from beginning",
                            systemImage: "arrow.counterclockwise",
                            isFocused: focused == .restart,
                            action: onStartFromBeginning
                        )
                        .focused($focused, equals: .restart)
                    }

                    CardActionMenuButton(
                        title: "Remove",
                        systemImage: "trash",
                        isFocused: focused == .remove,
                        isDestructive: true,
                        action: onRemove
                    )
                    .focused($focused, equals: .remove)
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
}

private struct CardActionMenuButton: View {
    let title: String
    let systemImage: String
    let isFocused: Bool
    /// Tints the resting state to mark an action that discards something. The
    /// focused state stays black-on-white like every other row, so the panel
    /// never grows a second highlight treatment.
    var isDestructive: Bool = false
    let action: () -> Void

    private var restingColor: Color {
        isDestructive ? Color(red: 0.93, green: 0.45, blue: 0.55) : .white
    }

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
            .foregroundColor(isFocused ? .black : restingColor)
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
