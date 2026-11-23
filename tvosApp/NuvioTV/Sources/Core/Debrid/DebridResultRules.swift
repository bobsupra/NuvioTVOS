import Foundation

/// One value a result rule can select, such as "2160p" or "Atmos". The id is
/// the desktop app's name for the value.
struct DebridRuleOption: Equatable, Identifiable {
    let id: String
    let label: String
}

/// What a result rule looks at.
enum DebridRuleFacet: String, CaseIterable {
    case resolutions = "Resolutions"
    case qualities = "Qualities"
    case visualTags = "VisualTags"
    case audioTags = "AudioTags"
    case audioChannels = "AudioChannels"
    case encodes = "Encodes"
    case languages = "Languages"

    static let unknown = "UNKNOWN"

    /// The values a rule can select, in the desktop app's default order.
    var options: [DebridRuleOption] {
        switch self {
        case .resolutions:
            return [
                DebridRuleOption(id: "P2160", label: "2160p"),
                DebridRuleOption(id: "P1440", label: "1440p"),
                DebridRuleOption(id: "P1080", label: "1080p"),
                DebridRuleOption(id: "P720", label: "720p"),
                DebridRuleOption(id: "P576", label: "576p"),
                DebridRuleOption(id: "P480", label: "480p"),
                DebridRuleOption(id: "P360", label: "360p"),
                DebridRuleOption(id: Self.unknown, label: "Unknown")
            ]
        case .qualities:
            let order: [DebridStreamQuality] = [
                .blurayRemux, .bluray, .webDl, .webrip, .hdrip, .hdRip, .dvdrip, .hdtv, .cam, .ts, .tc, .scr, .unknown
            ]
            return order.map { DebridRuleOption(id: Self.qualityID($0), label: $0.label) }
        case .visualTags:
            return [
                DebridRuleOption(id: "HDR_DV", label: "HDR+DV"),
                DebridRuleOption(id: "DV_ONLY", label: "DV Only"),
                DebridRuleOption(id: "HDR_ONLY", label: "HDR Only"),
                DebridRuleOption(id: "HDR10_PLUS", label: "HDR10+"),
                DebridRuleOption(id: "HDR10", label: "HDR10"),
                DebridRuleOption(id: "DV", label: "DV"),
                DebridRuleOption(id: "HDR", label: "HDR"),
                DebridRuleOption(id: "HLG", label: "HLG"),
                DebridRuleOption(id: "TEN_BIT", label: "10bit"),
                DebridRuleOption(id: "IMAX", label: "IMAX"),
                DebridRuleOption(id: "SDR", label: "SDR"),
                DebridRuleOption(id: "THREE_D", label: "3D"),
                DebridRuleOption(id: "AI", label: "AI"),
                DebridRuleOption(id: "H_OU", label: "H-OU"),
                DebridRuleOption(id: "H_SBS", label: "H-SBS"),
                DebridRuleOption(id: Self.unknown, label: "Unknown")
            ]
        case .audioTags:
            return [
                DebridRuleOption(id: "ATMOS", label: "Atmos"),
                DebridRuleOption(id: "DD_PLUS", label: "DD+"),
                DebridRuleOption(id: "DD", label: "DD"),
                DebridRuleOption(id: "DTS_X", label: "DTS:X"),
                DebridRuleOption(id: "DTS_HD_MA", label: "DTS-HD MA"),
                DebridRuleOption(id: "DTS_HD", label: "DTS-HD"),
                DebridRuleOption(id: "DTS_ES", label: "DTS-ES"),
                DebridRuleOption(id: "DTS", label: "DTS"),
                DebridRuleOption(id: "TRUEHD", label: "TrueHD"),
                DebridRuleOption(id: "OPUS", label: "OPUS"),
                DebridRuleOption(id: "FLAC", label: "FLAC"),
                DebridRuleOption(id: "AAC", label: "AAC"),
                DebridRuleOption(id: Self.unknown, label: "Unknown")
            ]
        case .audioChannels:
            return [
                DebridRuleOption(id: "CH_7_1", label: "7.1"),
                DebridRuleOption(id: "CH_6_1", label: "6.1"),
                DebridRuleOption(id: "CH_5_1", label: "5.1"),
                DebridRuleOption(id: "CH_2_0", label: "2.0"),
                DebridRuleOption(id: Self.unknown, label: "Unknown")
            ]
        case .encodes:
            return [
                DebridRuleOption(id: "AV1", label: "AV1"),
                DebridRuleOption(id: "HEVC", label: "HEVC"),
                DebridRuleOption(id: "AVC", label: "AVC"),
                DebridRuleOption(id: "XVID", label: "XviD"),
                DebridRuleOption(id: "DIVX", label: "DivX"),
                DebridRuleOption(id: Self.unknown, label: "Unknown")
            ]
        case .languages:
            return [
                DebridRuleOption(id: "EN", label: "English"),
                DebridRuleOption(id: "HI", label: "Hindi"),
                DebridRuleOption(id: "IT", label: "Italian"),
                DebridRuleOption(id: "ES", label: "Spanish"),
                DebridRuleOption(id: "FR", label: "French"),
                DebridRuleOption(id: "DE", label: "German"),
                DebridRuleOption(id: "PT", label: "Portuguese"),
                DebridRuleOption(id: "PL", label: "Polish"),
                DebridRuleOption(id: "CS", label: "Czech"),
                DebridRuleOption(id: "LA", label: "Latino"),
                DebridRuleOption(id: "JA", label: "Japanese"),
                DebridRuleOption(id: "KO", label: "Korean"),
                DebridRuleOption(id: "ZH", label: "Chinese"),
                DebridRuleOption(id: "MULTI", label: "Multi"),
                DebridRuleOption(id: Self.unknown, label: "Unknown")
            ]
        }
    }

    func label(for id: String) -> String? {
        options.first { $0.id == id }?.label
    }

    static func qualityID(_ quality: DebridStreamQuality) -> String {
        switch quality {
        case .blurayRemux: return "BLURAY_REMUX"
        case .bluray: return "BLURAY"
        case .webDl: return "WEB_DL"
        case .webrip: return "WEBRIP"
        case .hdrip: return "HDRIP"
        case .hdRip: return "HD_RIP"
        case .dvdrip: return "DVDRIP"
        case .hdtv: return "HDTV"
        case .cam: return "CAM"
        case .ts: return "TS"
        case .tc: return "TC"
        case .scr: return "SCR"
        case .unknown: return unknown
        }
    }

    static func resolutionID(_ resolution: Int) -> String {
        switch resolution {
        case 2160...: return "P2160"
        case 1440..<2160: return "P1440"
        case 1080..<1440: return "P1080"
        case 720..<1080: return "P720"
        case 576..<720: return "P576"
        case 480..<576: return "P480"
        case 360..<480: return "P360"
        default: return unknown
        }
    }
}

/// How a result rule uses its values.
enum DebridRuleKind: String, CaseIterable {
    /// Results with a selected value are listed first.
    case preferred
    /// Only results with a selected value are listed.
    case required
    /// Results with a selected value are hidden.
    case excluded
}

/// Settings → Connected Services → Result Management → Result rules: the
/// preferred, required and excluded values for each facet, plus the required
/// and excluded release groups. Stored as one JSON object whose field names
/// are the desktop app's (`requiredResolutions`, `excludedAudioTags` and so
/// on). An empty list means the rule is off.
struct DebridResultRules: Equatable {
    static let requiredReleaseGroupsField = "requiredReleaseGroups"
    static let excludedReleaseGroupsField = "excludedReleaseGroups"

    private var lists: [String: [String]] = [:]

    static let none = DebridResultRules()

    init() {}

    /// Reads stored rules. Values this app does not know are dropped, and
    /// text that is not a rules object gives no rules.
    init(json: String?) {
        guard let json, !json.isEmpty,
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        for kind in DebridRuleKind.allCases {
            for facet in DebridRuleFacet.allCases {
                let stored = object[Self.field(kind, facet)] as? [String] ?? []
                set(kind, facet, stored)
            }
        }
        setReleaseGroups(object[Self.requiredReleaseGroupsField] as? [String] ?? [], required: true)
        setReleaseGroups(object[Self.excludedReleaseGroupsField] as? [String] ?? [], required: false)
    }

    static func load(settings: UserDefaults) -> DebridResultRules {
        DebridResultRules(json: settings.string(forKey: SettingsKey.debridResultRules))
    }

    /// The text to store. Empty with no rules, so the default stays unset.
    var json: String {
        guard !lists.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: lists, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    static func field(_ kind: DebridRuleKind, _ facet: DebridRuleFacet) -> String {
        kind.rawValue + facet.rawValue
    }

    /// The selected value ids, in the facet's own order.
    func selection(_ kind: DebridRuleKind, _ facet: DebridRuleFacet) -> [String] {
        lists[Self.field(kind, facet)] ?? []
    }

    mutating func set(_ kind: DebridRuleKind, _ facet: DebridRuleFacet, _ ids: [String]) {
        let chosen = Set(ids)
        let ordered = facet.options.map(\.id).filter { chosen.contains($0) }
        lists[Self.field(kind, facet)] = ordered.isEmpty ? nil : ordered
    }

    /// Turns one value of a rule on or off. A value cannot be both required
    /// and excluded, which would hide every result, so turning it on in one
    /// takes it out of the other. An excluded value is not preferred either.
    mutating func toggle(_ kind: DebridRuleKind, _ facet: DebridRuleFacet, _ id: String) {
        var ids = selection(kind, facet)
        if let index = ids.firstIndex(of: id) {
            ids.remove(at: index)
            set(kind, facet, ids)
            return
        }
        ids.append(id)
        set(kind, facet, ids)
        let conflicting: [DebridRuleKind]
        switch kind {
        case .required: conflicting = [.excluded]
        case .excluded: conflicting = [.required, .preferred]
        case .preferred: conflicting = []
        }
        for other in conflicting {
            set(other, facet, selection(other, facet).filter { $0 != id })
        }
    }

    var requiredReleaseGroups: [String] { lists[Self.requiredReleaseGroupsField] ?? [] }
    var excludedReleaseGroups: [String] { lists[Self.excludedReleaseGroupsField] ?? [] }

    mutating func setReleaseGroups(_ groups: [String], required: Bool) {
        var seen = Set<String>()
        let cleaned = groups
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        lists[required ? Self.requiredReleaseGroupsField : Self.excludedReleaseGroupsField] =
            cleaned.isEmpty ? nil : cleaned
    }

    /// Release groups typed as one line, separated by commas.
    static func releaseGroups(fromText text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: ",;\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var isEmpty: Bool { lists.isEmpty }

    /// The number of rules that are on.
    var activeRuleCount: Int { lists.count }

    /// True when a required or excluded rule is on.
    var hasFilters: Bool {
        lists.keys.contains { !$0.hasPrefix(DebridRuleKind.preferred.rawValue) }
    }

    /// True when a preferred rule is on.
    var hasPreferences: Bool {
        lists.keys.contains { $0.hasPrefix(DebridRuleKind.preferred.rawValue) }
    }

    /// Whether the required and excluded rules let this result through.
    func matches(_ facts: DebridStreamFacts) -> Bool {
        for facet in DebridRuleFacet.allCases {
            let values = facts.values(for: facet)
            let required = selection(.required, facet)
            if !required.isEmpty, !values.contains(where: { required.contains($0) }) { return false }
            let excluded = selection(.excluded, facet)
            guard !excluded.isEmpty else { continue }
            if facet == .languages {
                // A result is hidden only when every language it has is excluded.
                if values.allSatisfy({ excluded.contains($0) }) { return false }
            } else if values.contains(where: { excluded.contains($0) }) {
                return false
            }
        }
        let group = facts.releaseGroup
        let sameGroup: (String) -> Bool = { $0.caseInsensitiveCompare(group) == .orderedSame }
        if !requiredReleaseGroups.isEmpty, !requiredReleaseGroups.contains(where: sameGroup) { return false }
        if excludedReleaseGroups.contains(where: sameGroup) { return false }
        return true
    }

    /// One rank per preferred rule that is on, lower first. A result with
    /// none of a rule's values ranks last for that rule.
    func preferenceRanks(_ facts: DebridStreamFacts) -> [Int] {
        DebridRuleFacet.allCases.compactMap { facet in
            let preferred = selection(.preferred, facet)
            guard !preferred.isEmpty else { return nil }
            return facts.values(for: facet).compactMap { preferred.firstIndex(of: $0) }.min() ?? Int.max
        }
    }

    /// `streams` with the results `isRuled` picks out reordered among
    /// themselves so preferred values come first. Every other stream keeps
    /// its place, and results that rank the same keep their order.
    func preferredFirst(
        _ streams: [NuvioStream],
        isRuled: (NuvioStream) -> Bool,
        facts: (NuvioStream) -> DebridStreamFacts = DebridStreamFacts.facts(for:)
    ) -> [NuvioStream] {
        guard hasPreferences else { return streams }
        let slots = streams.indices.filter { isRuled(streams[$0]) }
        guard slots.count > 1 else { return streams }
        let ranked = slots.enumerated().map { offset, index in
            (offset: offset, stream: streams[index], ranks: preferenceRanks(facts(streams[index])))
        }
        let ordered = ranked.sorted { left, right in
            for (l, r) in zip(left.ranks, right.ranks) where l != r { return l < r }
            return left.offset < right.offset
        }
        var result = streams
        for (slot, entry) in zip(slots, ordered) {
            result[slot] = entry.stream
        }
        return result
    }
}

/// What the release text of one result says about it, as rule value ids.
/// Read from the name, description and filename an add-on sent.
struct DebridStreamFacts: Equatable {
    let resolution: String
    let quality: String
    let visualTags: [String]
    let audioTags: [String]
    let audioChannels: [String]
    let encode: String
    /// Empty when the text names no language.
    let languages: [String]
    /// Empty when the text names no release group.
    let releaseGroup: String
    /// 0 when unknown.
    let sizeBytes: Int64

    /// The value ids a rule on `facet` compares. A result with no language
    /// in its text counts as Unknown.
    func values(for facet: DebridRuleFacet) -> [String] {
        switch facet {
        case .resolutions: return [resolution]
        case .qualities: return [quality]
        case .visualTags: return visualTags
        case .audioTags: return audioTags
        case .audioChannels: return audioChannels
        case .encodes: return [encode]
        case .languages: return languages.isEmpty ? [DebridRuleFacet.unknown] : languages
        }
    }

    private final class Box: @unchecked Sendable {
        let facts: DebridStreamFacts
        init(_ facts: DebridStreamFacts) { self.facts = facts }
    }

    private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 1000
        return cache
    }()

    /// The facts of a stream, kept so a list that is sorted and drawn again
    /// does not read the same text twice.
    static func facts(for stream: NuvioStream) -> DebridStreamFacts {
        let key = "\(stream.id)::\(stream.name ?? "")::\(stream.description ?? "")::\(stream.filename ?? "")::\(stream.videoSize ?? 0)" as NSString
        if let cached = cache.object(forKey: key) { return cached.facts }
        let facts = parse(
            name: stream.name,
            description: stream.description,
            filename: stream.filename,
            resolution: StreamPickerListBuilder.resolution(for: stream),
            quality: StreamPickerListBuilder.streamQuality(for: stream),
            sizeBytes: StreamPickerListBuilder.sizeBytes(for: stream)
        )
        cache.setObject(Box(facts), forKey: key)
        return facts
    }

    static func parse(
        name: String?,
        description: String?,
        filename: String?,
        resolution: Int,
        quality: DebridStreamQuality,
        sizeBytes: Int64 = 0
    ) -> DebridStreamFacts {
        let fields = [name, description, filename].compactMap { $0 }
        // Tags are read after the title of each text, so a title word is not taken for one.
        let text = ReleaseText(fields.map { afterTitle($0.lowercased()) }.joined(separator: " "))
        let group = trailingReleaseGroup(in: filename)
            ?? trailingReleaseGroup(in: description)
            ?? StreamQualityTags.extractReleaseGroup(from: filename)
            ?? StreamQualityTags.extractReleaseGroup(from: description)
            ?? ""
        return DebridStreamFacts(
            resolution: DebridRuleFacet.resolutionID(resolution),
            quality: DebridRuleFacet.qualityID(quality),
            visualTags: visualTags(in: text),
            audioTags: audioTags(in: text),
            audioChannels: audioChannels(in: text),
            encode: encode(in: text),
            languages: languages(in: fields),
            releaseGroup: group,
            sizeBytes: max(sizeBytes, 0)
        )
    }

    // MARK: - Release text

    /// Lowercased release text, searched as bytes.
    private struct ReleaseText {
        let bytes: [UInt8]

        init(_ lowercased: String) {
            bytes = Array(lowercased.utf8)
        }

        private static func isWordByte(_ byte: UInt8) -> Bool {
            (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x30 && byte <= 0x39)
        }

        private func matches(_ needle: [UInt8], at start: Int) -> Bool {
            for offset in needle.indices where bytes[start + offset] != needle[offset] { return false }
            return true
        }

        func contains(_ needle: String) -> Bool {
            let needle = Array(needle.utf8)
            guard !needle.isEmpty, bytes.count >= needle.count else { return false }
            for start in 0...(bytes.count - needle.count) where matches(needle, at: start) { return true }
            return false
        }

        /// True when `token` appears with no letter or digit on either side.
        func hasToken(_ token: String) -> Bool {
            let needle = Array(token.utf8)
            guard !needle.isEmpty, bytes.count >= needle.count else { return false }
            for start in 0...(bytes.count - needle.count) where matches(needle, at: start) {
                let end = start + needle.count
                let openBefore = start == 0 || !Self.isWordByte(bytes[start - 1])
                let openAfter = end == bytes.count || !Self.isWordByte(bytes[end])
                if openBefore && openAfter { return true }
            }
            return false
        }

        /// True when a channel layout such as "5.1" stands alone or follows
        /// the audio format ("DDP5.1", "AAC.2.0"), with no digit on either side.
        func hasChannels(_ layout: String) -> Bool {
            let needle = Array(layout.utf8)
            guard !needle.isEmpty, bytes.count >= needle.count else { return false }
            let isDigit: (UInt8) -> Bool = { $0 >= 0x30 && $0 <= 0x39 }
            for start in 0...(bytes.count - needle.count) where matches(needle, at: start) {
                let end = start + needle.count
                let openBefore = start == 0 || !isDigit(bytes[start - 1])
                let openAfter = end == bytes.count || !isDigit(bytes[end])
                if openBefore && openAfter { return true }
            }
            return false
        }

        /// True when an audio format name starts a word and no letter
        /// follows it, so "DD5.1" and "AAC2.0" count. An occurrence followed
        /// by one of `unless` is passed over.
        func hasCodec(_ name: String, unless: [String] = []) -> Bool {
            let needle = Array(name.utf8)
            guard !needle.isEmpty, bytes.count >= needle.count else { return false }
            let endings = unless.map { Array($0.utf8) }
            for start in 0...(bytes.count - needle.count) where matches(needle, at: start) {
                let end = start + needle.count
                let openBefore = start == 0 || !Self.isWordByte(bytes[start - 1])
                let letterAfter = end < bytes.count && bytes[end] >= 0x61 && bytes[end] <= 0x7A
                let barred = endings.contains { $0.count <= bytes.count - end && matches($0, at: end) }
                if openBefore && !letterAfter && !barred { return true }
            }
            return false
        }

        func hasAnyToken(_ tokens: [String]) -> Bool {
            tokens.contains { hasToken($0) }
        }
    }

    private static func visualTags(in text: ReleaseText) -> [String] {
        let hasDV = text.hasAnyToken(["dv", "dovi", "dolbyvision", "dolby vision", "dolby.vision", "dolby_vision", "dolby-vision"])
        let hasHDR = text.hasAnyToken(["hdr", "hdr10", "hdr10plus", "hdr10+", "hlg"])
        var tags: [String] = []
        if hasDV && hasHDR { tags.append("HDR_DV") }
        if hasDV && !hasHDR { tags.append("DV_ONLY") }
        if hasHDR && !hasDV { tags.append("HDR_ONLY") }
        if text.contains("hdr10+") || text.contains("hdr10plus") { tags.append("HDR10_PLUS") }
        if text.contains("hdr10") { tags.append("HDR10") }
        if hasDV { tags.append("DV") }
        if hasHDR { tags.append("HDR") }
        if text.hasToken("hlg") { tags.append("HLG") }
        if text.contains("10bit") || text.contains("10 bit") { tags.append("TEN_BIT") }
        if text.hasToken("3d") { tags.append("THREE_D") }
        if text.hasToken("imax") { tags.append("IMAX") }
        if text.hasToken("ai") { tags.append("AI") }
        if text.hasToken("sdr") { tags.append("SDR") }
        if text.contains("h-ou") { tags.append("H_OU") }
        if text.contains("h-sbs") { tags.append("H_SBS") }
        return tags.isEmpty ? [DebridRuleFacet.unknown] : tags
    }

    private static func audioTags(in text: ReleaseText) -> [String] {
        var tags: [String] = []
        let plus = ["+", "plus", " plus", ".plus"]
        if text.hasToken("atmos") { tags.append("ATMOS") }
        if text.contains("dd+") || text.hasCodec("ddp") || text.contains("dolby digital plus")
            || text.hasAnyToken(["eac3", "e-ac3", "e-ac-3"]) {
            tags.append("DD_PLUS")
        }
        // Plain Dolby Digital. "DD+" and "Dolby Digital Plus" are the tag above.
        if text.hasCodec("dd", unless: plus) || text.hasCodec("ac3") || text.hasCodec("dolby digital", unless: plus) {
            tags.append("DD")
        }
        if text.hasAnyToken(["dts:x", "dtsx", "dts-x", "dts.x"]) { tags.append("DTS_X") }
        if text.hasAnyToken([
            "dts-hd ma", "dts-hd.ma", "dts-hd_ma", "dts-hd-ma", "dts-hdma",
            "dtshd ma", "dtshd.ma", "dtshd_ma", "dtshd-ma", "dtshdma"
        ]) || text.contains("dts-hd master") {
            tags.append("DTS_HD_MA")
        }
        if text.contains("dts-hd") || text.contains("dtshd") { tags.append("DTS_HD") }
        if text.contains("dts-es") || text.contains("dtses") { tags.append("DTS_ES") }
        if text.hasCodec("dts") { tags.append("DTS") }
        if text.contains("truehd") || text.contains("true hd") { tags.append("TRUEHD") }
        if text.hasCodec("opus") { tags.append("OPUS") }
        if text.hasCodec("flac") { tags.append("FLAC") }
        if text.hasCodec("aac") { tags.append("AAC") }
        return tags.isEmpty ? [DebridRuleFacet.unknown] : tags
    }

    private static func audioChannels(in text: ReleaseText) -> [String] {
        var channels: [String] = []
        if text.hasChannels("7.1") { channels.append("CH_7_1") }
        if text.hasChannels("6.1") { channels.append("CH_6_1") }
        if text.hasChannels("5.1") || text.hasToken("6ch") { channels.append("CH_5_1") }
        if text.hasChannels("2.0") { channels.append("CH_2_0") }
        return channels.isEmpty ? [DebridRuleFacet.unknown] : channels
    }

    private static func encode(in text: ReleaseText) -> String {
        if text.hasToken("av1") { return "AV1" }
        if text.hasAnyToken(["hevc", "h265", "h.265", "x265"]) { return "HEVC" }
        if text.hasAnyToken(["avc", "h264", "h.264", "x264"]) { return "AVC" }
        if text.hasToken("xvid") { return "XVID" }
        if text.hasToken("divx") { return "DIVX" }
        return DebridRuleFacet.unknown
    }

    // MARK: - Languages

    /// The words and three-letter codes release names use for each language.
    /// Two-letter codes are left out: they also read as other tags ("DTS-ES")
    /// and as common words.
    private static let languageWords: [(id: String, words: [String])] = [
        ("EN", ["eng", "english"]),
        ("HI", ["hin", "hindi"]),
        ("IT", ["ita", "italian", "italiano"]),
        ("ES", ["spa", "esp", "spanish", "espanol", "castellano"]),
        ("FR", ["fre", "french", "truefrench", "vff", "vf", "vfq", "vfi", "vf2", "vostfr"]),
        ("DE", ["ger", "deu", "german", "deutsch"]),
        ("PT", ["portuguese", "portugues"]),
        ("PL", ["pol", "polish"]),
        ("CS", ["cze", "czech"]),
        ("LA", ["latino"]),
        ("JA", ["jpn", "japanese"]),
        ("KO", ["kor", "korean"]),
        ("ZH", ["chinese"]),
        ("MULTI", ["multi"])
    ]

    /// Flags add-ons put in a description to name the audio languages.
    private static let languageFlags: [(id: String, flags: [String])] = [
        ("EN", ["🇬🇧", "🇺🇸"]),
        ("HI", ["🇮🇳"]),
        ("IT", ["🇮🇹"]),
        ("ES", ["🇪🇸"]),
        ("FR", ["🇫🇷"]),
        ("DE", ["🇩🇪"]),
        ("PT", ["🇵🇹", "🇧🇷"]),
        ("PL", ["🇵🇱"]),
        ("CS", ["🇨🇿"]),
        ("LA", ["🇲🇽"]),
        ("JA", ["🇯🇵"]),
        ("KO", ["🇰🇷"]),
        ("ZH", ["🇨🇳", "🇹🇼"])
    ]

    /// The first year, resolution or episode marker of a release name. The
    /// title comes before it, the tags after.
    private static let titleEndRegex = try! NSRegularExpression(
        pattern: #"(?:^|[^a-z0-9])(?:(?:19|20)\d{2}|2160p?|1440p?|1080p?|720p?|576p?|480p?|4k|uhd|s\d{1,2}e\d{1,3})(?:[^a-z0-9]|$)"#
    )

    /// The part of a lowercased text from its first year, resolution or
    /// episode marker on. A text with no marker is returned whole.
    private static func afterTitle(_ lower: String) -> String {
        let range = NSRange(lower.startIndex..., in: lower)
        guard let match = titleEndRegex.firstMatch(in: lower, range: range),
              let start = Range(match.range, in: lower)?.lowerBound else { return lower }
        return String(lower[start...])
    }

    /// "-GRP" at the end of a release name, before the file extension and
    /// any bracketed site tag.
    private static let trailingGroupRegex = try! NSRegularExpression(
        pattern: #"-([a-z0-9_]+)(?:\[[^\]]*\])?(?:\.(?:mkv|mp4|avi|m4v|mov|wmv|webm|m2ts|ts))?\s*$"#,
        options: .caseInsensitive
    )

    /// Ends of hyphenated tags ("WEB-DL", "DTS-HD", "DD-EX", "Blu-Ray") that are not a group.
    private static let hyphenatedTagEnds: Set<String> = [
        "dl", "hd", "ex", "es", "ma", "x", "rip", "ray", "hdr", "dv", "vision", "atmos", "remux", "sbs", "ou",
        "ac3", "aac", "dts", "hevc", "avc", "x264", "x265", "h264", "h265", "10bit", "audio", "sub", "subs",
        "dub", "dubbed", "multi", "dual", "uhd", "web", "bluray", "hdtv", "cam", "ts", "tc", "scr"
    ]

    /// The release group a release name ends with ("...x264-SPARKS.mkv").
    /// Only a line that has a year, resolution or episode marker before the
    /// hyphen is read as a release name.
    private static func trailingReleaseGroup(in text: String?) -> String? {
        guard let text else { return nil }
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let range = NSRange(line.startIndex..., in: line)
            guard let match = trailingGroupRegex.firstMatch(in: line, range: range),
                  let whole = Range(match.range, in: line),
                  let groupRange = Range(match.range(at: 1), in: line) else { continue }
            let group = String(line[groupRange])
            let lower = group.lowercased()
            guard !hyphenatedTagEnds.contains(lower),
                  lower.contains(where: { $0.isLetter }),
                  StreamQualityTags.resolution(in: lower) == 0 else { continue }
            let before = String(line[..<whole.lowerBound]).lowercased() + " "
            guard titleEndRegex.firstMatch(in: before, range: NSRange(before.startIndex..., in: before)) != nil else { continue }
            return group
        }
        return nil
    }

    /// Languages are read after the title of each text, so a title such as
    /// "The French Dispatch" is not taken for the audio language. A text
    /// with no year, resolution or episode marker is read whole.
    private static func languages(in fields: [String]) -> [String] {
        var found = Set<String>()
        for field in fields {
            for entry in languageFlags where entry.flags.contains(where: { field.contains($0) }) {
                found.insert(entry.id)
            }
            let text = ReleaseText(afterTitle(field.lowercased()))
            for entry in languageWords where text.hasAnyToken(entry.words) {
                found.insert(entry.id)
            }
        }
        return DebridRuleFacet.languages.options.map(\.id).filter { found.contains($0) }
    }
}
