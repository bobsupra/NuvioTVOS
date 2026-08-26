import Foundation

/// NAL framing of a packet payload: Annex B start codes (MPEG-TS) or length-prefixed
/// (avcC/hvcC extradata, e.g. Matroska/MP4 recordings).
///
/// Public because the DV P7 rewrite takes it (#365): a walker handed the wrong framing does not
/// fail, it reads NAL boundaries at arbitrary offsets and reports that it found nothing.
public enum VideoNALFraming: Equatable, Hashable, Sendable {
    case annexB
    case lengthPrefixed(size: Int)
}

/// Extracts ATSC A/53 `cc_data` triplets from H.264 / HEVC video packet bitstreams (#131).
///
/// US broadcast/cable-sourced streams carry closed captions inside the picture as
/// `user_data_registered_itu_t_t35` SEI messages (country 0xB5, provider 0x0031,
/// user_identifier "GA94", user_data_type_code 0x03); FFmpeg's mpegts demuxer never synthesizes
/// a caption stream for them, so packet SEI is the only place they exist on the native remux
/// path. Pure and stateless; every length is bounds-checked and malformed input returns `[]`.
enum A53SEIParser {

    enum CodecKind {
        case h264
        case hevc
    }

    typealias NALFraming = VideoNALFraming

    /// "GA94" as raw bytes; static so the per-packet prefilter allocates nothing.
    private static let ga94Needle: [UInt8] = [0x47, 0x41, 0x39, 0x34]

    /// Resolve the framing once per session from codec extradata: avcC/hvcC config records start
    /// with configurationVersion 0x01 and carry lengthSizeMinusOne; Annex B extradata (or none,
    /// the MPEG-TS case) starts with a start code.
    static func nalFraming(codec: CodecKind, extradata: UnsafePointer<UInt8>?, size: Int) -> NALFraming {
        guard let ed = extradata, size >= 7, ed[0] == 0x01 else { return .annexB }
        switch codec {
        case .h264:
            return .lengthPrefixed(size: Int(ed[4] & 0x03) + 1)
        case .hevc:
            guard size >= 22 else { return .annexB }
            return .lengthPrefixed(size: Int(ed[21] & 0x03) + 1)
        }
    }

    /// Validate a packet payload against one framing. This is deliberately stricter than
    /// `forEachNAL`, which is a forgiving parser for caption extraction: a probe must not trust
    /// Annex-B/hvcC extradata when a demuxer has delivered packets in the other framing.
    static func isValidNALFraming(
        _ data: UnsafePointer<UInt8>, _ size: Int, _ framing: NALFraming
    ) -> Bool {
        guard size > 0 else { return false }
        switch framing {
        case .annexB:
            var i = 0
            var nalStart = -1
            var found = false
            while i + 3 <= size {
                if data[i] == 0x00, data[i + 1] == 0x00, data[i + 2] == 0x01 {
                    if nalStart >= 0 {
                        var end = i
                        if end > nalStart, data[end - 1] == 0x00 { end -= 1 }
                        guard end > nalStart else { return false }
                    }
                    nalStart = i + 3
                    found = true
                    i += 3
                } else {
                    i += 1
                }
            }
            guard found, nalStart >= 0, nalStart < size else { return false }
            return true

        case .lengthPrefixed(let width):
            guard (1...4).contains(width) else { return false }
            var offset = 0
            var count = 0
            while offset < size {
                guard offset + width <= size else { return false }
                var nalLength = 0
                for i in 0..<width { nalLength = (nalLength << 8) | Int(data[offset + i]) }
                offset += width
                guard nalLength > 0, offset + nalLength <= size else { return false }
                offset += nalLength
                count += 1
            }
            return count > 0
        }
    }

    /// Prefer the stream-level framing, but recover when packet payloads disagree with it. The
    /// mismatch occurs in practice for Annex-B codec private data paired with length-prefixed
    /// packets (and the reverse after a remux). Candidates are ordered to preserve the configured
    /// width whenever it validates, then try every supported alternate length width, and only
    /// then Annex-B. This ordering matters for a valid 4-byte prefix `00 00 01 xx`, which otherwise
    /// looks like a start code at offset zero.
    static func detectNALFraming(
        _ data: UnsafePointer<UInt8>, _ size: Int, preferred: NALFraming
    ) -> NALFraming? {
        var candidates = allValidNALFramings(data, size)
        // Annex-B is intentionally left last: a start code can be a valid prefix-looking byte
        // sequence, while a full length-prefix walk is stronger evidence.
        if preferred != .annexB, let preferredIndex = candidates.firstIndex(of: preferred) {
            candidates.remove(at: preferredIndex)
            candidates.insert(preferred, at: 0)
        }
        return candidates.first
    }

    /// Return every framing that consumes the complete packet. A packet can be valid under more
    /// than one framing (for example, an Annex-B start code can resemble a 3-byte length), so
    /// callers resolving a stream must retain this evidence instead of choosing the first match.
    static func allValidNALFramings(
        _ data: UnsafePointer<UInt8>, _ size: Int
    ) -> [NALFraming] {
        var candidates = (1...4).map { NALFraming.lengthPrefixed(size: $0) }
        candidates.append(.annexB)
        return candidates.filter { isValidNALFraming(data, size, $0) }
    }

    /// Resolve a stream framing from sampled packets. Only samples valid under exactly one
    /// framing count as evidence; ambiguous packets are ignored. Conflicting unambiguous evidence
    /// is treated as inconclusive so the caller can fall back to stream configuration.
    static func resolveNALFraming(
        samples: [[NALFraming]], configured: NALFraming
    ) -> NALFraming? {
        var evidence: Set<NALFraming> = []
        for valid in samples where valid.count == 1 {
            evidence.insert(valid[0])
        }
        guard evidence.count == 1 else { return nil }
        return evidence.first ?? configured
    }

    /// Cheap prefilter so packets without captions skip the NAL walk. "GA94" contains no zero
    /// pair, so no emulation-prevention byte can split it; false positives (slice data) are
    /// rejected by the structural parse in `triplets(in:...)`.
    static func mayContainA53(_ data: UnsafePointer<UInt8>, _ size: Int) -> Bool {
        guard size >= 4 else { return false }
        return ga94Needle.withUnsafeBufferPointer { memmem(data, size, $0.baseAddress, $0.count) != nil }
    }

    /// All A53 `cc_data` triplets in the packet, in bitstream (decode) order.
    static func triplets(
        in data: UnsafePointer<UInt8>, size: Int, codec: CodecKind, framing: NALFraming
    ) -> [CCDataParser.CCTriplet] {
        guard mayContainA53(data, size) else { return [] }
        var out: [CCDataParser.CCTriplet] = []
        forEachNAL(data, size, framing) { nal, nalSize in
            let headerLen: Int
            let isSEI: Bool
            switch codec {
            case .h264:
                headerLen = 1
                isSEI = nalSize > 1 && (nal[0] & 0x1F) == 6
            case .hevc:
                headerLen = 2
                let type = nalSize > 2 ? (nal[0] >> 1) & 0x3F : 0xFF
                isSEI = type == 39 || type == 40   // prefix / suffix SEI
            }
            guard isSEI else { return }
            let rbsp = unescapeRBSP(nal + headerLen, nalSize - headerLen)
            parseSEIPayloads(rbsp, into: &out)
        }
        return out
    }

    // MARK: - NAL iteration

    /// Shared by the DV P7 RPU rewrite (#365), which has to walk the same NALs in the same framing.
    static func forEachNAL(
        _ data: UnsafePointer<UInt8>, _ size: Int, _ framing: NALFraming,
        _ body: (UnsafePointer<UInt8>, Int) -> Void
    ) {
        switch framing {
        case .annexB:
            var i = 0
            var nalStart = -1
            while i + 3 <= size {
                if data[i] == 0x00, data[i + 1] == 0x00, data[i + 2] == 0x01 {
                    if nalStart >= 0 {
                        var end = i
                        if end > nalStart, data[end - 1] == 0x00 { end -= 1 }   // 4-byte start code
                        body(data + nalStart, end - nalStart)
                    }
                    nalStart = i + 3
                    i += 3
                } else {
                    i += data[i + 2] > 0x01 ? 3 : 1   // no start code can begin within the next 3 bytes
                }
            }
            if nalStart >= 0, nalStart < size { body(data + nalStart, size - nalStart) }
        case .lengthPrefixed(let lenSize):
            var i = 0
            while i + lenSize <= size {
                var nalLen = 0
                for k in 0..<lenSize { nalLen = (nalLen << 8) | Int(data[i + k]) }
                i += lenSize
                guard nalLen > 0, i + nalLen <= size else { return }
                body(data + i, nalLen)
                i += nalLen
            }
        }
    }

    /// Strip emulation-prevention bytes (00 00 03 -> 00 00). In a valid stream, a 0x03 after two
    /// zeros is always an EPB, so the unconditional drop matches FFmpeg's h2645 unescape.
    private static func unescapeRBSP(_ p: UnsafePointer<UInt8>, _ n: Int) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(n)
        var zeros = 0
        for i in 0..<max(0, n) {
            let b = p[i]
            if zeros >= 2, b == 0x03 {
                zeros = 0
            } else {
                out.append(b)
                zeros = b == 0x00 ? zeros + 1 : 0
            }
        }
        return out
    }

    // MARK: - SEI payload walk

    private static func parseSEIPayloads(_ rbsp: [UInt8], into out: inout [CCDataParser.CCTriplet]) {
        var i = 0
        let n = rbsp.count
        while i + 2 <= n {
            var payloadType = 0
            while i < n, rbsp[i] == 0xFF { payloadType += 255; i += 1 }
            guard i < n else { return }
            payloadType += Int(rbsp[i]); i += 1
            var payloadSize = 0
            while i < n, rbsp[i] == 0xFF { payloadSize += 255; i += 1 }
            guard i < n else { return }
            payloadSize += Int(rbsp[i]); i += 1
            guard i + payloadSize <= n else { return }
            if payloadType == 4, payloadSize > 0 {   // user_data_registered_itu_t_t35
                parseT35(rbsp, offset: i, size: payloadSize, into: &out)
            }
            i += payloadSize
        }
    }

    private static func parseT35(
        _ rbsp: [UInt8], offset: Int, size: Int, into out: inout [CCDataParser.CCTriplet]
    ) {
        var i = offset
        let end = offset + size
        guard i + 8 <= end,
              rbsp[i] == 0xB5,                          // itu_t_t35_country_code: United States
              rbsp[i + 1] == 0x00, rbsp[i + 2] == 0x31, // provider: ATSC
              rbsp[i + 3] == 0x47, rbsp[i + 4] == 0x41, // "GA94"
              rbsp[i + 5] == 0x39, rbsp[i + 6] == 0x34,
              rbsp[i + 7] == 0x03                       // user_data_type_code: cc_data
        else { return }
        i += 8
        guard i + 2 <= end else { return }
        let flags = rbsp[i]                             // em_data(1) cc_data(1) additional(1) cc_count(5)
        guard (flags & 0x40) != 0 else { return }       // process_cc_data_flag
        let ccCount = Int(flags & 0x1F)
        i += 2                                          // flags + em_data byte
        guard ccCount > 0, i + ccCount * 3 <= end else { return }
        rbsp.withUnsafeBufferPointer { buf in
            out.append(contentsOf: CCDataParser.parseCCDataTriplets(
                bytes: buf.baseAddress! + i, count: ccCount * 3))
        }
    }
}
