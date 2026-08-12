import Foundation

/// #316: stands a loopback origin in front of a remote HLS master so host-declared sidecars can be
/// declared as legible renditions, without moving a single media byte off the origin.
///
/// The sequence is deliberately cheap and entirely optional. Two playlist GETs (the master, then one
/// variant for the program duration and the VOD verdict), a rewrite, a socket. Anything that does not
/// line up, and the caller keeps the origin URL it already had: the sidecars stay overlay-only, exactly
/// as before, and the load is never failed over a subtitle feature.
enum RemoteHLSSubtitleProxy {

    /// A standing proxy: the caller plays `masterURL` and owns the teardown.
    struct Prepared {
        let server: HLSLocalServer
        let provider: RemoteHLSSubtitleProvider
        let masterURL: URL

        func tearDown() {
            provider.cancelFill()
            server.stop()
        }
    }

    enum Refusal: Error, Equatable {
        case fetchFailed(String)
        /// No EXT-X-ENDLIST: a live or still-growing playlist. The whole-program WebVTT shape the
        /// renditions use describes a finished program, so live keeps the overlay.
        case notVOD
        case unusablePlaylist(String)
        case serverUnavailable(String)
    }

    /// Whole-operation budget. A slow origin must not add itself to time-to-first-frame; the fetches
    /// here are playlist-sized and run against the same origin AVPlayer is about to open anyway.
    static let budgetSeconds: TimeInterval = 5

    static func prepare(originURL: URL,
                        tracks: [RemoteHLSSubtitleProvider.Track],
                        httpHeaders: [String: String]) async -> Prepared? {
        guard !tracks.isEmpty else { return nil }
        do {
            let prepared = try await build(originURL: originURL, tracks: tracks, httpHeaders: httpHeaders)
            EngineLog.emit(
                "[AetherEngine] #316: serving \(tracks.count) external subtitle rendition(s) over a "
                + "rewritten master at \(prepared.masterURL.absoluteString); media stays at the origin",
                category: .engine)
            return prepared
        } catch {
            EngineLog.emit(
                "[AetherEngine] #316: no subtitle renditions on this remote-HLS source (\(reason(error))); "
                + "the declared sidecars stay host-overlay only",
                category: .engine)
            return nil
        }
    }

    private static func reason(_ error: Error) -> String {
        switch error {
        case Refusal.fetchFailed(let detail): return "playlist fetch failed: \(detail)"
        case Refusal.notVOD: return "no EXT-X-ENDLIST, so not a finished program"
        case Refusal.unusablePlaylist(let detail): return "unusable playlist: \(detail)"
        case Refusal.serverUnavailable(let detail): return "loopback origin unavailable: \(detail)"
        case RemoteHLSMasterRewrite.Refusal.notAPlaylist: return "origin did not answer with a playlist"
        case RemoteHLSMasterRewrite.Refusal.masterWithoutVariants: return "master declares no variant URI"
        case RemoteHLSMasterRewrite.Refusal.noRenditions: return "nothing declared to inject"
        default: return "\(error)"
        }
    }

    private static func build(originURL: URL,
                              tracks: [RemoteHLSSubtitleProvider.Track],
                              httpHeaders: [String: String]) async throws -> Prepared {
        let session = makeSession()
        defer { session.finishTasksAndInvalidate() }

        let (body, finalURL) = try await fetchPlaylist(originURL, session: session, headers: httpHeaders)
        let parsed = try parse(body, at: finalURL)
        let duration = try await programDuration(of: parsed, at: finalURL,
                                                 session: session, headers: httpHeaders)

        let master = try RemoteHLSMasterRewrite.rewrite(
            originPlaylist: body,
            originURL: finalURL,
            renditions: RemoteHLSSubtitleProvider.renditions(for: tracks))

        let provider = RemoteHLSSubtitleProvider(tracks: tracks, masterBody: master,
                                                 programDuration: duration,
                                                 defaultHeaders: httpHeaders)
        let server = HLSLocalServer(provider: provider)
        do {
            try server.start()
        } catch {
            throw Refusal.serverUnavailable("\(error)")
        }
        guard let masterURL = server.playlistURL else {
            server.stop()
            throw Refusal.serverUnavailable("no playlist URL after start")
        }
        // Decode up front: the rendition is fetched the moment the host selects it, and a whole-program
        // .vtt is fetched once and never again.
        provider.startFill()
        return Prepared(server: server, provider: provider, masterURL: masterURL)
    }

    // MARK: - Playlist reads

    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = budgetSeconds / 2
        config.timeoutIntervalForResource = budgetSeconds
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }

    /// Returns the body and the URL it finally came from; every relative URI in the playlist resolves
    /// against the latter, so a redirecting origin (Plex's transcode handoff) still rewrites correctly.
    private static func fetchPlaylist(_ url: URL,
                                      session: URLSession,
                                      headers: [String: String]) async throws -> (String, URL) {
        var request = URLRequest(url: url)
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Refusal.fetchFailed("\(error.localizedDescription)")
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Refusal.fetchFailed("HTTP \(http.statusCode)")
        }
        guard let body = String(data: data, encoding: .utf8) else {
            throw Refusal.fetchFailed("body is not UTF-8")
        }
        return (body, response.url ?? url)
    }

    private static func parse(_ body: String, at url: URL) throws -> HLSPlaylist {
        do {
            return try HLSPlaylistParser.parse(body)
        } catch {
            throw Refusal.unusablePlaylist("\(error)")
        }
    }

    /// Sum of the origin's own EXTINFs. A master is resolved through its first variant; the durations
    /// are identical across variants, and one small GET buys both the length and the VOD verdict.
    private static func programDuration(of playlist: HLSPlaylist,
                                        at url: URL,
                                        session: URLSession,
                                        headers: [String: String]) async throws -> Double {
        switch playlist {
        case .media(let media):
            guard media.hasEndList else { throw Refusal.notVOD }
            return media.segments.reduce(0) { $0 + $1.duration }
        case .master(let master):
            guard let variant = master.variants.first,
                  let variantURL = HLSPlaylistParser.resolve(uri: variant.uri, against: url) else {
                throw Refusal.unusablePlaylist("master declares no resolvable variant")
            }
            let (body, finalURL) = try await fetchPlaylist(variantURL, session: session, headers: headers)
            guard case .media(let media) = try parse(body, at: finalURL) else {
                throw Refusal.unusablePlaylist("variant is not a media playlist")
            }
            guard media.hasEndList else { throw Refusal.notVOD }
            return media.segments.reduce(0) { $0 + $1.duration }
        }
    }
}
