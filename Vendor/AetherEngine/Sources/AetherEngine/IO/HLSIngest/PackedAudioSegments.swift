import Foundation

/// First-segment format classified from leading bytes. Main variant: `.mpegts` only. Companion audio also accepts Apple packed audio.
enum LiveSegmentFormat: Equatable {
    case mpegts          // sync byte 0x47
    case adtsAAC         // 0xFF, second byte & 0xF6 == 0xF0 (raw ADTS, no ID3 prefix)
    case id3PackedAudio  // "ID3" magic; ADTS frames follow the tag

    /// nil for fMP4 `ftyp`, WebVTT, or garbage.
    static func classify(_ bytes: Data) -> LiveSegmentFormat? {
        let head = [UInt8](bytes.prefix(3))
        guard !head.isEmpty else { return nil }
        if head[0] == 0x47 { return .mpegts }
        if head.count >= 2, head[0] == 0xFF, head[1] & 0xF6 == 0xF0 { return .adtsAAC }
        if head.count >= 3, head[0] == 0x49, head[1] == 0x44, head[2] == 0x33 { return .id3PackedAudio }
        return nil
    }
}

/// ID3v2 tag parser for Apple HLS packed-audio segments. Extracts the PRIV frame "com.apple.streaming.transportStreamTimestamp" (8-byte big-endian 90 kHz PTS masked to 33 bits). FFmpeg's "aac" demuxer discards these tags; the ingest parses them here to anchor `HLSSegmentProducer.PackedAudioSynthClock`.
enum PackedAudioID3 {

    static let appleTimestampOwner = "com.apple.streaming.transportStreamTimestamp"

    /// Returns 90 kHz program-clock timestamp (33-bit) from the first segment. Handles ID3v2.3 and v2.4. Returns nil if the tag is absent, malformed, unsynchronised, or has no matching PRIV frame.
    static func transportStreamTimestamp90k(in segment: Data) -> Int64? {
        // Apple writes ~73 bytes; 4 KB is a generous cap that avoids copying the whole segment.
        let b = [UInt8](segment.prefix(4096))
        guard b.count >= 10, b[0] == 0x49, b[1] == 0x44, b[2] == 0x33 else { return nil }
        let major = b[3]
        guard major == 3 || major == 4 else { return nil } // v2.2 uses 3-byte IDs/sizes and never appears in HLS packed audio
        let flags = b[5]
        guard flags & 0x80 == 0 else { return nil } // unsynchronisation requires 0xFF 0x00 de-escaping; no packed-audio producer sets it
        guard let tagSize = syncsafe32(b, at: 6) else { return nil }
        var pos = 10
        let end = min(b.count, 10 + tagSize)

        // Skip extended header: v2.4 size is syncsafe and includes itself; v2.3 is plain big-endian and excludes its own 4 bytes.
        if flags & 0x40 != 0 {
            if major == 4 {
                guard let extSize = syncsafe32(b, at: pos) else { return nil }
                pos += max(extSize, 6)
            } else {
                guard pos + 4 <= end else { return nil }
                pos += 4 + plain32(b, at: pos)
            }
        }

        while pos + 10 <= end {
            if b[pos] == 0 { break } // padding reached
            let isPriv = b[pos] == 0x50 && b[pos + 1] == 0x52
                && b[pos + 2] == 0x49 && b[pos + 3] == 0x56 // "PRIV"
            let frameSize: Int
            if major == 4 {
                guard let s = syncsafe32(b, at: pos + 4) else { return nil }
                frameSize = s
            } else {
                frameSize = plain32(b, at: pos + 4)
            }
            let bodyStart = pos + 10
            guard frameSize > 0, bodyStart + frameSize <= end else { return nil }
            if isPriv,
               let ts = appleTimestamp(privBody: b[bodyStart..<(bodyStart + frameSize)]) {
                return ts
            }
            pos = bodyStart + frameSize
        }
        return nil
    }

    /// PRIV body: owner string + NUL + 8-byte big-endian timestamp.
    private static func appleTimestamp(privBody: ArraySlice<UInt8>) -> Int64? {
        guard let nul = privBody.firstIndex(of: 0) else { return nil }
        let owner = String(decoding: privBody[privBody.startIndex..<nul], as: UTF8.self)
        guard owner == appleTimestampOwner else { return nil }
        let payload = privBody[(nul + 1)...]
        guard payload.count >= 8 else { return nil }
        var value: UInt64 = 0
        for byte in payload.prefix(8) {
            value = (value << 8) | UInt64(byte)
        }
        // Effective clock is 90 kHz over 33 bits, like a TS PTS.
        return Int64(value & 0x1_FFFF_FFFF)
    }

    /// 4-byte syncsafe integer (ID3v2.4): 7 bits per byte, high bit must be 0.
    private static func syncsafe32(_ b: [UInt8], at index: Int) -> Int? {
        guard index + 4 <= b.count else { return nil }
        let bytes = b[index..<(index + 4)]
        guard bytes.allSatisfy({ $0 & 0x80 == 0 }) else { return nil }
        return bytes.reduce(0) { ($0 << 7) | Int($1) }
    }

    /// 4-byte plain big-endian integer (ID3v2.3).
    private static func plain32(_ b: [UInt8], at index: Int) -> Int {
        guard index + 4 <= b.count else { return 0 }
        return (Int(b[index]) << 24) | (Int(b[index + 1]) << 16)
            | (Int(b[index + 2]) << 8) | Int(b[index + 3])
    }
}
