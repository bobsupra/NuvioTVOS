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
    /// the quick-actions menu. Nil disables the long-press.
    var onLongPress: ((NuvioMeta) -> Void)? = nil
    var onOpenDetails: (() -> Void)? = nil
    var onPlayManually: (() -> Void)? = nil
    var onStartFromBeginning: (() -> Void)? = nil
    var onRemoveFromContinueWatching: (() -> Void)? = nil
    var layoutMode: String = "Modern"
    var showPosterLabels: Bool = false
    var smoothFocusAnimations: Bool = true
    var focusHighlighterEnabled: Bool = false
    /// Keeps the last-selected card visually outlined while an overlay owns
    /// tvOS focus. The parent supplies this for exactly one saved card.
    var retainFocusAppearance: Bool = false
    /// Lets Home retain off-window artwork without leaving every card in the
    /// tvOS focus graph.
    var allowsFocus: Bool = true
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
        Button(action: onClick) {
            posterContent
        }
        .buttonStyle(PosterCardButtonStyle())
        .disabled(!allowsFocus)
        .focused($isFocused)
        .modifier(ExternalFocusBinding(binding: externalFocus, id: externalFocusValue ?? meta.id))
        .nuvioFocusEffectDisabledIfAvailable()
        .titleActionsContextMenu(
            meta: meta,
            onOpenDetails: onOpenDetails ?? onClick,
            continueProgress: continueProgress,
            continueIsUpNext: continueIsUpNext,
            onPlayManually: onPlayManually,
            onStartFromBeginning: onStartFromBeginning,
            onRemoveFromContinueWatching: onRemoveFromContinueWatching
        )
            .onChange(of: isFocused) { _, focused in
                if focused {
                    TVHomeDebugTrace.log(
                        "card.focus meta=\(meta.id) landscape=\(effectiveLandscape) "
                            + "episode=\(continueEpisodeText ?? "nil") "
                            + "episodeArt=\(continueEpisodeArtworkURL != nil)"
                    )
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
                TVHomeDebugTrace.log(
                    "card.preload.arm meta=\(meta.id) landscapeURL=\(landscapeArtworkURL != nil) "
                        + "episodeArt=\(continueEpisodeArtworkURL != nil)"
                )
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
        .titleActionsContextMenu(
            meta: meta,
            onOpenDetails: onOpenDetails ?? onClick,
            continueProgress: continueProgress,
            continueIsUpNext: continueIsUpNext,
            onPlayManually: onPlayManually,
            onStartFromBeginning: onStartFromBeginning,
            onRemoveFromContinueWatching: onRemoveFromContinueWatching
        )
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
            #if os(tvOS)
            // Cross-fade the landscape artwork away only once the resolved
            // trailer is ready to draw, avoiding a black frame on slow links.
            .opacity(isTrailerPreviewVisible ? 0 : 1)
            .overlay {
                // Do not even create AVPlayerViewController while the user is
                // moving focus. `isActive` is intentionally delayed; mounting
                // VideoPlayer before that delay still constructs AVKit's view
                // hierarchy for every card passed during rapid scrolling.
                if isFocused && isTrailerPreviewActive && trailersEnabled && !didFinishTrailerPreview {
                    TrailerPreviewPlayer(
                        meta: meta,
                        isActive: true,
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
            // Mask the complete card interior after composing both the trailer
            // and landscape artwork overlays. The focus border remains outside
            // this mask so its stroke stays crisp.
            .clipShape(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
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
            } else if let logoURL = landscapeLogoURL {
                AsyncImage(url: logoURL) { phase in
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

    /// Source title logo trimmed of surrounding whitespace, or nil when blank
    /// or not a valid URL — in which case `landscapeOverlay` shows the title
    /// text fallback.
    private var landscapeLogoURL: URL? {
        guard let raw = meta.logoUrl?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty else {
            return nil
        }
        return URL(string: raw)
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
                    .fill(continueBadgeFill)
            )
            .padding(16)
        }
    }

    private var continueBadgeFill: Color {
        guard continueIsUpNext else { return Color.black.opacity(0.72) }
        switch (continueUpNextBadgeText ?? "Next Up").uppercased() {
        case "NEW SEASON":
            return Color(red: 0xB4 / 255, green: 0x53 / 255, blue: 0x09 / 255)
        case "NEW EPISODE":
            return Color(red: 0x1D / 255, green: 0x4E / 255, blue: 0xD8 / 255)
        default:
            return Color.black.opacity(0.72)
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

// Home's vertical offset animates at the parent level. Without an equality
// boundary, every parent focus update rebuilds the full poster subtree for
// every mounted row, even though almost every card is unchanged. Keep dynamic
// focus bindings inside the retained subtree while invalidating it only when a
// value that affects the card's rendering or focus eligibility changes.
extension PosterCard: Equatable {
    static func == (lhs: PosterCard, rhs: PosterCard) -> Bool {
        lhs.meta.id == rhs.meta.id
            && lhs.meta.name == rhs.meta.name
            && lhs.meta.posterUrl == rhs.meta.posterUrl
            && lhs.meta.backgroundUrl == rhs.meta.backgroundUrl
            && lhs.meta.logoUrl == rhs.meta.logoUrl
            && lhs.meta.imdbId == rhs.meta.imdbId
            && lhs.meta.tmdbId == rhs.meta.tmdbId
            && lhs.meta.type == rhs.meta.type
            && lhs.meta.trailerYtIds == rhs.meta.trailerYtIds
            && lhs.isLandscape == rhs.isLandscape
            && lhs.continueProgress == rhs.continueProgress
            && lhs.continueRemainingText == rhs.continueRemainingText
            && lhs.continueEpisodeText == rhs.continueEpisodeText
            && lhs.continueEpisodeTitleText == rhs.continueEpisodeTitleText
            && lhs.continueEpisodeArtworkURL == rhs.continueEpisodeArtworkURL
            && lhs.continueIsUpNext == rhs.continueIsUpNext
            && lhs.continueUpNextBadgeText == rhs.continueUpNextBadgeText
            && lhs.showsWatchedBadge == rhs.showsWatchedBadge
            && lhs.shouldRequestInitialFocus == rhs.shouldRequestInitialFocus
            && lhs.externalFocusValue == rhs.externalFocusValue
            && (lhs.onLongPress != nil) == (rhs.onLongPress != nil)
            && (lhs.onOpenDetails != nil) == (rhs.onOpenDetails != nil)
            && (lhs.onPlayManually != nil) == (rhs.onPlayManually != nil)
            && (lhs.onStartFromBeginning != nil) == (rhs.onStartFromBeginning != nil)
            && (lhs.onRemoveFromContinueWatching != nil) == (rhs.onRemoveFromContinueWatching != nil)
            && lhs.layoutMode == rhs.layoutMode
            && lhs.showPosterLabels == rhs.showPosterLabels
            && lhs.smoothFocusAnimations == rhs.smoothFocusAnimations
            && lhs.focusHighlighterEnabled == rhs.focusHighlighterEnabled
            && lhs.retainFocusAppearance == rhs.retainFocusAppearance
            && lhs.allowsFocus == rhs.allowsFocus
            && lhs.isWatched == rhs.isWatched
    }
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
            .onChange(of: isActive) { _, active in
                if active {
                    player.play()
                    if hasResolvedPreview { onPlaybackReady() }
                } else {
                    player.pause()
                }
            }
            .onChange(of: trailerPreviewSound) { _, soundEnabled in
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
        PlaybackAudioSession.activateMoviePlayback()
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
    /// Forces the title/subtitle caption to render regardless of the user's
    /// global poster-labels setting (used by Search's Netflix-style grid).
    var forceShowLabels = false
    /// Optional directional-command hook installed on the focusable Button
    /// itself. Container-level handlers can miss commands consumed by tvOS's
    /// focus engine before they bubble out of a poster.
    var onMove: ((MoveCommandDirection) -> Void)? = nil
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
        let cardContent = VStack(alignment: .leading, spacing: 12) {
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

            if posterLabels || forceShowLabels {
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
        Button(action: action) {
            cardContent
                .scaleEffect(showsFocusedAppearance ? 1.06 : 1.0)
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($focused)
        .modifier(ExternalFocusBinding(binding: externalFocus, id: focusValue ?? meta.id))
        .focusEffectDisabledIfAvailable()
        .modifier(OptionalMoveCommandHandler(handler: onMove))
        .titleActionsContextMenu(
            meta: meta,
            onOpenDetails: action
        )
        .onChange(of: focused) { _, isFocused in
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

private struct OptionalMoveCommandHandler: ViewModifier {
    let handler: ((MoveCommandDirection) -> Void)?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let handler {
            content.onMoveCommand(perform: handler)
        } else {
            content
        }
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
        let traceLoad = preloadURLString != nil
        let started = TVHomeDebugTrace.now()
        if traceLoad {
            TVHomeDebugTrace.log("art.load.begin host=\(url.host ?? "unknown") key=\(key)")
        }
        let loadStartedAt = Date()
        if loadedKey == key { return }

        if preloadedKey == key, let preloadedImage {
            previousImage = image
            previousLoadedKey = loadedKey
            image = preloadedImage
            loadedKey = key
            if traceLoad {
                TVHomeDebugTrace.log(
                    "art.load.end source=preloaded ms=\(TVHomeDebugTrace.elapsedMilliseconds(since: started))"
                )
            }
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
            if traceLoad {
                TVHomeDebugTrace.log(
                    "art.load.end source=previous ms=\(TVHomeDebugTrace.elapsedMilliseconds(since: started))"
                )
            }
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
        if traceLoad {
            TVHomeDebugTrace.log(
                "art.load.end source=cache ms=\(TVHomeDebugTrace.elapsedMilliseconds(since: started))"
            )
        }
    }

    @MainActor
    private func preload() async {
        guard let preloadURLString,
              let url = URL(string: preloadURLString) else {
            return
        }

        let key = preloadCacheKey
        let started = TVHomeDebugTrace.now()
        TVHomeDebugTrace.log(
            "art.preload.begin host=\(url.host ?? "unknown") key=\(key)"
        )
        if loadedKey == key, let image {
            preloadedImage = image
            preloadedKey = key
            onPreloadFinished()
            TVHomeDebugTrace.log(
                "art.preload.end source=loaded ms=\(TVHomeDebugTrace.elapsedMilliseconds(since: started))"
            )
            return
        }
        if preloadedKey == key {
            onPreloadFinished()
            TVHomeDebugTrace.log(
                "art.preload.end source=preloaded ms=\(TVHomeDebugTrace.elapsedMilliseconds(since: started))"
            )
            return
        }

        let cached = await PosterArtworkCache.shared.image(
            for: url,
            maxPixelSize: maxPixelSize
        )
        if let cached {
            guard !Task.isCancelled, key == preloadCacheKey else { return }
            preloadedImage = cached
            preloadedKey = key
        }
        onPreloadFinished()
        TVHomeDebugTrace.log(
            "art.preload.end source=cache hit=\(cached != nil) "
                + "ms=\(TVHomeDebugTrace.elapsedMilliseconds(since: started))"
        )
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

/// Deduplicates full-series metadata requests made by catalog badges. Catalog
/// previews usually omit `videos`, so completion cannot be decided until the
/// episode guide is available. Only series with watched episode rows reach this
/// cache, avoiding a request for every untouched poster on screen.
@MainActor
private final class CatalogWatchedMetadataCache {
    static let shared = CatalogWatchedMetadataCache()

    private let repository = CinemetaCatalogRepository()
    private var metadataByKey: [String: NuvioMeta] = [:]
    private var inFlightByKey: [String: Task<NuvioMeta?, Never>] = [:]

    func fullMetadata(metaId: String, type: String, preview: NuvioMeta?) async -> NuvioMeta? {
        let profile = WatchedStore.activeProfileId ?? "default"
        let key = "\(profile)\u{1f}\(type.lowercased())\u{1f}\(metaId.lowercased())"
        if let cached = metadataByKey[key] { return cached }
        if let inFlight = inFlightByKey[key] { return await inFlight.value }

        let task: Task<NuvioMeta?, Never> = Task {
            // Catalog rows may contain a partial episode list. Always resolve
            // the full /meta payload so a recreated card cannot make a
            // different completion decision from the same watched history.
            if let refreshed = try? await repository.refreshMetadata(id: metaId, type: type) {
                return refreshed
            }
            // Keep an already supplied guide as a useful offline fallback.
            return preview
        }
        inFlightByKey[key] = task
        let resolved = await task.value
        inFlightByKey[key] = nil
        if let resolved { metadataByKey[key] = resolved }
        return resolved
    }
}

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
    @State private var refreshVersion = 0
    @Environment(\.isEnabled) private var isEnabled

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
        // Keep the badge mounted while unwatched. Search remains alive behind
        // the Details overlay, and an EmptyView branch can miss the store
        // notification that should reveal the checkmark when Details closes.
        WatchedCheckmarkIcon(size: size)
            .opacity(isWatched ? 1 : 0)
            .accessibilityHidden(!isWatched)
            .task(id: refreshTaskIdentity) {
                await refresh()
            }
            .onReceive(NotificationCenter.default.publisher(for: WatchedStore.changedNotification)) { _ in
                // Re-key the SwiftUI task instead of starting an untracked Task.
                // Store sync and view recreation can otherwise overlap refreshes,
                // allowing an older result to overwrite a newer watched state.
                refreshVersion &+= 1
            }
    }

    /// Re-runs the lookup whenever the card's identity changes. Search results
    /// arrive IMDb-only and gain TMDB aliases when their background `/meta`
    /// enrichment lands — without those aliases in the identity, the badge
    /// would never recalculate and would miss a TMDB-first watched record.
    private var refreshIdentity: String {
        let imdb = meta?.imdbId?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        let tmdb = meta?.tmdbId.map(String.init) ?? ""
        return "\(WatchedStore.activeProfileId ?? "default")\u{1f}\(type.lowercased())\u{1f}\(metaId)\u{1f}\(imdb)\u{1f}\(tmdb)"
    }

    private var refreshTaskIdentity: String {
        "\(refreshIdentity)\u{1f}\(refreshVersion)\u{1f}\(isEnabled)"
    }

    @MainActor
    private func refresh() async {
        let snapshot = WatchedStore.currentSnapshot()
        let isSeries = ["series", "tv", "show", "tvshow"].contains(type.lowercased())
        guard isSeries else {
            isWatched = meta.map { snapshot.contains(meta: $0) }
                ?? snapshot.contains(metaId: metaId, type: type)
            return
        }

        if meta.map({ snapshot.containsCatalogTitle(meta: $0) })
            ?? snapshot.contains(metaId: metaId, type: type) {
            isWatched = true
            return
        }

        // No watched episodes means this cannot be a completed series, and it
        // also lets untouched catalog cards avoid a metadata network request.
        let previewWatchedKeys = meta.map { snapshot.catalogWatchedEpisodeKeys(meta: $0) }
            ?? snapshot.watchedEpisodeKeys(metaId: metaId)
        guard !previewWatchedKeys.isEmpty else {
            isWatched = false
            return
        }

        // Search enrichment can carry the complete episode guide on the card.
        // Resolve it synchronously from that already-loaded data instead of
        // starting a second /meta request for every search result.
        if let videos = meta?.videos,
           CatalogWatchedPolicy.hasWatchedAllAiredEpisodes(
               videos: videos,
               watchedEpisodeKeys: previewWatchedKeys
           ) {
            isWatched = true
            return
        }

        guard let fullMeta = await CatalogWatchedMetadataCache.shared.fullMetadata(
            metaId: metaId,
            type: type,
            preview: meta
        ), !Task.isCancelled else { return }

        let freshSnapshot = WatchedStore.currentSnapshot()
        isWatched = freshSnapshot.containsCatalogTitle(meta: fullMeta)
            || CatalogWatchedPolicy.hasWatchedAllAiredEpisodes(
                videos: fullMeta.videos,
                watchedEpisodeKeys: freshSnapshot.catalogWatchedEpisodeKeys(meta: fullMeta)
            )
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

struct DefaultFocusBindingModifier<V: Hashable>: ViewModifier {
    let binding: FocusState<V?>.Binding?
    let value: V?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let binding, let value {
            if #available(tvOS 17.0, *) {
                content.defaultFocus(binding, value)
            } else {
                content
            }
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

    @ViewBuilder
    func defaultFocusIfAvailable<V: Hashable>(_ binding: FocusState<V?>.Binding?, _ value: V?) -> some View {
        self.modifier(DefaultFocusBindingModifier(binding: binding, value: value))
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

// MARK: - Title actions native context menu

/// Native tvOS/iOS context menu for titles (Go to details / Add to library / Mark as watched / Continue watching actions)
struct TitleActionsMenuContent: View {
    let meta: NuvioMeta
    var onOpenDetails: (() -> Void)? = nil
    var continueProgress: Double? = nil
    var continueIsUpNext: Bool = false
    var onPlayManually: (() -> Void)? = nil
    var onStartFromBeginning: (() -> Void)? = nil
    var onRemoveFromContinueWatching: (() -> Void)? = nil
    var body: some View {
        contextMenuContent
    }

    @ViewBuilder
    private var contextMenuContent: some View {
        if continueProgress != nil || continueIsUpNext {
            Button {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    onOpenDetails?()
                }
            } label: {
                Label("Go to details", systemImage: "info.circle")
            }

            if let onPlayManually {
                Button {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        onPlayManually()
                    }
                } label: {
                    Label("Play manually", systemImage: "play.fill")
                }
            }

            if let onStartFromBeginning, !continueIsUpNext {
                Button {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        onStartFromBeginning()
                    }
                } label: {
                    Label("Start from beginning", systemImage: "arrow.counterclockwise")
                }
            }

            if let onRemoveFromContinueWatching {
                Button(role: .destructive) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        onRemoveFromContinueWatching()
                    }
                } label: {
                    Label("Remove", systemImage: "trash")
                }
            }
        } else {
            let inLibrary = LibraryStore.contains(metaId: meta.id, type: meta.type)
            let isItemWatched = WatchedStore.contains(meta: meta)

            Button {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    onOpenDetails?()
                }
            } label: {
                Label("Go to details", systemImage: "info.circle")
            }

            Button {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    toggleLibrary(currentlyInLibrary: inLibrary)
                }
            } label: {
                Label(
                    inLibrary ? "Remove from library" : "Add to library",
                    systemImage: inLibrary ? "checkmark" : "plus"
                )
            }

            Button {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    toggleWatched()
                }
            } label: {
                Label(
                    isItemWatched ? "Mark as unwatched" : "Mark as watched",
                    systemImage: isItemWatched ? "eye.slash" : "eye"
                )
            }
        }
    }

    private func toggleLibrary(currentlyInLibrary: Bool) {
        guard TraktSettingsStore.librarySourceMode != .local else {
            _ = LibraryStore.toggle(meta: meta)
            return
        }

        guard SelectedLibraryService.isSelectedAndAuthenticated else { return }

        let desiredMembership = !currentlyInLibrary
        Task {
            _ = await SelectedLibraryService.setWatchlist(
                meta,
                isInWatchlist: desiredMembership
            )
        }
    }

    private func toggleWatched() {
        let isSeries = ["series", "tv", "show", "tvshow"].contains(meta.type.lowercased())
        guard isSeries else {
            _ = WatchedStore.toggle(meta: meta)
            return
        }

        Task {
            let fullMeta = await CatalogWatchedMetadataCache.shared.fullMetadata(
                metaId: meta.id,
                type: meta.type,
                preview: meta
            ) ?? meta
            guard !Task.isCancelled else { return }
            _ = WatchedStore.toggle(meta: fullMeta)
        }
    }
}

struct TitleActionsContextMenu: ViewModifier {
    let meta: NuvioMeta
    var onOpenDetails: (() -> Void)? = nil
    var continueProgress: Double? = nil
    var continueIsUpNext: Bool = false
    var onPlayManually: (() -> Void)? = nil
    var onStartFromBeginning: (() -> Void)? = nil
    var onRemoveFromContinueWatching: (() -> Void)? = nil

    func body(content: Content) -> some View {
        content
            .contextMenu {
                TitleActionsMenuContent(
                    meta: meta,
                    onOpenDetails: onOpenDetails,
                    continueProgress: continueProgress,
                    continueIsUpNext: continueIsUpNext,
                    onPlayManually: onPlayManually,
                    onStartFromBeginning: onStartFromBeginning,
                    onRemoveFromContinueWatching: onRemoveFromContinueWatching
                )
            }
    }
}

extension View {
    func titleActionsContextMenu(
        meta: NuvioMeta,
        onOpenDetails: (() -> Void)? = nil,
        continueProgress: Double? = nil,
        continueIsUpNext: Bool = false,
        onPlayManually: (() -> Void)? = nil,
        onStartFromBeginning: (() -> Void)? = nil,
        onRemoveFromContinueWatching: (() -> Void)? = nil
    ) -> some View {
        modifier(
            TitleActionsContextMenu(
                meta: meta,
                onOpenDetails: onOpenDetails,
                continueProgress: continueProgress,
                continueIsUpNext: continueIsUpNext,
                onPlayManually: onPlayManually,
                onStartFromBeginning: onStartFromBeginning,
                onRemoveFromContinueWatching: onRemoveFromContinueWatching
            )
        )
    }
}
