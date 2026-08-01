import SwiftUI

/// Full catalog of titles from a production company or network.
struct ProductionBrowseView: View {
    let company: MetaCompany
    let onSelect: (RelatedTitle) -> Void
    let onBack: () -> Void

    @State private var titles: [RelatedTitle] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @FocusState private var focusedId: String?
    @FocusState private var placeholderFocused: Bool
    @AppStorage(SettingsKey.amoled) private var amoled = false
    @AppStorage(SettingsKey.bodyColor) private var bodyColor = SettingsBackground.charcoal.rawValue

    private var columns: [GridItem] { TmdbBrowseGridMetrics.columns }

    var body: some View {
        ZStack {
            Color.nuvioBackground(amoled: amoled, body: bodyColor)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 20) {
                header

                if isLoading {
                    Spacer()
                    ProgressView()
                        .scaleEffect(1.6)
                        .frame(maxWidth: .infinity)
                    Spacer()
                } else if let errorMessage {
                    Spacer()
                    Text(errorMessage)
                        .font(.system(size: 30, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                        .frame(maxWidth: .infinity)
                    Spacer()
                } else if titles.isEmpty {
                    Spacer()
                    Text("No titles found for \(company.name)")
                        .font(.system(size: 30, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                        .frame(maxWidth: .infinity)
                    Spacer()
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: TmdbBrowseGridMetrics.posterGap) {
                            ForEach(titles) { title in
                                ProductionBrowseCard(title: title) {
                                    onSelect(title)
                                }
                                .focused($focusedId, equals: title.id)
                            }
                        }
                        .padding(.top, 16)
                        .padding(.horizontal, 60)
                        .padding(.bottom, 60)
                    }
                    .focusSection()
                    .defaultFocusIfAvailable($focusedId, titles.first?.id)
                }
            }
            .padding(.top, 48)

            if titles.isEmpty {
                placeholderFocusAnchor
            }
        }
        .onExitCommand(perform: onBack)
        .task(id: company.id) {
            await load()
        }
    }

    private var header: some View {
        HStack(spacing: 28) {
            if let logo = company.logoURL, let url = URL(string: logo) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                            .padding(12)
                            .frame(width: 160, height: 80)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    default:
                        companyNameFallback
                    }
                }
            } else {
                companyNameFallback
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(company.name)
                    .font(.system(size: 42, weight: .bold))
                    .foregroundColor(.white)
                Text(company.kind == .network ? "Network catalog" : "Production catalog")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundColor(.white.opacity(0.55))
                if !isLoading {
                    Text("\(titles.count) titles")
                        .font(.system(size: 24, weight: .regular))
                        .foregroundColor(.white.opacity(0.4))
                }
            }
            Spacer()
        }
        .padding(.horizontal, 60)
    }

    private var companyNameFallback: some View {
        Text(company.name)
            .font(.system(size: 28, weight: .semibold))
            .foregroundColor(.black)
            .padding(.horizontal, 20)
            .frame(width: 160, height: 80)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// Loading/error/empty states otherwise contain no focusable view. Without
    /// a responder, tvOS treats Menu as unhandled and suspends the app instead
    /// of delivering it to this screen's `onExitCommand`.
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

    private func load() async {
        isLoading = true
        errorMessage = nil
        let results = await TmdbDetailsService.discoverTitles(company: company)
        titles = results
        isLoading = false
        if focusedId == nil {
            focusedId = results.first?.id
        }
    }
}

/// Movies and series associated with a TMDB actor, director, or creator.
struct PersonBrowseView: View {
    let person: TmdbPersonMetadata
    let onSelect: (RelatedTitle) -> Void
    let onBack: () -> Void

    @State private var titles: [RelatedTitle] = []
    @State private var isLoading = true
    @FocusState private var focusedId: String?
    @FocusState private var placeholderFocused: Bool
    @AppStorage(SettingsKey.amoled) private var amoled = false
    @AppStorage(SettingsKey.bodyColor) private var bodyColor = SettingsBackground.charcoal.rawValue

    private var columns: [GridItem] { TmdbBrowseGridMetrics.columns }

    var body: some View {
        ZStack {
            Color.nuvioBackground(amoled: amoled, body: bodyColor)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 28) {
                    if let profileURL = person.profileURL,
                       let url = URL(string: profileURL) {
                        AsyncImage(url: url) { phase in
                            if case .success(let image) = phase {
                                image
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 96, height: 96)
                                    .clipShape(Circle())
                            } else {
                                personFallback
                            }
                        }
                    } else {
                        personFallback
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text(person.name)
                            .font(.system(size: 42, weight: .bold))
                            .foregroundColor(.white)
                        if let role = person.role {
                            Text(role)
                                .font(.system(size: 26, weight: .medium))
                                .foregroundColor(.white.opacity(0.55))
                        }
                        if !isLoading {
                            Text("\(titles.count) titles")
                                .font(.system(size: 24, weight: .regular))
                                .foregroundColor(.white.opacity(0.4))
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, 60)

                if isLoading {
                    Spacer()
                    ProgressView()
                        .scaleEffect(1.6)
                        .frame(maxWidth: .infinity)
                    Spacer()
                } else if titles.isEmpty {
                    Spacer()
                    Text("No movies or series found for \(person.name)")
                        .font(.system(size: 30, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                        .frame(maxWidth: .infinity)
                    Spacer()
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: TmdbBrowseGridMetrics.posterGap) {
                            ForEach(titles) { title in
                                ProductionBrowseCard(title: title) {
                                    onSelect(title)
                                }
                                .focused($focusedId, equals: title.id)
                            }
                        }
                        .padding(.top, 16)
                        .padding(.horizontal, 60)
                        .padding(.bottom, 60)
                    }
                    .focusSection()
                    .defaultFocusIfAvailable($focusedId, titles.first?.id)
                }
            }
            .padding(.top, 48)

            if titles.isEmpty {
                placeholderFocusAnchor
            }
        }
        .onExitCommand(perform: onBack)
        .task(id: person.id) {
            isLoading = true
            titles = await TmdbDetailsService.discoverTitles(person: person)
            isLoading = false
            focusedId = titles.first?.id
        }
    }

    private var personFallback: some View {
        Text(person.name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined())
            .font(.system(size: 30, weight: .semibold))
            .foregroundColor(.white)
            .frame(width: 96, height: 96)
            .background(Color.white.opacity(0.16))
            .clipShape(Circle())
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

private enum TmdbBrowseGridMetrics {
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

private struct ProductionBrowseCard: View {
    let title: RelatedTitle
    let onSelect: () -> Void

    @FocusState private var isFocused: Bool
    @AppStorage(SettingsKey.posterLabels) private var posterLabels = false
    @AppStorage(SettingsKey.smoothFocus) private var smoothFocus = true
    @AppStorage(SettingsKey.focusHighlighter) private var focusHighlighter = false

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
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
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(
                            isFocused ? AppFocusOutline.color : .clear,
                            lineWidth: focusHighlighter ? AppFocusOutline.emphasizedWidth : AppFocusOutline.width
                        )
                )
                .shadow(
                    color: .black.opacity(isFocused ? 0.5 : 0.2),
                    radius: isFocused ? 16 : 6
                )

                if posterLabels {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title.name)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(isFocused ? .white : .white.opacity(0.78))
                            .lineLimit(1)
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
