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
    @State private var noMovieFound = false
    @State private var historyCount = 0
    @State private var historySources: [String] = []

    private enum FocusTarget: Hashable { case surprise, open, another }
    @FocusState private var focus: FocusTarget?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.nuvioBackground(amoled: amoled, body: bodyColor).ignoresSafeArea()

            if let pick {
                backdrop(for: pick)
                details(for: pick)
            } else {
                landing
            }
        }
        .task(id: isActive) {
            guard isActive else { return }
            refreshProfile()
            didLoad = true
            // Then bring the connected trackers up to date and learn again.
            await SurpriseMeTrackers.refreshHistoriesIfNeeded()
            guard !Task.isCancelled else { return }
            refreshProfile()
        }
    }

    /// The tab opens on a button, like the profile tab: nothing is suggested
    /// until the viewer asks for it.
    private var landing: some View {
        VStack(spacing: 24) {
            Image(systemName: "dice.fill")
                .font(.system(size: 120))
                .foregroundColor(.white.opacity(0.9))
            Text(L10n.string("nav_surprise_me", fallback: "Surprise Me"))
                .font(.title2.bold())
            Text(learningLine)
                .font(.system(size: 24))
                .foregroundColor(.white.opacity(0.65))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 900)
            Button {
                roll()
                if pick != nil { focus = .open }
            } label: {
                Label(L10n.string("nav_surprise_me", fallback: "Surprise Me"), systemImage: "sparkles")
            }
            .focused($focus, equals: .surprise)
            if didLoad, noMovieFound {
                Text(L10n.string("surprise_me_empty", fallback: "No unwatched movies in your Home catalogs yet."))
                    .font(.system(size: 22))
                    .foregroundColor(.white.opacity(0.65))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var learningLine: String {
        guard historyCount > 0 else {
            return L10n.string(
                "surprise_me_learning_empty",
                fallback: "Watch a few titles and the suggestions will follow your tastes. Until then, you get well-rated picks."
            )
        }
        guard !historySources.isEmpty else {
            return L10n.format(
                "surprise_me_learning_count",
                fallback: "Based on %d titles you watched or saved",
                historyCount
            )
        }
        return L10n.format(
            "surprise_me_learning_sources",
            fallback: "Based on %1$d titles you watched or saved, from %2$@",
            historyCount,
            historySources.joined(separator: ", ")
        )
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
        // One history: what was watched in Nuvio and in every connected tracker.
        let watched = WatchedStore.items()
        let library = LibraryStore.items().map(\.meta)
        let continueWatching = ContinueWatchingStore.items().map(\.meta)
        profile = TasteProfile.build(
            watched: watched.map(\.meta),
            library: library,
            continueWatching: continueWatching
        )
        historyCount = Set((watched.map(\.meta) + library + continueWatching).map { $0.imdbId ?? $0.id }).count
        historySources = SurpriseMeTrackers.sourceLabels(of: watched)
    }

    private func roll() {
        let candidates = homeStore.sections.flatMap(\.items)
        guard let next = SurpriseMe.pick(
            from: candidates,
            profile: profile,
            isWatched: { WatchedStore.contains(meta: $0) },
            excluding: offered
        ) else {
            noMovieFound = true
            return
        }
        noMovieFound = false
        // Once everything was offered, start over but never repeat the current one.
        if offered.contains(next.id) { offered = pick.map { [$0.id] } ?? [] }
        offered.insert(next.id)
        pick = next
    }
}
