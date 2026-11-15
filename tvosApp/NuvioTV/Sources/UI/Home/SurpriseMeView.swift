import SwiftUI

/// The Surprise Me tab: one movie or series chosen for the viewer's tastes,
/// with a button to roll again. Configured in Settings > Integrations > Surprise Me.
///
/// Candidates come from the catalogs on Home and, when TMDB is on, from TMDB's
/// recommendations for the viewer's favourite titles and its well-rated movies
/// and series in their favourite genres. Settings decide whether it suggests
/// movies, series or both. Anything already watched, in Nuvio or a connected
/// tracker, is left out. With an AI key, the AI chooses among those candidates
/// and says why.
struct SurpriseMeView: View {
    @ObservedObject var homeStore: TVHomeStore
    let isActive: Bool
    let onOpenDetails: (NuvioMeta) -> Void

    @AppStorage(SettingsKey.amoled) private var amoled = false
    @AppStorage(SettingsKey.bodyColor) private var bodyColor = SettingsBackground.charcoal.rawValue
    @AppStorage(SettingsKey.surpriseMeUseTMDB) private var useTMDB = true
    @AppStorage(SettingsKey.surpriseMeUseTrackers) private var useTrackers = true
    @AppStorage(SettingsKey.surpriseMeContent) private var contentRaw = SurpriseMeContent.all.rawValue

    @State private var profile = TasteProfile.empty
    @State private var history = SurpriseMeHistory.empty
    /// TMDB candidates and queued AI picks, kept only for the profile, TMDB
    /// setting, history and kind of titles they were gathered for.
    @State private var pool = SurpriseMeCandidatePool()
    @State private var pick: NuvioMeta?
    @State private var pickReason: String?
    @State private var offered: Set<String> = []
    /// What the viewer did with earlier suggestions, kept across launches, so
    /// both the AI and the taste profile learn what lands and what doesn't.
    @State private var feedback = SurpriseMeFeedback()
    @State private var didLoad = false
    @State private var isThinking = false
    @State private var noMovieFound = false
    @State private var historySources: [String] = []

    private var content: SurpriseMeContent { SurpriseMeContent(rawValue: contentRaw) ?? .all }

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
            if useTrackers {
                // Bring the connected trackers up to date, then learn again.
                await SurpriseMeTrackers.refreshHistoriesIfNeeded()
                guard !Task.isCancelled else { return }
                refreshProfile()
            }
            syncPool()
            if pool.needsOnlineCandidates, let requested = pool.ticket {
                let fetched = await SurpriseMeOnline.candidates(history: history, profile: profile, content: content)
                // Ignored if the tab closed, TMDB was turned off, or the profile,
                // history or kind of titles changed while TMDB answered.
                guard !Task.isCancelled else { return }
                pool.accept(online: fetched, for: requested)
            }
        }
        .onChange(of: useTMDB) { _, _ in syncPool() }
        .onChange(of: contentRaw) { _, _ in syncPool() }
    }

    private var poolKey: SurpriseMeCandidatePool.Key {
        .init(
            profileScope: ProfileSettings.activeProfileScope,
            useTMDB: useTMDB,
            historySignature: history.signature,
            variant: content.rawValue
        )
    }

    /// Drops candidates and queued picks gathered for another profile, TMDB
    /// setting, history or kind of titles; on another profile, also what was
    /// shown and offered.
    private func syncPool() {
        let change = pool.prepare(for: poolKey)
        guard change != .unchanged else { return }
        noMovieFound = false
        guard change == .profileChanged else { return }
        pick = nil
        pickReason = nil
        offered = []
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
                Task { await roll(); if pick != nil { focus = .open } }
            } label: {
                if isThinking {
                    Label(L10n.string("surprise_me_thinking", fallback: "Thinking…"), systemImage: "sparkles")
                } else {
                    Label(L10n.string("nav_surprise_me", fallback: "Surprise Me"), systemImage: "sparkles")
                }
            }
            .disabled(isThinking)
            .focused($focus, equals: .surprise)
            if didLoad, noMovieFound {
                Text(L10n.string("surprise_me_empty", fallback: "Nothing unwatched found yet. Add catalogs or turn on TMDB."))
                    .font(.system(size: 22))
                    .foregroundColor(.white.opacity(0.65))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var learningLine: String {
        guard history.titleCount > 0 else {
            return L10n.string(
                "surprise_me_learning_empty",
                fallback: "Watch a few titles and the suggestions will follow your tastes. Until then, you get well-rated picks."
            )
        }
        guard !historySources.isEmpty else {
            return L10n.format(
                "surprise_me_learning_count",
                fallback: "Based on %d titles you watched or saved",
                history.titleCount
            )
        }
        return L10n.format(
            "surprise_me_learning_sources",
            fallback: "Based on %1$d titles you watched or saved, from %2$@",
            history.titleCount,
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
            Text(pickReason ?? reason(for: meta))
                .font(.system(size: 24, weight: .semibold))
                .foregroundColor(.white.opacity(0.75))
                .frame(maxWidth: 900, alignment: .leading)

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
                    remember(meta, .liked)
                    onOpenDetails(meta)
                } label: {
                    Label(L10n.string("surprise_me_open", fallback: "View"), systemImage: "play.fill")
                }
                .focused($focus, equals: .open)

                Button {
                    // Skipping counts only if they didn't open it first.
                    if feedback.verdict(for: meta) != .liked { remember(meta, .skipped) }
                    Task { await roll() }
                } label: {
                    Label(
                        isThinking
                            ? L10n.string("surprise_me_thinking", fallback: "Thinking…")
                            : L10n.string("surprise_me_another", fallback: "Another one"),
                        systemImage: "dice"
                    )
                }
                .disabled(isThinking)
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
        history = SurpriseMeHistory(
            watched: watched.map(\.meta),
            library: SurpriseMeLibraries.allItems(),
            continueWatching: ContinueWatchingStore.items().map(\.meta)
        )
        feedback = SurpriseMeFeedback.load()
        profile = TasteProfile.build(
            watched: history.watched,
            library: history.library,
            continueWatching: history.continueWatching,
            feedback: feedback
        )
        historySources = useTrackers ? SurpriseMeTrackers.sourceLabels(of: watched) : []
    }

    private var candidates: [NuvioMeta] {
        pool.candidates(home: homeStore.sections.flatMap(\.items))
    }

    private func roll() async {
        let isWatched: (NuvioMeta) -> Bool = { history.contains($0) || WatchedStore.contains(meta: $0) }

        syncPool()
        // AI picks wait in a queue, so "Another one" doesn't ask again each time.
        while let next = pool.nextQueuedPick() {
            guard !offered.contains(next.meta.id), !isWatched(next.meta), content.allows(next.meta) else { continue }
            show(next.meta, reason: next.reason.map { "✨ \($0)" })
            return
        }

        let configuration = SurpriseMeAIConfiguration.current()
        if configuration.isUsable {
            let shortlist = SurpriseMe.shortlist(
                from: candidates, profile: profile, isWatched: isWatched, excluding: offered,
                content: content, limit: SurpriseMeAI.maxCandidates
            )
            if let requested = pool.ticket {
                isThinking = true
                // Never offer again what was offered this session or skipped before.
                let excluded = offered.union(feedback.skipped.map(\.id))
                let picks = await SurpriseMeAI.rank(
                    candidates: shortlist,
                    context: SurpriseMeAIContext(profile: profile, history: history, feedback: feedback, content: content),
                    configuration: configuration,
                    language: Locale(identifier: "en").localizedString(forIdentifier: AppLocaleManager.shared.locale.identifier)
                        ?? "English",
                    isWatched: { meta in isWatched(meta) || excluded.contains(meta.id) }
                )
                isThinking = false
                // The profile, TMDB setting, history or kind of titles changed
                // while the AI answered.
                syncPool()
                guard pool.stillCurrent(requested) else { return }
                if let first = picks.first {
                    pool.accept(aiQueue: Array(picks.dropFirst()), for: requested)
                    show(first.meta, reason: first.reason.map { "✨ \($0)" })
                    return
                }
            }
        }

        guard let next = SurpriseMe.pick(
            from: candidates,
            profile: profile,
            isWatched: isWatched,
            excluding: offered,
            content: content
        ) else {
            noMovieFound = true
            return
        }
        show(next, reason: nil)
    }

    private func remember(_ meta: NuvioMeta, _ verdict: SurpriseMeFeedbackEntry.Verdict) {
        feedback.record(meta, verdict)
        feedback.save()
    }

    private func show(_ meta: NuvioMeta, reason: String?) {
        noMovieFound = false
        // Once everything was offered, start over but never repeat the current one.
        if offered.contains(meta.id) { offered = pick.map { [$0.id] } ?? [] }
        offered.insert(meta.id)
        pickReason = reason
        pick = meta
    }
}
