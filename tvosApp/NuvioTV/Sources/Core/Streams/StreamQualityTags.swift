import Foundation

/// Parsed quality / delivery tags from a stream card or last-watched fingerprint.
/// Used for ranking, resume matching, and lightweight source badges.
struct StreamQualityTags: Equatable, Codable {
    var resolution: Int = 0
    var isDolbyVision: Bool = false
    var isHDR: Bool = false
    var isAtmos: Bool = false
    var isCached: Bool = false
    var bingeGroup: String? = nil
    var addonName: String? = nil

    var hasVisualPreference: Bool { isDolbyVision || isHDR }
    var hasAudioPreference: Bool { isAtmos }

    static func parse(
        name: String? = nil,
        description: String? = nil,
        filename: String? = nil,
        url: String? = nil,
        bingeGroup: String? = nil,
        addonName: String? = nil,
        isCachedHint: Bool? = nil
    ) -> StreamQualityTags {
        let text = [name, description, filename, url]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()

        var tags = StreamQualityTags()
        tags.resolution = resolution(in: text)
        tags.isDolbyVision = textContainsAny(text, [
            "dolby vision", "dolbyvision", " dovi", "dovi ", "dvhe", "dvh1",
            " profile 5", "profile 5", " profile 7", "profile 7", " profile 8", "profile 8",
            " dv ", "dv.", ".dv.", "[dv]", "(dv)"
        ]) || text.range(of: #"\bdv\b"#, options: .regularExpression) != nil
        tags.isHDR = tags.isDolbyVision || textContainsAny(text, [
            "hdr10+", "hdr10", "hdr", "hlg", "pq10"
        ])
        tags.isAtmos = textContainsAny(text, [
            "atmos", "truehd atmos", "ddp atmos", "eac3 atmos", "dd+ atmos"
        ])
        tags.isCached = isCachedHint == true || textContainsAny(text, [
            "⚡", "[cached]", "(cached)", " cached", "cached ",
            "[rd+", "rd+", "[pm+", "pm+", "[tb+", "tb+", "torbox+",
            "instant", "debrid +"
        ])
        if let bingeGroup, !bingeGroup.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            tags.bingeGroup = bingeGroup.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let addonName, !addonName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            tags.addonName = addonName.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return tags
    }

    static func parse(stream: NuvioStream) -> StreamQualityTags {
        parse(
            name: stream.name,
            description: stream.description,
            filename: stream.filename,
            url: stream.url,
            bingeGroup: stream.bingeGroup,
            addonName: stream.addonName,
            isCachedHint: stream.isCached
        )
    }

    /// Higher is a better match to the previously watched stream / quality prefs.
    func matchScore(against preferred: StreamQualityTags) -> Int {
        var score = 0
        if let preferredGroup = preferred.bingeGroup,
           let group = bingeGroup,
           preferredGroup.compare(group, options: .caseInsensitive) == .orderedSame {
            // Stremio defines bingeGroup specifically for matching the same
            // release across episodes. It must dominate general quality ranking.
            score += 500_000
        }
        if let preferredAddon = preferred.addonName,
           let addon = addonName,
           preferredAddon.compare(addon, options: .caseInsensitive) == .orderedSame {
            // If an add-on does not expose bingeGroup, remain on the provider the
            // user selected before falling back to the global smart ordering.
            score += 250_000
        }
        if preferred.isDolbyVision, isDolbyVision { score += 80_000 }
        else if preferred.isHDR, isHDR { score += 50_000 }
        else if preferred.hasVisualPreference, hasVisualPreference { score += 20_000 }

        if preferred.isAtmos, isAtmos { score += 40_000 }

        if preferred.resolution > 0, resolution > 0 {
            let delta = abs(preferred.resolution - resolution)
            score += max(0, 30_000 - delta * 8)
        }

        if preferred.isCached, isCached { score += 15_000 }
        return score
    }

    private static func resolution(in text: String) -> Int {
        if text.contains("2160") || text.contains("4k") || text.contains("uhd") { return 2160 }
        if text.contains("1440") || text.contains("2k") { return 1440 }
        if text.contains("1080") || text.contains("fhd") { return 1080 }
        if text.contains("720") { return 720 }
        if text.contains("480") { return 480 }
        return 0
    }

    private static func textContainsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }
}

/// Profile-scoped memory of the last stream quality for a title, so resume can
/// re-scrape a fresh link that still matches DV / HDR / Atmos / resolution.
/// Keys live in the active profile's `UserDefaults` suite via `ProfileSettings`.
enum LastStreamQualityStore {
    private static let prefix = "nuvio.tv.lastStreamQuality."

    static func save(metaId: String, tags: StreamQualityTags, profileId: String? = nil) {
        let key = prefix + metaId
        guard let data = try? JSONEncoder().encode(tags) else { return }
        defaults(for: profileId).set(data, forKey: key)
    }

    static func save(metaId: String, stream: NuvioStream, profileId: String? = nil) {
        save(metaId: metaId, tags: StreamQualityTags.parse(stream: stream), profileId: profileId)
    }

    static func save(
        metaId: String,
        name: String?,
        description: String?,
        filename: String?,
        url: String?,
        profileId: String? = nil
    ) {
        save(
            metaId: metaId,
            tags: StreamQualityTags.parse(
                name: name,
                description: description,
                filename: filename,
                url: url
            ),
            profileId: profileId
        )
    }

    static func load(metaId: String, profileId: String? = nil) -> StreamQualityTags? {
        let key = prefix + metaId
        guard let data = defaults(for: profileId).data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(StreamQualityTags.self, from: data)
    }

    private static func defaults(for profileId: String?) -> UserDefaults {
        if let profileId {
            return ProfileSettings.store(for: profileId)
        }
        return ProfileSettings.current
    }
}

/// Lightweight badges shown on stream rows (not full Badger packs).
enum StreamBadgeKind: String, CaseIterable, Identifiable {
    case dolbyVision = "DV"
    case hdr = "HDR"
    case atmos = "Atmos"
    case fourK = "4K"
    case fullHD = "1080p"
    case cached = "Cached"

    var id: String { rawValue }

    var tint: (bg: Double, fg: Double) {
        switch self {
        case .dolbyVision: return (0.45, 1)
        case .hdr: return (0.35, 1)
        case .atmos: return (0.28, 1)
        case .fourK: return (0.22, 1)
        case .fullHD: return (0.16, 1)
        case .cached: return (0.20, 1)
        }
    }

    static func badges(for tags: StreamQualityTags) -> [StreamBadgeKind] {
        var list: [StreamBadgeKind] = []
        if tags.isDolbyVision { list.append(.dolbyVision) }
        else if tags.isHDR { list.append(.hdr) }
        if tags.isAtmos { list.append(.atmos) }
        if tags.resolution >= 2160 { list.append(.fourK) }
        else if tags.resolution >= 1080 { list.append(.fullHD) }
        if tags.isCached { list.append(.cached) }
        return list
    }

    static func badges(for stream: NuvioStream) -> [StreamBadgeKind] {
        badges(for: StreamQualityTags.parse(stream: stream))
    }
}
