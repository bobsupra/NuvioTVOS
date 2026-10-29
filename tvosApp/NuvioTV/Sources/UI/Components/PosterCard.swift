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
import AVFoundation
import AVKit
import CoreMedia
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Card corner radius options available in Settings (matching Android TV & Apple TV styling)
enum CardCornerRadiusOption: String, CaseIterable, Identifiable {
    case sharp = "Sharp (0pt)"
    case subtle = "Subtle (8pt)"
    case classic = "Classic (16pt)"
    case rounded = "Rounded (22pt)"
    case pill = "Pill (28pt)"

    var id: String { rawValue }

    var radius: CGFloat {
        switch self {
        case .sharp: return 0
        case .subtle: return 8
        case .classic: return 16
        case .rounded: return 22
        case .pill: return 28
        }
    }

    var scale: CGFloat {
        radius / 16.0
    }

    static func from(rawValue: String?) -> CardCornerRadiusOption {
        guard let rawValue, !rawValue.isEmpty else { return .classic }
        if let match = CardCornerRadiusOption(rawValue: rawValue) {
            return match
        }
        let lower = rawValue.lowercased()
        if lower.contains("sharp") || rawValue == "0" { return .sharp }
        if lower.contains("subtle") || rawValue == "8" { return .subtle }
        if lower.contains("classic") || lower.contains("standard") || rawValue == "16" { return .classic }
        if lower.contains("rounded") || rawValue == "22" { return .rounded }
        if lower.contains("pill") || rawValue == "28" { return .pill }
        return .classic
    }
}

/// Card size options available in Settings (matching Android TV width & size presets)
enum CardSizeOption: String, CaseIterable, Identifiable {
    case compact = "Compact"
    case dense = "Dense"
    case standard = "Standard"
    case balanced = "Balanced"
    case comfort = "Comfort"
    case large = "Large"

    var id: String { rawValue }

    /// Width scaling multiplier (1.0 = standard 210pt on tvOS modern layout)
    var scale: CGFloat {
        switch self {
        case .compact: return 0.85
        case .dense: return 0.92
        case .standard: return 1.00
        case .balanced: return 1.06
        case .comfort: return 1.12
        case .large: return 1.18
        }
    }

    static func from(rawValue: String?) -> CardSizeOption {
        guard let rawValue, !rawValue.isEmpty else { return .standard }
        if let match = CardSizeOption(rawValue: rawValue) {
            return match
        }
        let lower = rawValue.lowercased()
        if lower.contains("compact") { return .compact }
        if lower.contains("dense") { return .dense }
        if lower.contains("standard") { return .standard }
        if lower.contains("balanced") { return .balanced }
        if lower.contains("comfort") { return .comfort }
        if lower.contains("large") { return .large }
        return .standard
    }
}

/// Global card styling resolver
enum AppCardStyle {
    static let defaultCornerRadiusRaw = CardCornerRadiusOption.classic.rawValue
    static let defaultCardSizeRaw = CardSizeOption.standard.rawValue

    static func cornerRadius(for rawValue: String?, fallback: CGFloat = 16) -> CGFloat {
        guard let rawValue, !rawValue.isEmpty else { return fallback }
        return CardCornerRadiusOption.from(rawValue: rawValue).radius
    }

    static func cornerRadiusScale(for rawValue: String?) -> CGFloat {
        CardCornerRadiusOption.from(rawValue: rawValue).scale
    }

    static func cardSizeScale(for rawValue: String?) -> CGFloat {
        CardSizeOption.from(rawValue: rawValue).scale
    }

    static func posterWidth(base: CGFloat = 210, for sizeRawValue: String?) -> CGFloat {
        round(base * cardSizeScale(for: sizeRawValue))
    }

    static func posterHeight(base: CGFloat = 315, for sizeRawValue: String?) -> CGFloat {
        round(base * cardSizeScale(for: sizeRawValue))
    }

    static func episodeCornerRadius(for rawValue: String?) -> CGFloat {
        let opt = CardCornerRadiusOption.from(rawValue: rawValue)
        switch opt {
        case .sharp: return 0
        case .subtle: return 12
        case .classic: return 24
        case .rounded: return 30
        case .pill: return 38
        }
    }

    static func badgeCornerRadius(for rawValue: String?, base: CGFloat = 10) -> CGFloat {
        let opt = CardCornerRadiusOption.from(rawValue: rawValue)
        switch opt {
        case .sharp: return 0
        case .subtle: return max(4, base * 0.6)
        case .classic: return base
        case .rounded: return base * 1.3
        case .pill: return base * 1.8
        }
    }

    /// Computes the aspect-ratio-aware bounding box for seek preview cards,
    /// ensuring widescreen (2.39:1) and classic (4:3) content fit within maxWidth × maxHeight
    /// without edge cropping or vertical distortion.
    static func seekCardSize(
        for naturalSize: CGSize,
        maxWidth: CGFloat = 480,
        maxHeight: CGFloat = 270
    ) -> CGSize {
        guard naturalSize.width > 0, naturalSize.height > 0 else {
            return CGSize(width: maxWidth, height: maxHeight)
        }
        let aspect = naturalSize.width / naturalSize.height
        let targetAspect = maxWidth / maxHeight
        if aspect >= targetAspect {
            // Wider than 16:9 (e.g. 2.39:1) -> fit to width, scale height down
            return CGSize(width: maxWidth, height: max(1, round(maxWidth / aspect)))
        } else {
            // Taller than 16:9 (e.g. 4:3) -> fit to height, scale width down
            return CGSize(width: max(1, round(maxHeight * aspect)), height: maxHeight)
        }
    }
}

/// Home inputs captured by callbacks must invalidate cached cards when they change.
struct TVCardFocusCallbackContext: Equatable {
    var restrictFocusToCardKey: String? = nil
    var suppressFocusAnimations: Bool = false
}

/// Poster card component with focus animation (tvOS) and tap handling (iOS)
struct PosterCard: View {
    let meta: NuvioMeta
    var customPosterScreen: CustomPosterScreen = .home
    var isLandscape: Bool = false
    var isAlwaysLandscape: Bool = false
    var tileShape: CollectionTileShape = .poster
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
    var collectionOrigin: CollectionOriginPresentation? = nil
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
    var onRefreshCatalog: (() -> Void)? = nil
    var cardIndex: Int? = nil
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
    var focusCallbackContext: TVCardFocusCallbackContext = TVCardFocusCallbackContext()
    /// Optional upward-focus fallback for Home's lazy vertical rows. The
    /// handler deliberately stays off the default path for other directions.
    var onMove: ((MoveCommandDirection) -> Void)? = nil
    var isWatched: Bool? = nil
    let onClick: () -> Void

    private let landscapeTransitionDuration: TimeInterval = 0.3
    @AppStorage(SettingsKey.customPosterURLPattern) private var customPosterURLPattern = ""
    @AppStorage(SettingsKey.customPosterEnabledScreens) private var customPosterEnabledScreens = "all"
    @State private var loadedCustomLandscapeArtworkURL: String?

    #if os(tvOS)
    @FocusState private var isFocused: Bool
    @State private var didRequestInitialFocus = false
    @State private var landscapeArtworkPrepared = false
    @AppStorage(SettingsKey.trailersEnabled) private var trailersEnabled = true
    @AppStorage(SettingsKey.trailerDelay) private var trailerDelay = 7
    @AppStorage(SettingsKey.cardCornerRadius) private var cardCornerRadiusSetting = AppCardStyle.defaultCornerRadiusRaw
    @AppStorage(SettingsKey.liquidGlassCards) private var liquidGlassCards = true
    @State private var isTrailerPreviewActive = false
    @State private var isTrailerPreviewReady = false
    @State private var didFinishTrailerPreview = false
    /// Rapid navigation should not start a separate backdrop/episode-art decode
    /// for every card passed over. Arm that preload only after focus has settled,
    /// matching Home's hero debounce.
    @State private var landscapePreloadArmed = false
    #else
    @AppStorage(SettingsKey.cardCornerRadius) private var cardCornerRadiusSetting = AppCardStyle.defaultCornerRadiusRaw
    @AppStorage(SettingsKey.liquidGlassCards) private var liquidGlassCards = true
    #endif

    var body: some View {
        #if os(tvOS)
        // Keep directional input in tvOS's focus engine. Per-card move
        // handlers bypass the clickpad dead zone and can turn a light touch
        // into an immediate focus change.
        ZStack(alignment: .topLeading) {
            Button(action: onClick) {
                posterContent
            }
            .buttonStyle(PosterCardButtonStyle(onNativeFocusChange: { focused in
                if focused { onFocus?(meta) } else { onBlur?(meta) }
            }))
            .accessibilityIdentifier("poster-card-\(externalFocusValue ?? meta.id)")
            .disabled(!allowsFocus)
            .focused($isFocused)
            .modifier(ExternalFocusBinding(binding: externalFocus, id: externalFocusValue ?? meta.id))
            .nuvioFocusEffectDisabledIfAvailable()
            .modifier(OptionalMoveCommandHandler(handler: onMove))
            .titleActionsContextMenu(
                meta: meta,
                onOpenDetails: onOpenDetails ?? onClick,
                continueProgress: continueProgress,
                continueIsUpNext: continueIsUpNext,
                onPlayManually: onPlayManually,
                onStartFromBeginning: onStartFromBeginning,
                onRemoveFromContinueWatching: onRemoveFromContinueWatching,
                onRefreshCatalog: onRefreshCatalog,
                isEnabled: !isEffectivelyAlwaysLandscape
            )
            .onChange(of: isFocused) { _, focused in
                if focused {
                    didFinishTrailerPreview = false
                } else {
                    landscapePreloadArmed = false
                    cancelTrailerPreview()
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
                    try await Task.sleep(nanoseconds: 350_000_000)
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
            .onChange(of: shouldRequestInitialFocus) { _, shouldRequest in
                if shouldRequest {
                    guard !didRequestInitialFocus else { return }
                    didRequestInitialFocus = true
                    onInitialFocusRequested?()
                    DispatchQueue.main.async {
                        isFocused = true
                    }
                } else {
                    didRequestInitialFocus = false
                }
            }
            .frame(width: layoutWidth, height: totalCardHeight, alignment: .topLeading)
        }
        .frame(width: cardWidth, height: totalCardHeight, alignment: .topLeading)
        .titleActionsContextMenu(
            meta: meta,
            onOpenDetails: onOpenDetails ?? onClick,
            continueProgress: continueProgress,
            continueIsUpNext: continueIsUpNext,
            onPlayManually: onPlayManually,
            onStartFromBeginning: onStartFromBeginning,
            onRemoveFromContinueWatching: onRemoveFromContinueWatching,
            onRefreshCatalog: onRefreshCatalog,
            isEnabled: isEffectivelyAlwaysLandscape
        )
        .zIndex(showsFocusedAppearance ? 1 : 0)
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
            onRemoveFromContinueWatching: onRemoveFromContinueWatching,
            onRefreshCatalog: onRefreshCatalog
        )
        .frame(width: layoutWidth, height: totalCardHeight, alignment: .topLeading)
        #endif
    }

    private var posterContent: some View {
        VStack(alignment: .leading, spacing: 9) {
            CachedPosterArtwork(
                urlString: imageUrl,
                preloadURLString: landscapePreloadURL,
                fallbackURLString: effectiveLandscape ? landscapeArtworkFallbackURL : portraitArtworkFallbackURL,
                preloadFallbackURLString: landscapePreloadURL == nil ? nil : landscapeArtworkFallbackURL,
                width: cardWidth,
                height: cardHeight,
                maximumWidth: artworkDecodeWidth,
                preloadMaximumWidth: landscapeArtworkDecodeWidth,
                minimumSwapDelay: 0,
                onPreloadFinished: { succeeded in
                    #if os(tvOS)
                    landscapeArtworkPrepared = succeeded
                    #endif
                },
                onArtworkLoaded: { loadedURL in
                    if loadedURL == customLandscapeArtworkURL {
                        loadedCustomLandscapeArtworkURL = loadedURL
                    } else if loadedURL == landscapeArtworkFallbackURL {
                        loadedCustomLandscapeArtworkURL = nil
                    }
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
                // Prepare during the delay, but keep playback and visibility
                // gated by isTrailerPreviewActive until the timer completes.
                if isFocused && effectiveLandscape && trailersEnabled
                    && !isContinueOrUpcomingCard && !didFinishTrailerPreview {
                    TrailerPreviewPlayer(
                        meta: meta,
                        isActive: isTrailerPreviewActive,
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
            .overlay(alignment: effectiveLandscape ? .topTrailing : .top) {
                continueBadge
            }
            .overlay(alignment: .bottomTrailing) {
                if let collectionOrigin, !continueIsUpNext {
                    CollectionOriginBadge(origin: collectionOrigin)
                        .padding(.trailing, 22)
                        // The progress bar occupies the bottom 16...24 points.
                        // Leave a 10-point gap above it, or use the bottom inset
                        // directly when there is no progress bar.
                        .padding(.bottom, continueProgress != nil ? 34 : 16)
                }
            }
            .overlay(alignment: .topTrailing) {
                if showsWatchedBadge {
                    WatchedCheckmarkBadge(meta: meta)
                }
            }
            // Mask the complete card interior after composing both the trailer
            // and landscape artwork overlays. The focus border remains outside
            // this mask so its stroke stays crisp.
            .clipShape(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
            .modifier(
                LiquidGlassCardModifier(
                    cornerRadius: cardCornerRadius,
                    isFocused: showsFocusedAppearance,
                    isEnabled: liquidGlassCards
                )
            )
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
        if shouldShowLandscapeOverlay && !usesLoadedCustomLandscapeArtwork {
            ZStack(alignment: .bottomLeading) {
                if shouldShowLandscapeGradient {
                    if liquidGlassCards {
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0.0),
                                .init(color: .black.opacity(0.38), location: 0.35),
                                .init(color: .black.opacity(0.85), location: 0.85),
                                .init(color: .black.opacity(0.95), location: 1.0)
                            ],
                            startPoint: .center,
                            endPoint: .bottom
                        )
                    } else {
                        LinearGradient(
                            colors: [.clear, .black.opacity(0.78)],
                            startPoint: .center,
                            endPoint: .bottom
                        )
                    }
                }

                if continueEpisodeText != nil {
                    continueLandscapeSummary
                } else if continueProgress != nil || continueRemainingText != nil {
                    Text(meta.name)
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                        .frame(maxWidth: cardWidth * 0.82, alignment: .leading)
                        .padding(EdgeInsets(top: 22, leading: 22, bottom: 54, trailing: 22))
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
                } else if !isEffectivelyAlwaysLandscape || !showsPosterTitle {
                    fallbackTitle
                        .frame(maxWidth: cardWidth * 0.62, alignment: .leading)
                        .padding(22)
                }
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
            let badgeRadius = AppCardStyle.badgeCornerRadius(for: cardCornerRadiusSetting, base: 10)
            Text(continueBadgeDisplayText)
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background {
                    if liquidGlassCards {
                        RoundedRectangle(cornerRadius: badgeRadius, style: .continuous)
                            .fill(continueBadgeFill.opacity(0.75))
                            .modifier(
                                LiquidGlassBadgeModifier(
                                    cornerRadius: badgeRadius,
                                    isFocused: showsFocusedAppearance
                                )
                            )
                    } else {
                        RoundedRectangle(cornerRadius: badgeRadius, style: .continuous)
                            .fill(continueBadgeFill)
                    }
                }
                .padding(.top, 16)
                .padding(.bottom, 16)
                .padding(.horizontal, effectiveLandscape ? 16 : 8)
        }
    }

    private var continueBadgeFill: Color {
        guard continueIsUpNext else { return Color.black.opacity(0.72) }
        let badge = (continueUpNextBadgeText ?? "Next Up").uppercased()
        if badge == "NEW SEASON" {
            return Color(red: 0xB4 / 255, green: 0x53 / 255, blue: 0x09 / 255)
        } else if badge == "NEW EPISODE" {
            return Color(red: 0x1D / 255, green: 0x4E / 255, blue: 0xD8 / 255)
        } else if badge == "AIRING TODAY" {
            return Color(red: 0x05 / 255, green: 0x96 / 255, blue: 0x69 / 255)
        } else if badge.hasPrefix("AIRS IN") || badge == "COMING SOON" {
            return Color(red: 0x47 / 255, green: 0x55 / 255, blue: 0x69 / 255)
        } else {
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

    private var isEffectivelyAlwaysLandscape: Bool {
        isAlwaysLandscape || tileShape == .landscape || meta.tileShape == .landscape
    }

    private var shouldShowLandscapeOverlay: Bool {
        if usesLoadedCustomLandscapeArtwork { return false }
        if isContinueOrUpcomingCard { return true }
        if isEffectivelyAlwaysLandscape {
            return landscapeLogoURL != nil || !showsPosterTitle
        }
        return true
    }

    private var shouldShowLandscapeGradient: Bool {
        if usesLoadedCustomLandscapeArtwork { return false }
        if isContinueOrUpcomingCard { return true }
        if isEffectivelyAlwaysLandscape {
            return landscapeLogoURL != nil || !showsPosterTitle
        }
        return true
    }

    private var effectiveLandscape: Bool {
        if isEffectivelyAlwaysLandscape { return true }
        return isLandscape && (landscapeArtworkPrepared || landscapeArtworkURL == nil)
    }

    private var cardWidth: CGFloat {
        if effectiveLandscape {
            return effectiveHomeLayout == "Compact" ? 454 : 560
        }
        if tileShape == .square || meta.tileShape == .square {
            return effectiveHomeLayout == "Compact" ? 255 : 315
        }
        return effectiveHomeLayout == "Compact" ? 170 : 210
    }

    /// Keep the focusable surface aligned with the standard portrait column
    /// when a landscape card is displayed. The artwork remains landscape,
    /// but tvOS should use the leading edge for vertical row matching.
    private var layoutWidth: CGFloat {
        if effectiveLandscape {
            return effectiveHomeLayout == "Compact" ? 170 : 210
        }
        if tileShape == .square || meta.tileShape == .square {
            return cardWidth
        }
        return effectiveHomeLayout == "Compact" ? 170 : 210
    }

    private var cardHeight: CGFloat {
        effectiveHomeLayout == "Compact" ? 255 : 315
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
        AppCardStyle.cornerRadius(for: cardCornerRadiusSetting, fallback: 16)
    }

    private var landscapeArtworkURL: String? {
        if continueEpisodeText != nil,
           let continueEpisodeArtworkURL, !continueEpisodeArtworkURL.isEmpty {
            return continueEpisodeArtworkURL
        }
        if let customLandscapeArtworkURL { return customLandscapeArtworkURL }
        return originalLandscapeArtworkURL
    }

    private var originalLandscapeArtworkURL: String? {
        if continueEpisodeText != nil,
           let continueEpisodeArtworkURL, !continueEpisodeArtworkURL.isEmpty {
            return continueEpisodeArtworkURL
        }
        if let customLandscape = meta.landscapePosterUrl?.trimmingCharacters(in: .whitespacesAndNewlines), !customLandscape.isEmpty {
            return customLandscape
        }
        if meta.posterShape == "landscape" || meta.tileShape == .landscape {
            return meta.posterUrl ?? meta.backgroundUrl
        }
        return meta.backgroundUrl ?? meta.posterUrl
    }

    private var customPortraitArtworkURL: String? {
        CustomPosterURLResolver.resolve(
            pattern: customPosterURLPattern,
            meta: meta,
            screen: customPosterScreen,
            enabledScreens: customPosterEnabledScreens,
            shape: tileShape == .square || meta.tileShape == .square ? "square" : "poster"
        )
    }

    private var customLandscapeArtworkURL: String? {
        CustomPosterURLResolver.resolve(
            pattern: customPosterURLPattern,
            meta: meta,
            screen: customPosterScreen,
            enabledScreens: customPosterEnabledScreens,
            shape: "landscape"
        )
    }

    private var portraitArtworkFallbackURL: String? {
        customPortraitArtworkURL == nil ? nil : meta.posterUrl
    }

    private var landscapeArtworkFallbackURL: String? {
        if isContinueOrUpcomingCard, continueEpisodeText != nil {
            return meta.backdropUrl
        }
        return customLandscapeArtworkURL == nil ? nil : originalLandscapeArtworkURL
    }

    private var usesLoadedCustomLandscapeArtwork: Bool {
        !isContinueOrUpcomingCard
            && customLandscapeArtworkURL != nil
            && loadedCustomLandscapeArtworkURL == customLandscapeArtworkURL
    }

    private var imageUrl: String? {
        if effectiveLandscape {
            return landscapeArtworkURL
        }
        return customPortraitArtworkURL ?? meta.posterUrl
    }

    private var landscapePreloadURL: String? {
        landscapePreloadArmed || isLandscape || isEffectivelyAlwaysLandscape ? landscapeArtworkURL : nil
    }

    private var artworkDecodeWidth: CGFloat {
        effectiveLandscape ? (effectiveHomeLayout == "Compact" ? 454 : 560) : cardWidth
    }

    private var landscapeArtworkDecodeWidth: CGFloat {
        effectiveHomeLayout == "Compact" ? 454 : 560
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

    private var isContinueOrUpcomingCard: Bool {
        continueProgress != nil || continueIsUpNext || continueRemainingText != nil || continueEpisodeText != nil || continueUpNextBadgeText != nil
    }

    private var trailerActivationIdentity: String {
        "\(isFocused)\u{1f}\(effectiveLandscape)\u{1f}\(trailersEnabled)\u{1f}\(trailerDelay)\u{1f}\(isContinueOrUpcomingCard)"
    }

    private var isTrailerPreviewVisible: Bool {
        !isContinueOrUpcomingCard && isTrailerPreviewActive && isTrailerPreviewReady && !didFinishTrailerPreview
    }

    @MainActor
    private func activateTrailerPreviewAfterDelay() async {
        isTrailerPreviewActive = false
        isTrailerPreviewReady = false
        didFinishTrailerPreview = false
        guard isFocused, effectiveLandscape, trailersEnabled, !isContinueOrUpcomingCard else { return }

        let delay = min(15, max(0, trailerDelay))
        do {
            try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
        } catch {
            return
        }
        guard !Task.isCancelled, isFocused, effectiveLandscape, trailersEnabled, !isContinueOrUpcomingCard else { return }
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
        AppCardStyle.cornerRadius(for: cardCornerRadiusSetting, fallback: 8)
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

    private var landscapeArtworkDecodeWidth: CGFloat {
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
            && lhs.customPosterScreen == rhs.customPosterScreen
            && lhs.meta.name == rhs.meta.name
            && lhs.meta.posterUrl == rhs.meta.posterUrl
            && lhs.meta.backgroundUrl == rhs.meta.backgroundUrl
            && lhs.meta.landscapePosterUrl == rhs.meta.landscapePosterUrl
            && lhs.meta.logoUrl == rhs.meta.logoUrl
            && lhs.meta.imdbId == rhs.meta.imdbId
            && lhs.meta.tmdbId == rhs.meta.tmdbId
            && lhs.meta.type == rhs.meta.type
            && lhs.meta.trailerYtIds == rhs.meta.trailerYtIds
            && lhs.isLandscape == rhs.isLandscape
            && lhs.isAlwaysLandscape == rhs.isAlwaysLandscape
            && lhs.tileShape == rhs.tileShape
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
            && lhs.cardIndex == rhs.cardIndex
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
            && lhs.focusCallbackContext == rhs.focusCallbackContext
            && lhs.isWatched == rhs.isWatched
    }
}

#if os(tvOS)
final class TrailerPlayerLayerView: UIView {
    var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }

    override static var layerClass: AnyClass {
        AVPlayerLayer.self
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        playerLayer.videoGravity = .resizeAspectFill
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        playerLayer.videoGravity = .resizeAspectFill
        backgroundColor = .clear
    }
}

struct TrailerPlayerSurface: UIViewRepresentable {
    let player: AVPlayer
    var videoGravity: AVLayerVideoGravity = .resizeAspectFill
    var onLayerAvailable: ((AVPlayerLayer) -> Void)? = nil
    let onReadyForDisplay: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onReadyForDisplay: onReadyForDisplay)
    }

    func makeUIView(context: Context) -> TrailerPlayerLayerView {
        let view = TrailerPlayerLayerView()
        view.playerLayer.videoGravity = videoGravity
        view.playerLayer.player = player
        context.coordinator.observe(layer: view.playerLayer, player: player)
        onLayerAvailable?(view.playerLayer)
        return view
    }

    func updateUIView(_ uiView: TrailerPlayerLayerView, context: Context) {
        if uiView.playerLayer.videoGravity != videoGravity {
            uiView.playerLayer.videoGravity = videoGravity
        }
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
            context.coordinator.observe(layer: uiView.playerLayer, player: player)
            onLayerAvailable?(uiView.playerLayer)
        } else {
            context.coordinator.checkReadiness(layer: uiView.playerLayer, player: player)
        }
    }

    final class Coordinator {
        private let onReadyForDisplay: () -> Void
        private var readyObserver: NSKeyValueObservation?
        private var timeObserver: Any?
        private var currentItemObserver: NSKeyValueObservation?
        private var itemStatusObserver: NSKeyValueObservation?
        private weak var observedPlayer: AVPlayer?
        private weak var observedLayer: AVPlayerLayer?
        private var didNotify = false

        init(onReadyForDisplay: @escaping () -> Void) {
            self.onReadyForDisplay = onReadyForDisplay
        }

        func observe(layer: AVPlayerLayer, player: AVPlayer) {
            cleanup()
            self.observedPlayer = player
            self.observedLayer = layer
            self.didNotify = false

            if layer.isReadyForDisplay {
                notifyReady()
                return
            }

            readyObserver = layer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] layer, _ in
                if layer.isReadyForDisplay {
                    self?.notifyReady()
                }
            }

            currentItemObserver = player.observe(\.currentItem, options: [.new, .initial]) { [weak self] player, _ in
                guard let self else { return }
                self.observeCurrentItem(player.currentItem)
            }

            timeObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(value: 1, timescale: 30),
                queue: .main
            ) { [weak self] time in
                if time.seconds > 0 {
                    self?.notifyReady()
                }
            }
        }

        func checkReadiness(layer: AVPlayerLayer, player: AVPlayer) {
            if layer.isReadyForDisplay || (player.currentItem?.status == .readyToPlay && player.currentTime().seconds > 0) {
                notifyReady()
            }
        }

        private func observeCurrentItem(_ item: AVPlayerItem?) {
            itemStatusObserver?.invalidate()
            itemStatusObserver = nil
            guard let item else { return }
            if item.status == .readyToPlay {
                notifyReady()
                return
            }
            itemStatusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                if item.status == .readyToPlay {
                    self?.notifyReady()
                }
            }
        }

        private func notifyReady() {
            guard !didNotify else { return }
            didNotify = true
            DispatchQueue.main.async { [weak self] in
                self?.onReadyForDisplay()
            }
        }

        private func cleanup() {
            readyObserver?.invalidate()
            readyObserver = nil
            itemStatusObserver?.invalidate()
            itemStatusObserver = nil
            currentItemObserver?.invalidate()
            currentItemObserver = nil
            if let timeObserver, let observedPlayer {
                observedPlayer.removeTimeObserver(timeObserver)
            }
            timeObserver = nil
        }

        deinit {
            cleanup()
        }
    }
}

/// Shared video preview for Home cards and the focused Grid hero.
struct TrailerPreviewPlayer: View {
    let meta: NuvioMeta
    /// Prepare while the caller's delay runs; playback and visibility remain
    /// gated by its activation state.
    let isActive: Bool
    let onPlaybackReady: () -> Void
    let onPlaybackFinished: () -> Void
    var onPlaybackProgress: ((Double, Double) -> Void)? = nil
    var onPlaybackUnavailable: (() -> Void)? = nil

    @State private var player = AVPlayer()
    @State private var isRenderReady = false
    @State private var currentPlaybackSource: TrailerPlaybackSource?
    @State private var timeObserverToken: Any?
    @State private var itemStatusObserver: NSKeyValueObservation?
    @State private var failedToEndObserver: NSObjectProtocol?
    @State private var didReportUnavailable = false
    @State private var isPlaybackUnavailable = false
    @State private var playbackActiveOverride: Bool?
    @AppStorage(SettingsKey.trailerPreviewSound) private var trailerPreviewSound = false
    private let resolver = YouTubeTrailerResolver.shared

    var body: some View {
        TrailerPlayerSurface(player: player) {
            guard !isRenderReady else { return }
            isRenderReady = true
            if wantsPlayback {
                onPlaybackReady()
            }
        }
        // Keep the landscape artwork visible while the trailer URL is
        // resolving and buffering, only revealing the video when decoded & ready.
        .opacity(isVisible ? 1 : 0)
        .animation(.easeInOut(duration: 0.32), value: isVisible)
        .allowsHitTesting(false)
        .onAppear { playbackActiveOverride = isActive }
        .task(id: previewIdentity) {
            await startPreview()
        }
        .onChange(of: isActive) { _, active in
            playbackActiveOverride = active
            if active {
                if isPlaybackUnavailable {
                    reportPlaybackUnavailable()
                    return
                }
                applySoundPreference(trailerPreviewSound)
                player.play()
                if isRenderReady { onPlaybackReady() }
            } else {
                player.pause()
            }
        }
        .onChange(of: trailerPreviewSound) { _, soundEnabled in
            applySoundPreference(soundEnabled)
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime).receive(on: RunLoop.main)
        ) { notification in
            guard let item = notification.object as? AVPlayerItem,
                  item == player.currentItem else {
                return
            }
            onPlaybackFinished()
        }
        .onDisappear {
            playbackActiveOverride = false
            isRenderReady = false
            cleanupTimeObserver()
            cleanupFailureObservers()
            let seconds = player.currentTime().seconds
            if seconds > 0.1 && !seconds.isNaN && !seconds.isInfinite {
                TrailerPlaybackHandoff.shared.recordHandoff(
                    metaId: meta.id,
                    time: seconds,
                    playbackSource: currentPlaybackSource
                )
            }
            player.pause()
            player.replaceCurrentItem(with: nil)
        }
    }

    private var previewIdentity: String {
        "\(meta.id)\u{1f}\(meta.trailerYtIds?.joined(separator: ",") ?? "")"
    }

    private var isVisible: Bool {
        isActive && isRenderReady
    }

    // The resolving task can outlive the View value that launched it. Read
    // shared state after suspension instead of that value's initial isActive.
    private var wantsPlayback: Bool { playbackActiveOverride ?? isActive }

    @MainActor
    private func startPreview() async {
        isRenderReady = false
        didReportUnavailable = false
        isPlaybackUnavailable = false

        guard let playbackSource = await resolver.resolvePreview(for: meta) else {
            guard !Task.isCancelled else { return }
            reportPlaybackUnavailable()
            return
        }
        guard let url = URL(string: playbackSource.videoUrl) else {
            guard !Task.isCancelled else { return }
            reportPlaybackUnavailable()
            return
        }
        guard !Task.isCancelled else {
            return
        }

        currentPlaybackSource = playbackSource

        let asset: AVURLAsset
        if let userAgent = playbackSource.requestHeaders["User-Agent"], !userAgent.isEmpty {
            asset = AVURLAsset(
                url: url,
                options: [AVURLAssetHTTPUserAgentKey: userAgent]
            )
        } else {
            asset = AVURLAsset(url: url)
        }
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 2.0
        item.preferredPeakBitRate = 0
        item.preferredMaximumResolution = .zero
        player.replaceCurrentItem(with: item)
        observePlaybackFailure(for: item)
        applySoundPreference(trailerPreviewSound)
        setupTimeObserver()
        if wantsPlayback {
            player.play()
        }
    }

    private func setupTimeObserver() {
        cleanupTimeObserver()
        let metaId = meta.id
        let source = currentPlaybackSource
        let previewPlayer = player
        let progressCallback = onPlaybackProgress
        timeObserverToken = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { time in
            let seconds = time.seconds
            let duration = progressCallback == nil
                ? .nan
                : previewPlayer.currentItem?.duration.seconds ?? .nan
            let shouldReportProgress = progressCallback != nil && seconds.isFinite && seconds >= 0
                && duration.isFinite && duration > 0
            let shouldRecordHandoff = seconds > 0.1 && seconds.isFinite
            if shouldReportProgress || shouldRecordHandoff {
                MainActor.assumeIsolated {
                    if shouldReportProgress {
                        progressCallback?(seconds, duration)
                    }
                    if shouldRecordHandoff {
                        TrailerPlaybackHandoff.shared.recordHandoff(
                            metaId: metaId,
                            time: seconds,
                            playbackSource: source
                        )
                    }
                }
            }
        }
    }

    private func observePlaybackFailure(for item: AVPlayerItem) {
        guard onPlaybackUnavailable != nil else { return }
        itemStatusObserver?.invalidate()
        let previewPlayer = player
        itemStatusObserver = item.observe(\.status, options: [.initial, .new]) { observedItem, _ in
            guard observedItem.status == .failed else { return }
            Task { @MainActor in
                guard observedItem == previewPlayer.currentItem else { return }
                self.reportPlaybackUnavailable()
            }
        }
        failedToEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { notification in
            guard let failedItem = notification.object as? AVPlayerItem,
                  failedItem == previewPlayer.currentItem else { return }
            Task { @MainActor in
                self.reportPlaybackUnavailable()
            }
        }
    }

    private func cleanupTimeObserver() {
        if let token = timeObserverToken {
            player.removeTimeObserver(token)
            timeObserverToken = nil
        }
    }

    private func cleanupFailureObservers() {
        itemStatusObserver?.invalidate()
        itemStatusObserver = nil
        if let failedToEndObserver {
            NotificationCenter.default.removeObserver(failedToEndObserver)
            self.failedToEndObserver = nil
        }
    }

    @MainActor
    private func reportPlaybackUnavailable() {
        isPlaybackUnavailable = true
        // Preparation may fail before the delay ends. Report it when playback
        // becomes active, so the parent's existing fallback guards still apply.
        guard wantsPlayback, let onPlaybackUnavailable, !didReportUnavailable else { return }
        didReportUnavailable = true
        onPlaybackUnavailable()
    }

    private func applySoundPreference(_ soundEnabled: Bool) {
        player.isMuted = !soundEnabled
        player.volume = soundEnabled ? 1 : 0
        guard soundEnabled, wantsPlayback else { return }

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
    var customPosterScreen: CustomPosterScreen = .search
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
    var onBlur: ((NuvioMeta) -> Void)? = nil
    var onLongPress: (() -> Void)? = nil
    /// Forces the title/subtitle caption to render regardless of the user's
    /// global poster-labels setting (used by Search's Netflix-style grid).
    var forceShowLabels = false
    var onRefreshCatalog: (() -> Void)? = nil
    /// Optional directional-command hook used by grid search views to transfer
    /// focus to their keyboard controls at a grid boundary.
    var onMove: ((MoveCommandDirection) -> Void)? = nil
    let action: () -> Void

    @FocusState private var focused: Bool
    @State private var didRequestInitialFocus = false
    @AppStorage(SettingsKey.posterLabels) private var posterLabels = false
    @AppStorage(SettingsKey.smoothFocus) private var smoothFocus = true
    @AppStorage(SettingsKey.focusHighlighter) private var focusHighlighter = false
    @AppStorage(SettingsKey.cardCornerRadius) private var cardCornerRadiusSetting = AppCardStyle.defaultCornerRadiusRaw
    @AppStorage(SettingsKey.liquidGlassCards) private var liquidGlassCards = true
    @AppStorage(SettingsKey.customPosterURLPattern) private var customPosterURLPattern = ""
    @AppStorage(SettingsKey.customPosterEnabledScreens) private var customPosterEnabledScreens = "all"

    private var customPosterArtworkURL: String? {
        CustomPosterURLResolver.resolve(
            pattern: customPosterURLPattern,
            meta: meta,
            screen: customPosterScreen,
            enabledScreens: customPosterEnabledScreens,
            shape: meta.tileShape == .square ? "square" : "poster"
        )
    }

    private var showsFocusedAppearance: Bool { focused || retainFocusAppearance }

    private var cardCornerRadius: CGFloat {
        AppCardStyle.cornerRadius(for: cardCornerRadiusSetting, fallback: 16)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
    }

    var body: some View {
        let cardContent = VStack(alignment: .leading, spacing: 12) {
            CachedPosterArtwork(
                urlString: customPosterArtworkURL ?? meta.posterUrl,
                preloadURLString: nil,
                fallbackURLString: customPosterArtworkURL == nil ? nil : meta.posterUrl,
                width: width,
                height: height,
                maximumWidth: width,
                minimumSwapDelay: 0,
                onPreloadFinished: { _ in }
            ) {
                placeholder
            }
            .frame(width: width, height: height)
            .clipShape(shape)
            .modifier(
                LiquidGlassCardModifier(
                    cornerRadius: cardCornerRadius,
                    isFocused: showsFocusedAppearance,
                    isEnabled: liquidGlassCards
                )
            )
            .overlay(alignment: .topTrailing) {
                WatchedCheckmarkBadge(meta: meta)
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
        .buttonStyle(PosterCardButtonStyle(onNativeFocusChange: { focused in
            if focused { onFocus?(meta) } else { onBlur?(meta) }
        }))
        .focused($focused)
        .modifier(ExternalFocusBinding(binding: externalFocus, id: focusValue ?? meta.id))
        .focusEffectDisabledIfAvailable()
        .modifier(OptionalMoveCommandHandler(handler: onMove))
        .titleActionsContextMenu(
            meta: meta,
            onOpenDetails: action,
            onRefreshCatalog: onRefreshCatalog
        )
        .onAppear {
            guard shouldRequestInitialFocus, !didRequestInitialFocus else { return }
            didRequestInitialFocus = true
            onInitialFocusRequested?()
            DispatchQueue.main.async { focused = true }
        }
        .onChange(of: shouldRequestInitialFocus) { _, shouldRequest in
            if shouldRequest {
                guard !didRequestInitialFocus else { return }
                didRequestInitialFocus = true
                onInitialFocusRequested?()
                DispatchQueue.main.async { focused = true }
            } else {
                didRequestInitialFocus = false
            }
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

struct OptionalMoveCommandHandler: ViewModifier {
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

    @AppStorage(SettingsKey.amoled) private var amoled = false
    @AppStorage(SettingsKey.amoledSurfaces) private var amoledSurfaces = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if amoled && amoledSurfaces {
            content
                .background(Color.black, in: shape)
                .overlay(
                    shape.strokeBorder(
                        Color.white.opacity(prominent ? 0.30 : 0.10),
                        lineWidth: prominent ? 1.5 : 1
                    )
                )
        } else {
            #if os(tvOS)
            if #available(tvOS 26.0, *) {
                content
                    .background(
                        Color.white.opacity(prominent ? 0.16 : 0.08),
                        in: shape
                    )
                    .glassEffect(.regular, in: shape)
            } else {
                content
                    .background(.ultraThinMaterial, in: shape)
                    .background(
                        Color.white.opacity(prominent ? 0.16 : 0.08),
                        in: shape
                    )
            }
            #else
            content
                .background(.ultraThinMaterial, in: shape)
                .background(Color.white.opacity(prominent ? 0.16 : 0.08), in: shape)
            #endif
        }
    }
}

/// Liquid Glass surface modifier for card shapes (posters, landscape cards, episode tiles).
/// Uses native frosted glass only while focused; unfocused cards retain the
/// specular highlight with a lightweight translucent fill.
struct LiquidGlassCardModifier: ViewModifier {
    let cornerRadius: CGFloat
    var isFocused: Bool = false
    var isEnabled: Bool = true

    @AppStorage(SettingsKey.amoled) private var amoled = false
    @AppStorage(SettingsKey.amoledSurfaces) private var amoledSurfaces = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if amoled && amoledSurfaces {
            content
                .background(Color.black, in: shape)
                .overlay {
                    shape.strokeBorder(
                        Color.white.opacity(isFocused ? 0.34 : 0.08),
                        lineWidth: isFocused ? 1.5 : 1
                    )
                }
        } else if isEnabled {
            content
                .background {
                    #if os(tvOS)
                    if isFocused {
                        if #available(tvOS 26.0, *) {
                            shape
                                .fill(Color.white.opacity(0.16))
                                .glassEffect(.regular, in: shape)
                        } else {
                            shape
                                .fill(.ultraThinMaterial)
                                .overlay(shape.fill(Color.white.opacity(0.14)))
                        }
                    } else {
                        shape
                            .fill(Color.white.opacity(0.07))
                    }
                    #else
                    if isFocused {
                        shape
                            .fill(.ultraThinMaterial)
                            .overlay(shape.fill(Color.white.opacity(0.14)))
                    } else {
                        shape.fill(Color.white.opacity(0.07))
                    }
                    #endif
                }
                .overlay {
                    // Apple TV liquid glass specular reflection border
                    shape
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(isFocused ? 0.55 : 0.28),
                                    Color.white.opacity(isFocused ? 0.20 : 0.08),
                                    Color.white.opacity(isFocused ? 0.35 : 0.12)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: isFocused ? 1.5 : 1.0
                        )
                }
        } else {
            content
        }
    }
}

/// Frosted liquid glass pill/badge modifier for metadata tags, episode chips, and progress overlays.
struct LiquidGlassBadgeModifier: ViewModifier {
    let cornerRadius: CGFloat
    var isFocused: Bool = true

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if isFocused {
            #if os(tvOS)
            if #available(tvOS 26.0, *) {
                content
                    .glassEffect(.regular, in: shape)
                    .overlay(
                        shape.strokeBorder(
                            LinearGradient(
                                colors: [Color.white.opacity(0.40), Color.white.opacity(0.12)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                    )
            } else {
                content
                    .background(.ultraThinMaterial, in: shape)
                    .overlay(
                        shape.strokeBorder(Color.white.opacity(0.24), lineWidth: 1)
                    )
            }
            #else
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay(
                    shape.strokeBorder(Color.white.opacity(0.24), lineWidth: 1)
                )
            #endif
        } else {
            content.overlay(
                shape.strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.28), Color.white.opacity(0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
            )
        }
    }
}

extension View {
    func liquidGlassCard(cornerRadius: CGFloat, isFocused: Bool = false, isEnabled: Bool = true) -> some View {
        self.modifier(LiquidGlassCardModifier(cornerRadius: cornerRadius, isFocused: isFocused, isEnabled: isEnabled))
    }

    func liquidGlassBadge(cornerRadius: CGFloat, isFocused: Bool = true) -> some View {
        self.modifier(LiquidGlassBadgeModifier(cornerRadius: cornerRadius, isFocused: isFocused))
    }
}

/// A card standing in for one whose row has no data yet.
///
/// This is the one place a spinner still belongs: the row's catalog request is
/// genuinely outstanding and will either answer or fail, unlike a single poster
/// URL that can hang forever with nothing left to report. Uses the same
/// lightweight card modifier as loaded posters so loading rows remain cheap.
struct LoadingPosterCard: View {
    let width: CGFloat
    let height: CGFloat
    var cornerRadius: CGFloat = 16
    var isFocused: Bool = false
    var isLiquidGlassEnabled: Bool = true

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    var body: some View {
        ZStack {
            Color.clear

            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white.opacity(0.55))
        }
        .frame(width: width, height: height)
        .background {
            if !isLiquidGlassEnabled {
                shape
                    .fill(Color.white.opacity(isFocused ? 0.14 : 0.07))
            }
        }
        .overlay {
            if !isLiquidGlassEnabled {
                shape
                    .strokeBorder(
                        isFocused ? AppFocusOutline.color : Color.white.opacity(0.14),
                        lineWidth: isFocused ? AppFocusOutline.width : 1
                    )
            }
        }
        .modifier(LiquidGlassCardModifier(
            cornerRadius: cornerRadius,
            isFocused: isFocused,
            isEnabled: isLiquidGlassEnabled
        ))
        .clipShape(shape)
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
struct ArtworkPlaceholder: View {
    let hasArtworkURL: Bool
    let cornerRadius: CGFloat

    var body: some View {
        ZStack {
            Color.clear

            if !hasArtworkURL {
                Image(systemName: "photo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 42, height: 42)
                    .foregroundColor(.white.opacity(0.38))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.white.opacity(0.07))
        )
    }
}

struct CachedPosterArtwork<Placeholder: View>: View {
    let urlString: String?
    var preloadURLString: String? = nil
    var fallbackURLString: String? = nil
    var preloadFallbackURLString: String? = nil
    let width: CGFloat
    let height: CGFloat
    var maximumWidth: CGFloat? = nil
    var preloadMaximumWidth: CGFloat? = nil
    var minimumSwapDelay: TimeInterval = 0
    var onPreloadFinished: (Bool) -> Void = { _ in }
    var onArtworkLoaded: (String?) -> Void = { _ in }
    @ViewBuilder let placeholder: Placeholder

    init(
        urlString: String?,
        preloadURLString: String? = nil,
        fallbackURLString: String? = nil,
        preloadFallbackURLString: String? = nil,
        width: CGFloat,
        height: CGFloat,
        maximumWidth: CGFloat? = nil,
        preloadMaximumWidth: CGFloat? = nil,
        minimumSwapDelay: TimeInterval = 0,
        onPreloadFinished: @escaping (Bool) -> Void = { _ in },
        onArtworkLoaded: @escaping (String?) -> Void = { _ in },
        @ViewBuilder placeholder: () -> Placeholder
    ) {
        self.urlString = urlString
        self.preloadURLString = preloadURLString
        self.fallbackURLString = fallbackURLString
        self.preloadFallbackURLString = preloadFallbackURLString
        self.width = width
        self.height = height
        self.maximumWidth = maximumWidth
        self.preloadMaximumWidth = preloadMaximumWidth
        self.minimumSwapDelay = minimumSwapDelay
        self.onPreloadFinished = onPreloadFinished
        self.onArtworkLoaded = onArtworkLoaded
        self.placeholder = placeholder()
    }

    private struct CardArtworkState {
        var image: UIImage?
        var loadedKey: String?
        var loadedSourceURL: String?
        var previousImage: UIImage?
        var previousLoadedKey: String?
        var previousLoadedSourceURL: String?
        var preloadedImage: UIImage?
        var preloadedKey: String?
        var preloadedSourceURL: String?
    }

    @State private var state = CardArtworkState()

    private var maxPixelSize: Int {
        let displayScale = UIScreen.main.scale
        let targetMaxWidth = maximumWidth ?? width
        return max(160, Int(ceil(max(targetMaxWidth, height) * displayScale)))
    }

    private var preloadMaxPixelSize: Int {
        let displayScale = UIScreen.main.scale
        let targetMaxWidth = preloadMaximumWidth ?? maximumWidth ?? width
        return max(160, Int(ceil(max(targetMaxWidth, height) * displayScale)))
    }

    private var cacheKey: String {
        "\(urlString ?? "")#fallback:\(fallbackURLString ?? "")#\(maxPixelSize)"
    }

    private var preloadCacheKey: String {
        "\(preloadURLString ?? "")#fallback:\(preloadFallbackURLString ?? "")#\(preloadMaxPixelSize)"
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
        if state.loadedKey == cacheKey { return state.image }
        if state.preloadedKey == cacheKey { return state.preloadedImage }
        if state.previousLoadedKey == cacheKey { return state.previousImage }

        // While a brand-new variant is loading, keep real artwork on screen.
        // For landscape expansion this naturally starts with a zoomed poster;
        // for collapse the matching portrait is normally `previousImage`.
        return state.image ?? state.previousImage
    }

    @MainActor
    private func load() async {
        guard !Task.isCancelled else { return }
        guard urlString != nil || fallbackURLString != nil else {
            state.image = nil
            state.loadedKey = nil
            state.loadedSourceURL = nil
            state.previousImage = nil
            state.previousLoadedKey = nil
            state.previousLoadedSourceURL = nil
            onArtworkLoaded(nil)
            return
        }

        let key = cacheKey
        let traceLoad = preloadURLString != nil
        let started = TVHomeDebugTrace.now()
        let logHost = (urlString ?? fallbackURLString).flatMap(URL.init(string:))?.host ?? "unknown"
        if traceLoad { TVHomeDebugTrace.log("art.load.begin host=\(logHost) key=\(key)") }
        let loadStartedAt = Date()
        if state.loadedKey == key {
            onArtworkLoaded(state.loadedSourceURL)
            return
        }

        if state.preloadedKey == key, let preloadedImage = state.preloadedImage {
            state.previousImage = state.image
            state.previousLoadedKey = state.loadedKey
            state.previousLoadedSourceURL = state.loadedSourceURL
            state.image = preloadedImage
            state.loadedKey = key
            state.loadedSourceURL = state.preloadedSourceURL
            onArtworkLoaded(state.loadedSourceURL)
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
        if state.previousLoadedKey == key, let previousImage = state.previousImage {
            state.image = previousImage
            state.loadedKey = key
            state.loadedSourceURL = state.previousLoadedSourceURL
            state.previousImage = nil
            state.previousLoadedKey = nil
            state.previousLoadedSourceURL = nil
            onArtworkLoaded(state.loadedSourceURL)
            if traceLoad {
                TVHomeDebugTrace.log(
                    "art.load.end source=previous ms=\(TVHomeDebugTrace.elapsedMilliseconds(since: started))"
                )
            }
            return
        }

        if let loaded = await cachedImage(
            primaryURLString: urlString,
            fallbackURLString: fallbackURLString,
            maxPixelSize: maxPixelSize
        ) {
            let remainingDelay = minimumSwapDelay - Date().timeIntervalSince(loadStartedAt)
            if remainingDelay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(remainingDelay * 1_000_000_000))
            }
            guard !Task.isCancelled, key == cacheKey else { return }
            state.previousImage = state.image
            state.previousLoadedKey = state.loadedKey
            state.previousLoadedSourceURL = state.loadedSourceURL
            state.image = loaded.image
            state.loadedKey = key
            state.loadedSourceURL = loaded.urlString
            onArtworkLoaded(loaded.urlString)
        } else {
            guard !Task.isCancelled, key == cacheKey else { return }
            onArtworkLoaded(nil)
        }
        if traceLoad {
            TVHomeDebugTrace.log(
                "art.load.end source=cache ms=\(TVHomeDebugTrace.elapsedMilliseconds(since: started))"
            )
        }
    }

    @MainActor
    private func preload() async {
        guard !Task.isCancelled else { return }
        guard preloadURLString != nil || preloadFallbackURLString != nil else { return }

        let key = preloadCacheKey
        let started = TVHomeDebugTrace.now()
        let logHost = (preloadURLString ?? preloadFallbackURLString).flatMap(URL.init(string:))?.host ?? "unknown"
        TVHomeDebugTrace.log("art.preload.begin host=\(logHost) key=\(key)")
        if state.loadedKey == key, let image = state.image {
            state.preloadedImage = image
            state.preloadedKey = key
            state.preloadedSourceURL = state.loadedSourceURL
            onPreloadFinished(true)
            onArtworkLoaded(state.preloadedSourceURL)
            TVHomeDebugTrace.log(
                "art.preload.end source=loaded ms=\(TVHomeDebugTrace.elapsedMilliseconds(since: started))"
            )
            return
        }
        if state.preloadedKey == key, state.preloadedImage != nil {
            onPreloadFinished(true)
            onArtworkLoaded(state.preloadedSourceURL)
            TVHomeDebugTrace.log(
                "art.preload.end source=preloaded ms=\(TVHomeDebugTrace.elapsedMilliseconds(since: started))"
            )
            return
        }

        let loaded = await cachedImage(
            primaryURLString: preloadURLString,
            fallbackURLString: preloadFallbackURLString,
            maxPixelSize: preloadMaxPixelSize
        )
        guard !Task.isCancelled, key == preloadCacheKey else { return }
        if let loaded {
            state.preloadedImage = loaded.image
            state.preloadedKey = key
            state.preloadedSourceURL = loaded.urlString
        }
        onPreloadFinished(loaded != nil)
        onArtworkLoaded(loaded?.urlString)
        TVHomeDebugTrace.log(
            "art.preload.end source=cache hit=\(loaded != nil) "
                + "ms=\(TVHomeDebugTrace.elapsedMilliseconds(since: started))"
        )
    }

    @MainActor
    private func cachedImage(
        primaryURLString: String?,
        fallbackURLString: String?,
        maxPixelSize: Int
    ) async -> (image: UIImage, urlString: String)? {
        var attempted: Set<String> = []
        for rawURL in [primaryURLString, fallbackURLString].compactMap({ $0 }) {
            // A vanished card must not start another fallback download. Keep
            // any existing shared request available to its other consumers.
            guard !Task.isCancelled else { return nil }
            guard attempted.insert(rawURL).inserted,
                  let url = URL(string: rawURL),
                  let image = await PosterArtworkCache.shared.image(for: url, maxPixelSize: maxPixelSize) else {
                continue
            }
            guard !Task.isCancelled else { return nil }
            return (image, rawURL)
        }
        return nil
    }
}

actor PosterArtworkCache {
    static let shared = PosterArtworkCache()
    private static let tracker = NSCacheMemoryTracker(
        maxCost: {
            let gib = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
            if gib > 3.5 {
                return 140 * 1024 * 1024 // 140 MB (Apple TV 4K Gen 2/3)
            } else if gib > 2.5 {
                return 100 * 1024 * 1024 // 100 MB (Apple TV 4K Gen 1)
            } else {
                return 60 * 1024 * 1024  // 60 MB (Apple TV HD)
            }
        }()
    )

    static func telemetryMetrics() -> (count: Int, totalBytes: Int, maxCost: Int) {
        tracker.metrics()
    }

    private let cache = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    init() {
        let gib = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
        if gib > 3.5 {
            cache.countLimit = 220
            cache.totalCostLimit = Self.tracker.maxCost
        } else if gib > 2.5 {
            cache.countLimit = 160
            cache.totalCostLimit = Self.tracker.maxCost
        } else {
            cache.countLimit = 90
            cache.totalCostLimit = Self.tracker.maxCost
        }
        cache.delegate = Self.tracker
        #if canImport(UIKit)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { _ in
            Task {
                await PosterArtworkCache.shared.purge()
            }
        }
        #endif
    }

    func purge() {
        cache.removeAllObjects()
        Self.tracker.reset()
    }

    static func clearAllArtwork() async {
        await shared.purge()
        await PosterDiskCache.shared.clear()
        posterURLSession.configuration.urlCache?.removeAllCachedResponses()
        URLCache.shared.removeAllCachedResponses()
    }

    func updateMemoryCache(_ image: UIImage, forKey key: NSString) {
        let cost = image.decodedByteCost
        cache.setObject(image, forKey: key, cost: cost)
        Self.tracker.recordInsertion(cost: cost)
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

        let isVolatile = PosterArtworkCachePolicy.isVolatile(url)

        let task = Task.detached(priority: .utility) { () -> UIImage? in
            // Disk before network (Stale-While-Revalidate). The bytes are keyed by URL alone,
            // so one stored poster serves every size a card asks for.
            if let stored = await PosterDiskCache.shared.data(for: url),
               let image = await PosterDecodeLimiter.shared.image(
                   from: stored.data,
                   maxPixelSize: boundedPixelSize
               ) {
                // If it's a dynamic/volatile rating poster and the disk cache is stale (> 24h),
                // silently revalidate in the background to refresh rating badges without blocking UI.
                if isVolatile && !stored.isFresh {
                    Task.detached(priority: .background) {
                        guard let freshData = await downloadPosterData(url: url, revalidate: true) else { return }
                        await PosterDiskCache.shared.store(freshData, for: url)
                        if let freshImage = await PosterDecodeLimiter.shared.image(
                            from: freshData,
                            maxPixelSize: boundedPixelSize
                        ) {
                            await PosterArtworkCache.shared.updateMemoryCache(freshImage, forKey: key)
                        }
                    }
                }
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
            let cost = image.decodedByteCost
            cache.setObject(image, forKey: key, cost: cost)
            Self.tracker.recordInsertion(cost: cost)
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
actor PosterDiskCache {
    static let shared = PosterDiskCache()

    private let directory: URL
    private let maximumBytes = 200 * 1024 * 1024
    private let fileManager = FileManager.default
    /// Walking the directory on every write would cost more than the eviction
    /// saves, so the sweep runs once per batch of new artwork.
    private var bytesWrittenSinceTrim = 0
    private let trimInterval = 20 * 1024 * 1024
    static let freshnessTTL: TimeInterval = 24 * 60 * 60
    /// Refresh artwork cached by releases that treated generated poster bytes
    /// as immutable. Future freshness is governed by `freshnessTTL`.
    private static let storageVersion = "v2"

    init() {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        directory = caches.appendingPathComponent("poster_artwork", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func data(for url: URL) -> (data: Data, isFresh: Bool)? {
        let file = fileURL(for: url)
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else {
            return nil
        }
        guard let attributes = try? fileManager.attributesOfItem(atPath: file.path),
              let modified = attributes[.modificationDate] as? Date else {
            return (data, false)
        }
        let fresh = PosterDiskCacheFreshness.isFresh(modified: modified, now: Date(), ttl: Self.freshnessTTL)
        return (data, fresh)
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
        let digest = SHA256.hash(data: Data("\(Self.storageVersion):\(url.absoluteString)".utf8))
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

    func clear() {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }
        for file in files {
            try? fileManager.removeItem(at: file)
        }
        bytesWrittenSinceTrim = 0
    }
}

/// Pure freshness rule for deterministic boundary tests.
enum PosterDiskCacheFreshness {
    static func isFresh(modified: Date, now: Date, ttl: TimeInterval) -> Bool {
        let age = now.timeIntervalSince(modified)
        return age >= 0 && age <= ttl
    }
}

private let posterURLSession: URLSession = {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 10
    config.timeoutIntervalForResource = 20
    config.httpMaximumConnectionsPerHost = 10
    let totalRam = ProcessInfo.processInfo.physicalMemory
    let isLegacyDevice = totalRam <= 2_500_000_000 // <= 2.5 GB (Apple TV HD)
    config.urlCache = URLCache(
        memoryCapacity: isLegacyDevice ? (8 * 1024 * 1024) : (20 * 1024 * 1024),
        diskCapacity: isLegacyDevice ? (50 * 1024 * 1024) : (100 * 1024 * 1024),
        diskPath: "nuvio_poster_urlcache"
    )
    return URLSession(configuration: config)
}()

/// Matches what the Android loader gets from OkHttp's defaults: a 10s ceiling
/// instead of `URLSession`'s 60s, and a non-2xx response treated as a failure
/// instead of being handed to the decoder as if it were image bytes.
enum PosterArtworkCachePolicy {
    private static let volatileHosts = [
        "xperience-app.com", "btttr.cc", "ratingposterdb.com", "top-posters.com",
        "easyratingsdb.com", "extendedratings.com", "postersplus.elfhosted.com",
        "postersplus.cc", "slokker.cc", "stremio.ru"
    ]

    static func isVolatile(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return volatileHosts.contains { host == $0 || host.hasSuffix(".\($0)") }
    }
}

private func downloadPosterData(url: URL, revalidate: Bool = false) async -> Data? {
    let task = await PosterDataRequests.shared.request(url: url, revalidate: revalidate) {
        await fetchPosterData(url: url, revalidate: revalidate)
    }
    return await task.value
}

private func fetchPosterData(url: URL, revalidate: Bool) async -> Data? {
    var request = URLRequest(url: url)
    request.timeoutInterval = 10
    if revalidate { request.cachePolicy = .reloadIgnoringLocalCacheData }

    guard let (data, response) = try? await posterURLSession.data(for: request) else {
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
    guard CGImageSourceGetCount(source) > 0, CGImageSourceGetType(source) != nil else {
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

#endif

/// Deduplicates full-series metadata requests made by catalog badges. Catalog
/// previews usually omit `videos`, so completion cannot be decided until the
/// episode guide is available. Only series with watched episode rows reach this
/// cache, avoiding a request for every untouched poster on screen.
struct CatalogWatchedGuideResolution {
    let profileId: String?
    let titleIdentityKeys: Set<String>

    init(profileId: String?, meta: NuvioMeta) {
        self.profileId = profileId
        titleIdentityKeys = CatalogWatchedBadgeIdentity.titleIdentityKeys(for: meta)
    }
}

enum CatalogWatchedBadgeIdentity {
    static func titleIdentityKeys(for meta: NuvioMeta) -> Set<String> {
        var keys = WatchedStore.catalogTitleIdentityKeys(for: meta)
        guard let year = meta.year else { return keys }
        let title = WatchedStore.normalizedCatalogTitle(meta.name)
        guard !title.isEmpty else { return keys }
        keys.insert("title:\(meta.canonicalType.lowercased()):\(title):\(year)")
        return keys
    }
}

@MainActor
final class CatalogWatchedMetadataCache {
    static let shared = CatalogWatchedMetadataCache()
    static let fullSeriesGuideResolvedNotification = Notification.Name(
        "nuvio.tv.watched.fullSeriesGuideResolved"
    )
    nonisolated private static let tracker = SimpleCountTracker()

    nonisolated static func telemetryCount() -> Int {
        tracker.count
    }

    private let repository = CinemetaCatalogRepository()
    private var metadataByKey: [String: NuvioMeta] = [:]
    private var inFlightByKey: [String: Task<NuvioMeta?, Never>] = [:]
    private var notifiedGuideKeys: Set<String> = []
    private var decisionsByKey: [String: Int] = [:]
    private struct DecisionOwner {
        let profileId: String?
        let titleIdentityKeys: Set<String>
    }
    struct DecisionToken: Equatable {
        let globalGeneration: UInt64
        let keyGeneration: UInt64
    }
    private var decisionOwnersByKey: [String: DecisionOwner] = [:]
    private var decisionGenerationsByKey: [String: UInt64] = [:]
    private var generation: UInt64 = 0
    private var decisionGeneration: UInt64 = 0
    private let notificationCenter: NotificationCenter
    private var observers: [NSObjectProtocol] = []
    private let metadataFetcher: (@MainActor (String, String) async -> NuvioMeta?)?

    init(
        notificationCenter: NotificationCenter = .default,
        metadataFetcher: (@MainActor (String, String) async -> NuvioMeta?)? = nil
    ) {
        self.notificationCenter = notificationCenter
        self.metadataFetcher = metadataFetcher
        let watchedVisibilityNotifications = [
            WatchedStore.changedNotification,
            TraktSettingsStore.continueWatchingChangedNotification,
            TraktAuthStore.changedNotification,
            SimklAuthStore.changedNotification,
            MdbListAuthStore.changedNotification,
            WeTrakrAuthStore.changedNotification,
            TraktSettingsStore.libraryChangedNotification
        ]
        for name in watchedVisibilityNotifications {
            observers.append(notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.invalidateDecisions()
                }
            })
        }
        var purgeNotifications = [AppCacheManager.didClearCacheNotification]
        #if canImport(UIKit)
        purgeNotifications.append(UIApplication.didReceiveMemoryWarningNotification)
        #endif
        for name in purgeNotifications {
            observers.append(notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.purgeTransientValues()
                }
            })
        }
    }

    deinit {
        for observer in observers { notificationCenter.removeObserver(observer) }
    }

    /// Drop reconstructible badge data without changing watched history or
    /// cancelling a metadata request that a user action may still need.
    func purgeTransientValues() {
        generation &+= 1
        metadataByKey.removeAll()
        decisionsByKey.removeAll()
        decisionOwnersByKey.removeAll()
        decisionGenerationsByKey.removeAll()
        notifiedGuideKeys.removeAll()
        inFlightByKey.removeAll()
        Self.tracker.set(count: 0)
    }

    func cachedDecision(for key: String) -> Int? {
        decisionsByKey[key]
    }

    func setDecision(_ watchCount: Int, for key: String, ifGenerationMatches expectedGeneration: UInt64? = nil) {
        if let expectedGeneration, expectedGeneration != decisionGeneration { return }
        decisionsByKey[key] = max(0, watchCount)
        decisionOwnersByKey.removeValue(forKey: key)
    }

    func decisionGenerationToken() -> UInt64 {
        decisionGeneration
    }

    func decisionGenerationToken(for key: String) -> DecisionToken {
        DecisionToken(
            globalGeneration: decisionGeneration,
            keyGeneration: decisionGenerationsByKey[key, default: 0]
        )
    }

    func isCurrent(_ token: DecisionToken, for key: String) -> Bool {
        token.globalGeneration == decisionGeneration
            && token.keyGeneration == decisionGenerationsByKey[key, default: 0]
    }

    func setDecision(
        _ watchCount: Int,
        for key: String,
        ifTokenMatches token: DecisionToken,
        profileId: String?,
        titleIdentityKeys: Set<String>
    ) {
        guard isCurrent(token, for: key) else { return }
        decisionsByKey[key] = max(0, watchCount)
        decisionOwnersByKey[key] = DecisionOwner(
            profileId: profileId,
            titleIdentityKeys: titleIdentityKeys
        )
    }

    func invalidateDecisions(matching resolution: CatalogWatchedGuideResolution) {
        let matchingKeys = decisionOwnersByKey.compactMap { key, owner -> String? in
            guard owner.profileId == resolution.profileId,
                  !owner.titleIdentityKeys.isDisjoint(with: resolution.titleIdentityKeys) else { return nil }
            return key
        }
        for key in matchingKeys {
            decisionsByKey.removeValue(forKey: key)
            decisionOwnersByKey.removeValue(forKey: key)
            decisionGenerationsByKey[key, default: 0] &+= 1
        }
    }

    private func invalidateDecisions() {
        decisionGeneration &+= 1
        decisionsByKey.removeAll()
        decisionOwnersByKey.removeAll()
        decisionGenerationsByKey.removeAll()
    }

    func fullMetadata(metaId: String, type: String, preview: NuvioMeta?) async -> NuvioMeta? {
        let requestGeneration = generation
        let key = metadataKey(metaId: metaId, type: type)
        if let cached = metadataByKey[key] { return cached }
        if let inFlight = inFlightByKey[key] { return await inFlight.value }

        let task: Task<NuvioMeta?, Never> = Task(priority: .utility) {
            if let metadataFetcher {
                return await metadataFetcher(metaId, type) ?? preview
            }
            // Reuses memory/disk cached metadata instead of forcing full network downloads
            if let cached = try? await repository.getMetadata(id: metaId, type: type) {
                return cached
            }
            // Keep an already supplied guide as a useful offline fallback.
            return preview
        }
        inFlightByKey[key] = task
        let resolved = await task.value
        // An older completion must not repopulate a purged cache or remove
        // the replacement request registered under the same key.
        guard generation == requestGeneration else { return resolved }
        inFlightByKey[key] = nil
        if let resolved {
            metadataByKey[key] = resolved
            Self.tracker.set(count: metadataByKey.count)
        }
        return resolved
    }

    /// Library series actions must not treat a compact preview as a complete
    /// guide. If an earlier catalog badge cached that preview after an offline
    /// lookup, discard only the incomplete value and retry on the next menu use.
    func fullSeriesMetadata(metaId: String, type: String, preview: NuvioMeta?) async -> NuvioMeta? {
        let key = metadataKey(metaId: metaId, type: type)
        let profileId = WatchedStore.activeProfileId
        if let cached = metadataByKey[key], cached.isSeries, cached.videos?.isEmpty == false {
            notifyGuideResolutionIfNeeded(key: key, profileId: profileId, meta: cached)
            return cached
        }
        removeIncompleteGuideIfNeeded(for: key)

        let resolved = await fullMetadata(metaId: metaId, type: type, preview: preview)
        guard let resolved, resolved.isSeries, resolved.videos?.isEmpty == false else {
            removeIncompleteGuideIfNeeded(for: key)
            return nil
        }
        notifyGuideResolutionIfNeeded(key: key, profileId: profileId, meta: resolved)
        return resolved
    }

    private func notifyGuideResolutionIfNeeded(key: String, profileId: String?, meta: NuvioMeta) {
        guard notifiedGuideKeys.insert(key).inserted else { return }
        let resolution = CatalogWatchedGuideResolution(profileId: profileId, meta: meta)
        invalidateDecisions(matching: resolution)
        notificationCenter.post(name: Self.fullSeriesGuideResolvedNotification, object: resolution)
    }

    private func metadataKey(metaId: String, type: String) -> String {
        "\(WatchedStore.activeProfileId ?? "default")\u{1f}\(type.lowercased())\u{1f}\(metaId.lowercased())"
    }

    private func removeIncompleteGuideIfNeeded(for key: String) {
        guard let cached = metadataByKey[key], cached.videos?.isEmpty != false else { return }
        metadataByKey.removeValue(forKey: key)
        Self.tracker.set(count: metadataByKey.count)
    }
}

struct WatchedCheckmarkIcon: View {
    var size: CGFloat = 38
    var watchCount: Int = 1

    private var presentation: WatchedCheckmarkPresentation {
        WatchedCheckmarkPresentation(watchCount: watchCount)
    }

    var body: some View {
        Group {
            switch presentation.content {
            case .checkmark:
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.48, weight: .bold))
            case let .count(count):
                Text("\(count)")
                    .font(.system(size: size * 0.43, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.48)
                    .frame(width: size * 0.84, height: size)
            }
        }
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityHidden(watchCount <= 0)
    }
}

struct WatchedCheckmarkPresentation: Equatable {
    enum Content: Equatable {
        case checkmark
        case count(Int)
    }

    let content: Content

    init(watchCount: Int) {
        content = watchCount > 1 ? .count(watchCount) : .checkmark
    }

    var accessibilityLabel: String {
        switch content {
        case .checkmark:
            return L10n.string("watched_accessibility", fallback: "Watched")
        case let .count(count):
            return L10n.format(
                "watched_repeat_count_accessibility",
                fallback: "Watched %d times",
                count
            )
        }
    }
}

enum CatalogWatchedBadgeCountResolver {
    static func movieWatchCount(
        snapshot: WatchedSnapshot,
        metaId: String,
        type: String,
        resolvedMeta: NuvioMeta? = nil
    ) -> Int {
        let identityMeta = NuvioMeta(id: metaId, name: "", type: type)
        guard let resolvedMeta else {
            return snapshot.watchCount(meta: identityMeta)
        }
        return snapshot.watchCount(meta: resolvedMeta, additionalMeta: identityMeta)
    }
}

struct WatchedCheckmarkBadge: View {
    let metaId: String
    let type: String
    let meta: NuvioMeta?
    var libraryWatchedContext: LibraryWatchedContext? = nil
    var isLibraryContextCurrent = true
    var size: CGFloat = 38

    @State private var watchCount = 0
    @State private var refreshVersion = 0
    @Environment(\.isEnabled) private var isEnabled

    init(metaId: String, type: String, size: CGFloat = 38) {
        self.metaId = metaId
        self.type = type
        self.meta = nil
        self.libraryWatchedContext = nil
        self.size = size
    }

    init(
        meta: NuvioMeta,
        libraryWatchedContext: LibraryWatchedContext? = nil,
        isLibraryContextCurrent: Bool = true,
        size: CGFloat = 38
    ) {
        self.metaId = meta.id
        self.type = meta.type
        self.meta = meta
        self.libraryWatchedContext = libraryWatchedContext
        self.isLibraryContextCurrent = isLibraryContextCurrent
        self.size = size
    }

    var body: some View {
        // Keep the badge mounted while unwatched. Search remains alive behind
        // the Details overlay, and an EmptyView branch can miss the store
        // notification that should reveal or update the count when Details closes.
        WatchedCheckmarkIcon(size: size, watchCount: watchCount)
            .opacity(watchCount > 0 ? 1 : 0)
            .accessibilityHidden(watchCount <= 0)
            .task(id: refreshTaskIdentity) {
                await refresh()
            }
            .onReceive(NotificationCenter.default.publisher(for: WatchedStore.changedNotification).receive(on: RunLoop.main)) { _ in
                // Re-key the SwiftUI task instead of starting an untracked Task.
                // Store sync and view recreation can otherwise overlap refreshes,
                // allowing an older result to overwrite a newer watched state.
                refreshVersion &+= 1
            }
            .onReceive(NotificationCenter.default.publisher(for: TraktAuthStore.changedNotification).receive(on: RunLoop.main)) { _ in
                refreshVersion &+= 1
            }
            .onReceive(NotificationCenter.default.publisher(for: SimklAuthStore.changedNotification).receive(on: RunLoop.main)) { _ in
                refreshVersion &+= 1
            }
            .onReceive(NotificationCenter.default.publisher(for: MdbListAuthStore.changedNotification).receive(on: RunLoop.main)) { _ in
                refreshVersion &+= 1
            }
            .onReceive(NotificationCenter.default.publisher(for: WeTrakrAuthStore.changedNotification).receive(on: RunLoop.main)) { _ in
                refreshVersion &+= 1
            }
            .onReceive(NotificationCenter.default.publisher(for: TraktSettingsStore.continueWatchingChangedNotification).receive(on: RunLoop.main)) { _ in
                refreshVersion &+= 1
            }
            .onReceive(NotificationCenter.default.publisher(for: TraktSettingsStore.libraryChangedNotification).receive(on: RunLoop.main)) { _ in
                refreshVersion &+= 1
            }
            .onReceive(NotificationCenter.default.publisher(for: CatalogWatchedMetadataCache.fullSeriesGuideResolvedNotification).receive(on: RunLoop.main)) { notification in
                guard let resolution = notification.object as? CatalogWatchedGuideResolution else { return }
                let badgeProfileId: String?
                if let libraryWatchedContext {
                    badgeProfileId = libraryWatchedContext.profileId
                } else {
                    badgeProfileId = WatchedStore.activeProfileId
                }
                guard badgeProfileId == resolution.profileId else { return }
                let badgeMeta = meta ?? NuvioMeta(id: metaId, name: "", type: type)
                let badgeKeys = CatalogWatchedBadgeIdentity.titleIdentityKeys(for: badgeMeta)
                guard !badgeKeys.isDisjoint(with: resolution.titleIdentityKeys) else { return }
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
        let profile: String
        if let libraryWatchedContext {
            profile = libraryWatchedContext.profileId ?? "legacy"
        } else {
            profile = WatchedStore.activeProfileId ?? "default"
        }
        let scope = libraryWatchedContext?.source.rawValue ?? "global"
        return "\(scope)\u{1f}\(profile)\u{1f}\(type.lowercased())\u{1f}\(metaId)\u{1f}\(imdb)\u{1f}\(tmdb)"
    }

    private var refreshTaskIdentity: String {
        "\(refreshIdentity)\u{1f}\(refreshVersion)\u{1f}\(isEnabled)\u{1f}\(isLibraryContextCurrent)"
    }

    @MainActor
    private func refresh() async {
        let decisionCache = CatalogWatchedMetadataCache.shared
        let decisionGeneration = decisionCache.decisionGenerationToken(for: refreshIdentity)
        if let cached = decisionCache.cachedDecision(for: refreshIdentity) {
            watchCount = cached
            return
        }

        if let libraryWatchedContext {
            await refreshLibraryScopedWatchedState(
                using: libraryWatchedContext,
                decisionCache: decisionCache,
                decisionGeneration: decisionGeneration
            )
            return
        }

        let snapshot = WatchedStore.currentSnapshot()
        let isSeries = meta?.isSeries ?? NuvioMeta.isSeriesType(type)
        let titleWasWatched = meta.map { snapshot.containsCatalogTitle(meta: $0) }
            ?? snapshot.contains(metaId: metaId, type: type)

        guard isSeries else {
            if let meta {
                let result = snapshot.watchCount(meta: meta)
                watchCount = result
                cacheDecision(result, in: decisionCache, token: decisionGeneration, resolvedMeta: meta)
                return
            }

            let knownCount = CatalogWatchedBadgeCountResolver.movieWatchCount(
                snapshot: snapshot,
                metaId: metaId,
                type: type
            )
            watchCount = knownCount

            guard titleWasWatched || knownCount > 0 else {
                watchCount = 0
                cacheDecision(0, in: decisionCache, token: decisionGeneration)
                return
            }

            let fullMeta = await decisionCache.fullMetadata(
                metaId: metaId,
                type: type,
                preview: nil
            )
            guard !Task.isCancelled, decisionCache.isCurrent(decisionGeneration, for: refreshIdentity) else { return }

            let result: Int
            if let fullMeta {
                let freshSnapshot = WatchedStore.currentSnapshot()
                let resolvedCount = CatalogWatchedBadgeCountResolver.movieWatchCount(
                    snapshot: freshSnapshot,
                    metaId: metaId,
                    type: type,
                    resolvedMeta: fullMeta
                )
                result = max(resolvedCount, titleWasWatched ? 1 : 0)
            } else {
                result = max(knownCount, titleWasWatched ? 1 : 0)
            }
            watchCount = result
            cacheDecision(result, in: decisionCache, token: decisionGeneration, resolvedMeta: fullMeta)
            return
        }

        // A whole-title marker is a legacy one-watch fallback, but episode
        // counts can represent a higher completed-season repeat count. Resolve
        // the guide before caching the fallback whenever episode history exists.
        let previewEpisodeCounts = meta.map { snapshot.catalogEpisodeWatchCounts(meta: $0) } ?? [:]
        let hasEpisodeHistory = !previewEpisodeCounts.isEmpty
            || !snapshot.watchedEpisodeKeys(metaId: metaId).isEmpty
        let previewCount = meta.map { snapshot.catalogWatchCount(meta: $0) } ?? 0

        guard hasEpisodeHistory else {
            let result = max(previewCount, titleWasWatched ? 1 : 0)
            watchCount = result
            cacheDecision(result, in: decisionCache, token: decisionGeneration, resolvedMeta: meta)
            return
        }

        let suppliedGuide = meta?.videos?.isEmpty == false
        let fullMeta: NuvioMeta?
        if suppliedGuide {
            fullMeta = meta
        } else {
            fullMeta = await decisionCache.fullMetadata(
                metaId: metaId,
                type: type,
                preview: meta
            )
        }
        guard !Task.isCancelled, decisionCache.isCurrent(decisionGeneration, for: refreshIdentity) else { return }

        let freshSnapshot = WatchedStore.currentSnapshot()
        let resolvedCount: Int
        if let fullMeta, fullMeta.videos?.isEmpty == false {
            resolvedCount = freshSnapshot.catalogWatchCount(meta: fullMeta)
        } else if let meta {
            // Preserve a model-derived count if metadata is unavailable; an
            // explicit title watch still supplies the legacy checkmark.
            resolvedCount = snapshot.catalogWatchCount(meta: meta)
        } else {
            resolvedCount = 0
        }
        let hasTitleMarker = (fullMeta.map { freshSnapshot.containsCatalogTitle(meta: $0) } ?? false)
            || titleWasWatched
        let result = max(resolvedCount, hasTitleMarker ? 1 : 0)
        watchCount = result
        cacheDecision(result, in: decisionCache, token: decisionGeneration, resolvedMeta: fullMeta ?? meta)
    }

    @MainActor
    private func refreshLibraryScopedWatchedState(
        using context: LibraryWatchedContext,
        decisionCache: CatalogWatchedMetadataCache,
        decisionGeneration: CatalogWatchedMetadataCache.DecisionToken
    ) async {
        watchCount = 0
        guard isLibraryContextCurrent else { return }
        var resolvedMeta = meta
        let initialSnapshot = WatchedStore.librarySnapshot(for: context.source, profileId: context.profileId)
        let isSeries = meta?.isSeries ?? NuvioMeta.isSeriesType(type)
        let titleWasWatched = meta.map { initialSnapshot.containsCatalogTitle(meta: $0) }
            ?? initialSnapshot.contains(metaId: metaId, type: type)

        guard isSeries else {
            let result = CatalogWatchedBadgeCountResolver.movieWatchCount(
                snapshot: initialSnapshot,
                metaId: metaId,
                type: type,
                resolvedMeta: meta
            )
            watchCount = result
            cacheDecision(result, in: decisionCache, token: decisionGeneration, resolvedMeta: meta)
            return
        }

        let episodeHistory = meta.map { initialSnapshot.catalogEpisodeWatchCounts(meta: $0) } ?? [:]
        let hasEpisodeHistory = !episodeHistory.isEmpty
            || !(meta.map { initialSnapshot.catalogWatchedEpisodeKeys(meta: $0) }
                ?? initialSnapshot.watchedEpisodeKeys(metaId: metaId)).isEmpty
        guard hasEpisodeHistory else {
            let result = max(meta.map { initialSnapshot.catalogWatchCount(meta: $0) } ?? 0, titleWasWatched ? 1 : 0)
            watchCount = result
            cacheDecision(result, in: decisionCache, token: decisionGeneration, resolvedMeta: meta)
            return
        }

        if resolvedMeta?.videos?.isEmpty != false {
            resolvedMeta = await decisionCache.fullMetadata(metaId: metaId, type: type, preview: meta)
        }
        guard !Task.isCancelled,
              isLibraryContextCurrent,
              decisionCache.isCurrent(decisionGeneration, for: refreshIdentity) else { return }

        guard resolvedMeta?.videos?.isEmpty == false else {
            // Episode completion cannot be determined from a compact preview.
            // Leave this decision uncached so a later full-guide resolution can
            // trigger a fresh badge query.
            watchCount = titleWasWatched ? 1 : 0
            return
        }

        let freshSnapshot = WatchedStore.librarySnapshot(for: context.source, profileId: context.profileId)
        let resolvedCount: Int
        if let resolvedMeta {
            resolvedCount = freshSnapshot.catalogWatchCount(meta: resolvedMeta)
        } else {
            resolvedCount = 0
        }
        let hasTitleMarker = (resolvedMeta.map { freshSnapshot.containsCatalogTitle(meta: $0) } ?? false)
            || titleWasWatched
        let result = max(resolvedCount, hasTitleMarker ? 1 : 0)
        watchCount = result
        cacheDecision(result, in: decisionCache, token: decisionGeneration, resolvedMeta: resolvedMeta)
    }

    private func cacheDecision(
        _ result: Int,
        in cache: CatalogWatchedMetadataCache,
        token: CatalogWatchedMetadataCache.DecisionToken,
        resolvedMeta: NuvioMeta? = nil
    ) {
        let identityMeta = meta ?? NuvioMeta(id: metaId, name: "", type: type)
        var identityKeys = CatalogWatchedBadgeIdentity.titleIdentityKeys(for: identityMeta)
        if let resolvedMeta {
            identityKeys.formUnion(CatalogWatchedBadgeIdentity.titleIdentityKeys(for: resolvedMeta))
        }
        let profileId: String?
        if let libraryWatchedContext {
            profileId = libraryWatchedContext.profileId
        } else {
            profileId = WatchedStore.activeProfileId
        }
        cache.setDecision(
            result,
            for: refreshIdentity,
            ifTokenMatches: token,
            profileId: profileId,
            titleIdentityKeys: identityKeys
        )
    }
}

/// Custom button style for poster cards
struct PosterCardButtonStyle: ButtonStyle {
    var onNativeFocusChange: ((Bool) -> Void)? = nil

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            #if os(tvOS)
            .background {
                if let onNativeFocusChange {
                    TVNativeFocusObserver(onFocusChange: onNativeFocusChange)
                }
            }
            #endif
            #if os(tvOS)
            .scaleEffect(configuration.isPressed ? 0.985 : 1.0)
            #else
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            #endif
            .animation(.easeInOut(duration: 0.2), value: configuration.isPressed)
    }
}

#if os(tvOS)
/// Observe the focus environment inside a focused surface's descendants.
/// Unlike a FocusState write, this reports focus granted by the native engine.
struct TVNativeFocusObserver: View {
    @Environment(\.isFocused) private var isFocused
    @State private var reportedFocus = false
    let onFocusChange: (Bool) -> Void

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear {
                if isFocused {
                    reportedFocus = true
                    onFocusChange(true)
                }
            }
            .onChange(of: isFocused) { _, focused in
                reportedFocus = focused
                onFocusChange(focused)
            }
            .onDisappear {
                if reportedFocus { onFocusChange(false) }
            }
    }
}

extension View {
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

enum LibraryWatchedMenuStatePolicy {
    static func resolvedState(
        _ state: Bool?,
        identity: String?,
        currentIdentity: String
    ) -> Bool? {
        guard identity == currentIdentity else { return nil }
        return state
    }

    static func isGuideResolutionPending(
        isSeries: Bool,
        hasFullGuide: Bool,
        resolvedIdentity: String?,
        currentIdentity: String
    ) -> Bool {
        isSeries && !hasFullGuide && resolvedIdentity != currentIdentity
    }
}

enum WatchedMenuIntentPolicy {
    static func needsMutation(currentlyWatched: Bool, desiredIsWatched: Bool) -> Bool {
        currentlyWatched != desiredIsWatched
    }
}

/// Native tvOS/iOS context menu for titles (Go to details / Add to library / Mark as watched / Continue watching actions)
struct TitleActionsMenuContent: View {
    let meta: NuvioMeta
    var libraryWatchedContext: LibraryWatchedContext? = nil
    var onOpenLibraryDetails: ((LibraryWatchedContext) -> Void)? = nil
    var onOpenDetails: (() -> Void)? = nil
    var continueProgress: Double? = nil
    var continueIsUpNext: Bool = false
    var onPlayManually: (() -> Void)? = nil
    var onStartFromBeginning: (() -> Void)? = nil
    var onRemoveFromContinueWatching: (() -> Void)? = nil
    var onRefreshCatalog: (() -> Void)? = nil
    @State private var libraryWatchedState: Bool?
    @State private var resolvedLibraryWatchedTaskIdentity: String?
    @State private var libraryWatchedRefreshVersion = 0

    var body: some View {
        contextMenuContent
            .task(id: libraryWatchedTaskIdentity) {
                await refreshLibraryWatchedState()
            }
            .onReceive(NotificationCenter.default.publisher(for: WatchedStore.changedNotification).receive(on: RunLoop.main)) { _ in
                libraryWatchedRefreshVersion &+= 1
            }
            .onReceive(NotificationCenter.default.publisher(for: TraktSettingsStore.libraryChangedNotification).receive(on: RunLoop.main)) { _ in
                libraryWatchedRefreshVersion &+= 1
            }
            .onReceive(NotificationCenter.default.publisher(for: TraktAuthStore.changedNotification).receive(on: RunLoop.main)) { _ in
                libraryWatchedRefreshVersion &+= 1
            }
            .onReceive(NotificationCenter.default.publisher(for: SimklAuthStore.changedNotification).receive(on: RunLoop.main)) { _ in
                libraryWatchedRefreshVersion &+= 1
            }
            .onReceive(NotificationCenter.default.publisher(for: MdbListAuthStore.changedNotification).receive(on: RunLoop.main)) { _ in
                libraryWatchedRefreshVersion &+= 1
            }
            .onReceive(NotificationCenter.default.publisher(for: WeTrakrAuthStore.changedNotification).receive(on: RunLoop.main)) { _ in
                libraryWatchedRefreshVersion &+= 1
            }
    }

    private var isLibraryWatched: Bool {
        guard let libraryWatchedContext else { return false }
        if let resolved = LibraryWatchedMenuStatePolicy.resolvedState(
            libraryWatchedState,
            identity: resolvedLibraryWatchedTaskIdentity,
            currentIdentity: libraryWatchedTaskIdentity
        ) {
            return resolved
        }
        return WatchedStore.isWatchedForLibrary(
            meta: meta,
            source: libraryWatchedContext.source,
            profileId: libraryWatchedContext.profileId
        )
    }

    private var isLibraryWatchedResolutionPending: Bool {
        guard let libraryWatchedContext else { return false }
        guard libraryWatchedContext.isCurrentScope,
              libraryWatchedContext.isCurrent else { return true }
        return LibraryWatchedMenuStatePolicy.isGuideResolutionPending(
            isSeries: meta.isSeries,
            hasFullGuide: meta.videos?.isEmpty == false,
            resolvedIdentity: resolvedLibraryWatchedTaskIdentity,
            currentIdentity: libraryWatchedTaskIdentity
        )
    }

    private var libraryWatchedTaskIdentity: String {
        "\(libraryWatchedContext?.cacheIdentity ?? "global")\u{1f}\(meta.id)\u{1f}\(meta.type)\u{1f}\(libraryWatchedRefreshVersion)"
    }

    private func scheduleOpenDetails() {
        if let libraryWatchedContext, let onOpenLibraryDetails {
            guard let capturedContext = libraryWatchedContext.recaptureForCurrentAction() else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
                onOpenLibraryDetails(capturedContext)
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
                onOpenDetails?()
            }
        }
    }

    @MainActor
    private func refreshLibraryWatchedState() async {
        libraryWatchedState = nil
        resolvedLibraryWatchedTaskIdentity = nil
        guard let context = libraryWatchedContext else {
            return
        }
        var resolvedMeta = meta
        if meta.isSeries, meta.videos?.isEmpty != false {
            guard let fullSeriesMeta = await CatalogWatchedMetadataCache.shared.fullSeriesMetadata(
                metaId: meta.id,
                type: meta.type,
                preview: meta
            ) else { return }
            resolvedMeta = fullSeriesMeta
        }
        guard !Task.isCancelled, context.isCurrentScope else { return }
        libraryWatchedState = WatchedStore.isWatchedForLibrary(
            meta: resolvedMeta,
            source: context.source,
            profileId: context.profileId
        )
        resolvedLibraryWatchedTaskIdentity = libraryWatchedTaskIdentity
    }

    @ViewBuilder
    private var contextMenuContent: some View {
        if continueProgress != nil || continueIsUpNext {
            Button {
                scheduleOpenDetails()
            } label: {
                Label(L10n.string("action_go_to_details", fallback: "Go to details"), systemImage: "info.circle")
            }

            if let onPlayManually {
                Button {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
                        onPlayManually()
                    }
                } label: {
                    Label(L10n.string("action_play_manually", fallback: "Play manually"), systemImage: "play.fill")
                }
            }

            if let onStartFromBeginning, !continueIsUpNext {
                Button {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
                        onStartFromBeginning()
                    }
                } label: {
                    Label(L10n.string("action_start_from_beginning", fallback: "Start from beginning"), systemImage: "arrow.counterclockwise")
                }
            }

            if let onRemoveFromContinueWatching {
                Button(role: .destructive) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
                        onRemoveFromContinueWatching()
                    }
                } label: {
                    Label(L10n.string("action_remove", fallback: "Remove"), systemImage: "trash")
                }
            }
        } else {
            let inLibrary = LibraryStore.contains(metaId: meta.id, type: meta.type)
            let isItemWatched = libraryWatchedContext == nil
                ? WatchedStore.contains(meta: meta)
                : isLibraryWatched

            Button {
                scheduleOpenDetails()
            } label: {
                Label(L10n.string("action_go_to_details", fallback: "Go to details"), systemImage: "info.circle")
            }

            Button {
                scheduleWatchedToggle(desiredIsWatched: !isItemWatched)
            } label: {
                Label(
                    isItemWatched
                        ? L10n.string("details_mark_as_unwatched", fallback: "Mark as unwatched")
                        : L10n.string("details_mark_as_watched", fallback: "Mark as watched"),
                    systemImage: isItemWatched ? "eye.slash" : "eye"
                )
            }
            .disabled(isLibraryWatchedResolutionPending)

            if let onRefreshCatalog {
                Button {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
                        onRefreshCatalog()
                    }
                } label: {
                    Label(L10n.string("action_refresh_catalog", fallback: "Refresh Catalog"), systemImage: "arrow.clockwise")
                }
            }

            if inLibrary {
                Button(role: .destructive) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
                        toggleLibrary(currentlyInLibrary: true)
                    }
                } label: {
                    Label(L10n.string("action_remove", fallback: "Remove"), systemImage: "trash")
                }
            } else {
                Button {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
                        toggleLibrary(currentlyInLibrary: false)
                    }
                } label: {
                    Label(L10n.string("action_add_to_library", fallback: "Add to library"), systemImage: "plus")
                }
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

    private func scheduleWatchedToggle(desiredIsWatched: Bool) {
        let capturedContext = libraryWatchedContext?.recaptureForCurrentAction()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
            guard libraryWatchedContext != nil else {
                setGlobalWatched(to: desiredIsWatched)
                return
            }
            guard let capturedContext else { return }
            Task { @MainActor in
                var resolvedMeta = meta
                if meta.isSeries, meta.videos?.isEmpty != false {
                    guard let fullSeriesMeta = await CatalogWatchedMetadataCache.shared.fullSeriesMetadata(
                        metaId: meta.id,
                        type: meta.type,
                        preview: meta
                    ) else { return }
                    resolvedMeta = fullSeriesMeta
                }
                guard !Task.isCancelled, capturedContext.isCurrent else { return }
                guard !meta.isSeries || resolvedMeta.videos?.isEmpty == false else { return }
                _ = capturedContext.setWatchedUsingCapturedAction(
                    resolvedMeta,
                    isWatched: desiredIsWatched
                )
            }
        }
    }

    private func setGlobalWatched(to desiredIsWatched: Bool) {
        let isSeries = ["series", "tv", "show", "tvshow"].contains(meta.type.lowercased())
        guard isSeries else {
            let currentlyWatched = WatchedStore.contains(meta: meta)
            guard WatchedMenuIntentPolicy.needsMutation(
                currentlyWatched: currentlyWatched,
                desiredIsWatched: desiredIsWatched
            ) else { return }
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
            let currentlyWatched = WatchedStore.isWatchedForDisplay(meta: fullMeta)
            guard WatchedMenuIntentPolicy.needsMutation(
                currentlyWatched: currentlyWatched,
                desiredIsWatched: desiredIsWatched
            ) else { return }
            _ = WatchedStore.toggle(meta: fullMeta)
        }
    }
}

struct TitleActionsContextMenu: ViewModifier {
    let meta: NuvioMeta
    var libraryWatchedContext: LibraryWatchedContext? = nil
    var onOpenLibraryDetails: ((LibraryWatchedContext) -> Void)? = nil
    var isEnabled = true
    var onOpenDetails: (() -> Void)? = nil
    var continueProgress: Double? = nil
    var continueIsUpNext: Bool = false
    var onPlayManually: (() -> Void)? = nil
    var onStartFromBeginning: (() -> Void)? = nil
    var onRemoveFromContinueWatching: (() -> Void)? = nil
    var onRefreshCatalog: (() -> Void)? = nil

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content
                .contextMenu {
                    TitleActionsMenuContent(
                        meta: meta,
                        libraryWatchedContext: libraryWatchedContext,
                        onOpenLibraryDetails: onOpenLibraryDetails,
                        onOpenDetails: onOpenDetails,
                        continueProgress: continueProgress,
                        continueIsUpNext: continueIsUpNext,
                        onPlayManually: onPlayManually,
                        onStartFromBeginning: onStartFromBeginning,
                        onRemoveFromContinueWatching: onRemoveFromContinueWatching,
                        onRefreshCatalog: onRefreshCatalog
                    )
                }
        } else {
            content
        }
    }
}

extension View {
    func titleActionsContextMenu(
        meta: NuvioMeta,
        libraryWatchedContext: LibraryWatchedContext? = nil,
        onOpenLibraryDetails: ((LibraryWatchedContext) -> Void)? = nil,
        onOpenDetails: (() -> Void)? = nil,
        continueProgress: Double? = nil,
        continueIsUpNext: Bool = false,
        onPlayManually: (() -> Void)? = nil,
        onStartFromBeginning: (() -> Void)? = nil,
        onRemoveFromContinueWatching: (() -> Void)? = nil,
        onRefreshCatalog: (() -> Void)? = nil,
        isEnabled: Bool = true
    ) -> some View {
        modifier(
            TitleActionsContextMenu(
                meta: meta,
                libraryWatchedContext: libraryWatchedContext,
                onOpenLibraryDetails: onOpenLibraryDetails,
                isEnabled: isEnabled,
                onOpenDetails: onOpenDetails,
                continueProgress: continueProgress,
                continueIsUpNext: continueIsUpNext,
                onPlayManually: onPlayManually,
                onStartFromBeginning: onStartFromBeginning,
                onRemoveFromContinueWatching: onRemoveFromContinueWatching,
                onRefreshCatalog: onRefreshCatalog
            )
        )
    }
}
