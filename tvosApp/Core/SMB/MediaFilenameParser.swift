import Foundation

/// A filename parsed into a search-ready title plus optional year / season /
/// episode. Feeds `SMBLibraryResolver`, which turns this into a real Cinemeta
/// id via `CatalogRepository.search`.
struct ParsedMediaName: Equatable {
    var title: String
    var year: Int?
    var season: Int?
    var episode: Int?

    var isSeries: Bool { season != nil && episode != nil }
}

/// Extracts a matchable title from a release-style filename. Purely textual —
/// no network calls — so it is unit-testable without a server or catalog.
/// Heuristic by nature (the same tradeoff every filename-based matcher makes):
/// unusual naming or a title that itself looks like a year can defeat it. A
/// file this returns `nil` for, or whose title `SMBLibraryResolver` can't
/// match, surfaces in the scan report as unmatched rather than silently
/// guessing.
enum MediaFilenameParser {
    /// Files below this size are almost never a real title — samples,
    /// trailers, and thumbnail sidecars that share a video extension.
    static let minimumFileSizeBytes: Int64 = 50 * 1024 * 1024

    private static let droppedNameFragments: [String] = [
        "sample", "trailer", "extras", "featurette", "behind the scenes", "deleted scenes"
    ]

    /// Resolution / source / codec / color / audio / release-marker tokens
    /// that mark where the title ends in a scene-style filename. Matched
    /// whole-word (after separator normalization), not as substrings.
    private static let releaseTokens: Set<String> = [
        "2160p", "1440p", "1080p", "720p", "480p", "4k", "uhd",
        "bluray", "blu-ray", "bdrip", "brrip", "webrip", "web-dl", "webdl", "web",
        "hdtv", "dvdrip", "dvd", "hdrip", "hdcam", "camrip", "cam", "telesync",
        "remux",
        "x264", "x265", "h264", "h265", "hevc", "avc", "xvid", "divx", "av1",
        "hdr10+", "hdr10", "hdr", "hlg", "dolby vision", "dolbyvision", "dovi", "sdr",
        "truehd", "atmos", "dts-hd", "dts-x", "dtsx", "dts", "ddp5.1", "ddp",
        "dd5.1", "eac3", "ac3", "aac", "flac", "5.1", "7.1", "2.0",
        "extended", "unrated", "proper", "repack", "internal", "limited",
        "multi", "dual", "dubbed", "subbed"
    ]

    /// `parentPath` is the file's share-relative directory (e.g.
    /// `"TV Shows/Show Name/Season 02"`); it supplies the show title and/or
    /// season when a filename alone is just an episode number or title
    /// (`"03 - The One Where....mkv"`).
    static func parse(filename: String, parentPath: String = "") -> ParsedMediaName? {
        let base = normalizeSeparators((filename as NSString).deletingPathExtension)
        guard !isDropped(base) else { return nil }

        let normalizedParent = normalizeSeparators(parentPath)
        let year = extractYear(in: base) ?? extractYear(in: normalizedParent)

        if let match = seasonEpisode(in: base) {
            let titleSource = match.titlePrefix.flatMap(meaningfulPrefix) ?? folderTitle(from: normalizedParent)
            guard let titleSource, let title = cleanTitle(titleSource) else { return nil }
            return ParsedMediaName(title: title, year: year, season: match.season, episode: match.episode)
        }

        if let match = seasonEpisode(in: normalizedParent) {
            guard let folder = folderTitle(from: normalizedParent), let title = cleanTitle(folder) else { return nil }
            return ParsedMediaName(title: title, year: year, season: match.season, episode: match.episode)
        }

        // "Show Name/Season 02/03 - Episode Title.mkv": the common convention
        // where the folder names the season and the filename supplies only
        // the episode — either a bare leading number or a spelled-out
        // "Episode N". Checked after the whole-string cases above so an
        // ordinary movie in an ordinary folder never matches here (both
        // require the literal word "season" in the parent path).
        if let season = seasonNumber(in: normalizedParent),
           let episode = leadingNumber(in: base) ?? episodeNumber(in: base) {
            guard let folder = folderTitle(from: normalizedParent), let title = cleanTitle(folder) else { return nil }
            return ParsedMediaName(title: title, year: year, season: season, episode: episode)
        }

        guard let title = cleanTitle(base) else { return nil }
        return ParsedMediaName(title: title, year: year, season: nil, episode: nil)
    }

    private static func isDropped(_ base: String) -> Bool {
        let lower = base.lowercased()
        return droppedNameFragments.contains { lower.contains($0) }
    }

    // MARK: - Season / episode

    private struct EpisodeMatch {
        let season: Int
        let episode: Int
        /// Text preceding the match, when the pattern captured it — used as
        /// the title source so trailing episode-title text doesn't leak in.
        let titlePrefix: String?
    }

    private static func seasonEpisode(in text: String) -> EpisodeMatch? {
        // S01E02, s1e2, S01.E02, S01 E02
        if let m = firstMatch(in: text, pattern: #"(?i)^(.*?)[.\s_-]*s(\d{1,2})[.\s_-]*e(\d{1,3})"#),
           let season = Int(m[2]), let episode = Int(m[3]) {
            return EpisodeMatch(season: season, episode: episode, titlePrefix: m[1])
        }
        // 1x05 — the trailing `(?!\d)` keeps this from matching inside a bare
        // resolution string like "1920x1080".
        if let m = firstMatch(in: text, pattern: #"(?i)^(.*?)[.\s_-]*(\d{1,2})x(\d{1,3})(?!\d)"#),
           let season = Int(m[2]), let episode = Int(m[3]) {
            return EpisodeMatch(season: season, episode: episode, titlePrefix: m[1])
        }
        // "Season 2" / "Episode 5" spelled out together in one string (a
        // folder literally named "Season 2 Episode 5", or similar).
        if let season = seasonNumber(in: text), let episode = episodeNumber(in: text) {
            return EpisodeMatch(season: season, episode: episode, titlePrefix: nil)
        }
        return nil
    }

    private static func seasonNumber(in text: String) -> Int? {
        firstMatch(in: text, pattern: #"(?i)season[.\s_-]*(\d{1,2})"#).flatMap { Int($0[1]) }
    }

    private static func episodeNumber(in text: String) -> Int? {
        firstMatch(in: text, pattern: #"(?i)episode[.\s_-]*(\d{1,3})"#).flatMap { Int($0[1]) }
    }

    /// A bare leading episode number, as in `"03 - Episode Title.mkv"`.
    private static func leadingNumber(in base: String) -> Int? {
        firstMatch(in: base, pattern: #"^(\d{1,3})(?:[.\s_-]|$)"#).flatMap { Int($0[1]) }
    }

    /// A captured title prefix that's too short to search on (empty, or just
    /// leftover punctuation) is worse than no title — the caller falls back
    /// to the parent folder instead.
    private static func meaningfulPrefix(_ prefix: String) -> String? {
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count >= 2 ? trimmed : nil
    }

    /// The last path component that isn't itself a season/episode label, so
    /// `"Show Name/Season 02"` yields `"Show Name"` rather than `"Season 02"`.
    private static func folderTitle(from parentPath: String) -> String? {
        let components = parentPath.split(separator: "/").map(String.init)
        for component in components.reversed() where !isSeasonOrEpisodeLabel(component) {
            return component
        }
        return nil
    }

    private static func isSeasonOrEpisodeLabel(_ text: String) -> Bool {
        let lower = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lower.range(of: #"^(season|series)\s*\d+$"#, options: .regularExpression) != nil
            || lower.range(of: #"^s\d{1,2}$"#, options: .regularExpression) != nil
            || lower.range(of: #"^episode\s*\d+$"#, options: .regularExpression) != nil
    }

    // MARK: - Year

    private static func extractYear(in text: String) -> Int? {
        if let m = firstMatch(in: text, pattern: #"[\(\[](19\d{2}|20\d{2})[\)\]]"#), let year = Int(m[1]) {
            return year
        }
        // A match at position 0 could be the start of a title that itself
        // looks like a year ("2001: A Space Odyssey") rather than a real
        // release year — prefer a later match when one exists, matching
        // `cleanTitle`'s own never-cut-at-the-first-word rule. Only falls
        // back to a leading match when it's the sole candidate.
        let matches = allMatches(in: text, pattern: #"(?:^|[.\s_-])(19\d{2}|20\d{2})(?:[.\s_-]|$)"#)
        guard !matches.isEmpty else { return nil }
        return (matches.first { $0.start > 0 } ?? matches[0]).value
    }

    // MARK: - Title cleanup

    /// Cuts a filename fragment at its first release token or bare year and
    /// collapses separators, leaving just the title. The cut always leaves at
    /// least one word — a title that itself starts with a year-like number
    /// ("2001: A Space Odyssey") only gets cut at a *later* token, not
    /// truncated to nothing.
    private static func cleanTitle(_ raw: String) -> String? {
        let spaced = raw.split(separator: ".", omittingEmptySubsequences: true).joined(separator: " ")
        let words = spaced.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard !words.isEmpty else { return nil }

        var cutIndex = words.count
        for index in 1..<words.count {
            let normalized = words[index]
                .trimmingCharacters(in: CharacterSet(charactersIn: "()[]"))
                .lowercased()
            let looksLikeYear = Int(normalized).map { (1900...2099).contains($0) } ?? false
            if releaseTokens.contains(normalized) || looksLikeYear {
                cutIndex = index
                break
            }
        }

        let title = words.prefix(cutIndex).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    // MARK: - Helpers

    private static func normalizeSeparators(_ text: String) -> String {
        text.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "+", with: " ")
    }

    /// Capture groups for the first match (index 0 = whole match), or nil.
    /// An unmatched optional group comes back as `""`.
    private static func firstMatch(in text: String, pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            guard let r = Range(match.range(at: index), in: text) else { return "" }
            return String(text[r])
        }
    }

    /// Every match's first capture group as an `Int`, with its start offset
    /// (in characters from the start of `text`) so callers can tell a match
    /// at the very beginning of the string from a later one.
    private static func allMatches(in text: String, pattern: String) -> [(start: Int, value: Int)] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let captureRange = Range(match.range(at: 1), in: text),
                  let value = Int(text[captureRange]) else { return nil }
            let start = text.distance(from: text.startIndex, to: captureRange.lowerBound)
            return (start, value)
        }
    }
}
