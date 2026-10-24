import SwiftUI
import UIKit

// Rating badges shared by Details and the Home hero, so both show the same
// providers, icons, order and number formats.

struct TvRatingBadge: Identifiable {
    let visual: TvRatingVisual
    let rating: NuvioExternalRating

    var id: String { rating.source }

    var formattedValue: String { visual.format(rating.value) }

    /// MDBList providers in their fixed priority, then add-on sources, sorted
    /// by the user's rating order.
    static func badges(from externalRatings: [NuvioExternalRating]) -> [TvRatingBadge] {
        let ratings = Dictionary(
            externalRatings.map { rating in
                let key = rating.source.lowercased() == "mal" ? MdbListDetailsService.providerMyAnimeList : rating.source
                return (key, rating)
            },
            uniquingKeysWith: { first, _ in first }
        )
        // 1. Built-in MDBList provider badges in priority order:
        var badges = TvRatingVisual.all.compactMap { visual -> TvRatingBadge? in
            guard let rating = ratings[visual.source] else { return nil }
            return TvRatingBadge(visual: visual, rating: rating)
        }
        // 2. Extra rating badges provided by add-ons:
        let builtInSources = Set(TvRatingVisual.all.map { $0.source.lowercased() })
        let extraRatings = externalRatings.filter {
            let lower = $0.source.lowercased()
            return !builtInSources.contains(lower) && lower != "mal"
        }
        for extra in extraRatings {
            let visual = TvRatingVisual(
                source: extra.source,
                displayName: extra.name ?? extra.source.capitalized,
                assetName: nil,
                iconUrl: extra.iconUrl.flatMap { URL(string: $0) },
                iconWidth: 38,
                color: Color(red: 0.96, green: 0.77, blue: 0.09),
                format: { AddonRatingsService.formatRating(value: $0, max: extra.max) }
            )
            badges.append(TvRatingBadge(visual: visual, rating: extra))
        }
        return AddonRatingsService.sortRatings(badges, by: { $0.visual.source })
    }
}

struct TvRatingVisual {
    let source: String
    let displayName: String
    let assetName: String?
    let iconUrl: URL?
    /// Icon width at the Details icon height of 38 pt.
    let iconWidth: CGFloat
    let color: Color
    let format: (Double) -> String

    init(
        source: String,
        displayName: String,
        assetName: String? = nil,
        iconUrl: URL? = nil,
        iconWidth: CGFloat,
        color: Color,
        format: @escaping (Double) -> String
    ) {
        self.source = source
        self.displayName = displayName
        self.assetName = assetName
        self.iconUrl = iconUrl
        self.iconWidth = iconWidth
        self.color = color
        self.format = format
    }

    static let all: [TvRatingVisual] = [
        TvRatingVisual(
            source: MdbListDetailsService.providerIMDb,
            displayName: "IMDb",
            assetName: "rating_imdb",
            iconWidth: 68,
            color: Color(red: 0.96, green: 0.77, blue: 0.09),
            format: { String(format: "%.1f", $0) }
        ),
        TvRatingVisual(
            source: MdbListDetailsService.providerTMDB,
            displayName: "TMDB",
            assetName: "rating_tmdb",
            iconWidth: 40,
            color: Color(red: 0.00, green: 0.71, blue: 0.89),
            format: { String(Int($0.rounded())) }
        ),
        TvRatingVisual(
            source: MdbListDetailsService.providerTomatoes,
            displayName: "Rotten Tomatoes",
            assetName: "rating_rotten_tomatoes",
            iconWidth: 38,
            color: Color(red: 0.98, green: 0.20, blue: 0.04),
            format: { "\(Int($0.rounded()))%" }
        ),
        TvRatingVisual(
            source: MdbListDetailsService.providerAudience,
            displayName: "Audience Score",
            assetName: "rating_audience_score",
            iconWidth: 31,
            color: Color(red: 0.98, green: 0.20, blue: 0.04),
            format: { "\(Int($0.rounded()))%" }
        ),
        TvRatingVisual(
            source: MdbListDetailsService.providerMetacritic,
            displayName: "Metacritic",
            assetName: "rating_metacritic",
            iconWidth: 38,
            color: Color(red: 1.00, green: 0.80, blue: 0.20),
            format: { String(Int($0.rounded())) }
        ),
        TvRatingVisual(
            source: MdbListDetailsService.providerTrakt,
            displayName: "Trakt",
            assetName: "rating_trakt",
            iconWidth: 38,
            color: Color(red: 0.93, green: 0.11, blue: 0.14),
            format: { String(Int($0.rounded())) }
        ),
        TvRatingVisual(
            source: MdbListDetailsService.providerLetterboxd,
            displayName: "Letterboxd",
            assetName: "rating_letterboxd",
            iconWidth: 38,
            color: Color(red: 0.00, green: 0.88, blue: 0.33),
            format: { String(format: "%.1f", $0) }
        ),
        TvRatingVisual(
            source: MdbListDetailsService.providerMyAnimeList,
            displayName: "MyAnimeList",
            assetName: "rating_myanimelist",
            iconWidth: 42,
            color: Color(red: 0.18, green: 0.32, blue: 0.64),
            format: { String(format: "%.1f", $0) }
        ),
        TvRatingVisual(
            source: MdbListDetailsService.providerTVDB,
            displayName: "TVDB",
            assetName: "rating_tvdb",
            iconWidth: 42,
            color: Color(red: 0.11, green: 0.66, blue: 0.31),
            format: { $0 > 10 ? "\(Int($0.rounded()))%" : String(format: "%.1f", $0) }
        ),
    ]
}

/// A provider icon at any height: bundled assets for MDBList providers, the
/// add-on's icon URL (through the shared image cache) for the rest.
struct TvRatingIcon: View {
    let visual: TvRatingVisual
    let height: CGFloat

    var body: some View {
        let scale = height / 38
        Group {
            if let assetName = visual.assetName {
                Image(assetName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: visual.iconWidth * scale, height: height)
            } else if let iconUrl = visual.iconUrl {
                CachedRatingIcon(url: iconUrl, fallbackColor: visual.color)
                    .frame(width: visual.iconWidth * scale, height: height)
            } else {
                Image(systemName: "star.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 24 * scale, height: 24 * scale)
                    .foregroundColor(visual.color)
            }
        }
        .accessibilityLabel(visual.displayName)
    }
}

/// Add-on rating icon. Unlike `AsyncImage` it keeps decoded icons in memory,
/// so switching titles does not reload (and pop in) the same ČSFD/Kinopoisk
/// logo every time.
struct CachedRatingIcon: View {
    let url: URL
    let fallbackColor: Color

    @State private var image: UIImage?
    @State private var failed = false

    init(url: URL, fallbackColor: Color) {
        self.url = url
        self.fallbackColor = fallbackColor
        _image = State(initialValue: BackdropImageCache.shared.cachedImage(for: url))
    }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .transition(.opacity)
            } else if failed {
                Image(systemName: "star.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundColor(fallbackColor)
            }
        }
        .task(id: url) {
            if let cached = BackdropImageCache.shared.cachedImage(for: url) {
                // Usually already set by `init`; avoid a redundant redraw.
                if image !== cached { image = cached }
                if failed { failed = false }
                return
            }
            // Icons are often tiny PNGs or `data:` URLs; don't apply the
            // backdrop loader's minimum size.
            let loaded = await BackdropImageCache.shared.image(for: url, minimumBytes: 0)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                image = loaded
                failed = loaded == nil
            }
        }
    }
}

/// Compact one-line ratings row for the Home hero (icons + values, like
/// Details). Its height is fixed so badges arriving later never move the
/// lines around it.
struct TvHeroRatingsRow: View {
    let badges: [TvRatingBadge]
    var iconHeight: CGFloat = 26
    var fontSize: CGFloat = 22
    var maxCount = 5

    var body: some View {
        let shown = Array(badges.prefix(maxCount))
        HStack(spacing: iconHeight * 0.8) {
            ForEach(shown) { badge in
                HStack(spacing: 7) {
                    TvRatingIcon(visual: badge.visual, height: iconHeight)
                    Text(badge.formattedValue)
                        .font(.custom("Inter-SemiBold", size: fontSize))
                        .foregroundColor(.white.opacity(0.82))
                        .lineLimit(1)
                        .fixedSize()
                }
                .transition(.opacity)
            }
        }
        .frame(height: iconHeight + 4, alignment: .leading)
        .animation(.easeOut(duration: 0.25), value: shown.map(\.id))
    }
}
