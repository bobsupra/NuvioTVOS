import Foundation

/// #551: what a warm still has to fetch once its head is in hand.
///
/// A second request is the most expensive thing a speculative path can spend against a metered
/// origin (#377), so the tail is asked for only where a cold open would actually go looking for it:
/// an MP4 whose `moov` sits behind media the warm head does not reach. Matroska is excluded on
/// measurement rather than on principle, since it reads no cues at open whether they sit at the
/// front or the back, and every other container here is left alone because the sniffer cannot say
/// anything true about it.
enum SourcePrewarmPlan {

    /// Walks the top-level box chain inside `head` and reports whether the source's trailing object
    /// is still unaccounted for. False for anything that is not an MP4-family head, and false as
    /// soon as `moov` is found inside the warm bytes.
    static func needsTrailingObject(head: Data) -> Bool {
        guard isMP4Family(head) else { return false }
        var offset = 0
        while offset + 8 <= head.count {
            let size32 = beUInt32(head, at: offset)
            let type = boxType(head, at: offset + 4)
            if type == "moov" { return false }
            var advance: Int64
            switch size32 {
            case 0:
                // "To the end of the file": nothing follows it, so the walk is over and the warm
                // head never saw a moov.
                return true
            case 1:
                guard offset + 16 <= head.count else { return true }
                let large = beUInt64(head, at: offset + 8)
                guard large >= 16 else { return true }
                advance = Int64(bitPattern: large)
            default:
                guard size32 >= 8 else { return true }
                advance = Int64(size32)
            }
            guard advance > 0, offset < Int.max - Int(clamping: advance) else { return true }
            offset += Int(clamping: advance)
        }
        return true
    }

    /// `ftyp` at the start is the ISO base-media brand marker; `moov` / `mdat` / `free` cover the
    /// QuickTime files that open without one.
    private static func isMP4Family(_ head: Data) -> Bool {
        guard head.count >= 8 else { return false }
        switch boxType(head, at: 4) {
        case "ftyp", "moov", "mdat", "free", "skip", "wide", "pnot": return true
        default: return false
        }
    }

    private static func boxType(_ data: Data, at offset: Int) -> String {
        guard offset + 4 <= data.count else { return "" }
        let base = data.startIndex + offset
        let bytes = [UInt8](data[base..<(base + 4)])
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return "" }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func beUInt32(_ data: Data, at offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        var v: UInt32 = 0
        for i in 0..<4 { v = (v << 8) | UInt32(data[base + i]) }
        return v
    }

    private static func beUInt64(_ data: Data, at offset: Int) -> UInt64 {
        let base = data.startIndex + offset
        var v: UInt64 = 0
        for i in 0..<8 { v = (v << 8) | UInt64(data[base + i]) }
        return v
    }
}
