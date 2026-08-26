import Foundation

/// One synced watch-progress row, exactly as Nuvio Sync stores it.
///
/// Deliberately carries no metadata and no display state. The phone app keeps
/// the same shape (`WatchProgressEntry` minus its local-only presentation
/// fields), and the wire format in `sync_pull_watch_progress` is a direct
/// mapping of these properties.
struct WatchProgressRecord: Codable, Equatable, Identifiable {
    var id: String { progressKey }

    /// Server row identity: `id` for movies, `id_s{season}e{episode}` for
    /// episodes. Matches `progressKeyForEntry` in the phone app so both
    /// platforms upsert the same row instead of forking parallel ones.
    let progressKey: String
    let contentId: String
    /// Normalised to `movie` / `series`.
    let contentType: String
    /// `id` for movies, `id:{season}:{episode}` for episodes.
    let videoId: String
    let season: Int?
    let episode: Int?
    /// Seconds watched.
    let position: Double
    /// Seconds of runtime, or `0` when the writer never learned it. The phone
    /// stores duration-less rows (it falls back to an explicit percentage), so
    /// they arrive here and must survive — discarding them is what used to make
    /// recently-watched titles vanish from this device.
    let duration: Double
    let lastWatchedAt: Date
    /// Written on this Apple TV and not yet confirmed by a push. A pending row
    /// outranks anything the server sends back, so a pull that races a local
    /// save cannot roll playback backwards.
    var isPendingPush: Bool

    init(
        progressKey: String,
        contentId: String,
        contentType: String,
        videoId: String,
        season: Int?,
        episode: Int?,
        position: Double,
        duration: Double,
        lastWatchedAt: Date,
        isPendingPush: Bool = false
    ) {
        self.progressKey = progressKey
        self.contentId = contentId
        self.contentType = contentType
        self.videoId = videoId
        self.season = season
        self.episode = episode
        self.position = position
        self.duration = duration
        self.lastWatchedAt = lastWatchedAt
        self.isPendingPush = isPendingPush
    }

    var isEpisode: Bool { season != nil && episode != nil }

    var isSeries: Bool { WatchProgressLedger.isSeriesType(contentType) }
}

/// Durable, per-profile store of raw watch progress.
///
/// This is the source of truth for what the account has watched.
/// `ContinueWatchingStore` is a *derived* view over it: rows that cannot be
/// rendered yet (metadata still unresolved, add-ons not loaded) stay here and
/// are retried, instead of being dropped during the sync pull.
enum WatchProgressLedger {
    static let changedNotification = Notification.Name("nuvio.tv.watchProgress.ledger.changed")

    private static let baseKey = "nuvio.tv.watchProgress.ledger.v1"
    /// Guards the one-time movie re-push recovery, per profile.
    private static let movieRepushFlagKey = "nuvio.tv.watchProgress.ledger.movieRepush.v1"
    private static let storageDirectoryName = "WatchProgressLedger"
    /// Generous: rows are ~150 bytes with no metadata attached. The ledger now
    /// lives in a file rather than preferences, so this bounds unchecked growth
    /// rather than the tvOS preferences limit.
    private static let maxRecords = 2000

    /// Matches the phone's `CompletionThresholdFraction`. Both platforms must
    /// agree or a title reappears on one device after the other retires it.
    static let completionFraction = 0.90

    private(set) static var activeProfileId: String?

    /// Decoded rows for `cachedKey`. Playback saves progress every few seconds,
    /// and each one would otherwise decode and re-encode the whole ledger.
    private static var cachedRecords: [WatchProgressRecord]?
    private static var cachedKey: String?

    static func setActiveProfile(_ profileId: String?) {
        activeProfileId = profileId
        invalidateCache()
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }

    private static func invalidateCache() {
        cachedRecords = nil
        cachedKey = nil
    }

    private static var storageKey: String {
        guard let id = activeProfileId, !id.isEmpty else { return baseKey }
        return "\(baseKey).\(id)"
    }

    /// Shared by the recovery and by ``eraseProfile(_:)``: the two must agree on
    /// the key or an erase silently fails to clear the flag it is aiming at.
    private static func repushFlagKey(for profileId: String?) -> String {
        let id = profileId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return "\(movieRepushFlagKey).\(id.isEmpty ? "default" : id)"
    }

    // MARK: - Storage

    static func records() -> [WatchProgressRecord] {
        let key = storageKey
        if cachedKey == key, let cachedRecords {
            return cachedRecords
        }
        guard let data = storedData(forKey: key),
              let decoded = try? JSONDecoder().decode([WatchProgressRecord].self, from: data) else {
            cachedRecords = []
            cachedKey = key
            return []
        }
        cachedRecords = decoded
        cachedKey = key
        return decoded
    }

    /// File first, then the preferences key older builds wrote. A legacy payload
    /// is moved across on first read so it stops counting against the tvOS
    /// preferences budget — see ``LargePayloadStore``.
    private static func storedData(forKey key: String) -> Data? {
        if let data = LargePayloadStore.read(key: key, directory: storageDirectoryName) {
            return data
        }
        guard let legacy = UserDefaults.standard.data(forKey: key) else { return nil }
        if LargePayloadStore.write(legacy, key: key, directory: storageDirectoryName) {
            UserDefaults.standard.removeObject(forKey: key)
        }
        return legacy
    }

    static func record(forKey key: String) -> WatchProgressRecord? {
        records().first { $0.progressKey == key }
    }

    static func record(contentId: String, season: Int?, episode: Int?) -> WatchProgressRecord? {
        record(forKey: progressKey(contentId: contentId, season: season, episode: episode))
    }

    /// Newest row for a title, regardless of which episode it belongs to.
    static func latestRecord(contentId: String) -> WatchProgressRecord? {
        records()
            .filter { $0.contentId == contentId }
            .max { $0.lastWatchedAt < $1.lastWatchedAt }
    }

    @discardableResult
    static func upsert(_ record: WatchProgressRecord) -> Bool {
        var current = records().filter { $0.progressKey != record.progressKey }
        current.append(record)
        return persist(current)
    }

    @discardableResult
    static func remove(keys: [String]) -> Bool {
        guard !keys.isEmpty else { return true }
        let removing = Set(keys)
        let remaining = records().filter { !removing.contains($0.progressKey) }
        guard remaining.count != records().count else { return true }
        return persist(remaining)
    }

    /// Retires every row for a title — used when the user clears a card or the
    /// title is marked watched outright.
    @discardableResult
    static func removeContent(id: String) -> Bool {
        let remaining = records().filter { $0.contentId != id }
        return persist(remaining)
    }

    /// Applies a server snapshot without ever discarding a row.
    ///
    /// Rows are merged by `progressKey` and the newer `lastWatchedAt` wins. A
    /// local row awaiting a push only survives while it is genuinely the fresher
    /// of the two — mirroring `shouldPreserveLocalWatchProgressEntry` in the
    /// phone app. Preserving a pending row unconditionally would let stale local
    /// history (a backfill from an older install, say) overwrite progress the
    /// user has since made on their phone.
    @discardableResult
    static func mergeRemote(_ remote: [WatchProgressRecord]) -> Bool {
        guard !remote.isEmpty else { return true }
        return persist(Array(merged(remote, into: records()).values))
    }

    /// Applies an account snapshot as authoritative, deletions included.
    ///
    /// `sync_pull_watch_progress` returns the profile's entire current state, so
    /// a row removed on another device is expressed only as an *absence* — there
    /// is no delete flag to act on. ``mergeRemote(_:)`` unions and therefore can
    /// never represent that, which left a title deleted on the phone sitting in
    /// Continue Watching on this Apple TV forever.
    ///
    /// Absence only means deletion for rows the server is known to have seen. A
    /// row still awaiting its push, or written while this pull was in flight, is
    /// missing for a reason that is not a deletion and is kept.
    ///
    /// Returns the keys actually dropped so the caller can clear the *rendered*
    /// list too: emptying the ledger makes ``ContinueWatchingBuilder/rebuild``
    /// bail before it replaces the derived rows, which would otherwise strand
    /// the card for the title that was just deleted.
    static func reconcileRemote(
        _ remote: [WatchProgressRecord],
        syncStartedAt: Date
    ) -> (saved: Bool, removedKeys: [String], didChange: Bool) {
        // A zero-row response is ambiguous: it can mean the account was
        // intentionally cleared, but it can also be a transient/backend/profile
        // mismatch. Never turn that ambiguity into destructive local data loss.
        // Explicit removals are still reconciled from non-empty snapshots.
        guard !remote.isEmpty else {
            return (true, [], false)
        }

        let byKey = merged(remote, into: records())
        let remoteKeys = Set(remote.map(\.progressKey))

        var survivors: [WatchProgressRecord] = []
        var removedKeys: [String] = []
        for record in byKey.values {
            if remoteKeys.contains(record.progressKey)
                || record.isPendingPush
                || record.lastWatchedAt > syncStartedAt {
                survivors.append(record)
            } else {
                removedKeys.append(record.progressKey)
            }
        }

        // A refresh that did not change the merged ledger (the common case on
        // a background pull of an account that has been quiet) must not
        // re-encode and rewrite the whole 500+ row payload on disk. Compare
        // value-by-value under each key: `survivors` comes from a dictionary
        // so its order is unspecified, while `records()` is in stored file
        // order, and a same-key new row must still persist.
        let currentByKey = Dictionary(
            records().map { ($0.progressKey, $0) },
            uniquingKeysWith: { _, newer in newer }
        )
        let survivorByKey = Dictionary(
            survivors.map { ($0.progressKey, $0) },
            uniquingKeysWith: { _, newer in newer }
        )
        if currentByKey == survivorByKey {
            return (true, removedKeys, false)
        }
        return (persist(survivors), removedKeys, true)
    }

    /// Remote rows layered onto local ones by `progressKey`, newer wins. A local
    /// row still awaiting its push outranks an older server copy so a pull that
    /// races a save cannot roll playback backwards.
    private static func merged(
        _ remote: [WatchProgressRecord],
        into current: [WatchProgressRecord]
    ) -> [String: WatchProgressRecord] {
        var byKey: [String: WatchProgressRecord] = [:]
        for record in current {
            byKey[record.progressKey] = record
        }
        for record in remote {
            guard let existing = byKey[record.progressKey] else {
                byKey[record.progressKey] = record
                continue
            }
            if existing.isPendingPush, existing.lastWatchedAt > record.lastWatchedAt {
                continue
            }
            if record.lastWatchedAt >= existing.lastWatchedAt {
                byKey[record.progressKey] = record
            }
        }
        return byKey
    }

    /// Clears the pending flag after a push confirms those rows reached the
    /// server, so a later pull is allowed to update them again.
    static func markPushed(keys: [String]) {
        guard !keys.isEmpty else { return }
        let pushed = Set(keys)
        var changed = false
        let updated = records().map { record -> WatchProgressRecord in
            guard pushed.contains(record.progressKey), record.isPendingPush else { return record }
            changed = true
            var copy = record
            copy.isPendingPush = false
            return copy
        }
        guard changed else { return }
        _ = persist(updated)
    }

    /// Seeds the ledger from a previously rendered Continue Watching list.
    ///
    /// Builds before the ledger existed kept only the derived list, so an
    /// upgrading user (or one who never signed in to Nuvio Sync) would otherwise
    /// start with no raw rows at all. Runs once per profile — afterwards the
    /// ledger is authoritative and this must not overwrite it.
    static func backfillIfEmpty(from items: [ContinueWatchingItem]) {
        guard !items.isEmpty, records().isEmpty else { return }
        let seeded = items.compactMap { item -> WatchProgressRecord? in
            // Next Up cards are presentation, not playback; the finished episode
            // that produced them is what belongs in a ledger.
            guard !item.isUpNextEntry else { return nil }
            return WatchProgressRecord(
                progressKey: progressKey(
                    contentId: item.meta.id,
                    season: item.season,
                    episode: item.episode
                ),
                contentId: item.meta.id,
                contentType: item.meta.isSeries ? "series" : "movie",
                videoId: videoId(
                    contentId: item.meta.id,
                    season: item.season,
                    episode: item.episode
                ),
                season: item.season,
                episode: item.episode,
                position: item.position,
                duration: item.duration,
                lastWatchedAt: item.lastWatchedAt,
                // Not known to be on the server yet; a push will settle it.
                isPendingPush: true
            )
        }
        guard !seeded.isEmpty else { return }
        _ = persist(seeded)
    }

    /// One-time recovery for movie progress the backend silently discarded.
    ///
    /// Movies were pushed with explicit null `season`/`episode`, which the RPC
    /// rejected while accepting the episode rows sent alongside them. The push
    /// cleared each row's pending flag on HTTP success regardless, so those rows
    /// are marked synced and would never be retried — a corrected payload alone
    /// leaves every movie already watched on this device stranded.
    ///
    /// Scoped to movies deliberately. Re-flagging everything would also re-upload
    /// rows another device legitimately deleted, and progress has no tombstones
    /// to tell "the server dropped it" from "someone removed it". Episode rows
    /// demonstrably synced, so they are left alone.
    static func repushMoviesOnceIfNeeded() {
        let flagKey = repushFlagKey(for: activeProfileId)
        guard !UserDefaults.standard.bool(forKey: flagKey) else { return }

        let current = records()
        // Nothing loaded yet — this runs during profile activation, which can
        // land before the ledger is populated. Consuming the flag here would
        // spend the one recovery on an empty store and strand the rows that
        // arrive moments later.
        guard !current.isEmpty else { return }

        var changed = false
        let updated = current.map { record -> WatchProgressRecord in
            guard !record.isEpisode, !record.isPendingPush else { return record }
            changed = true
            var copy = record
            copy.isPendingPush = true
            return copy
        }
        if changed {
            _ = persist(updated)
        }
        UserDefaults.standard.set(true, forKey: flagKey)
    }

    /// Scoped counterpart to ``eraseAllProfiles()`` — see
    /// ``WatchedStore/eraseProfile(_:)``.
    static func eraseProfile(_ profileId: String) {
        let key = profileId.isEmpty ? baseKey : "\(baseKey).\(profileId)"
        UserDefaults.standard.removeObject(forKey: key)
        LargePayloadStore.remove(key: key, directory: storageDirectoryName)
        // The one-shot repush flag is part of this profile's state, and
        // ``eraseAllProfiles()`` clears it by prefix. Leaving it behind means a
        // profile erased and rebuilt has already spent its recovery — which for
        // a test suite silently disables what the next run is asserting.
        UserDefaults.standard.removeObject(forKey: repushFlagKey(for: profileId))
        invalidateCache()
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }

    static func eraseAllProfiles() {
        let defaults = UserDefaults.standard
        defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(baseKey) || $0.hasPrefix(movieRepushFlagKey) }
            .forEach { defaults.removeObject(forKey: $0) }
        LargePayloadStore.removeDirectory(storageDirectoryName)
        invalidateCache()
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }

    @discardableResult
    private static func persist(_ records: [WatchProgressRecord]) -> Bool {
        // Keep the newest rows when trimming; the oldest are the least likely to
        // be needed for either Continue Watching or a resume lookup.
        let trimmed = Array(
            records
                .sorted { $0.lastWatchedAt > $1.lastWatchedAt }
                .prefix(maxRecords)
        )
        guard let data = try? JSONEncoder().encode(trimmed) else { return false }
        let key = storageKey
        guard LargePayloadStore.write(data, key: key, directory: storageDirectoryName) else {
            // No preferences fallback: the ledger shares its budget with every
            // other key in the plist, and an oversized write aborts the process.
            // Callers treat `false` as "not persisted" and keep the row pending.
            return false
        }
        // Left behind by a build that stored the ledger in preferences.
        UserDefaults.standard.removeObject(forKey: key)
        cachedRecords = trimmed
        cachedKey = key
        NotificationCenter.default.post(name: changedNotification, object: nil)
        return true
    }

    // MARK: - Rules
    //
    // These mirror `WatchingPolicies.kt` / `SeriesContinuity.kt` in the phone
    // app so both platforms agree on what is still "in progress".

    static func isSeriesType(_ type: String) -> Bool {
        let normalized = type.lowercased()
        return normalized == "series" || normalized == "tv"
    }

    static func progressKey(contentId: String, season: Int?, episode: Int?) -> String {
        guard let season, let episode else { return contentId }
        return "\(contentId)_s\(season)e\(episode)"
    }

    static func videoId(contentId: String, season: Int?, episode: Int?) -> String {
        guard let season, let episode else { return contentId }
        return "\(contentId):\(season):\(episode)"
    }

    /// An unknown runtime is never "complete" — the phone treats those rows as
    /// resumable, and treating them as finished here is what silently removed
    /// synced movies from this device.
    static func isComplete(_ record: WatchProgressRecord) -> Bool {
        guard record.duration > 0 else { return false }
        return (record.position / record.duration) >= completionFraction
    }

    static func hasStarted(_ record: WatchProgressRecord) -> Bool {
        record.position > 0
    }

    /// Rows that should appear as real resume progress, newest first and at most
    /// one per series. Mirrors `continueWatchingProgressEntries`.
    static func continueWatchingCandidates() -> [WatchProgressRecord] {
        let inProgress = records().filter { record in
            guard hasStarted(record), !isComplete(record) else { return false }
            // An episode or movie already marked watched in WatchedStore has been completed
            // and should not be offered as an in-progress resume row.
            if record.isEpisode, let season = record.season, let episode = record.episode {
                if WatchedStore.containsEpisode(metaId: record.contentId, season: season, episode: episode) {
                    return false
                }
            } else if !record.isEpisode {
                if WatchedStore.contains(metaId: record.contentId, type: record.contentType) {
                    return false
                }
            }
            return true
        }
        let episodes = inProgress.filter(\.isEpisode)
        let others = inProgress.filter { !$0.isEpisode }

        var seenSeries: Set<String> = []
        let latestPerSeries = episodes
            .sorted { $0.lastWatchedAt > $1.lastWatchedAt }
            .filter { seenSeries.insert($0.contentId).inserted }

        return (others + latestPerSeries).sorted { $0.lastWatchedAt > $1.lastWatchedAt }
    }

    /// Finished episodes that should seed a "Next Up" suggestion, newest first
    /// and at most one per series. Mirrors `buildHomeNextUpSeedCandidates`.
    static func upNextSeeds(
        preferFurthestEpisode: Bool = UpNextEpisodeSelectionPolicy.prefersFurthestEpisode
    ) -> [WatchProgressRecord] {
        let completedEpisodes = records()
            .filter { $0.isEpisode && $0.isSeries && ($0.season ?? 0) > 0 }
            .filter { record in
                if isComplete(record) { return true }
                if let season = record.season, let episode = record.episode,
                   WatchedStore.containsEpisode(metaId: record.contentId, season: season, episode: episode) {
                    return true
                }
                return false
            }

        var selectedBySeries: [String: WatchProgressRecord] = [:]
        for candidate in completedEpisodes {
            guard let current = selectedBySeries[candidate.contentId] else {
                selectedBySeries[candidate.contentId] = candidate
                continue
            }
            if UpNextEpisodeSelectionPolicy.prefers(
                candidateSeason: candidate.season ?? 0,
                candidateEpisode: candidate.episode ?? 0,
                candidateWatchedAt: candidate.lastWatchedAt,
                over: current.season ?? 0,
                currentEpisode: current.episode ?? 0,
                currentWatchedAt: current.lastWatchedAt,
                preferFurthestEpisode: preferFurthestEpisode
            ) {
                selectedBySeries[candidate.contentId] = candidate
            }
        }
        return selectedBySeries.values.sorted { $0.lastWatchedAt > $1.lastWatchedAt }
    }
}
