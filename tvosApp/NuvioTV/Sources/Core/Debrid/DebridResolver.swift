import Foundation

/// Entry point for turning a torrent-only `NuvioStream` into a playable one.
/// Reads the user's configured provider + API key from the given settings store
/// and dispatches to the matching backend. Providers not yet implemented (or
/// "None") make this a no-op so playback falls back to the next stream.
struct DebridResolver {
    private let store: UserDefaults

    init(store: UserDefaults) {
        self.store = store
    }

    /// The provider currently selected in Settings → Integrations → Debrid.
    var selectedKind: DebridProviderKind {
        DebridProviderKind(settingsValue: store.string(forKey: SettingsKey.debridProvider))
    }

    /// Whether resolution is possible at all (the user enabled debrid link resolving,
    /// a provider with a backend is selected, and a key is present).
    var isEnabled: Bool {
        let debridEnabled = store.object(forKey: SettingsKey.debridEnabled) as? Bool ?? true
        return debridEnabled && provider(for: selectedKind) != nil && !apiKey.isEmpty
    }

    private var apiKey: String {
        DebridCredentials.token(for: selectedKind, store: store)
    }

    /// Resolves a torrent stream to a direct URL. Returns `nil` when the stream
    /// isn't a torrent, no provider is configured, or resolution fails — the
    /// caller should then move on to the next stream.
    func resolvedURL(for stream: NuvioStream, season: Int?, episode: Int?) async -> DebridResult? {
        guard stream.isDebridResolvable, let infoHash = stream.effectiveInfoHash else { return nil }
        guard let provider = provider(for: selectedKind) else { return nil }

        let request = DebridRequest(
            infoHash: infoHash,
            fileIdx: stream.effectiveFileIdx,
            sources: stream.sources,
            filename: stream.filename,
            season: season,
            episode: episode
        )
        return await provider.resolve(request, apiKey: apiKey)
    }

    /// Maps a provider kind to its implementation. Unimplemented kinds
    /// (AllDebrid, Debrid-Link) and None return `nil`.
    private func provider(for kind: DebridProviderKind) -> DebridProvider? {
        guard kind.hasResolver else { return nil }
        switch kind {
        case .realDebrid: return RealDebridResolver()
        case .premiumize: return PremiumizeResolver()
        case .torbox: return TorboxResolver()
        case .none, .allDebrid, .debridLink: return nil
        }
    }
}

/// Settings → Connected Services → Link Preparation: the details page
/// resolves the first debrid results to playable links before one is picked.
/// Each resolution is a request to the viewer's debrid service and may add
/// the item to their account, so it is bounded three ways: the count chosen
/// in Settings for one movie or episode, a budget across titles, and a pause
/// after the service answers that it is rate-limited.
enum DebridLinkPreparation {
    /// "Links to prepare". 0 is off, as before the setting existed.
    static let counts = [1, 2, 3, 5]
    static let defaultCount = 1

    /// Resolutions started in the background, as on the other apps.
    private static let maxPerMinute = 6
    private static let maxPerHour = 30
    /// No link is prepared for this long after a rate-limit answer.
    private static let rateLimitPause: TimeInterval = 600
    /// A prepared link older than this is resolved again when picked.
    static let linkLifetime: TimeInterval = 1_800

    private static let lock = NSLock()
    private static var starts: [Date] = []
    private static var pausedUntil: Date?

    static func limit(in settings: UserDefaults) -> Int {
        let stored = settings.integer(forKey: SettingsKey.debridPrepareLinksCount)
        return min(max(stored, 0), counts.max() ?? 0)
    }

    /// The results to prepare, in the list's order: torrents the debrid
    /// service resolves that are cached there, or that their add-on marks as
    /// cached. Never more than `limit`.
    static func candidates(from displayed: [NuvioStream], limit: Int) -> [NuvioStream] {
        guard limit > 0 else { return [] }
        var seen = Set<String>()
        var result: [NuvioStream] = []
        for stream in displayed where result.count < limit {
            guard stream.isDebridResolvable,
                  !stream.isNotPlayable,
                  stream.unavailabilityReason == nil,
                  // Only a link the viewer's own debrid service confirmed
                  // as cached. An add-on's label is not enough: resolving an
                  // uncached torrent would add it to the account.
                  stream.isCached == true,
                  seen.insert(stream.id).inserted else { continue }
            result.append(stream)
        }
        return result
    }

    /// Takes one resolution from the budget. False when it is used up or the
    /// service asked to slow down.
    static func consumeBudget(now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let pausedUntil, now < pausedUntil { return false }
        starts.removeAll { now.timeIntervalSince($0) >= 3_600 }
        let lastMinute = starts.filter { now.timeIntervalSince($0) < 60 }.count
        guard lastMinute < maxPerMinute, starts.count < maxPerHour else { return false }
        starts.append(now)
        return true
    }

    static func noteRateLimited(now: Date = Date()) {
        lock.lock()
        pausedUntil = now.addingTimeInterval(rateLimitPause)
        lock.unlock()
    }
}
