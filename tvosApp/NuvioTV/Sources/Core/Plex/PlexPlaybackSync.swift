import Foundation

/// Keeps Plex's resume position in step with Nuvio playback of Plex files.
///
/// Stream lists register each Plex URL they offer, and read the item's current
/// position from the server in the background. When one of those URLs plays,
/// Plex's position is the resume point (so a show started in another Plex app
/// continues where it stopped there), and play, pause, seek, stop, and a
/// periodic heartbeat are reported back so other Plex apps resume here too.
@MainActor
final class PlexPlaybackSync {
    static let shared = PlexPlaybackSync()

    struct Entry {
        let serverID: String
        let ratingKey: String
        let durationMs: Int64?
        /// Seconds; `nil` until the server answered. 0 means no saved position.
        var serverPositionSeconds: Double?
        var resumeConsumed = false
    }

    private var entries: [String: Entry] = [:]
    private var lastState: [String: PlexClient.TimelineState] = [:]
    private var lastReportAt: [String: Date] = [:]

    nonisolated static let heartbeatInterval: TimeInterval = 10

    private init() {}

    // MARK: - Stream registration

    func register(url: String, serverID: String, ratingKey: String, durationMs: Int64?) {
        if entries[url] == nil {
            entries[url] = Entry(serverID: serverID, ratingKey: ratingKey, durationMs: durationMs)
        } else {
            entries[url]?.resumeConsumed = false
        }
        guard let client = PlexSessionManager.shared.client(forServerID: serverID) else { return }
        Task { [weak self] in
            guard let state = try? await client.playbackState(ratingKey: ratingKey) else { return }
            await MainActor.run {
                self?.entries[url]?.serverPositionSeconds = Double(state.viewOffsetMs ?? 0) / 1000
            }
        }
    }

    func isPlexStream(_ url: String?) -> Bool {
        guard let url else { return false }
        return entries[url] != nil
    }

    /// The position playback of `url` should start from. Plex's answer wins
    /// for the first load of a Plex stream; reloads mid-session (source
    /// failover, engine handoff) keep the caller's own position.
    func resumePosition(for url: URL, fallback: Double?) -> Double? {
        let key = url.absoluteString
        guard var entry = entries[key], !entry.resumeConsumed,
              let serverPosition = entry.serverPositionSeconds else { return fallback }
        entry.resumeConsumed = true
        entries[key] = entry
        return serverPosition > 5 ? serverPosition : nil
    }

    // MARK: - Reporting

    enum PlayerState {
        case playing, paused, stopped
    }

    /// Reports a state change right away and repeats `playing` at most every
    /// `heartbeatInterval` seconds. Not a Plex stream: nothing happens.
    func report(_ state: PlayerState, url: String?, currentTime: TimeInterval, duration: TimeInterval) {
        guard let url, var entry = entry(for: url),
              currentTime.isFinite, currentTime >= 0 else { return }
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
            let sessionReported = lastState[url] == .playing || lastState[url] == .paused
            if timelineState != .stopped || !sessionReported { return }
        }
        let now = Date()
        if lastState[url] == timelineState, timelineState != .stopped,
           let last = lastReportAt[url], now.timeIntervalSince(last) < Self.heartbeatInterval {
            return
        }
        if lastState[url] == .stopped, timelineState == .stopped { return }
        lastState[url] = timelineState
        lastReportAt[url] = now
        entry.serverPositionSeconds = currentTime
        entries[url] = entry

        guard let client = PlexSessionManager.shared.client(forServerID: entry.serverID) else { return }
        let durationMs = duration.isFinite && duration > 0 ? Int64(duration * 1000) : (entry.durationMs ?? 0)
        let ratingKey = entry.ratingKey
        let timeMs = Int64(currentTime * 1000)
        Task.detached(priority: .utility) {
            do {
                try await client.reportTimeline(ratingKey: ratingKey, state: timelineState, timeMs: timeMs, durationMs: durationMs)
            } catch {
                print("[Plex] timeline report failed: \(error.localizedDescription)")
            }
        }
    }

    /// The registered entry for `url`, or one recovered from the synced library.
    /// Continue Watching and other shortcuts replay a stored stream URL without
    /// building a stream list, so the URL was never registered in this launch;
    /// its `/library/parts/...` path still identifies the item.
    private func entry(for url: String) -> Entry? {
        if let existing = entries[url] { return existing }
        guard let recovered = Self.entryFromLibrary(url) else { return nil }
        entries[url] = recovered
        return recovered
    }

    private static func entryFromLibrary(_ urlString: String) -> Entry? {
        guard let url = URL(string: urlString), url.path.hasPrefix("/library/parts/") else { return nil }
        let servers = PlexServerStore.shared.servers
        // Prefer the server this URL points at; a stored link can predate an
        // address change, so fall back to any added server.
        let sameAddress = servers.filter { $0.baseURL?.host == url.host && $0.baseURL?.port == url.port }
        for server in sameAddress.isEmpty ? servers : sameAddress {
            for title in PlexLibraryIndex.shared.titlesByServerID[server.id] ?? [] {
                if let item = title.items.first(where: { $0.partKey == url.path }) {
                    return Entry(serverID: server.id, ratingKey: item.ratingKey, durationMs: item.durationMs)
                }
            }
        }
        return nil
    }

    /// A seek: report the new position now, whatever the heartbeat timing.
    func seeked(url: String?, to currentTime: TimeInterval, duration: TimeInterval) {
        guard let url, let state = lastState[url], state != .stopped else { return }
        lastReportAt[url] = nil
        lastState[url] = nil
        report(state == .paused ? .paused : .playing, url: url, currentTime: currentTime, duration: duration)
    }
}
