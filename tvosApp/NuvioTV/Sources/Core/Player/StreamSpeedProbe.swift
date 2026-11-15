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

/// How fast a source is likely to be for Nuvio Recommended, judged without
/// contacting it.
///
/// It never opens a source's URL before the viewer picks it. Many add-ons
/// (AIOStreams, Comet, Torrentio, MediaFusion...) return links that look direct
/// or cached but resolve on request: opening one adds the torrent to the
/// debrid account or makes NzbDav fetch the NZB, which fills the viewer's
/// library and uses indexer quota. So only what the source itself says is
/// used: the seeders a torrent add-on reports.
enum StreamSpeedProbe {
    /// Speed verdict for a source, or nil when there is nothing to judge it by.
    static func verdict(for stream: NuvioStream, resolution: Int) -> StreamSpeedVerdict? {
        seederVerdict(for: stream, resolution: resolution)
    }

    // MARK: - Torrents

    /// The seeder count an add-on reports in the source text, as Torrentio-style
    /// add-ons do ("👤 188"), or as "Seeders: 188" / "Seeds 188".
    static func seeders(in stream: NuvioStream) -> Int? {
        let text = [stream.name, stream.description, stream.filename].compactMap { $0 }.joined(separator: "\n")
        let patterns = [
            #"👤\s*(\d[\d,.]*)"#,
            #"(?i)\bseed(?:er)?s?\s*[:=]?\s*(\d[\d,.]*)"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text) else { continue }
            let digits = text[range].filter(\.isNumber)
            if let value = Int(digits) { return value }
        }
        return nil
    }

    /// For a torrent, more seeders means a faster, steadier download. Only used
    /// when the source can't be downloaded from directly and isn't likely cached
    /// on a debrid service, where seeders don't matter.
    static func seederVerdict(for stream: NuvioStream, resolution: Int) -> StreamSpeedVerdict? {
        guard stream.isDebridResolvable, !stream.isLikelyCached,
              let seeders = seeders(in: stream) else { return nil }
        let (fast, ok): (Int, Int)
        switch resolution {
        case 2160...: (fast, ok) = (50, 15)
        case 1080..<2160: (fast, ok) = (25, 8)
        default: (fast, ok) = (10, 3)
        }
        if seeders >= fast { return .fast }
        if seeders >= ok { return .ok }
        return .slow
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
