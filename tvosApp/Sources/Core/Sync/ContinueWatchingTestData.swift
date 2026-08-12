import Foundation

/// Fills the watch-progress ledger with realistic test history.
///
/// Exists to reproduce a large account locally — paging, the metadata budget and
/// the row cap only behave interestingly once there are far more titles than fit
/// on screen, and that is impractical to reach by actually watching things.
///
/// Three deliberate properties:
/// * Titles come from the device's own configured catalogs, so every id resolves
///   through the same add-ons real history would. Fabricated ids would fail
///   metadata lookup and test the wrong path.
/// * Series are shaped so the row draws every card kind it has: resume progress,
///   "Next Up", "New Episode", "New Season" and "Airs <date>". Movies only ever resume, so they
///   come out of the pick as-is. Shaping matters because the kinds take different
///   paths through the builder — a seed made only of resume progress leaves the
///   Next Up path, the episode guide lookup and the unaired policy untested.
/// * Every row is written with `isPendingPush: true` and pushed, so the seeded
///   history reaches the account and the user's other devices — which is the
///   point: a seed only reproduces a large account if the other clients see it
///   too. `pushWatchProgress` filters on that flag, so a row left unflagged
///   stays stranded on the seeding device. `clear()` retires the same rows
///   remotely before removing them locally.
@MainActor
enum ContinueWatchingTestData {
    /// Progress keys this seeder created, so removal takes back exactly what it
    /// added and never touches genuine history.
    private static let markerKey = "nuvio.tv.continueWatching.testData.keys.v1"

    /// Roughly matches the shape of the large account this was built to mimic:
    /// a few episodes per series rather than one row per title.
    private static let episodesPerSeries = 2...5

    /// Episode guides the shaping pass may load. The unaired and just-aired
    /// shapes have to stop on a real episode, and only the guide says which one
    /// that is — a catalog entry carries no episode list. Bounded because most
    /// titles have finished airing and cannot carry those shapes at all, so an
    /// unbounded scan would spend a request per series to find the few that can.
    private static let guideScanBudget = 32
    private static let guideScanConcurrency = 4

    /// What a seeded series should end up rendering as.
    private enum SeriesShape {
        /// Newest episode left partway through — a resume card.
        case inProgress
        /// Every seeded episode finished, counted from the start of season 1, so
        /// whatever follows becomes a plain "Next Up" card.
        case nextUp
        /// Finished through a real episode whose successor has not aired.
        case comingSoon(season: Int, episode: Int)
        /// Finished through a real episode whose successor aired recently enough
        /// to be badged "New Episode" — or "New Season", when that successor also
        /// opens a later season (`startsNewSeason`). `airedAt` is the successor's
        /// release date: the badge also requires the seeding episode to have been
        /// watched before the drop, so the seeded history has to be dated against
        /// it.
        case newEpisode(season: Int, episode: Int, airedAt: Date, startsNewSeason: Bool)

        /// The last episode to mark watched, when the guide chose it.
        var watchThrough: (season: Int, episode: Int)? {
            switch self {
            case .inProgress, .nextUp:
                return nil
            case let .comingSoon(season, episode), let .newEpisode(season, episode, _, _):
                return (season, episode)
            }
        }

        /// The latest the seeding episode may be marked watched for this shape to
        /// render as intended — a day before the successor aired.
        var seedWatchedBefore: Date? {
            guard case let .newEpisode(_, _, airedAt, _) = self else { return nil }
            return airedAt.addingTimeInterval(-86_400)
        }

        var label: String {
            switch self {
            case .inProgress: return "resuming"
            case .nextUp: return "next up"
            case let .newEpisode(_, _, _, startsNewSeason):
                return startsNewSeason ? "new season" : "new episode"
            case .comingSoon: return "airing soon"
            }
        }
    }

    /// The shape aimed for before the guide has a say, cycled across the picked
    /// series so the newest rows — the ones that land on the first page — show a
    /// mix rather than a block of one kind.
    private enum SeriesGoal: CaseIterable {
        case inProgress
        case nextUp
        case comingSoon
        case newEpisode
        case newSeason

        var needsGuide: Bool {
            switch self {
            case .comingSoon, .newEpisode, .newSeason: return true
            case .inProgress, .nextUp: return false
            }
        }
    }

    /// Summary order for the status line; movies first because they are the one
    /// kind that needs no shaping.
    private static let mixOrder = [
        "movies", "resuming", "next up", "new episode", "new season", "airing soon"
    ]

    static private(set) var status = "not run"

    static var seededKeyCount: Int { seededKeys().count }

    /// Creates progress for up to `titles` distinct titles drawn from the Home
    /// catalogs. Returns the number of ledger rows written.
    @discardableResult
    static func seed(titles: Int = 200) async -> Int {
        status = "loading catalogs…"
        let repository = CinemetaCatalogRepository()
        let catalogs: [NuvioCatalog]
        do {
            catalogs = try await repository.getHomeCatalogs()
        } catch {
            status = "failed: could not load catalogs (\(error.localizedDescription))"
            return 0
        }

        // Interleave catalogs so the sample spans genres and both content types
        // instead of taking one row's worth of near-identical titles.
        var pools = catalogs.compactMap { catalog -> [NuvioMeta]? in
            guard let items = catalog.items, !items.isEmpty else { return nil }
            return items
        }
        guard !pools.isEmpty else {
            status = "failed: catalogs contained no items"
            return 0
        }

        var picked: [NuvioMeta] = []
        var seenIds: Set<String> = []
        var poolIndex = 0
        var exhausted = 0
        while picked.count < titles, exhausted < pools.count {
            defer { poolIndex = (poolIndex + 1) % pools.count }
            guard !pools[poolIndex].isEmpty else {
                exhausted += 1
                continue
            }
            exhausted = 0
            let meta = pools[poolIndex].removeFirst()
            guard seenIds.insert(meta.id).inserted else { continue }
            picked.append(meta)
        }

        guard !picked.isEmpty else {
            status = "failed: no usable titles in catalogs"
            return 0
        }

        let shapes = await seriesShapes(for: picked, repository: repository)

        var records: [WatchProgressRecord] = []
        var keys: Set<String> = seededKeys()
        var mix: [String: Int] = [:]
        // Stagger backwards from now so the row has a meaningful recency order
        // and paging has something to sort.
        var watchedAt = Date()

        for meta in picked {
            let isSeries = meta.isSeries
            let runtime = Double(Int.random(in: isSeries ? 1_320...2_760 : 5_400...8_400))

            if isSeries {
                let shape = shapes[meta.id] ?? .inProgress
                mix[shape.label, default: 0] += 1
                let episodeCount = Int.random(in: episodesPerSeries)
                // A guide-backed shape stops on a specific real episode; the
                // others are free to count from the start of season 1.
                let season = shape.watchThrough?.season ?? 1
                let lastEpisode = shape.watchThrough?.episode ?? episodeCount
                let firstEpisode = max(1, lastEpisode - episodeCount + 1)
                // A "New Episode" drop is only news if it aired after the
                // seeding episode was watched, so this shape's rows are pulled
                // back ahead of the drop. The shared stagger keeps advancing
                // untouched, so backdating one series does not cost the rest of
                // the seed its recency spread.
                let seedCeiling = shape.seedWatchedBefore

                // Newest episode first, so the series' most recent record is the
                // one the row keys off: the unfinished episode for a resume card,
                // the last finished one for every other shape.
                for episode in stride(from: lastEpisode, through: firstEpisode, by: -1) {
                    watchedAt = watchedAt.addingTimeInterval(-Double(Int.random(in: 900...7_200)))
                    // Both terms descend as the loop walks backwards through the
                    // season, so the series keeps its newest-episode-first order
                    // either way.
                    let recordWatchedAt = seedCeiling.map { ceiling in
                        min(watchedAt, ceiling.addingTimeInterval(-3_600 * Double(lastEpisode - episode)))
                    } ?? watchedAt
                    // Only the in-progress shape leaves something unfinished. The
                    // others finish everything, which is what makes the builder
                    // draw a Next Up card instead of resume progress — a series
                    // with any episode still in progress outranks its own seed.
                    let isFinished: Bool
                    if case .inProgress = shape {
                        isFinished = episode < lastEpisode
                    } else {
                        isFinished = true
                    }
                    let position = isFinished
                        ? runtime
                        : runtime * Double.random(in: 0.08...0.75)
                    let key = WatchProgressLedger.progressKey(
                        contentId: meta.id,
                        season: season,
                        episode: episode
                    )
                    keys.insert(key)
                    records.append(
                        WatchProgressRecord(
                            progressKey: key,
                            contentId: meta.id,
                            contentType: "series",
                            videoId: WatchProgressLedger.videoId(
                                contentId: meta.id,
                                season: season,
                                episode: episode
                            ),
                            season: season,
                            episode: episode,
                            position: position,
                            duration: runtime,
                            lastWatchedAt: recordWatchedAt,
                            isPendingPush: true
                        )
                    )
                }
            } else {
                mix["movies", default: 0] += 1
                watchedAt = watchedAt.addingTimeInterval(-Double(Int.random(in: 900...7_200)))
                let key = WatchProgressLedger.progressKey(
                    contentId: meta.id,
                    season: nil,
                    episode: nil
                )
                keys.insert(key)
                records.append(
                    WatchProgressRecord(
                        progressKey: key,
                        contentId: meta.id,
                        contentType: "movie",
                        videoId: meta.id,
                        season: nil,
                        episode: nil,
                        position: runtime * Double.random(in: 0.08...0.75),
                        duration: runtime,
                        lastWatchedAt: watchedAt,
                        isPendingPush: true
                    )
                )
            }
        }

        guard WatchProgressLedger.mergeRemote(records) else {
            status = "failed: could not write the ledger"
            return 0
        }
        UserDefaults.standard.set(Array(keys), forKey: markerKey)

        await ContinueWatchingBuilder.rebuild(reason: "test data seeded")
        let uploaded = await NuvioSyncManager.current?.pushWatchProgressNow() ?? false
        // The mix is the point of the shaping pass, so report it: it is the only
        // way to tell a seed that produced every card kind from one that quietly
        // fell back to resume rows because no guide would load.
        let summary = mixOrder
            .compactMap { label in mix[label].map { "\($0) \(label)" } }
            .joined(separator: ", ")
        status = "seeded \(records.count) row(s) across \(picked.count) title(s) "
            + "(\(summary)); "
            + (uploaded ? "uploaded to your account" : "upload pending — sync will retry")
        return records.count
    }

    // MARK: - Shaping

    /// Decides what each seeded series should render as.
    ///
    /// The guide-backed shapes are resolved up front because they cost a network
    /// round trip each, and a show that cannot carry one — it finished airing, or
    /// its guide would not load — falls back to a plain Next Up rather than
    /// costing the seed a title.
    private static func seriesShapes(
        for picked: [NuvioMeta],
        repository: CatalogRepository
    ) async -> [String: SeriesShape] {
        let series = picked.filter(\.isSeries)
        guard !series.isEmpty else { return [:] }

        var goals: [String: SeriesGoal] = [:]
        var scanIds: [String] = []
        for (index, meta) in series.enumerated() {
            let goal = SeriesGoal.allCases[index % SeriesGoal.allCases.count]
            goals[meta.id] = goal
            if goal.needsGuide, scanIds.count < guideScanBudget {
                scanIds.append(meta.id)
            }
        }

        let guides = await fetchGuides(ids: scanIds, repository: repository)

        var shapes: [String: SeriesShape] = [:]
        for meta in series {
            let guide = guides[meta.id]
            switch goals[meta.id] ?? .nextUp {
            case .inProgress:
                shapes[meta.id] = .inProgress
            case .nextUp:
                shapes[meta.id] = .nextUp
            case .comingSoon:
                shapes[meta.id] = guide
                    .flatMap { upcomingTarget(in: $0) }
                    .map { SeriesShape.comingSoon(season: $0.season, episode: $0.episode) }
                    ?? SeriesShape.nextUp
            case .newEpisode, .newSeason:
                let startsNewSeason = goals[meta.id] == .newSeason
                shapes[meta.id] = guide
                    .flatMap { recentlyAiredTarget(in: $0, startingNewSeason: startsNewSeason) }
                    .map {
                        SeriesShape.newEpisode(
                            season: $0.season,
                            episode: $0.episode,
                            airedAt: $0.airedAt,
                            startsNewSeason: startsNewSeason
                        )
                    }
                    ?? SeriesShape.nextUp
            }
        }
        return shapes
    }

    /// Loads episode guides a few at a time. `refreshMetadata` rather than
    /// `getMetadata` because a catalog entry carries no episode list, and picking
    /// a real episode to stop on is the entire point of the lookup.
    private static func fetchGuides(
        ids: [String],
        repository: CatalogRepository
    ) async -> [String: NuvioMeta] {
        guard !ids.isEmpty else { return [:] }
        var resolved: [String: NuvioMeta] = [:]
        var completed = 0

        await withTaskGroup(of: (String, NuvioMeta?).self) { group in
            var index = 0
            var inFlight = 0

            func addNext() {
                guard index < ids.count else { return }
                let id = ids[index]
                index += 1
                inFlight += 1
                group.addTask {
                    (id, try? await repository.refreshMetadata(id: id, type: "series"))
                }
            }

            for _ in 0..<min(guideScanConcurrency, ids.count) { addNext() }
            while inFlight > 0 {
                guard let (id, meta) = await group.next() else { break }
                inFlight -= 1
                completed += 1
                if let meta { resolved[id] = meta }
                status = "reading episode guides (\(completed)/\(ids.count))…"
                addNext()
            }
        }
        return resolved
    }

    /// The episode to finish so the one after it has not aired — an "Airs …"
    /// card. `hasAired` reads a missing date as aired, so this only matches a
    /// real future date. The unaired episode has to sit in the same season as the
    /// watched one: an unaired *season premiere* is surfaced only within a week
    /// of it, so a rollover would seed a card that comes and goes with the
    /// calendar instead of one that is reliably there.
    private static func upcomingTarget(in meta: NuvioMeta) -> (season: Int, episode: Int)? {
        let episodes = sortedEpisodes(in: meta)
        guard let index = episodes.firstIndex(where: { !EpisodeReleasePolicy.hasAired($0.released) }),
              index > 0,
              episodes[index].season == episodes[index - 1].season else { return nil }
        return (episodes[index - 1].season, episodes[index - 1].episode)
    }

    /// The episode to finish so the one after it aired recently enough to be
    /// badged "New Episode" rather than a plain "Next Up", plus that successor's
    /// release date — the badge is withheld unless the seeding episode was
    /// watched before the drop, so the caller has to date its history from here.
    ///
    /// `startingNewSeason` asks for the successor to open a later season instead,
    /// which is what earns "New Season". Far fewer shows can carry that — the
    /// premiere has to be the recent one — so it falls back to a plain Next Up
    /// more often, the same way the unaired shape does.
    private static func recentlyAiredTarget(
        in meta: NuvioMeta,
        startingNewSeason: Bool
    ) -> (season: Int, episode: Int, airedAt: Date)? {
        let episodes = sortedEpisodes(in: meta)
        guard let index = episodes.lastIndex(where: {
            EpisodeReleasePolicy.isRecentlyReleased(
                $0.released,
                within: EpisodeReleasePolicy.newEpisodeWindowDays
            )
        }), index > 0 else { return nil }
        let crossesSeason = episodes[index].season != episodes[index - 1].season
        guard crossesSeason == startingNewSeason,
              let airedAt = EpisodeReleasePolicy.releaseDate(for: episodes[index].released) else { return nil }
        return (episodes[index - 1].season, episodes[index - 1].episode, airedAt)
    }

    /// Aired order, specials excluded — the same ordering the builder walks when
    /// it looks for the next episode.
    private static func sortedEpisodes(in meta: NuvioMeta) -> [NuvioVideo] {
        (meta.videos ?? [])
            .filter { $0.season > 0 }
            .sorted { ($0.season, $0.episode) < ($1.season, $1.episode) }
    }

    /// Removes only what `seed` created, on the account as well as this device.
    @discardableResult
    static func clear() async -> Int {
        let keys = seededKeys()
        guard !keys.isEmpty else {
            status = "nothing to remove"
            return 0
        }

        // Retire the rows on the account first. Removing locally while the
        // server still holds them would simply invite the next pull to restore
        // them, leaving fabricated history stuck on the account.
        let removedRemotely = await NuvioSyncManager.current?.deleteRemoteWatchProgress(
            keys: Array(keys)
        ) ?? false
        guard removedRemotely else {
            status = "kept: could not reach your account to delete them. "
                + "Removing locally now would let the next sync restore them — try again when online."
            return 0
        }

        WatchProgressLedger.remove(keys: Array(keys))
        UserDefaults.standard.removeObject(forKey: markerKey)
        await ContinueWatchingBuilder.rebuild(reason: "test data cleared")
        status = "removed \(keys.count) seeded row(s) from this Apple TV and your account"
        return keys.count
    }

    private static func seededKeys() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: markerKey) ?? [])
    }
}
