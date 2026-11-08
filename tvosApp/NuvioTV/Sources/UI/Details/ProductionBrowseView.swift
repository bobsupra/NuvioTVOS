import SwiftUI

/// Full catalog of titles from a production company or network.
struct ProductionBrowseView: View {
    let company: MetaCompany
    let onSelect: (RelatedTitle) -> Void
    let onBack: () -> Void

    @State private var titles: [RelatedTitle] = []
    @State private var networkBrowse: TmdbNetworkBrowseData?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @AppStorage(SettingsKey.amoled) private var amoled = false
    @AppStorage(SettingsKey.bodyColor) private var bodyColor = SettingsBackground.charcoal.rawValue

    var body: some View {
        ZStack {
            Color.nuvioBackground(amoled: amoled, body: bodyColor)
                .ignoresSafeArea()

            CompanyBrowseContent(
                company: company,
                data: networkBrowse,
                providedRails: company.kind == .network ? (networkBrowse?.rails ?? []) : productionRails,
                fallbackTitles: titles,
                isLoading: isLoading,
                errorMessage: errorMessage,
                onSelect: onSelect
            )

        }
        .onExitCommand(perform: onBack)
        .task(id: company.id) {
            await load()
        }
    }

    private var productionRails: [TmdbNetworkBrowseRail] {
        let series = titles.filter { $0.type == "series" }
        let movies = titles.filter { $0.type == "movie" }
        var rails: [TmdbNetworkBrowseRail] = []
        if !series.isEmpty {
            rails.append(TmdbNetworkBrowseRail(id: "series", title: L10n.string("details_series_popular", fallback: "Series • Popular"), items: series))
        }
        if !movies.isEmpty {
            rails.append(TmdbNetworkBrowseRail(id: "movies", title: L10n.string("details_movies_popular", fallback: "Movies • Popular"), items: movies))
        }
        if rails.isEmpty && !titles.isEmpty {
            rails.append(TmdbNetworkBrowseRail(id: "titles", title: L10n.string("details_titles_popular", fallback: "Titles • Popular"), items: titles))
        }
        return rails
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        networkBrowse = nil
        let results: [RelatedTitle]
        if company.kind == .network {
            let browse = await TmdbDetailsService.fetchNetworkBrowse(company: company)
            networkBrowse = browse
            if let browse, !browse.rails.isEmpty {
                results = browse.rails.flatMap(\.items)
            } else {
                results = await TmdbDetailsService.discoverTitles(company: company)
            }
        } else {
            results = await TmdbDetailsService.discoverTitles(company: company)
        }
        titles = results
        isLoading = false
    }
}

/// Company catalog presentation matching the Android TV layout: a cinematic
/// identity hero followed by horizontally scrolling title rails.
private struct CompanyBrowseContent: View {
    let company: MetaCompany
    let data: TmdbNetworkBrowseData?
    let providedRails: [TmdbNetworkBrowseRail]
    let fallbackTitles: [RelatedTitle]
    let isLoading: Bool
    let errorMessage: String?
    let onSelect: (RelatedTitle) -> Void

    @FocusState private var placeholderFocused: Bool
    @State private var scrollOffset: CGFloat = 0
    @AppStorage(SettingsKey.amoled) private var amoled = false
    @AppStorage(SettingsKey.bodyColor) private var bodyColor = SettingsBackground.charcoal.rawValue

    private var displayName: String { data?.name ?? company.name }
    private var logoURL: String? { data?.logoURL ?? company.logoURL }
    private var usesWhiteLogo: Bool {
        company.kind == .network && displayName.localizedCaseInsensitiveContains("apple")
    }

    private var rails: [TmdbNetworkBrowseRail] {
        if !providedRails.isEmpty { return providedRails }
        guard !fallbackTitles.isEmpty else { return [] }
        return [TmdbNetworkBrowseRail(
            id: "popular",
            title: company.kind == .network
                ? L10n.string("details_series_popular", fallback: "Series • Popular")
                : L10n.string("details_titles_popular", fallback: "Titles • Popular"),
            items: fallbackTitles
        )]
    }

    private var backdropURL: URL? {
        guard let item = rails.first?.items.first,
              let string = item.backdropURL ?? item.posterURL else { return nil }
        return URL(string: string)
    }

    private var scrollShadowProgress: CGFloat {
        min(max(scrollOffset / 120, 0), 1)
    }

    var body: some View {
        ZStack(alignment: .top) {
            backdrop

            Color.black
                .opacity(0.78 * scrollShadowProgress)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            ScrollView {
                VStack(alignment: .leading, spacing: 34) {
                    GeometryReader { geometry in
                        Color.clear
                            .preference(
                                key: CompanyBrowseScrollOffsetKey.self,
                                value: geometry.frame(in: .named("company-browse-scroll")).minY
                            )
                    }
                    .frame(height: 0)

                    hero

                    if isLoading {
                        ProgressView()
                            .scaleEffect(1.6)
                            .frame(maxWidth: .infinity, minHeight: 260)
                    } else if let errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 30, weight: .medium))
                            .foregroundColor(.white.opacity(0.7))
                            .frame(maxWidth: .infinity, minHeight: 260)
                    } else if rails.isEmpty {
                        Text(L10n.format("details_no_titles_found_for", fallback: "No titles found for %@", displayName))
                            .font(.system(size: 30, weight: .medium))
                            .foregroundColor(.white.opacity(0.7))
                            .frame(maxWidth: .infinity, minHeight: 260)
                    } else {
                        ForEach(rails) { rail in
                            NetworkBrowseRail(rail: rail, onSelect: onSelect)
                        }
                    }
                }
                .padding(.bottom, 70)
            }
            .focusSection()
            .coordinateSpace(name: "company-browse-scroll")
            .modifier(CompanyBrowseScrollTracker(offset: $scrollOffset))

            CompanyBrowseScrollTransitionShadow(progress: scrollShadowProgress)

            if isLoading || rails.isEmpty {
                placeholderFocusAnchor
            }
        }
        .ignoresSafeArea(edges: .top)
    }

    private var backdrop: some View {
        let backdropColor = Color.nuvioBackground(amoled: amoled, body: bodyColor)

        return ZStack {
            if let backdropURL {
                AsyncImage(url: backdropURL) { phase in
                    if case .success(let image) = phase {
                        image
                            .resizable()
                            .scaledToFill()
                    }
                }
                // Match TvDetailsBackdrop: the artwork fills the entire
                // screen layer, so its crop starts at the same vertical point
                // instead of being constrained to the hero's shorter frame.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            } else {
                backdropColor
            }

            GeometryReader { proxy in
                LinearGradient(
                    stops: [
                        .init(color: backdropColor.opacity(0.95), location: 0),
                        .init(color: backdropColor.opacity(0.86), location: 0.25),
                        .init(color: backdropColor.opacity(0.64), location: 0.50),
                        .init(color: backdropColor.opacity(0.34), location: 0.70),
                        .init(color: backdropColor.opacity(0.10), location: 0.88),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: proxy.size.width * 0.76)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var hero: some View {
        HStack(alignment: .bottom, spacing: 50) {
            VStack(alignment: .leading, spacing: 12) {
                Text(company.kind == .network
                     ? L10n.string("tmdb_entity_kind_network", fallback: "Network")
                     : L10n.string("details_production", fallback: "Production"))
                    .font(.system(size: 32, weight: .medium))
                    .foregroundColor(.white.opacity(0.72))

                Text(displayName)
                    .font(.system(size: 64, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(2)

                let location = [data?.headquarters, data?.originCountry]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: ", ")
                if !location.isEmpty {
                    Text(location)
                        .font(.system(size: 30, weight: .regular))
                        .foregroundColor(.white.opacity(0.72))
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 20)

            if let logoURL, let url = URL(string: logoURL) {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        if usesWhiteLogo {
                            image
                                .renderingMode(.template)
                                .resizable()
                                .foregroundColor(.white)
                                .scaledToFit()
                        } else {
                            image
                                .resizable()
                                .scaledToFit()
                        }
                    } else {
                        Text(displayName)
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundColor(.white)
                    }
                }
                .frame(width: 520, height: 190)
            }
        }
        .padding(.horizontal, 80)
        .padding(.top, 72)
        .frame(maxWidth: .infinity, minHeight: 390, alignment: .bottom)
    }

    private var placeholderFocusAnchor: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .focusable(true)
            .focused($placeholderFocused)
            .focusEffectDisabledIfAvailable()
            .onAppear {
                DispatchQueue.main.async { placeholderFocused = true }
            }
    }
}

private struct CompanyBrowseScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct CompanyBrowseScrollTracker: ViewModifier {
    @Binding var offset: CGFloat

    func body(content: Content) -> some View {
        if #available(tvOS 18.0, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y
            } action: { _, newOffset in
                offset = max(0, newOffset)
            }
        } else {
            content.onPreferenceChange(CompanyBrowseScrollOffsetKey.self) { minY in
                offset = max(0, -minY)
            }
        }
    }
}

private struct CompanyBrowseScrollTransitionShadow: View {
    let progress: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(
                colors: [
                    .black.opacity(0.34 * progress),
                    .black.opacity(0.12 * progress),
                    .clear
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 72)

            Spacer(minLength: 0)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct NetworkBrowseRail: View {
    let rail: TmdbNetworkBrowseRail
    var externalFocus: FocusState<String?>.Binding? = nil
    let onSelect: (RelatedTitle) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(rail.title)
                .font(.system(size: 34, weight: .semibold))
                .foregroundColor(.white.opacity(0.92))
                .padding(.horizontal, 80)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: TmdbBrowseGridMetrics.posterGap) {
                    ForEach(rail.items) { title in
                        ProductionBrowseCard(
                            title: title,
                            externalFocus: externalFocus,
                            onSelect: {
                                onSelect(title)
                            }
                        )
                    }
                }
                .padding(.horizontal, 80)
                .padding(.vertical, 12)
            }
            .scrollClipDisabledIfAvailable()
        }
    }
}

/// Movies and series associated with a TMDB actor, director, or creator.
struct PersonBrowseView: View {
    let person: TmdbPersonMetadata
    let onSelect: (RelatedTitle) -> Void
    let onBack: () -> Void

    @State private var detail: ScenePersonDetail? = nil
    @State private var isLoading = true
    @State private var scrollOffset: CGFloat = 0
    @FocusState private var focusedCardID: String?
    @FocusState private var placeholderFocused: Bool
    @AppStorage(SettingsKey.amoled) private var amoled = false
    @AppStorage(SettingsKey.bodyColor) private var bodyColor = SettingsBackground.charcoal.rawValue

    private var displayName: String { detail?.name ?? person.name }

    private var rails: [TmdbNetworkBrowseRail] {
        guard let detail else { return [] }
        var list: [TmdbNetworkBrowseRail] = []
        if !detail.movies.isEmpty {
            list.append(
                TmdbNetworkBrowseRail(
                    id: "movies",
                    title: L10n.format("details_movies_count", fallback: "Movies • %d", detail.movies.count),
                    items: detail.movies.map(\.asRelatedTitle)
                )
            )
        }
        if !detail.series.isEmpty {
            list.append(
                TmdbNetworkBrowseRail(
                    id: "series",
                    title: L10n.format("details_series_count", fallback: "Series • %d", detail.series.count),
                    items: detail.series.map(\.asRelatedTitle)
                )
            )
        }
        return list
    }

    private var backdropURL: URL? {
        let movieBackdrop = detail?.movies.compactMap(\.backdropURL).first
        let seriesBackdrop = detail?.series.compactMap(\.backdropURL).first
        return movieBackdrop ?? seriesBackdrop
    }

    private var scrollShadowProgress: CGFloat {
        min(max(scrollOffset / 120, 0), 1)
    }

    var body: some View {
        ZStack(alignment: .top) {
            backdrop

            Color.black
                .opacity(0.78 * scrollShadowProgress)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            ScrollView {
                VStack(alignment: .leading, spacing: 34) {
                    GeometryReader { geometry in
                        Color.clear
                            .preference(
                                key: CompanyBrowseScrollOffsetKey.self,
                                value: geometry.frame(in: .named("person-browse-scroll")).minY
                            )
                    }
                    .frame(height: 0)

                    hero

                    if isLoading {
                        ProgressView()
                            .scaleEffect(1.6)
                            .frame(maxWidth: .infinity, minHeight: 260)
                    } else if rails.isEmpty {
                        Text(L10n.format("details_no_titles_found_for_person", fallback: "No movies or series found for %@", displayName))
                            .font(.system(size: 30, weight: .medium))
                            .foregroundColor(.white.opacity(0.7))
                            .frame(maxWidth: .infinity, minHeight: 260)
                    } else {
                        ForEach(rails) { rail in
                            NetworkBrowseRail(rail: rail, externalFocus: $focusedCardID, onSelect: onSelect)
                        }
                    }
                }
                .padding(.bottom, 70)
            }
            .focusSection()
            .coordinateSpace(name: "person-browse-scroll")
            .modifier(CompanyBrowseScrollTracker(offset: $scrollOffset))

            CompanyBrowseScrollTransitionShadow(progress: scrollShadowProgress)

            if isLoading || rails.isEmpty {
                placeholderFocusAnchor
            }
        }
        .defaultFocusIfAvailable($focusedCardID, rails.first?.items.first?.id)
        .onChange(of: rails.first?.items.first?.id) { _, newFirstID in
            if focusedCardID == nil, let newFirstID {
                focusedCardID = newFirstID
            }
        }
        .ignoresSafeArea(edges: .top)
        .onExitCommand(perform: onBack)
        .task(id: person.id) {
            isLoading = true
            let provider = TmdbSceneCastProvider()
            detail = await provider.fetchPersonDetail(for: person)
            isLoading = false
            if focusedCardID == nil, let firstID = rails.first?.items.first?.id {
                focusedCardID = firstID
            }
        }
    }

    private var backdrop: some View {
        let backdropColor = Color.nuvioBackground(amoled: amoled, body: bodyColor)

        return ZStack(alignment: .top) {
            backdropColor
                .ignoresSafeArea()

            if let backdropURL {
                ZStack {
                    AsyncImage(url: backdropURL) { phase in
                        if case .success(let image) = phase {
                            image
                                .resizable()
                                .scaledToFill()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: 520)
                    .clipped()
                    .blur(radius: 8, opaque: true)

                    GeometryReader { proxy in
                        LinearGradient(
                            stops: [
                                .init(color: backdropColor.opacity(0.96), location: 0),
                                .init(color: backdropColor.opacity(0.86), location: 0.25),
                                .init(color: backdropColor.opacity(0.64), location: 0.50),
                                .init(color: backdropColor.opacity(0.34), location: 0.70),
                                .init(color: backdropColor.opacity(0.10), location: 0.88),
                                .init(color: .clear, location: 1)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: proxy.size.width * 0.76)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    }

                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.0),
                            .init(color: backdropColor.opacity(0.4), location: 0.35),
                            .init(color: backdropColor.opacity(0.85), location: 0.7),
                            .init(color: backdropColor, location: 1.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: 520)
                .clipped()
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var hero: some View {
        HStack(alignment: .bottom, spacing: 50) {
            VStack(alignment: .leading, spacing: 12) {
                Text(categoryLabel)
                    .font(.system(size: 32, weight: .medium))
                    .foregroundColor(.white.opacity(0.72))

                Text(displayName)
                    .font(.system(size: 64, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(2)

                let metaParts = [
                    detail?.birthInfo,
                    detail?.placeOfBirth
                ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }

                if !metaParts.isEmpty {
                    Text(metaParts.joined(separator: " • "))
                        .font(.system(size: 26, weight: .regular))
                        .foregroundColor(.white.opacity(0.68))
                        .lineLimit(2)
                }

                if let bio = detail?.biography, !bio.isEmpty {
                    Text(bio)
                        .font(.system(size: 20, weight: .regular))
                        .foregroundColor(.white.opacity(0.82))
                        .lineSpacing(4)
                        .lineLimit(4)
                        .padding(.top, 4)
                }
            }

            Spacer(minLength: 20)

            // Right-side portrait card matching streaming service logo / hero style
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 200, height: 280)

                let profileURL = detail?.profileURL ?? person.profileURL.flatMap(URL.init)
                if let profileURL {
                    AsyncImage(url: profileURL) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFill()
                                .frame(width: 200, height: 280)
                                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                        case .failure, .empty:
                            personFallback
                        @unknown default:
                            personFallback
                        }
                    }
                } else {
                    personFallback
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 1.5)
            )
            .shadow(color: Color.black.opacity(0.55), radius: 20, y: 8)
        }
        .padding(.horizontal, 80)
        .padding(.top, 72)
        .frame(maxWidth: .infinity, minHeight: 390, alignment: .bottom)
    }

    private var categoryLabel: String {
        if let role = person.role, !role.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return role
        }
        return "Cast & Crew"
    }

    private var personFallback: some View {
        Image(systemName: "person.fill")
            .resizable()
            .scaledToFit()
            .frame(width: 80, height: 80)
            .foregroundColor(.white.opacity(0.35))
    }

    private var placeholderFocusAnchor: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .focusable(true)
            .focused($placeholderFocused)
            .focusEffectDisabledIfAvailable()
            .onAppear {
                DispatchQueue.main.async { placeholderFocused = true }
            }
    }
}

enum TmdbBrowseGridMetrics {
    static let posterWidth: CGFloat = 210
    static let posterHeight: CGFloat = 315
    static let posterGap: CGFloat = 28

    static var columns: [GridItem] {
        [GridItem(
            .adaptive(minimum: posterWidth, maximum: posterWidth),
            spacing: posterGap,
            alignment: .top
        )]
    }
}

struct ProductionBrowseCard: View {
    let title: RelatedTitle
    let alwaysShowLabels: Bool
    var externalFocus: FocusState<String?>.Binding?
    let onSelect: () -> Void

    @FocusState private var isFocused: Bool
    @AppStorage(SettingsKey.posterLabels) private var posterLabels = false
    @AppStorage(SettingsKey.smoothFocus) private var smoothFocus = true
    @AppStorage(SettingsKey.focusHighlighter) private var focusHighlighter = false
    @AppStorage(SettingsKey.cardCornerRadius) private var cardCornerRadiusSetting = AppCardStyle.defaultCornerRadiusRaw
    @AppStorage(SettingsKey.liquidGlassCards) private var liquidGlassCards = true

    private var cardCornerRadius: CGFloat {
        AppCardStyle.cornerRadius(for: cardCornerRadiusSetting, fallback: 16)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
    }

    init(
        title: RelatedTitle,
        alwaysShowLabels: Bool = false,
        externalFocus: FocusState<String?>.Binding? = nil,
        onSelect: @escaping () -> Void
    ) {
        self.title = title
        self.alwaysShowLabels = alwaysShowLabels
        self.externalFocus = externalFocus
        self.onSelect = onSelect
    }

    var body: some View {
        if let externalFocus {
            cardButton
                .focused(externalFocus, equals: title.id)
        } else {
            cardButton
        }
    }

    private var cardButton: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 12) {
                ZStack {
                    shape
                        .fill(Color.white.opacity(0.08))
                    if let poster = title.posterURL, let url = URL(string: poster) {
                        AsyncImage(url: url) { phase in
                            if case .success(let image) = phase {
                                image
                                    .resizable()
                                    .scaledToFill()
                            }
                        }
                        .frame(width: TmdbBrowseGridMetrics.posterWidth, height: TmdbBrowseGridMetrics.posterHeight)
                        .clipped()
                    } else {
                        Image(systemName: "film")
                            .font(.system(size: 40, weight: .medium))
                            .foregroundColor(.white.opacity(0.4))
                    }
                }
                .frame(width: TmdbBrowseGridMetrics.posterWidth, height: TmdbBrowseGridMetrics.posterHeight)
                .clipShape(shape)
                .modifier(
                    LiquidGlassCardModifier(
                        cornerRadius: cardCornerRadius,
                        isFocused: isFocused,
                        isEnabled: liquidGlassCards
                    )
                )
                .overlay(
                    shape.stroke(
                        isFocused ? AppFocusOutline.color : .clear,
                        lineWidth: focusHighlighter ? AppFocusOutline.emphasizedWidth : AppFocusOutline.width
                    )
                )
                .shadow(
                    color: .black.opacity(isFocused ? 0.5 : 0.2),
                    radius: isFocused ? 16 : 6
                )

                if posterLabels || alwaysShowLabels {
                    VStack(alignment: .leading, spacing: 3) {
                        MarqueeText(title.name, size: 20, weight: .semibold,
                                    color: isFocused ? .white : .white.opacity(0.78), isActive: isFocused)
                        Text(subtitle)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.white.opacity(0.45))
                            .lineLimit(1)
                    }
                    .frame(width: TmdbBrowseGridMetrics.posterWidth, alignment: .leading)
                }
            }
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($isFocused)
        .focusEffectDisabledIfAvailable()
        .titleActionsContextMenu(
            meta: title.asMeta,
            onOpenDetails: onSelect
        )
        .scaleEffect(isFocused ? 1.06 : 1)
        .animation(smoothFocus ? .spring(response: 0.28, dampingFraction: 0.75) : nil, value: isFocused)
        .zIndex(isFocused ? 1 : 0)
    }

    private var subtitle: String {
        var parts = [title.type == "series" ? "Series" : "Movie"]
        if let year = title.year { parts.append(year) }
        if let rating = title.rating, rating > 0 {
            parts.append(String(format: "★ %.1f", rating))
        }
        return parts.joined(separator: "  ·  ")
    }
}
