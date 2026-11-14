import SwiftUI

/// The Surprise Me tab: one movie from the catalogs on Home, chosen for the
/// viewer's tastes, with a button to roll again.
struct SurpriseMeView: View {
    @ObservedObject var homeStore: TVHomeStore
    let isActive: Bool
    let onOpenDetails: (NuvioMeta) -> Void

    @AppStorage(SettingsKey.amoled) private var amoled = false
    @AppStorage(SettingsKey.bodyColor) private var bodyColor = SettingsBackground.charcoal.rawValue

    @State private var profile = TasteProfile.empty
    @State private var pick: NuvioMeta?
    @State private var offered: Set<String> = []
    @State private var didLoad = false

    private enum FocusTarget: Hashable { case open, another }
    @FocusState private var focus: FocusTarget?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.nuvioBackground(amoled: amoled, body: bodyColor).ignoresSafeArea()

            if let pick {
                backdrop(for: pick)
                details(for: pick)
            } else {
                emptyState
            }
        }
        .task(id: isActive) {
            guard isActive else { return }
            refreshProfile()
            if pick == nil { roll() }
            didLoad = true
        }
        .onChange(of: homeStore.sectionsRevision) { _, _ in
            if isActive, pick == nil { roll() }
        }
    }

    private func backdrop(for meta: NuvioMeta) -> some View {
        ZStack {
            if let raw = TVHomeView.preferredBackdropURL(for: meta), let url = URL(string: raw) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Color.clear
                    }
                }
                .id(meta.id)
                .transition(.opacity)
            }
            LinearGradient(
                colors: [.black.opacity(0.85), .black.opacity(0.35), .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .center, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.5), value: meta.id)
    }

    private func details(for meta: NuvioMeta) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(reason(for: meta))
                .font(.system(size: 24, weight: .semibold))
                .foregroundColor(.white.opacity(0.7))

            Text(meta.name)
                .font(.system(size: 64, weight: .bold))
                .foregroundColor(.white)
                .lineLimit(2)

            Text(metaLine(for: meta))
                .font(.system(size: 26, weight: .medium))
                .foregroundColor(.white.opacity(0.8))

            if let description = meta.description, !description.isEmpty {
                Text(description)
                    .font(.system(size: 26))
                    .foregroundColor(.white.opacity(0.85))
                    .lineLimit(4)
                    .frame(maxWidth: 900, alignment: .leading)
            }

            HStack(spacing: 24) {
                Button {
                    onOpenDetails(meta)
                } label: {
                    Label(L10n.string("surprise_me_open", fallback: "View"), systemImage: "play.fill")
                }
                .focused($focus, equals: .open)

                Button {
                    roll()
                } label: {
                    Label(L10n.string("surprise_me_another", fallback: "Another one"), systemImage: "dice")
                }
                .focused($focus, equals: .another)
            }
            .padding(.top, 12)
        }
        .padding(.leading, 90)
        .padding(.bottom, 90)
        .focusSection()
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "dice")
                .font(.system(size: 72))
            Text(didLoad
                 ? L10n.string("surprise_me_empty", fallback: "No unwatched movies in your Home catalogs yet.")
                 : L10n.string("surprise_me_loading", fallback: "Finding something for you…"))
                .font(.system(size: 30, weight: .semibold))
        }
        .foregroundColor(.white.opacity(0.7))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func reason(for meta: NuvioMeta) -> String {
        let genres = profile.matchingGenres(for: meta)
        guard !genres.isEmpty else {
            return L10n.string("surprise_me_reason_popular", fallback: "Surprise Me · A well-rated pick")
        }
        return L10n.format(
            "surprise_me_reason_genres",
            fallback: "Surprise Me · Because you watch %@",
            genres.joined(separator: " & ")
        )
    }

    private func metaLine(for meta: NuvioMeta) -> String {
        var parts: [String] = []
        if let year = meta.year { parts.append(String(year)) }
        if let rating = meta.rating, rating > 0 { parts.append(String(format: "★ %.1f", rating)) }
        if let genres = meta.genres, !genres.isEmpty { parts.append(genres.prefix(3).joined(separator: ", ")) }
        return parts.joined(separator: "  ·  ")
    }

    private func refreshProfile() {
        profile = TasteProfile.build(
            watched: WatchedStore.items().map(\.meta),
            library: LibraryStore.items().map(\.meta),
            continueWatching: ContinueWatchingStore.items().map(\.meta)
        )
    }

    private func roll() {
        let candidates = homeStore.sections.flatMap(\.items)
        guard let next = SurpriseMe.pick(
            from: candidates,
            profile: profile,
            isWatched: { WatchedStore.contains(meta: $0) },
            excluding: offered
        ) else { return }
        // Once everything was offered, start over but never repeat the current one.
        if offered.contains(next.id) { offered = pick.map { [$0.id] } ?? [] }
        offered.insert(next.id)
        pick = next
    }
}
