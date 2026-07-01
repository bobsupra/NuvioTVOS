import SwiftUI

/// Embeddable Discover section — a filterable poster grid (type / sort / genre)
/// backed by Cinemeta. Hosted inside the Search tab below the search bar.
/// The host provides the outer title, padding and background.
struct DiscoverSection: View {
    let onContentClick: (String, String) -> Void
    @StateObject private var viewModel = DiscoverViewModel()

    init(onContentClick: @escaping (String, String) -> Void) {
        self.onContentClick = onContentClick
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            filterBar
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    // MARK: - Filters (dropdown menus)

    private var filterBar: some View {
        HStack(spacing: 16) {
            FilterMenu(label: viewModel.type.title) {
                ForEach(DiscoverType.allCases) { type in
                    Button { viewModel.setType(type) } label: {
                        menuItem(type.title, selected: viewModel.type == type)
                    }
                }
            }

            FilterMenu(label: viewModel.sort.title) {
                ForEach(DiscoverSort.allCases) { sort in
                    Button { viewModel.setSort(sort) } label: {
                        menuItem(sort.title, selected: viewModel.sort == sort)
                    }
                }
            }

            FilterMenu(label: viewModel.genre ?? "All Genres") {
                Button { viewModel.setGenre(nil) } label: {
                    menuItem("All Genres", selected: viewModel.genre == nil)
                }
                ForEach(viewModel.genres, id: \.self) { genre in
                    Button { viewModel.setGenre(genre) } label: {
                        menuItem(genre, selected: viewModel.genre == genre)
                    }
                }
            }
        }
    }

    private func menuItem(_ title: String, selected: Bool) -> some View {
        Text(selected ? "✓  \(title)" : title)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading {
            centered { ProgressView().scaleEffect(1.6).tint(.white) }
        } else if let error = viewModel.error, viewModel.items.isEmpty {
            centered {
                message(icon: "wifi.exclamationmark", title: error)
            }
        } else if viewModel.items.isEmpty {
            centered {
                message(icon: "rectangle.on.rectangle.slash",
                        title: "Nothing here",
                        subtitle: "Try a different genre or category.")
            }
        } else {
            grid
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 44) {
                ForEach(viewModel.items) { item in
                    DiscoverCard(meta: item) {
                        onContentClick(item.id, item.type)
                    }
                    .onAppear { viewModel.loadMoreIfNeeded(currentItem: item) }
                }
            }
            .padding(.top, 16)
            .padding(.horizontal, 12)

            if viewModel.isLoadingMore {
                ProgressView()
                    .tint(.white)
                    .padding(.vertical, 28)
            }

            Color.clear.frame(height: 60)
        }
        .scrollClipDisabledIfAvailable()
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 210, maximum: 230), spacing: 36, alignment: .top)]
    }

    private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack {
            Spacer(minLength: 40)
            content()
            Spacer(minLength: 40)
        }
        .frame(maxWidth: .infinity)
    }

    private func message(icon: String, title: String, subtitle: String? = nil) -> some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 64, weight: .light))
                .foregroundColor(.white.opacity(0.4))
            Text(title)
                .font(.system(size: 28, weight: .semibold))
                .foregroundColor(.white.opacity(0.8))
                .multilineTextAlignment(.center)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 22))
                    .foregroundColor(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: 700)
    }
}

// MARK: - Filter dropdown

/// A glass chip that opens a dropdown menu of options. Falls back to a static
/// chip on tvOS < 17 (where `Menu` is unavailable). Shared by Discover & Library.
struct FilterMenu<MenuContent: View>: View {
    let label: String
    @ViewBuilder var menu: () -> MenuContent
    @State private var showOptions = false
    @FocusState private var focused: Bool

    var body: some View {
        Button { showOptions = true } label: { chipLabel }
            .buttonStyle(PosterCardButtonStyle())
            .focused($focused)
            .focusEffectDisabledIfAvailable()
            .scaleEffect(focused ? 1.05 : 1.0)
            .animation(.easeOut(duration: 0.14), value: focused)
            .confirmationDialog(label, isPresented: $showOptions, titleVisibility: .visible, actions: menu)
    }

    private var chipLabel: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 24, weight: .semibold))
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 18, weight: .semibold))
        }
        .foregroundColor(.white.opacity(focused ? 1.0 : 0.9))
        .padding(.horizontal, 28)
        .frame(height: 60)
        .modifier(GlassChipBackground(filled: false))
        .overlay(
            Capsule()
                .strokeBorder(Color.white.opacity(focused ? 0.86 : 0), lineWidth: focused ? 3 : 0)
        )
    }
}

// MARK: - Card

private struct DiscoverCard: View {
    let meta: NuvioMeta
    let action: () -> Void
    @FocusState private var focused: Bool
    @AppStorage(SettingsKey.posterLabels) private var posterLabels = false
    @AppStorage(SettingsKey.smoothFocus) private var smoothFocus = true
    @AppStorage(SettingsKey.focusHighlighter) private var focusHighlighter = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                ZStack(alignment: .bottom) {
                    AsyncImage(url: URL(string: meta.posterUrl ?? "")) { phase in
                        if case .success(let image) = phase {
                            image.resizable().aspectRatio(contentMode: .fill)
                        } else {
                            ZStack {
                                Rectangle().fill(Color.white.opacity(0.07))
                                Image(systemName: meta.type == "series" ? "tv" : "film")
                                    .font(.system(size: 40))
                                    .foregroundColor(.white.opacity(0.25))
                            }
                        }
                    }
                    .frame(width: 210, height: 315)

                    if metaLine != nil {
                        LinearGradient(
                            colors: [.clear, .black.opacity(0.85)],
                            startPoint: .center,
                            endPoint: .bottom
                        )
                        .frame(height: 120)
                        .frame(maxWidth: .infinity, alignment: .bottom)

                        if let metaLine {
                            Text(metaLine)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.white.opacity(0.95))
                                .lineLimit(1)
                                .padding(.horizontal, 12)
                                .padding(.bottom, 10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(width: 210, height: 315)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    WatchedCheckmarkBadge(metaId: meta.id, type: meta.type)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(focused ? focusBorderColor : .clear, lineWidth: focusHighlighter ? 5 : 3)
                )
                .shadow(color: .black.opacity(focused ? 0.5 : 0.2), radius: focused ? 16 : 6)

                if posterLabels {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(meta.name)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(focused ? .white : .white.opacity(0.78))
                            .lineLimit(1)
                        if let year = meta.year {
                            Text(String(year))
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(.white.opacity(0.45))
                        }
                    }
                    .frame(width: 210, alignment: .leading)
                }
            }
            .scaleEffect(focused ? 1.06 : 1.0)
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($focused)
        .focusEffectDisabledIfAvailable()
        .animation(smoothFocus ? .spring(response: 0.28, dampingFraction: 0.75) : nil, value: focused)
    }

    /// "Genre · ★ Rating" overlay, omitting whichever piece is missing.
    private var metaLine: String? {
        var parts: [String] = []
        if let genre = meta.genres?.first, !genre.isEmpty { parts.append(genre) }
        if let rating = meta.rating, rating > 0 { parts.append(String(format: "★ %.1f", rating)) }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }

    private var focusBorderColor: Color {
        .white.opacity(0.86)
    }
}
