import Foundation

/// Keeps Plex's resume position in step with Nuvio playback of Plex files.
///
/// A Plex stream is recognised by its `/library/parts/...` path, looked up in
/// the synced library. That works the same for a stream picked from a stream
/// list and for a stored link replayed from Continue Watching, and it survives
/// the server changing address.
///
/// - Before playback, `resolve` points the link at the server's current
///   address and adds the token as a request header.
/// - Plex's saved position is the resume point, so a title started in another
///   Plex app continues where it stopped there.
/// - Play, pause, seek, stop, and a periodic heartbeat are reported back, so
///   other Plex apps resume where Nuvio stopped.
@MainActor
final class PlexPlaybackSync {
    static let shared = PlexPlaybackSync()

    struct Item: Hashable {
        let serverID: String
        let ratingKey: String
        let durationMs: Int64?
    }

    /// What is known about one item's playback in this app run.
    private struct Session {
        var lastState: PlexClient.TimelineState?
        var lastReportAt: Date?
        var resumeConsumed = false
    }

    private var sessions: [Item: Session] = [:]
    /// Where reports go; replaced in tests.
    var sendTimeline: (Item, PlexClient.TimelineState, _ timeMs: Int64, _ durationMs: Int64) -> Void = { item, state, timeMs, durationMs in
        guard let client = PlexSessionManager.shared.client(forServerID: item.serverID) else { return }
        Task.detached(priority: .utility) {
            do {
                try await client.reportTimeline(ratingKey: item.ratingKey, state: state, timeMs: timeMs, durationMs: durationMs)
            } catch {
                print("[Plex] timeline report failed: \(error.localizedDescription)")
                await PlexSessionManager.shared.reconnectIfNeeded(serverID: item.serverID)
            }
        }
    }
    var now: () -> Date = Date.init

    nonisolated static let heartbeatInterval: TimeInterval = 10

    init() {}

    // MARK: - Recognising Plex streams

    /// The Plex item a stream URL plays, or `nil` for any other stream.
    func item(for url: URL) -> Item? {
        let index = PlexLibraryIndex.shared
        let found: (server: PlexServerConfig, title: PlexIndexedTitle, item: PlexIndexedItem)?
        let remembered: PlexRememberedItem?
        if url.path.hasPrefix("/library/parts/") {
            found = index.locate(partPath: url.path, preferredHost: url.host)
            remembered = found == nil ? index.rememberedItem(partPath: url.path) : nil
        } else if let converted = PlexClient.transcodedRatingKey(url) {
            found = index.locate(ratingKey: converted.ratingKey, preferredHost: url.host)
            remembered = found == nil ? index.rememberedItem(ratingKey: converted.ratingKey) : nil
        } else {
            found = nil
            remembered = nil
        }
        if let found {
            return Item(serverID: found.server.id, ratingKey: found.item.ratingKey, durationMs: found.item.durationMs)
        }
        // A looked-up title's file replayed after a relaunch.
        return remembered.map { Item(serverID: $0.serverID, ratingKey: $0.ratingKey, durationMs: $0.durationMs) }
    }

    private func item(forString url: String?) -> Item? {
        url.flatMap(URL.init(string:)).flatMap(item(for:))
    }

    /// The URL and headers to actually request: the server's current address
    /// with the token in a header. A stored link keeps working after the
    /// server moves, and never needs a token inside it. Other streams pass
    /// through unchanged.
    func resolve(url: URL, headers: [String: String]) -> (url: URL, headers: [String: String]) {
        guard let item = item(for: url),
              let server = PlexServerStore.shared.server(id: item.serverID),
              let baseURL = server.baseURL else { return (url, headers) }
        let rebuilt: URL?
        if let converted = PlexClient.transcodedRatingKey(url) {
            rebuilt = PlexClient.transcodeURL(
                baseURL: baseURL,
                ratingKey: converted.ratingKey,
                session: converted.session ?? UUID().uuidString
            )
        } else {
            rebuilt = PlexClient.streamURL(baseURL: baseURL, partKey: url.path)
        }
        guard let current = rebuilt else { return (url, headers) }
        var merged = headers
        merged[PlexClient.tokenHeader] = PlexCredentialStore.token(forServerID: server.id)
        return (current, merged)
    }

    /// The link to hand an external player (Infuse, VLC, ...). Those apps take
    /// a URL and nothing else, so a Plex link carries its token in the query
    /// for them. The link is never stored; other streams pass through unchanged.
    func urlForExternalPlayer(_ url: URL) -> URL {
        let (current, headers) = resolve(url: url, headers: [:])
        guard let token = headers[PlexClient.tokenHeader], !token.isEmpty,
              var components = URLComponents(url: current, resolvingAgainstBaseURL: false) else { return current }
        var items = (components.queryItems ?? []).filter { $0.name != PlexClient.tokenHeader }
        items.append(URLQueryItem(name: PlexClient.tokenHeader, value: token))
        components.queryItems = items
        return components.url ?? url
    }

    /// Headers safe to store with a link: a Plex link is stored without its
    /// token. A looked-up title's file is remembered, so the stored link is
    /// still recognised (and given its token) after a relaunch.
    func headersForStorage(url: String, headers: [String: String]) -> [String: String] {
        guard let item = item(forString: url) else { return headers }
        PlexLibraryIndex.shared.rememberLookedUpItem(serverID: item.serverID, ratingKey: item.ratingKey)
        return headers.filter { $0.key != PlexClient.tokenHeader }
    }

    // MARK: - Resume

    /// A stream list offers this item again: its next play resumes from Plex.
    func streamOffered(_ item: Item) {
        sessions[item, default: Session()].resumeConsumed = false
    }

    /// The position playback of `url` should start from. Plex's saved position
    /// wins for the first load of a play; reloads within it (source failover,
    /// engine handoff) keep the caller's own position.
    func resumePosition(for url: URL, fallback: Double?) -> Double? {
        guard let item = item(for: url) else { return fallback }
        var session = sessions[item] ?? Session()
        guard !session.resumeConsumed,
              let state = PlexLibraryIndex.shared.watchState(serverID: item.serverID, ratingKey: item.ratingKey) else {
            return fallback
        }
        session.resumeConsumed = true
        sessions[item] = session
        return state.resumeSeconds > 5 ? state.resumeSeconds : nil
    }

    // MARK: - Reporting

    enum PlayerState {
        case playing, paused, stopped
    }

    /// Reports a state change right away and repeats `playing` at most every
    /// `heartbeatInterval` seconds. Not a Plex stream: nothing happens.
    func report(_ state: PlayerState, url: String?, currentTime: TimeInterval, duration: TimeInterval) {
        guard let item = item(forString: url), currentTime.isFinite, currentTime >= 0 else { return }
        var session = sessions[item] ?? Session()
        let timelineState: PlexClient.TimelineState
        switch state {
        case .playing: timelineState = .playing
        case .paused: timelineState = .paused
        case .stopped: timelineState = .stopped
        }
        // Playback reaches `playing` before the resume seek lands, so the first
        // report would say 0:00 and briefly reset the resume point every Plex
        // app sees. Wait for a real position; a stop before any report was
        // sent leaves the saved point alone too.
        if currentTime < 1 {
            let reported = session.lastState == .playing || session.lastState == .paused
            if timelineState != .stopped || !reported { return }
        }
        let date = now()
        if session.lastState == timelineState, timelineState != .stopped,
           let last = session.lastReportAt, date.timeIntervalSince(last) < Self.heartbeatInterval {
            return
        }
        if session.lastState == .stopped, timelineState == .stopped { return }
        session.lastState = timelineState
        session.lastReportAt = date
        if timelineState == .stopped {
            // The next play is a new one and reads Plex's position again.
            session.resumeConsumed = false
        }
        sessions[item] = session

        let durationMs = duration.isFinite && duration > 0 ? Int64(duration * 1000) : (item.durationMs ?? 0)
        let timeMs = Int64(currentTime * 1000)
        rememberPosition(item, timeMs: timeMs, durationMs: durationMs)
        sendTimeline(item, timelineState, timeMs, durationMs)
        if timelineState == .stopped,
           let session = url.flatMap(URL.init(string:)).flatMap(PlexClient.transcodedRatingKey)?.session,
           let client = PlexSessionManager.shared.client(forServerID: item.serverID) {
            // A conversion keeps the server busy until it is told to stop.
            Task.detached(priority: .utility) { await client.stopTranscode(session: session) }
        }
    }

    /// A seek: report the new position now, whatever the heartbeat timing.
    func seeked(url: String?, to currentTime: TimeInterval, duration: TimeInterval) {
        guard let item = item(forString: url), var session = sessions[item],
              let state = session.lastState, state != .stopped else { return }
        session.lastReportAt = nil
        session.lastState = nil
        sessions[item] = session
        report(state == .paused ? .paused : .playing, url: url, currentTime: currentTime, duration: duration)
    }

    /// Mirrors what the server will save, so a replay before the next read of
    /// the server's state resumes from here. Past Plex's 90% threshold the
    /// server marks the item watched and clears its position.
    private func rememberPosition(_ item: Item, timeMs: Int64, durationMs: Int64) {
        // Only once the server's state has been read; a lone entry would make
        // every other item look unwatched rather than unknown.
        guard var state = PlexLibraryIndex.shared.watchState(serverID: item.serverID, ratingKey: item.ratingKey) else { return }
        if durationMs > 0, Double(timeMs) >= Double(durationMs) * 0.9 {
            state.viewOffsetMs = 0
            state.viewCount = max(state.viewCount, 1)
        } else {
            state.viewOffsetMs = timeMs
        }
        state.lastViewedAt = Int64(now().timeIntervalSince1970)
        PlexLibraryIndex.shared.setWatchStates([item.ratingKey: state], forServerID: item.serverID, merging: true)
    }
}
