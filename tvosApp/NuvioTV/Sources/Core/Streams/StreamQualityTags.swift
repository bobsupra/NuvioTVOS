import Foundation

/// Release quality tier matching Android TV's `DebridStreamQuality`.
enum DebridStreamQuality: Int, Codable, Comparable, CaseIterable {
    case unknown = 0
    case scr = 1
    case tc = 2
    case ts = 3
    case cam = 4
    case hdtv = 5
    case dvdrip = 6
    case hdRip = 7
    case hdrip = 8
    case webrip = 9
    case webDl = 10
    case bluray = 11
    case blurayRemux = 12

    static func < (lhs: DebridStreamQuality, rhs: DebridStreamQuality) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var label: String {
        switch self {
        case .blurayRemux: return "BluRay REMUX"
        case .bluray: return "BluRay"
        case .webDl: return "WEB-DL"
        case .webrip: return "WEBRip"
        case .hdrip: return "HDRip"
        case .hdRip: return "HC HD-Rip"
        case .dvdrip: return "DVDRip"
        case .hdtv: return "HDTV"
        case .cam: return "CAM"
        case .ts: return "TS"
        case .tc: return "TC"
        case .scr: return "SCR"
        case .unknown: return "Unknown"
        }
    }
}

/// Parsed quality / delivery tags from a stream card or last-watched fingerprint.
/// Used for ranking, resume matching, and lightweight source badges.
struct StreamQualityTags: Equatable, Codable {
    var resolution: Int = 0
    var isDolbyVision: Bool = false
    var isHDR: Bool = false
    var isAtmos: Bool = false
    var isCached: Bool = false
    var isHEVC: Bool = false
    var isAVC: Bool = false
    var isAV1: Bool = false
    var quality: DebridStreamQuality = .unknown
    var bingeGroup: String? = nil
    var addonName: String? = nil

    var hasVisualPreference: Bool { isDolbyVision || isHDR }
    var hasAudioPreference: Bool { isAtmos }

    /// Returns true if this stream is hardware-accelerated on the provided Apple TV capability profile.
    func isHardwareAccelerated(on capability: AppleTVCapability = .current) -> Bool {
        if isAV1 {
            return capability.supportsAV1HardwareDecode
        }
        if isHEVC {
            return capability.supportsHEVCHardwareDecode && (resolution == 0 || resolution <= capability.maxResolution)
        }
        if isAVC {
            return resolution == 0 || resolution <= capability.maxResolution
        }
        // Unknown codec defaults to hardware compatibility check based on resolution
        return resolution == 0 || resolution <= capability.maxResolution
    }

    static func parse(
        name: String? = nil,
        description: String? = nil,
        filename: String? = nil,
        url: String? = nil,
        bingeGroup: String? = nil,
        addonName: String? = nil,
        isCachedHint: Bool? = nil
    ) -> StreamQualityTags {
        // Exclude stream URLs from resolution and quality parsing. URLs often contain random
        // hex hashes, timestamps, port numbers, or query parameters (e.g. /720/ or ?v=2k) that
        // lead to false-positive resolution classification. Only inspect release metadata.
        let metadataText = [name, description, filename]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()

        let fullText = [name, description, filename, url]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()

        var tags = StreamQualityTags()
        tags.resolution = resolution(in: metadataText)
        tags.quality = quality(in: metadataText)
        tags.isDolbyVision = textContainsAny(fullText, [
            "dolby vision", "dolbyvision", " dovi", "dovi ", "dvhe", "dvh1",
            " profile 5", "profile 5", " profile 7", "profile 7", " profile 8", "profile 8",
            " dv ", "dv.", ".dv.", "[dv]", "(dv)"
        ]) || fullText.range(of: #"\bdv\b"#, options: .regularExpression) != nil
        // Match HDR markers as standalone release tokens. `HDRip` is a common
        // SDR release label (High Definition rip), not an HDR transfer.
        tags.isHDR = tags.isDolbyVision || textContainsHDRToken(fullText)
        tags.isAtmos = textContainsAny(fullText, [
            "atmos", "truehd atmos", "ddp atmos", "eac3 atmos", "dd+ atmos"
        ])
        tags.isCached = isCachedHint == true || textContainsAny(fullText, [
            "⚡", "[cached]", "(cached)", " cached", "cached ",
            "[rd+", "rd+", "[pm+", "pm+", "[tb+", "tb+", "torbox+",
            "instant", "debrid +"
        ])
        tags.isAV1 = textContainsAV1Token(fullText)
        tags.isHEVC = textContainsHEVCToken(fullText)
        tags.isAVC = textContainsAVCToken(fullText)
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
        // Preferred quality tags must have valid resolution (>= 720p). If a corrupt/ticket
        // stream was previously saved as preference, do not match against it.
        guard preferred.resolution >= 720 else { return 0 }
        if resolution == 0 { return -300_000 }

        var score = 0
        if let preferredGroup = preferred.bingeGroup,
           let group = bingeGroup,
           preferredGroup.compare(group, options: .caseInsensitive) == .orderedSame {
            // Stremio defines bingeGroup specifically for matching the same
            // release across episodes. Only reward if the current stream is also valid (>= 720p).
            if resolution >= 720 {
                score += 500_000
            }
        }
        if let preferredAddon = preferred.addonName,
           let addon = addonName,
           preferredAddon.compare(addon, options: .caseInsensitive) == .orderedSame {
            // Only reward addon continuity if the stream has a valid resolution (not an unknown/ticket entry).
            if resolution >= 720 {
                score += 50_000
            }
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
        if resolution < 720 { score -= 150_000 }
        return score
    }

    /// Canonical token-based resolution parsing matching Android TV's `resolutionValue`.
    static func resolution(in text: String) -> Int {
        let lower = text.lowercased()
        func hasToken(_ pattern: String) -> Bool {
            lower.range(
                of: #"(?:^|[^a-z0-9])(?:"# + pattern + #")(?:[^a-z0-9]|$)"#,
                options: .regularExpression
            ) != nil
        }

        if hasToken("2160p?|4k|uhd") { return 2160 }
        if hasToken("1440p?|2k") { return 1440 }
        if hasToken("1080p?|fhd") { return 1080 }
        if hasToken("720p?|hd") { return 720 }
        if hasToken("576p?") { return 576 }
        if hasToken("480p?|sd") { return 480 }
        if hasToken("360p?") { return 360 }
        return 0
    }

    /// Canonical release quality classification matching Android TV's `streamQuality`.
    static func quality(in text: String) -> DebridStreamQuality {
        let lower = text.lowercased()
        func hasToken(_ token: String) -> Bool {
            lower.range(
                of: #"(?:^|[^a-z0-9])"# + NSRegularExpression.escapedPattern(for: token) + #"(?:[^a-z0-9]|$)"#,
                options: .regularExpression
            ) != nil
        }

        if lower.contains("remux") { return .blurayRemux }
        if lower.contains("blu-ray") || lower.contains("bluray") || lower.contains("bdrip") || lower.contains("brrip") { return .bluray }
        if lower.contains("web-dl") || lower.contains("webdl") { return .webDl }
        if lower.contains("webrip") || lower.contains("web-rip") { return .webrip }
        if lower.contains("hdrip") { return .hdrip }
        if lower.contains("hd-rip") || lower.contains("hcrip") { return .hdRip }
        if lower.contains("dvdrip") { return .dvdrip }
        if lower.contains("hdtv") { return .hdtv }
        if hasToken("cam") { return .cam }
        if hasToken("ts") { return .ts }
        if hasToken("tc") { return .tc }
        if hasToken("scr") { return .scr }
        return .unknown
    }

    private static func textContainsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    private static func textContainsHDRToken(_ text: String) -> Bool {
        text.range(
            of: #"(?<![a-z0-9])(?:hdr10\+?|hdr|hlg|pq10)(?![a-z0-9])"#,
            options: .regularExpression
        ) != nil
    }

    private static func textContainsAV1Token(_ text: String) -> Bool {
        text.range(
            of: #"(?<![a-z0-9])(?:av1|av01)(?![a-z0-9])"#,
            options: .regularExpression
        ) != nil
    }

    private static func textContainsHEVCToken(_ text: String) -> Bool {
        text.range(
            of: #"(?<![a-z0-9])(?:hevc|h\.?265|x265|dvhe|dvh1)(?![a-z0-9])"#,
            options: .regularExpression
        ) != nil
    }

    private static func textContainsAVCToken(_ text: String) -> Bool {
        text.range(
            of: #"(?<![a-z0-9])(?:avc1?|h\.?264|x264)(?![a-z0-9])"#,
            options: .regularExpression
        ) != nil
    }
}

/// Profile-scoped memory of the last stream quality for a title, so resume can
/// re-scrape a fresh link that still matches DV / HDR / Atmos / resolution.
/// Keys live in the active profile's `UserDefaults` suite via `ProfileSettings`.
enum LastStreamQualityStore {
    private static let prefix = "nuvio.tv.lastStreamQuality."

    static func save(metaId: String, tags: StreamQualityTags, profileId: String? = nil) {
        // Never persist low-resolution (< 720p), unknown, or ticket streams as the title's preferred quality
        guard tags.resolution >= 720 else { return }
        let key = prefix + metaId
        guard let data = try? JSONEncoder().encode(tags) else { return }
        defaults(for: profileId).set(data, forKey: key)
    }

    static func save(metaId: String, stream: NuvioStream, profileId: String? = nil) {
        var tags = StreamQualityTags.parse(stream: stream)
        if tags.resolution == 0 {
            tags.resolution = SmartPlaybackSelector.inferredResolution(for: stream)
        }
        save(metaId: metaId, tags: tags, profileId: profileId)
    }

    static func save(
        metaId: String,
        name: String?,
        description: String?,
        filename: String?,
        url: String?,
        profileId: String? = nil
    ) {
        let tags = StreamQualityTags.parse(
            name: name,
            description: description,
            filename: filename,
            url: url
        )
        save(metaId: metaId, tags: tags, profileId: profileId)
    }

    static func load(metaId: String, profileId: String? = nil) -> StreamQualityTags? {
        let key = prefix + metaId
        let store = defaults(for: profileId)
        guard let data = store.data(forKey: key) else { return nil }
        guard let tags = try? JSONDecoder().decode(StreamQualityTags.self, from: data) else { return nil }
        // Self-heal: purge corrupt/sub-720p/ticket tags from UserDefaults so a title never gets stuck on N/A
        if tags.resolution < 720 {
            store.removeObject(forKey: key)
            return nil
        }
        return tags
    }

    private static func defaults(for profileId: String?) -> UserDefaults {
        if let profileId {
            return ProfileSettings.store(for: profileId)
        }
        return ProfileSettings.current
    }
}

/// Profile-scoped memory of the exact playable link used for the latest
/// in-progress movie or episode. Progress providers do not retain source URLs,
/// so this stays separate from their authoritative resume position.
enum LastPlaybackStreamStore {
    private static let prefix = "nuvio.tv.lastPlaybackStream."

    private struct Record: Codable {
        let url: String
        /// Optional for compatibility with records saved before stream headers
        /// were persisted.
        let httpHeaders: [String: String]?
        let season: Int?
        let episode: Int?
    }

    static func save(
        metaId: String,
        url: String,
        httpHeaders: [String: String] = [:],
        season: Int?,
        episode: Int?,
        profileId: String? = nil
    ) {
        let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !metaId.isEmpty, !url.isEmpty, URL(string: url) != nil,
              let data = try? JSONEncoder().encode(
                Record(
                    url: url,
                    httpHeaders: httpHeaders.isEmpty ? nil : httpHeaders,
                    season: season,
                    episode: episode
                )
              ) else { return }
        defaults(for: profileId).set(data, forKey: prefix + metaId)
    }

    static func load(
        metaId: String,
        season: Int?,
        episode: Int?,
        profileId: String? = nil
    ) -> (url: String, httpHeaders: [String: String])? {
        guard let data = defaults(for: profileId).data(forKey: prefix + metaId),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.season == season,
              record.episode == episode else {
            return nil
        }
        return (record.url, record.httpHeaders ?? [:])
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
    case hevc = "HEVC"
    case avc = "AVC"
    case av1 = "AV1"

    var id: String { rawValue }

    var tint: (bg: Double, fg: Double) {
        switch self {
        case .dolbyVision: return (0.45, 1)
        case .hdr: return (0.35, 1)
        case .atmos: return (0.28, 1)
        case .fourK: return (0.22, 1)
        case .fullHD: return (0.16, 1)
        case .cached: return (0.20, 1)
        case .hevc: return (0.26, 1)
        case .avc: return (0.18, 1)
        case .av1: return (0.30, 1)
        }
    }

    static func badges(for tags: StreamQualityTags) -> [StreamBadgeKind] {
        var list: [StreamBadgeKind] = []
        if tags.isDolbyVision { list.append(.dolbyVision) }
        else if tags.isHDR { list.append(.hdr) }
        if tags.isAtmos { list.append(.atmos) }
        if tags.resolution >= 2160 { list.append(.fourK) }
        else if tags.resolution >= 1080 { list.append(.fullHD) }
        if tags.isHEVC { list.append(.hevc) }
        else if tags.isAV1 { list.append(.av1) }
        else if tags.isAVC { list.append(.avc) }
        if tags.isCached { list.append(.cached) }
        return list
    }

    static func badges(for stream: NuvioStream) -> [StreamBadgeKind] {
        badges(for: StreamQualityTags.parse(stream: stream))
    }
}

// MARK: - Android TV stream badges

/// The image-backed badge pack format used by Android TV. Keeping the wire
/// shape here lets tvOS consume the same hosted JSON without making the stream
/// model carry presentation-only state.
struct StreamBadgeFilter: Codable, Equatable {
    var id: String = ""
    var groupId: String = ""
    var name: String = ""
    var pattern: String = ""
    var imageURL: String = ""
    var isEnabled: Bool = true
    var tagColor: String = ""
    var tagStyle: String = ""
    var textColor: String = ""
    var borderColor: String = ""
    init(
        id: String = "",
        groupId: String = "",
        name: String = "",
        pattern: String = "",
        imageURL: String = "",
        isEnabled: Bool = true,
        tagColor: String = "",
        tagStyle: String = "",
        textColor: String = "",
        borderColor: String = ""
    ) {
        self.id = id
        self.groupId = groupId
        self.name = name
        self.pattern = pattern
        self.imageURL = imageURL
        self.isEnabled = isEnabled
        self.tagColor = tagColor
        self.tagStyle = tagStyle
        self.textColor = textColor
        self.borderColor = borderColor
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        groupId = try container.decodeIfPresent(String.self, forKey: .groupId) ?? ""
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        pattern = try container.decodeIfPresent(String.self, forKey: .pattern) ?? ""
        imageURL = try container.decodeIfPresent(String.self, forKey: .imageURL)
            ?? (try container.decodeIfPresent(String.self, forKey: .imageUrl)) ?? ""
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        tagColor = try container.decodeIfPresent(String.self, forKey: .tagColor) ?? ""
        tagStyle = try container.decodeIfPresent(String.self, forKey: .tagStyle) ?? ""
        textColor = try container.decodeIfPresent(String.self, forKey: .textColor) ?? ""
        borderColor = try container.decodeIfPresent(String.self, forKey: .borderColor) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(groupId, forKey: .groupId)
        try container.encode(name, forKey: .name)
        try container.encode(pattern, forKey: .pattern)
        try container.encode(imageURL, forKey: .imageURL)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(tagColor, forKey: .tagColor)
        try container.encode(tagStyle, forKey: .tagStyle)
        try container.encode(textColor, forKey: .textColor)
        try container.encode(borderColor, forKey: .borderColor)
    }

    private enum CodingKeys: String, CodingKey {
        case id, groupId, name, pattern, imageURL, imageUrl, isEnabled, tagColor, tagStyle, textColor, borderColor
    }

    /// Canonical resolution tier (e.g. 2160 for 4K, 1080 for 1080p) if this filter represents a resolution badge.
    var resolutionTier: Int? {
        let key = " \(name) \(id) ".lowercased()
        func hasToken(_ pat: String) -> Bool {
            key.range(
                of: #"(?:^|[^a-z0-9])(?:"# + pat + #")(?:[^a-z0-9]|$)"#,
                options: .regularExpression
            ) != nil
        }
        if hasToken("4k|2160p?|uhd") { return 2160 }
        if hasToken("1440p?|2k|qhd") { return 1440 }
        if hasToken("1080p?|fhd") { return 1080 }
        if hasToken("720p?|hd720|hd") { return 720 }
        if hasToken("480p?|sd480|sd") { return 480 }
        return nil
    }

    func isResolutionFilter(in groups: [StreamBadgeGroup] = []) -> Bool {
        if resolutionTier != nil { return true }
        if let group = groups.first(where: { $0.id == groupId }),
           group.name.localizedCaseInsensitiveContains("resolution") {
            return true
        }
        return groupId.localizedCaseInsensitiveContains("res")
    }

    var isSDRFilter: Bool {
        let key = " \(name) \(id) ".lowercased()
        return key.range(
            of: #"(?:^|[^a-z0-9])sdr(?:[^a-z0-9]|$)"#,
            options: .regularExpression
        ) != nil
    }

    var isHDRFilter: Bool {
        let key = " \(name) \(id) ".lowercased()
        return key.range(
            of: #"(?:^|[^a-z0-9])(?:hdr(?:10\+?|10p)?|dv|dovi|dolby\s*vision)(?:[^a-z0-9]|$)"#,
            options: .regularExpression
        ) != nil
    }
}

struct StreamBadgeGroup: Codable, Equatable {
    var id: String = ""
    var name: String = ""
    var color: String = ""
    var isExpanded: Bool = true

    init(
        id: String = "",
        name: String = "",
        color: String = "",
        isExpanded: Bool = true
    ) {
        self.id = id
        self.name = name
        self.color = color
        self.isExpanded = isExpanded
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        color = try container.decodeIfPresent(String.self, forKey: .color) ?? ""
        isExpanded = try container.decodeIfPresent(Bool.self, forKey: .isExpanded) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(color, forKey: .color)
        try container.encode(isExpanded, forKey: .isExpanded)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, color, isExpanded
    }
}

struct StreamBadgeImport: Codable, Equatable, Identifiable {
    var sourceUrl: String
    var filters: [StreamBadgeFilter]
    var groups: [StreamBadgeGroup] = []
    var isActive: Bool = true

    var id: String { sourceUrl }
    var enabledFilterCount: Int { filters.filter(\.isEnabled).count }
}

struct StreamBadgeRules: Codable, Equatable {
    static let importLimit = 3
    var imports: [StreamBadgeImport] = []

    var activeImport: StreamBadgeImport? {
        imports.first(where: { $0.isActive })
    }

    func normalized() -> StreamBadgeRules {
        var result: [StreamBadgeImport] = []
        for item in imports {
            let url = item.sourceUrl.trimmingCharacters(in: .whitespacesAndNewlines)
            let filters = item.filters.filter {
                !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                !$0.pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            guard !url.isEmpty, !filters.isEmpty else { continue }
            let normalized = StreamBadgeImport(
                sourceUrl: url,
                filters: filters,
                groups: item.groups,
                isActive: item.isActive
            )
            if let index = result.firstIndex(where: { $0.sourceUrl.caseInsensitiveCompare(url) == .orderedSame }) {
                result[index] = normalized
            } else if result.count < Self.importLimit {
                result.append(normalized)
            }
        }
        return StreamBadgeRules(imports: result)
    }

    func upserting(_ item: StreamBadgeImport, activate: Bool = true) -> StreamBadgeRules {
        var next = normalized().imports
        var item = item
        item.sourceUrl = item.sourceUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        item.isActive = activate
        if let index = next.firstIndex(where: { $0.sourceUrl.caseInsensitiveCompare(item.sourceUrl) == .orderedSame }) {
            next[index] = item
        } else {
            next.append(item)
        }
        if activate {
            next = next.map { current in
                var current = current
                current.isActive = current.sourceUrl.caseInsensitiveCompare(item.sourceUrl) == .orderedSame
                return current
            }
        }
        return StreamBadgeRules(imports: next).normalized()
    }

    func settingActive(sourceUrl: String) -> StreamBadgeRules {
        let sourceUrl = sourceUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard imports.contains(where: { $0.sourceUrl.caseInsensitiveCompare(sourceUrl) == .orderedSame }) else {
            return normalized()
        }
        return StreamBadgeRules(imports: imports.map { item in
            var item = item
            item.isActive = item.sourceUrl.caseInsensitiveCompare(sourceUrl) == .orderedSame
            return item
        }).normalized()
    }

    /// Disabling the selected pack leaves its rules installed but stops badges
    /// from rendering. Enabling a pack makes it the selected source, preserving
    /// the Android TV one-pack-at-a-time behaviour.
    func settingEnabled(sourceUrl: String, isEnabled: Bool) -> StreamBadgeRules {
        guard isEnabled else {
            return StreamBadgeRules(imports: imports.map { item in
                var item = item
                if item.sourceUrl.caseInsensitiveCompare(sourceUrl) == .orderedSame {
                    item.isActive = false
                }
                return item
            }).normalized()
        }
        return settingActive(sourceUrl: sourceUrl)
    }

    func removing(sourceUrl: String) -> StreamBadgeRules {
        StreamBadgeRules(
            imports: imports.filter { $0.sourceUrl.caseInsensitiveCompare(sourceUrl.trimmingCharacters(in: .whitespacesAndNewlines)) != .orderedSame }
        ).normalized()
    }
}

private struct StreamBadgePayload: Decodable {
    let filters: [StreamBadgeFilter]
    let groups: [StreamBadgeGroup]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        filters = try container.decodeIfPresent([StreamBadgeFilter].self, forKey: .filters) ?? []
        groups = try container.decodeIfPresent([StreamBadgeGroup].self, forKey: .groups) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case filters
        case groups
    }
}

private enum StreamBadgeRulesParser {
    static func parse(sourceUrl: String, data: Data) throws -> StreamBadgeImport {
        let payload = try JSONDecoder().decode(StreamBadgePayload.self, from: data)
        let filters = payload.filters.filter {
            !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !$0.pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !filters.isEmpty else {
            throw NSError(domain: "NuvioStreamBadges", code: 1, userInfo: [NSLocalizedDescriptionKey: "Badge import did not contain any usable filters."])
        }
        return StreamBadgeImport(
            sourceUrl: sourceUrl.trimmingCharacters(in: .whitespacesAndNewlines),
            filters: filters,
            groups: payload.groups
        )
    }
}

enum StreamBadgePlacement: String, Codable, CaseIterable {
    case top = "TOP"
    case bottom = "BOTTOM"
}

struct StreamBadgeSettingsSnapshot: Equatable {
    var rules: StreamBadgeRules
    var showFileSizeBadges: Bool
    var showAddonLogo: Bool
    var badgePlacement: StreamBadgePlacement
}

/// Profile-scoped storage and URL importer for Android TV-compatible badges.
enum StreamBadgeSettingsStore {
    static let changedNotification = Notification.Name("NuvioStreamBadgeSettingsChanged")
    static let goldBadgePackURL = "https://raw.githubusercontent.com/djgenesis/badges/refs/heads/main/gold_badges_complete.json"

    private static var cachedSnapshot: StreamBadgeSettingsSnapshot?
    private static var cachedProfileScope: String?
    private static var cachedRulesValue: String?

    static var snapshot: StreamBadgeSettingsSnapshot {
        let profileScope = ProfileSettings.activeProfileScope
        let defaults = ProfileSettings.current
        let storedRules = defaults.string(forKey: SettingsKey.streamBadgeRules)
        let storedPlacement = defaults.string(forKey: SettingsKey.streamBadgePlacement)
        let storedFileSize = defaults.object(forKey: SettingsKey.showFileSizeBadges) as? Bool ?? true
        let storedAddonLogo = defaults.object(forKey: SettingsKey.showAddonLogo) as? Bool ?? false
        let placement = StreamBadgePlacement(rawValue: storedPlacement ?? StreamBadgePlacement.bottom.rawValue) ?? .bottom

        if cachedProfileScope == profileScope,
           cachedRulesValue == storedRules,
           let cachedSnapshot,
           cachedSnapshot.showFileSizeBadges == storedFileSize,
           cachedSnapshot.showAddonLogo == storedAddonLogo,
           cachedSnapshot.badgePlacement == placement {
            return cachedSnapshot
        }

        let rules: StreamBadgeRules
        if let data = storedRules?.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(StreamBadgeRules.self, from: data) {
            rules = decoded.normalized()
        } else {
            rules = StreamBadgeRules()
        }
        let snapshot = StreamBadgeSettingsSnapshot(
            rules: rules,
            showFileSizeBadges: storedFileSize,
            showAddonLogo: storedAddonLogo,
            badgePlacement: placement
        )
        cachedProfileScope = profileScope
        cachedRulesValue = storedRules
        cachedSnapshot = snapshot
        return snapshot
    }

    static func saveRules(_ rules: StreamBadgeRules) {
        let rules = rules.normalized()
        let defaults = ProfileSettings.current
        if rules.imports.isEmpty {
            defaults.removeObject(forKey: SettingsKey.streamBadgeRules)
        } else if let data = try? JSONEncoder().encode(rules), let value = String(data: data, encoding: .utf8) {
            defaults.set(value, forKey: SettingsKey.streamBadgeRules)
        }
        postChanged()
    }

    static func setPlacement(_ placement: StreamBadgePlacement) {
        ProfileSettings.current.set(placement.rawValue, forKey: SettingsKey.streamBadgePlacement)
        postChanged()
    }

    static func setShowFileSizeBadges(_ enabled: Bool) {
        ProfileSettings.current.set(enabled, forKey: SettingsKey.showFileSizeBadges)
        postChanged()
    }

    static func setShowAddonLogo(_ enabled: Bool) {
        ProfileSettings.current.set(enabled, forKey: SettingsKey.showAddonLogo)
        postChanged()
    }

    static func setActiveSource(_ sourceUrl: String) {
        saveRules(snapshot.rules.settingActive(sourceUrl: sourceUrl))
    }

    static func setSourceEnabled(_ sourceUrl: String, isEnabled: Bool) {
        saveRules(snapshot.rules.settingEnabled(sourceUrl: sourceUrl, isEnabled: isEnabled))
    }

    static func removeSource(_ sourceUrl: String) {
        saveRules(snapshot.rules.removing(sourceUrl: sourceUrl))
    }

    static func importRules(from rawUrl: String) async throws -> StreamBadgeRules {
        let trimmedUrl = rawUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        // The tvOS Simulator's remote-keyboard bridge can turn the colon in a
        // pasted scheme into `>`. Treat that one input artifact as its intended
        // `://` separator so a valid HTTPS pack URL still imports.
        let normalizedUrl: String
        if trimmedUrl.hasPrefix("https>//") {
            normalizedUrl = "https://" + trimmedUrl.dropFirst("https>//".count)
        } else if trimmedUrl.hasPrefix("http>//") {
            normalizedUrl = "http://" + trimmedUrl.dropFirst("http>//".count)
        } else {
            normalizedUrl = trimmedUrl
        }
        guard let url = URL(string: normalizedUrl),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw NSError(domain: "NuvioStreamBadges", code: 2, userInfo: [NSLocalizedDescriptionKey: "Badge URL must start with http:// or https://."])
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        if let response = response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
            throw NSError(domain: "NuvioStreamBadges", code: response.statusCode, userInfo: [NSLocalizedDescriptionKey: "Badge server returned HTTP \(response.statusCode)."])
        }
        let imported = try StreamBadgeRulesParser.parse(sourceUrl: normalizedUrl, data: data)
        let current = snapshot.rules
        if !current.imports.contains(where: { $0.sourceUrl.caseInsensitiveCompare(normalizedUrl) == .orderedSame }),
           current.imports.count >= StreamBadgeRules.importLimit {
            throw NSError(domain: "NuvioStreamBadges", code: 3, userInfo: [NSLocalizedDescriptionKey: "You can import up to 3 badge URLs."])
        }
        let rules = current.upserting(imported)
        saveRules(rules)
        return rules
    }

    static func postChanged() {
        cachedSnapshot = nil
        cachedProfileScope = nil
        cachedRulesValue = nil
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: changedNotification, object: nil)
        }
    }
}

enum StreamBadgeMatcher {
    private struct CachedRegex {
        let expression: NSRegularExpression
        let requiresIndividualCandidates: Bool
    }

    private static var regexCache: [String: CachedRegex] = [:]
    private static var invalidPatterns: Set<String> = []
    private static let regexCacheLimit = 512

    static func matchedBadges(for stream: NuvioStream, rules: StreamBadgeRules) -> [StreamBadgeFilter] {
        // Store snapshots are normalized before they reach the picker. Avoid
        // normalizing the complete badge pack again for every stream card.
        guard let active = rules.activeImport else { return [] }
        let candidates = matchCandidates(for: stream)
        guard let combinedCandidate = candidates.last else { return [] }
        let combinedRange = NSRange(
            combinedCandidate.startIndex..<combinedCandidate.endIndex,
            in: combinedCandidate
        )
        var result: [StreamBadgeFilter] = []
        var seen = Set<String>()
        for filter in active.filters where filter.isEnabled {
            guard let cached = regularExpression(for: filter.pattern) else { continue }
            var matched = cached.expression.firstMatch(
                in: combinedCandidate,
                range: combinedRange
            ) != nil

            // Joining fields preserves ordinary word/spacing boundaries and
            // reduces the normal path from up to eight regex scans to one.
            // Explicit start/end anchors still need the original per-field
            // behavior when the combined candidate does not match.
            if !matched, cached.requiresIndividualCandidates, candidates.count > 1 {
                matched = candidates.dropLast().contains { candidate in
                    let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
                    return cached.expression.firstMatch(in: candidate, range: range) != nil
                }
            }
            guard matched else { continue }
            let key = (filter.imageURL.isEmpty ? filter.name : filter.imageURL).lowercased()
            if seen.insert(key).inserted { result.append(filter) }
        }
        return sanitizeMatchedBadges(result, for: stream, groups: active.groups)
    }

    private static func sanitizeMatchedBadges(
        _ badges: [StreamBadgeFilter],
        for stream: NuvioStream,
        groups: [StreamBadgeGroup]
    ) -> [StreamBadgeFilter] {
        guard !badges.isEmpty else { return [] }

        // 1. Resolution mutual exclusivity:
        // A single stream file has one canonical resolution. Never show multiple resolution badges.
        let canonicalResolution = StreamQualityTags.parse(stream: stream).resolution
        let resolutionBadges = badges.filter { $0.isResolutionFilter(in: groups) }

        var winningResolutionBadge: StreamBadgeFilter?
        if !resolutionBadges.isEmpty {
            if canonicalResolution > 0 {
                // If stream is known to be e.g. 1080p, pick the badge matching canonical resolution
                winningResolutionBadge = resolutionBadges.first(where: { $0.resolutionTier == canonicalResolution })
            } else {
                // Unknown canonical resolution: take at most one resolution badge (highest tier or first matched)
                winningResolutionBadge = resolutionBadges.sorted {
                    ($0.resolutionTier ?? 0) > ($1.resolutionTier ?? 0)
                }.first
            }
        }

        // 2. Dynamic range mutual exclusivity:
        // SDR and HDR/DV cannot coexist. If any HDR/DV badge matched, strip SDR badges.
        let hasHDR = badges.contains { $0.isHDRFilter }

        var sanitized: [StreamBadgeFilter] = []
        for badge in badges {
            if badge.isResolutionFilter(in: groups) {
                if let winner = winningResolutionBadge, badge.id == winner.id && badge.name == winner.name {
                    sanitized.append(badge)
                    winningResolutionBadge = nil // ensure only added once
                }
                continue
            }
            if hasHDR && badge.isSDRFilter {
                continue
            }
            sanitized.append(badge)
        }

        return sanitized
    }

    private static func regularExpression(for pattern: String) -> CachedRegex? {
        if let cached = regexCache[pattern] {
            return cached
        }
        if invalidPatterns.contains(pattern) {
            return nil
        }

        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            invalidPatterns.insert(pattern)
            return nil
        }

        let cached = CachedRegex(
            expression: regex,
            requiresIndividualCandidates: hasFieldBoundaryAnchor(pattern)
        )

        if regexCache.count >= regexCacheLimit {
            regexCache.removeAll(keepingCapacity: true)
            invalidPatterns.removeAll(keepingCapacity: true)
        }
        regexCache[pattern] = cached
        return cached
    }

    /// Detect anchors that change meaning when separately searchable stream
    /// fields are joined. Carets inside character classes and escaped literals
    /// are deliberately ignored.
    private static func hasFieldBoundaryAnchor(_ pattern: String) -> Bool {
        var isEscaped = false
        var isInsideCharacterClass = false

        for scalar in pattern.unicodeScalars {
            if isEscaped {
                if !isInsideCharacterClass,
                   scalar == "A" || scalar == "Z" || scalar == "z" || scalar == "G" {
                    return true
                }
                isEscaped = false
                continue
            }

            switch scalar {
            case "\\":
                isEscaped = true
            case "[":
                isInsideCharacterClass = true
            case "]":
                isInsideCharacterClass = false
            case "^" where !isInsideCharacterClass,
                 "$" where !isInsideCharacterClass:
                return true
            default:
                break
            }
        }
        return false
    }

    static func matchCandidates(for stream: NuvioStream) -> [String] {
        // Exclude stream.url, stream.infoHash, and stream.sources. Transport URLs, hashes,
        // and tracker hints contain random tokens, hex strings, or route parameters (e.g. /4k/)
        // that trigger false-positive matches for resolution or source badges. Match solely
        // against clean release metadata, identical to Android TV's badgeMatchCandidates.
        let values = [
            stream.filename,
            stream.name,
            stream.description,
            stream.addonName
        ].compactMap { value -> String? in
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard values.count > 1 else { return values }
        return values + [values.joined(separator: " ")]
    }
}

enum StreamBadgeSizing {
    static func fileSizeBytes(for stream: NuvioStream) -> Int64? {
        if let videoSize = stream.videoSize, videoSize > 0 { return videoSize }
        let text = [stream.name, stream.description, stream.filename]
            .compactMap { $0 }
            .joined(separator: " ")
        let pattern = #"(\d+(?:[.,]\d+)?)\s*(TB|GB|MB|KB)"#
        guard let match = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let token = String(text[match])
        let numberText = token.components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted)
            .first(where: { Double($0) != nil }) ?? "0"
        let number = Double(numberText.replacingOccurrences(of: ",", with: ".")) ?? 0
        let upper = token.uppercased()
        let multiplier: Double = upper.contains("TB") ? 1_099_511_627_776 :
            upper.contains("GB") ? 1_073_741_824 :
            upper.contains("MB") ? 1_048_576 : 1_024
        let bytes = Int64(number * multiplier)
        return bytes > 0 ? bytes : nil
    }

    static func fileSizeLabel(for stream: NuvioStream) -> String? {
        guard let bytes = fileSizeBytes(for: stream) else { return nil }
        let gib = Double(bytes) / 1_073_741_824
        if gib >= 1 {
            return String(format: "Size %.1f GB", gib)
        }
        return "Size \(Int((Double(bytes) / 1_048_576).rounded())) MB"
    }
}
