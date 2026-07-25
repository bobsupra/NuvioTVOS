import Foundation

/// Fills the watch-progress ledger with realistic test history.
///
/// Exists to reproduce a large account locally — paging, the metadata budget and
/// the row cap only behave interestingly once there are far more titles than fit
/// on screen, and that is impractical to reach by actually watching things.
///
/// Two deliberate properties:
/// * Titles come from the device's own configured catalogs, so every id resolves
///   through the same add-ons real history would. Fabricated ids would fail
///   metadata lookup and test the wrong path.
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

    static private(set) var status = "not run"

    static var seededKeyCount: Int { seededKeys().count }

    /// Creates progress for up to `titles` distinct titles drawn from the Home
    /// catalogs. Returns the number of ledger rows written.
    @discardableResult
    static func seed(titles: Int = 90) async -> Int {
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

        var records: [WatchProgressRecord] = []
        var keys: Set<String> = seededKeys()
        // Stagger backwards from now so the row has a meaningful recency order
        // and paging has something to sort.
        var watchedAt = Date()

        for meta in picked {
            let isSeries = meta.isSeries
            let runtime = Double(Int.random(in: isSeries ? 1_320...2_760 : 5_400...8_400))

            if isSeries {
                let season = 1
                let episodeCount = Int.random(in: episodesPerSeries)
                for episode in 1...episodeCount {
                    watchedAt = watchedAt.addingTimeInterval(-Double(Int.random(in: 900...7_200)))
                    // Finish all but the last episode: a completed episode is what
                    // seeds a "Next Up" card, so this exercises both row kinds.
                    let isFinished = episode < episodeCount
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
                            lastWatchedAt: watchedAt,
                            isPendingPush: true
                        )
                    )
                }
            } else {
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
        status = uploaded
            ? "seeded \(records.count) row(s) across \(picked.count) title(s); uploaded to your account"
            : "seeded \(records.count) row(s) across \(picked.count) title(s); "
                + "upload pending — sync will retry"
        return records.count
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
