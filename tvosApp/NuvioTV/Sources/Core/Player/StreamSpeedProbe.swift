import Foundation

/// How a source's measured download speed compares with what its resolution needs.
enum StreamSpeedVerdict: Equatable, Sendable {
    case fast
    case ok
    case slow

    /// Rough sustained speed a resolution needs to play smoothly, in Mbit/s.
    static func requiredMbps(forResolution resolution: Int) -> Double {
        switch resolution {
        case 2160...: return 25
        case 1440..<2160: return 16
        case 1080..<1440: return 8
        case 720..<1080: return 5
        default: return 3
        }
    }

    static func classify(mbps: Double, resolution: Int) -> StreamSpeedVerdict {
        let required = requiredMbps(forResolution: resolution)
        if mbps >= required * 2 { return .fast }
        if mbps >= required { return .ok }
        return .slow
    }
}

/// A short speed check for Nuvio Recommended: downloads a few megabytes of a
/// source's file and measures the rate, so a top pick that would buffer on this
/// connection can be moved down.
///
/// Only direct HTTP sources that are likely cached are checked, so a check never
/// makes a debrid service start downloading a torrent. Results are remembered
/// per host for a while so the same server isn't checked again and again.
actor StreamSpeedProbe {
    static let shared = StreamSpeedProbe()

    static let sampleBytes = 4 * 1024 * 1024
    static let timeLimit: TimeInterval = 6
    static let cacheLifetime: TimeInterval = 10 * 60

    private struct CachedResult {
        let mbps: Double
        let measuredAt: Date
    }

    private var resultsByHost: [String: CachedResult] = [:]
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = Self.timeLimit
            configuration.timeoutIntervalForResource = Self.timeLimit + 2
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.urlCache = nil
            self.session = URLSession(configuration: configuration)
        }
    }

    /// The URL to check, or nil when the source shouldn't be checked.
    nonisolated static func probeURL(for stream: NuvioStream) -> URL? {
        guard !stream.isNotPlayable, stream.unavailabilityReason == nil,
              stream.isDirectProviderStream || stream.isLikelyCached,
              let direct = stream.directURL,
              let url = URL(string: direct),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    /// Speed verdict for a source, or nil when it can't be checked or the check failed.
    func verdict(for stream: NuvioStream, resolution: Int) async -> StreamSpeedVerdict? {
        guard let url = Self.probeURL(for: stream) else { return nil }
        guard let mbps = await measure(url: url, headers: stream.httpHeaders ?? [:]) else { return nil }
        return StreamSpeedVerdict.classify(mbps: mbps, resolution: resolution)
    }

    private func measure(url: URL, headers: [String: String]) async -> Double? {
        let host = url.host?.lowercased() ?? url.absoluteString
        if let cached = resultsByHost[host], Date().timeIntervalSince(cached.measuredAt) < Self.cacheLifetime {
            return cached.mbps
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = Self.timeLimit
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        // Ask for the start of the file only; reading stops at the sample size
        // even if the server ignores the range.
        request.setValue("bytes=0-\(Self.sampleBytes - 1)", forHTTPHeaderField: "Range")

        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                bytes.task.cancel()
                return nil
            }
            // Time from the first byte, so redirects and the server's response
            // delay don't count as download speed.
            var received = 0
            var firstByteAt: Date?
            let deadline = Date().addingTimeInterval(Self.timeLimit)
            for try await _ in bytes {
                if firstByteAt == nil { firstByteAt = Date() }
                received += 1
                if received >= Self.sampleBytes { break }
                if received % 65_536 == 0, Date() > deadline { break }
            }
            bytes.task.cancel()
            guard let firstByteAt, received >= 256 * 1024 else { return nil }
            let elapsed = max(Date().timeIntervalSince(firstByteAt), 0.05)
            let mbps = Double(received) * 8 / elapsed / 1_000_000
            resultsByHost[host] = CachedResult(mbps: mbps, measuredAt: Date())
            return mbps
        } catch {
            return nil
        }
    }
}

enum StreamSpeedRanking {
    /// The overall pick after speed checks: when the top pick is slow on this
    /// connection, the best-ranked checked alternative that isn't slow takes
    /// its place. Unchecked sources keep their ranking.
    static func overallPick(
        ranked: [NuvioStream],
        verdicts: [String: StreamSpeedVerdict]
    ) -> NuvioStream? {
        guard let top = ranked.first else { return nil }
        guard verdicts[top.id] == .slow else { return top }
        return ranked.dropFirst().first { verdicts[$0.id] == .fast || verdicts[$0.id] == .ok } ?? top
    }
}
