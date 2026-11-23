import SwiftUI

/// The settings every poster card reads, read once for the whole app instead of by each card.
///
/// A card used to hold its own `@AppStorage` for each of these, so every card that came on
/// screen while a row scrolled set up a dozen settings observers of its own. ContentView now
/// reads them once (against the active profile's settings) and hands them down; a change in
/// Settings still reaches every card at once.
struct CardAppearance: Equatable {
    var customPosterURLPattern = ""
    var customPosterEnabledScreens = "all"
    var trailersEnabled = true
    var trailerDelay = 7
    var cardCornerRadius = AppCardStyle.defaultCornerRadiusRaw
    var liquidGlassCards = true
    var posterLabels = false
    var smoothFocus = true
    var focusHighlighter = false
    var amoled = false
    var amoledSurfaces = false
    var focusedPosterBackdropEnabled = true
    var continueWatchingLabels = CardLabelVisibility.always.rawValue
    var continueWatchingBlurNextUp = false
    var blurUnwatchedEpisodes = false
    var hideUnwatchedEpisodeTitles = false
    var hideUnwatchedEpisodeDescriptions = false
    var landscapeAlwaysBackdropLogo = false
    var trailerStartSeconds = 0
    var animatedArtworkOnFocus = false
    var cardDepth = CardDepthStyle()

    /// The values saved in `defaults`, for views outside ContentView's tree.
    static func stored(in defaults: UserDefaults) -> CardAppearance {
        var appearance = CardAppearance()
        if let value = defaults.string(forKey: SettingsKey.customPosterURLPattern) { appearance.customPosterURLPattern = value }
        if let value = defaults.string(forKey: SettingsKey.customPosterEnabledScreens) { appearance.customPosterEnabledScreens = value }
        appearance.customPosterEnabledScreens = CustomPosterScreen.effectiveStorageValue(
            stored: appearance.customPosterEnabledScreens,
            pattern: appearance.customPosterURLPattern,
            chosenHere: defaults.bool(forKey: SettingsKey.customPosterScreensChosenHere)
        )
        if let value = defaults.object(forKey: SettingsKey.trailersEnabled) as? Bool { appearance.trailersEnabled = value }
        if let value = defaults.object(forKey: SettingsKey.trailerDelay) as? Int { appearance.trailerDelay = value }
        if let value = defaults.string(forKey: SettingsKey.cardCornerRadius) { appearance.cardCornerRadius = value }
        if let value = defaults.object(forKey: SettingsKey.liquidGlassCards) as? Bool { appearance.liquidGlassCards = value }
        if let value = defaults.object(forKey: SettingsKey.posterLabels) as? Bool { appearance.posterLabels = value }
        if let value = defaults.object(forKey: SettingsKey.smoothFocus) as? Bool { appearance.smoothFocus = value }
        if let value = defaults.object(forKey: SettingsKey.focusHighlighter) as? Bool { appearance.focusHighlighter = value }
        if let value = defaults.object(forKey: SettingsKey.amoled) as? Bool { appearance.amoled = value }
        if let value = defaults.object(forKey: SettingsKey.amoledSurfaces) as? Bool { appearance.amoledSurfaces = value }
        if let value = defaults.object(forKey: SettingsKey.focusedPosterBackdropEnabled) as? Bool { appearance.focusedPosterBackdropEnabled = value }
        if let value = defaults.string(forKey: SettingsKey.continueWatchingLabels) { appearance.continueWatchingLabels = value }
        if let value = defaults.object(forKey: SettingsKey.continueWatchingBlurNextUp) as? Bool { appearance.continueWatchingBlurNextUp = value }
        if let value = defaults.object(forKey: SettingsKey.blurUnwatchedEpisodes) as? Bool { appearance.blurUnwatchedEpisodes = value }
        if let value = defaults.object(forKey: SettingsKey.hideUnwatchedEpisodeTitles) as? Bool { appearance.hideUnwatchedEpisodeTitles = value }
        if let value = defaults.object(forKey: SettingsKey.hideUnwatchedEpisodeDescriptions) as? Bool { appearance.hideUnwatchedEpisodeDescriptions = value }
        if let value = defaults.object(forKey: SettingsKey.landscapeAlwaysBackdropLogo) as? Bool { appearance.landscapeAlwaysBackdropLogo = value }
        if let value = defaults.object(forKey: SettingsKey.trailerStartSeconds) as? Int { appearance.trailerStartSeconds = value }
        appearance.animatedArtworkOnFocus = AnimatedArtworkMode.playsOnFocus(defaults.string(forKey: SettingsKey.animatedArtwork))
        appearance.cardDepth = CardDepthStyle.stored(in: defaults)
        return appearance
    }
}

extension CustomPosterScreen {
    /// The "Apply custom posters to" value the cards use. Until its rows are
    /// used on this Apple TV, a custom poster address applies to every
    /// screen, as it did before the rows existed, whatever is stored.
    static func effectiveStorageValue(stored: String, pattern: String, chosenHere: Bool) -> String {
        if chosenHere || pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return stored
        }
        return "all"
    }
}

/// Settings → Poster Card Style → Animated artwork. The desktop app's
/// "Always" is left out: on Apple TV only the focused card animates.
enum AnimatedArtworkMode {
    static let off = "Off"
    static let onFocus = "On focus"
    static let options = [off, onFocus]

    static func playsOnFocus(_ stored: String?) -> Bool {
        stored == onFocus
    }

    /// Animated posters are recognised by their address, so no card has to
    /// download anything to find out.
    static func isAnimatedImageURL(_ urlString: String?) -> Bool {
        guard let urlString, let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }
        return url.pathExtension.lowercased() == "gif"
    }
}

#if os(tvOS)
/// An animated poster over a grid card, for Settings → Poster Card Style →
/// Animated artwork. Made only for a card whose poster is a GIF, with the
/// option on. Nothing is downloaded or played until focus has rested on the
/// card, and it stops when focus leaves.
struct FocusedAnimatedArtwork: View {
    let urlString: String
    let isFocused: Bool
    @State private var isArmed = false

    var body: some View {
        ZStack {
            if isFocused && isArmed {
                AnimatedRemoteGIFView(urlString: urlString, isActive: true, maxPixelSize: 640)
            }
        }
        .allowsHitTesting(false)
        .task(id: isFocused) {
            guard isFocused else {
                if isArmed { isArmed = false }
                return
            }
            do {
                try await Task.sleep(nanoseconds: 350_000_000)
            } catch {
                return
            }
            isArmed = true
        }
    }
}
#endif

/// Settings → Poster Card Style → Card depth effect: a lit top edge and a
/// soft sheen on image cards. Edge, sheen and coverage run from 0 to 100,
/// as in the desktop app.
struct CardDepthStyle: Equatable {
    enum Surface {
        case posters, continueWatching, episodes, cast
    }

    static let defaultEdge = 28
    static let defaultSheen = 10
    static let defaultCoverage = 0

    static let keys = [
        SettingsKey.cardDepthEnabled, SettingsKey.cardDepthEdge, SettingsKey.cardDepthSheen,
        SettingsKey.cardDepthCoverage, SettingsKey.cardDepthPosters, SettingsKey.cardDepthContinueWatching,
        SettingsKey.cardDepthEpisodes, SettingsKey.cardDepthCast
    ]

    var isEnabled = false
    var edge = CardDepthStyle.defaultEdge
    var sheen = CardDepthStyle.defaultSheen
    var coverage = CardDepthStyle.defaultCoverage
    var posters = true
    var continueWatching = true
    var episodes = true
    var cast = true

    func applies(to surface: Surface) -> Bool {
        guard isEnabled, edge > 0 || sheen > 0 else { return false }
        switch surface {
        case .posters: return posters
        case .continueWatching: return continueWatching
        case .episodes: return episodes
        case .cast: return cast
        }
    }

    static func stored(in defaults: UserDefaults) -> CardDepthStyle {
        var style = CardDepthStyle()
        if let value = defaults.object(forKey: SettingsKey.cardDepthEnabled) as? Bool { style.isEnabled = value }
        if let value = defaults.object(forKey: SettingsKey.cardDepthEdge) as? Int { style.edge = value }
        if let value = defaults.object(forKey: SettingsKey.cardDepthSheen) as? Int { style.sheen = value }
        if let value = defaults.object(forKey: SettingsKey.cardDepthCoverage) as? Int { style.coverage = value }
        if let value = defaults.object(forKey: SettingsKey.cardDepthPosters) as? Bool { style.posters = value }
        if let value = defaults.object(forKey: SettingsKey.cardDepthContinueWatching) as? Bool { style.continueWatching = value }
        if let value = defaults.object(forKey: SettingsKey.cardDepthEpisodes) as? Bool { style.episodes = value }
        if let value = defaults.object(forKey: SettingsKey.cardDepthCast) as? Bool { style.cast = value }
        return style
    }
}

/// Draws the card depth effect over a card. With the effect off, or off for
/// this kind of card, the overlay is empty and nothing is drawn.
struct CardDepthEffect<S: InsettableShape>: ViewModifier {
    let style: CardDepthStyle
    let surface: CardDepthStyle.Surface
    let shape: S

    func body(content: Content) -> some View {
        content.overlay {
            if style.applies(to: surface) {
                CardDepthOverlay(style: style, shape: shape)
            }
        }
    }
}

private struct CardDepthOverlay<S: InsettableShape>: View {
    let style: CardDepthStyle
    let shape: S

    var body: some View {
        let edge = Double(min(max(style.edge, 0), 100)) / 100
        let sheen = Double(min(max(style.sheen, 0), 100)) / 100
        let coverage = Double(min(max(style.coverage, 0), 100)) / 100
        ZStack {
            if sheen > 0 {
                // The sheen covers the top 22 percent of the card.
                LinearGradient(
                    colors: [.white.opacity(sheen), .white.opacity(0)],
                    startPoint: .top,
                    endPoint: UnitPoint(x: 0.5, y: 0.22)
                )
                .clipShape(shape)
            }
            if edge > 0 {
                shape.strokeBorder(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(edge), location: 0),
                            .init(color: .white.opacity(edge * (0.33 + 0.67 * coverage)), location: 0.5),
                            .init(color: .white.opacity(edge * coverage), location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 2
                )
            }
        }
        .allowsHitTesting(false)
    }
}

private struct CardAppearanceKey: EnvironmentKey {
    static var defaultValue: CardAppearance { .stored(in: ProfileSettings.current) }
}

extension EnvironmentValues {
    var cardAppearance: CardAppearance {
        get { self[CardAppearanceKey.self] }
        set { self[CardAppearanceKey.self] = newValue }
    }
}

/// Reads the card settings once and hands them to every card below. Applied inside
/// `.defaultAppStorage`, so the values are the active profile's.
struct CardAppearanceProvider: ViewModifier {
    @AppStorage(SettingsKey.customPosterURLPattern) private var customPosterURLPattern = ""
    @AppStorage(SettingsKey.customPosterEnabledScreens) private var customPosterEnabledScreens = "all"
    @AppStorage(SettingsKey.trailersEnabled) private var trailersEnabled = true
    @AppStorage(SettingsKey.trailerDelay) private var trailerDelay = 7
    @AppStorage(SettingsKey.cardCornerRadius) private var cardCornerRadius = AppCardStyle.defaultCornerRadiusRaw
    @AppStorage(SettingsKey.liquidGlassCards) private var liquidGlassCards = true
    @AppStorage(SettingsKey.posterLabels) private var posterLabels = false
    @AppStorage(SettingsKey.smoothFocus) private var smoothFocus = true
    @AppStorage(SettingsKey.focusHighlighter) private var focusHighlighter = false
    @AppStorage(SettingsKey.amoled) private var amoled = false
    @AppStorage(SettingsKey.amoledSurfaces) private var amoledSurfaces = false
    @AppStorage(SettingsKey.focusedPosterBackdropEnabled) private var focusedPosterBackdropEnabled = true
    @AppStorage(SettingsKey.continueWatchingLabels) private var continueWatchingLabels = CardLabelVisibility.always.rawValue
    @AppStorage(SettingsKey.continueWatchingBlurNextUp) private var continueWatchingBlurNextUp = false
    @AppStorage(SettingsKey.blurUnwatchedEpisodes) private var blurUnwatchedEpisodes = false
    @AppStorage(SettingsKey.hideUnwatchedEpisodeTitles) private var hideUnwatchedEpisodeTitles = false
    @AppStorage(SettingsKey.hideUnwatchedEpisodeDescriptions) private var hideUnwatchedEpisodeDescriptions = false
    @AppStorage(SettingsKey.landscapeAlwaysBackdropLogo) private var landscapeAlwaysBackdropLogo = false
    @AppStorage(SettingsKey.trailerStartSeconds) private var trailerStartSeconds = 0
    @AppStorage(SettingsKey.customPosterScreensChosenHere) private var customPosterScreensChosenHere = false
    @AppStorage(SettingsKey.animatedArtwork) private var animatedArtwork = AnimatedArtworkMode.off
    @AppStorage(SettingsKey.cardDepthEnabled) private var cardDepthEnabled = false
    @AppStorage(SettingsKey.cardDepthEdge) private var cardDepthEdge = CardDepthStyle.defaultEdge
    @AppStorage(SettingsKey.cardDepthSheen) private var cardDepthSheen = CardDepthStyle.defaultSheen
    @AppStorage(SettingsKey.cardDepthCoverage) private var cardDepthCoverage = CardDepthStyle.defaultCoverage
    @AppStorage(SettingsKey.cardDepthPosters) private var cardDepthPosters = true
    @AppStorage(SettingsKey.cardDepthContinueWatching) private var cardDepthContinueWatching = true
    @AppStorage(SettingsKey.cardDepthEpisodes) private var cardDepthEpisodes = true
    @AppStorage(SettingsKey.cardDepthCast) private var cardDepthCast = true

    func body(content: Content) -> some View {
        let effectiveScreens = CustomPosterScreen.effectiveStorageValue(
            stored: customPosterEnabledScreens,
            pattern: customPosterURLPattern,
            chosenHere: customPosterScreensChosenHere
        )
        content.environment(
            \.cardAppearance,
            CardAppearance(
                customPosterURLPattern: customPosterURLPattern,
                customPosterEnabledScreens: effectiveScreens,
                trailersEnabled: trailersEnabled,
                trailerDelay: trailerDelay,
                cardCornerRadius: cardCornerRadius,
                liquidGlassCards: liquidGlassCards,
                posterLabels: posterLabels,
                smoothFocus: smoothFocus,
                focusHighlighter: focusHighlighter,
                amoled: amoled,
                amoledSurfaces: amoledSurfaces,
                focusedPosterBackdropEnabled: focusedPosterBackdropEnabled,
                continueWatchingLabels: continueWatchingLabels,
                continueWatchingBlurNextUp: continueWatchingBlurNextUp,
                blurUnwatchedEpisodes: blurUnwatchedEpisodes,
                hideUnwatchedEpisodeTitles: hideUnwatchedEpisodeTitles,
                hideUnwatchedEpisodeDescriptions: hideUnwatchedEpisodeDescriptions,
                landscapeAlwaysBackdropLogo: landscapeAlwaysBackdropLogo,
                trailerStartSeconds: trailerStartSeconds,
                animatedArtworkOnFocus: AnimatedArtworkMode.playsOnFocus(animatedArtwork),
                cardDepth: CardDepthStyle(
                    isEnabled: cardDepthEnabled,
                    edge: cardDepthEdge,
                    sheen: cardDepthSheen,
                    coverage: cardDepthCoverage,
                    posters: cardDepthPosters,
                    continueWatching: cardDepthContinueWatching,
                    episodes: cardDepthEpisodes,
                    cast: cardDepthCast
                )
            )
        )
    }
}
