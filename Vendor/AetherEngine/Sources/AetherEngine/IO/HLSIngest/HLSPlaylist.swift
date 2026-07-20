import Foundation

struct HLSVariant: Equatable {
    let bandwidth: Int
    let uri: String
    /// nil when the variant declares no alternate-audio group.
    let audioGroupID: String?
}

/// EXT-X-MEDIA:TYPE=AUDIO with a URI. Companion reader ingests chosen rendition for demuxed-audio variants (ARD-style).
struct HLSAudioRendition: Equatable {
    let groupID: String
    let uri: String
    let isDefault: Bool
}

/// `demuxedAudioGroupIDs` is kept as a stable Set for O(1) membership checks even though it is derivable from `audioRenditions`. EXT-X-MEDIA without a URI means audio is muxed into the variant stream.
struct HLSMasterPlaylist: Equatable {
    let variants: [HLSVariant]
    let demuxedAudioGroupIDs: Set<String>
    let audioRenditions: [HLSAudioRendition]
}

/// AES-128 clear-key context (Pluto/Samsung-TV+ style). `iv`: explicit EXT-X-KEY IV attribute or big-endian media-sequence number per RFC 8216 §5.2.
struct HLSSegmentCrypt: Equatable {
    let keyURI: String
    let iv: Data
}

struct HLSMediaSegment: Equatable {
    let uri: String
    let duration: Double
    let discontinuityBefore: Bool
    let crypt: HLSSegmentCrypt?

    init(uri: String, duration: Double, discontinuityBefore: Bool, crypt: HLSSegmentCrypt? = nil) {
        self.uri = uri
        self.duration = duration
        self.discontinuityBefore = discontinuityBefore
        self.crypt = crypt
    }
}

struct HLSMediaPlaylist: Equatable {
    let targetDuration: Double
    let mediaSequence: Int
    let segments: [HLSMediaSegment]
    let hasEndList: Bool
    let isEncrypted: Bool
    /// True for SAMPLE-AES / SAMPLE-AES-CTR or AES-128 with no URI; AES-128 with a URI is supported and decrypted inline.
    let hasUnsupportedEncryption: Bool
    let hasMap: Bool
}

enum HLSPlaylist: Equatable {
    case master(HLSMasterPlaylist)
    case media(HLSMediaPlaylist)
}

/// Line-oriented RFC 8216 parser for the subset the live ingest needs. Pure (no I/O).
enum HLSPlaylistParser {

    static func parse(_ text: String) throws -> HLSPlaylist {
        let lines = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard lines.first?.hasPrefix("#EXTM3U") == true else {
            throw HLSIngestError.playlistInvalid(reason: "missing #EXTM3U")
        }
        if lines.contains(where: { $0.hasPrefix("#EXT-X-STREAM-INF") }) {
            return .master(try parseMaster(lines))
        }
        return .media(try parseMedia(lines))
    }

    static func resolve(uri: String, against base: URL) -> URL? {
        URL(string: uri, relativeTo: base)?.absoluteURL
    }

    // MARK: - Private

    private static func parseMaster(_ lines: [String]) throws -> HLSMasterPlaylist {
        var variants: [HLSVariant] = []
        var demuxedAudioGroups: Set<String> = []
        var audioRenditions: [HLSAudioRendition] = []
        var pendingBandwidth: Int?
        var pendingAudioGroup: String?
        for line in lines {
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                pendingBandwidth = attribute("BANDWIDTH", in: line).flatMap(Int.init) ?? 0
                pendingAudioGroup = attribute("AUDIO", in: line)
            } else if line.hasPrefix("#EXT-X-MEDIA:") {
                if attribute("TYPE", in: line) == "AUDIO",
                   let uri = attribute("URI", in: line),
                   let group = attribute("GROUP-ID", in: line) {
                    demuxedAudioGroups.insert(group)
                    audioRenditions.append(HLSAudioRendition(
                        groupID: group,
                        uri: uri,
                        isDefault: attribute("DEFAULT", in: line) == "YES"
                    ))
                }
            } else if !line.hasPrefix("#"), let bw = pendingBandwidth {
                variants.append(HLSVariant(bandwidth: bw, uri: line, audioGroupID: pendingAudioGroup))
                pendingBandwidth = nil
                pendingAudioGroup = nil
            }
        }
        guard !variants.isEmpty else {
            throw HLSIngestError.playlistInvalid(reason: "master playlist without variants")
        }
        return HLSMasterPlaylist(
            variants: variants,
            demuxedAudioGroupIDs: demuxedAudioGroups,
            audioRenditions: audioRenditions
        )
    }

    private static func parseMedia(_ lines: [String]) throws -> HLSMediaPlaylist {
        var targetDuration: Double?
        var mediaSequence = 0
        var segments: [HLSMediaSegment] = []
        var hasEndList = false
        var isEncrypted = false
        var hasUnsupportedEncryption = false
        var hasMap = false
        var pendingDuration: Double?
        var pendingDiscontinuity = false
        // AES-128 keys are "sticky": one EXT-X-KEY tag governs all following segments until the next tag. Pluto/Samsung-TV+ emit one tag per segment with the same URI and an incrementing explicit IV.
        var currentKeyURI: String?
        var currentExplicitIV: Data?

        for line in lines {
            if line.hasPrefix("#EXT-X-TARGETDURATION:") {
                targetDuration = Double(line.dropFirst("#EXT-X-TARGETDURATION:".count))
            } else if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                mediaSequence = Int(line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)) ?? 0
            } else if line.hasPrefix("#EXTINF:") {
                let payload = line.dropFirst("#EXTINF:".count)
                pendingDuration = Double(payload.split(separator: ",").first.map(String.init) ?? "")
            } else if line.hasPrefix("#EXT-X-DISCONTINUITY") && !line.hasPrefix("#EXT-X-DISCONTINUITY-SEQUENCE") {
                pendingDiscontinuity = true
            } else if line.hasPrefix("#EXT-X-KEY:") {
                let method = attribute("METHOD", in: line) ?? "NONE"
                switch method {
                case "NONE":
                    currentKeyURI = nil
                    currentExplicitIV = nil
                case "AES-128":
                    isEncrypted = true
                    currentKeyURI = attribute("URI", in: line)
                    currentExplicitIV = attribute("IV", in: line).flatMap(parseHexIV)
                    // A keyless AES-128 tag is unusable; treat as unsupported.
                    if currentKeyURI == nil { hasUnsupportedEncryption = true }
                default:
                    // SAMPLE-AES / SAMPLE-AES-CTR / anything else: not decryptable here.
                    isEncrypted = true
                    hasUnsupportedEncryption = true
                    currentKeyURI = nil
                    currentExplicitIV = nil
                }
            } else if line.hasPrefix("#EXT-X-MAP:") {
                hasMap = true
            } else if line.hasPrefix("#EXT-X-ENDLIST") {
                hasEndList = true
            } else if !line.hasPrefix("#") {
                let crypt: HLSSegmentCrypt?
                if let keyURI = currentKeyURI {
                    let sequence = mediaSequence + segments.count
                    crypt = HLSSegmentCrypt(
                        keyURI: keyURI,
                        iv: currentExplicitIV ?? sequenceIV(sequence)
                    )
                } else {
                    crypt = nil
                }
                segments.append(HLSMediaSegment(
                    uri: line,
                    duration: pendingDuration ?? targetDuration ?? 0,
                    discontinuityBefore: pendingDiscontinuity,
                    crypt: crypt
                ))
                pendingDuration = nil
                pendingDiscontinuity = false
            }
        }
        guard let target = targetDuration else {
            throw HLSIngestError.playlistInvalid(reason: "missing TARGETDURATION")
        }
        guard !segments.isEmpty else {
            throw HLSIngestError.playlistInvalid(reason: "no segments")
        }
        return HLSMediaPlaylist(
            targetDuration: target,
            mediaSequence: mediaSequence,
            segments: segments,
            hasEndList: hasEndList,
            isEncrypted: isEncrypted,
            hasUnsupportedEncryption: hasUnsupportedEncryption,
            hasMap: hasMap
        )
    }

    /// Parse a `0x`-prefixed hex EXT-X-KEY IV into 16-byte big-endian Data. Returns nil on malformed length (caller falls back to sequence-number IV).
    private static func parseHexIV(_ raw: String) -> Data? {
        var hex = raw.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("0x") || hex.hasPrefix("0X") { hex = String(hex.dropFirst(2)) }
        guard hex.count == 32 else { return nil }
        var bytes = Data(capacity: 16)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            guard let byte = UInt8(hex[idx..<next], radix: 16) else { return nil }
            bytes.append(byte)
            idx = next
        }
        return bytes
    }

    /// RFC 8216 default IV: 16-byte big-endian segment media-sequence number.
    private static func sequenceIV(_ sequence: Int) -> Data {
        var iv = Data(repeating: 0, count: 16)
        var value = UInt64(bitPattern: Int64(sequence))
        for offset in 0..<8 {
            iv[15 - offset] = UInt8(value & 0xFF)
            value >>= 8
        }
        return iv
    }

    /// Extract a KEY=VALUE attribute from a tag line, tolerating quoted values. Match is anchored to `:` or `,` before the key: bare substring search matched `BANDWIDTH=` inside `AVERAGE-BANDWIDTH=` and caused wrong variant selection.
    private static func attribute(_ key: String, in line: String) -> String? {
        let needle = "\(key)="
        var searchStart = line.startIndex
        while let range = line.range(of: needle, range: searchStart..<line.endIndex) {
            searchStart = range.upperBound
            if range.lowerBound != line.startIndex {
                let before = line[line.index(before: range.lowerBound)]
                guard before == ":" || before == "," else { continue }
            }
            // Reject matches inside quoted values (odd quote count before match = inside quotes).
            let quotesBefore = line[line.startIndex..<range.lowerBound]
                .reduce(0) { $1 == "\"" ? $0 + 1 : $0 }
            guard quotesBefore % 2 == 0 else { continue }
            let rest = line[range.upperBound...]
            if rest.hasPrefix("\"") {
                let afterQuote = rest.dropFirst()
                guard let end = afterQuote.firstIndex(of: "\"") else { return nil }
                return String(afterQuote[..<end])
            }
            let end = rest.firstIndex(of: ",") ?? rest.endIndex
            return String(rest[..<end])
        }
        return nil
    }
}
