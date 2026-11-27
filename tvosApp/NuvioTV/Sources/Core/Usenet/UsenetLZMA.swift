import Foundation

/// LZMA decoding, for 7z headers (7-Zip compresses an archive's file list with LZMA even when
/// the files themselves are stored). After LzmaSpec.cpp of the LZMA SDK (public domain).
enum UsenetLZMA {
    enum Failure: Error, Equatable {
        case badProperties
        case corrupted
        /// More output than an archive header ever needs.
        case tooLarge
    }

    static let maxOutput = 64 << 20

    /// `size` bytes out of `data`, an LZMA stream with the 5-byte `properties` (lc/lp/pb and the
    /// dictionary size) kept apart, as 7z keeps them.
    static func decode(properties: Data, data: Data, size: Int) throws -> Data {
        let props = [UInt8](properties)
        guard props.count >= 5, props[0] < 9 * 5 * 5 else { throw Failure.badProperties }
        guard size >= 0, size <= maxOutput else { throw Failure.tooLarge }
        var d = Int(props[0])
        let lc = d % 9
        d /= 9
        let lp = d % 5
        let pb = d / 5
        let dictionarySize = Int(props[1]) | Int(props[2]) << 8 | Int(props[3]) << 16 | Int(props[4]) << 24
        var decoder = Decoder(input: [UInt8](data), lc: lc, lp: lp, pb: pb,
                              dictionarySize: max(dictionarySize, 1 << 12), size: size)
        return try decoder.run()
    }

    private struct RangeDecoder {
        let input: [UInt8]
        var position = 0
        var range: UInt32 = 0xFFFF_FFFF
        var code: UInt32 = 0
        var corrupted = false

        init(input: [UInt8]) {
            self.input = input
            if next() != 0 { corrupted = true }
            for _ in 0..<4 { code = code << 8 | UInt32(next()) }
            if code == range { corrupted = true }
        }

        mutating func next() -> UInt8 {
            guard position < input.count else {
                corrupted = true
                return 0
            }
            defer { position += 1 }
            return input[position]
        }

        mutating func normalize() {
            if range < 1 << 24 {
                range <<= 8
                code = code << 8 | UInt32(next())
            }
        }

        mutating func directBits(_ count: Int) -> UInt32 {
            var result: UInt32 = 0
            for _ in 0..<count {
                range >>= 1
                code &-= range
                let t = 0 &- (code >> 31)
                code &+= range & t
                if code == range { corrupted = true }
                normalize()
                result = result << 1 &+ (t &+ 1)
            }
            return result
        }

        mutating func bit(_ probs: inout [UInt16], _ index: Int) -> Int {
            var v = UInt32(probs[index])
            let bound = (range >> 11) &* v
            let symbol: Int
            if code < bound {
                v += ((1 << 11) - v) >> 5
                range = bound
                symbol = 0
            } else {
                v -= v >> 5
                code &-= bound
                range &-= bound
                symbol = 1
            }
            probs[index] = UInt16(v)
            normalize()
            return symbol
        }

        mutating func tree(_ probs: inout [UInt16], base: Int, bits: Int) -> Int {
            var m = 1
            for _ in 0..<bits { m = (m << 1) + bit(&probs, base + m) }
            return m - (1 << bits)
        }

        mutating func reverseTree(_ probs: inout [UInt16], base: Int, bits: Int) -> Int {
            var m = 1
            var symbol = 0
            for i in 0..<bits {
                let b = bit(&probs, base + m)
                m = (m << 1) + b
                symbol |= b << i
            }
            return symbol
        }
    }

    /// Match lengths: a choice bit, then 3, 3 or 8 bits.
    private struct LengthDecoder {
        var probs = [UInt16](repeating: 1024, count: 2 + 16 * 8 + 16 * 8 + 256)

        mutating func decode(_ rc: inout RangeDecoder, posState: Int) -> Int {
            if rc.bit(&probs, 0) == 0 { return rc.tree(&probs, base: 2 + posState * 8, bits: 3) }
            if rc.bit(&probs, 1) == 0 { return 8 + rc.tree(&probs, base: 2 + 128 + posState * 8, bits: 3) }
            return 16 + rc.tree(&probs, base: 2 + 256, bits: 8)
        }
    }

    private struct Decoder {
        var rc: RangeDecoder
        let lc: Int
        let lp: Int
        let pb: Int
        let dictionarySize: Int
        let size: Int
        var out: [UInt8] = []
        var literals: [UInt16]
        var posSlot = [UInt16](repeating: 1024, count: 4 * 64)
        var align = [UInt16](repeating: 1024, count: 16)
        var posDecoders = [UInt16](repeating: 1024, count: 115)
        var isMatch = [UInt16](repeating: 1024, count: 12 << 4)
        var isRep = [UInt16](repeating: 1024, count: 12)
        var isRepG0 = [UInt16](repeating: 1024, count: 12)
        var isRepG1 = [UInt16](repeating: 1024, count: 12)
        var isRepG2 = [UInt16](repeating: 1024, count: 12)
        var isRep0Long = [UInt16](repeating: 1024, count: 12 << 4)
        var length = LengthDecoder()
        var repLength = LengthDecoder()

        init(input: [UInt8], lc: Int, lp: Int, pb: Int, dictionarySize: Int, size: Int) {
            rc = RangeDecoder(input: input)
            self.lc = lc
            self.lp = lp
            self.pb = pb
            self.dictionarySize = dictionarySize
            self.size = size
            literals = [UInt16](repeating: 1024, count: 0x300 << (lc + lp))
            out.reserveCapacity(size)
        }

        mutating func run() throws -> Data {
            guard !rc.corrupted else { throw Failure.corrupted }
            var state = 0
            var rep0 = 0, rep1 = 0, rep2 = 0, rep3 = 0
            while out.count < size {
                let posState = out.count & ((1 << pb) - 1)
                if rc.bit(&isMatch, (state << 4) + posState) == 0 {
                    literal(state: state, rep0: rep0)
                    state = state < 4 ? 0 : (state < 10 ? state - 3 : state - 6)
                    continue
                }
                var len: Int
                if rc.bit(&isRep, state) != 0 {
                    guard !out.isEmpty else { throw Failure.corrupted }
                    if rc.bit(&isRepG0, state) == 0 {
                        if rc.bit(&isRep0Long, (state << 4) + posState) == 0 {
                            state = state < 7 ? 9 : 11
                            out.append(out[out.count - rep0 - 1])
                            continue
                        }
                    } else {
                        let distance: Int
                        if rc.bit(&isRepG1, state) == 0 {
                            distance = rep1
                        } else {
                            if rc.bit(&isRepG2, state) == 0 {
                                distance = rep2
                            } else {
                                distance = rep3
                                rep3 = rep2
                            }
                            rep2 = rep1
                        }
                        rep1 = rep0
                        rep0 = distance
                    }
                    len = repLength.decode(&rc, posState: posState)
                    state = state < 7 ? 8 : 11
                } else {
                    rep3 = rep2
                    rep2 = rep1
                    rep1 = rep0
                    len = length.decode(&rc, posState: posState)
                    state = state < 7 ? 7 : 10
                    let distance = self.distance(len)
                    if distance == 0xFFFF_FFFF { break } // end marker
                    guard distance < out.count, distance < dictionarySize else { throw Failure.corrupted }
                    rep0 = distance
                }
                len = min(len + 2, size - out.count)
                guard rep0 < out.count else { throw Failure.corrupted }
                for _ in 0..<len { out.append(out[out.count - rep0 - 1]) }
                if rc.corrupted { throw Failure.corrupted }
            }
            guard !rc.corrupted, out.count == size else { throw Failure.corrupted }
            return Data(out)
        }

        mutating func literal(state: Int, rep0: Int) {
            let previous = out.last.map(Int.init) ?? 0
            let literalState = ((out.count & ((1 << lp) - 1)) << lc) + (previous >> (8 - lc))
            let base = 0x300 * literalState
            var symbol = 1
            if state >= 7, rep0 < out.count {
                var matchByte = Int(out[out.count - rep0 - 1])
                while symbol < 0x100 {
                    let matchBit = (matchByte >> 7) & 1
                    matchByte <<= 1
                    let b = rc.bit(&literals, base + ((1 + matchBit) << 8) + symbol)
                    symbol = symbol << 1 | b
                    if matchBit != b { break }
                }
            }
            while symbol < 0x100 { symbol = symbol << 1 | rc.bit(&literals, base + symbol) }
            out.append(UInt8(symbol - 0x100))
        }

        mutating func distance(_ len: Int) -> Int {
            let lenState = min(len, 3)
            let slot = rc.tree(&posSlot, base: lenState * 64, bits: 6)
            guard slot >= 4 else { return slot }
            let directBits = (slot >> 1) - 1
            var distance = (2 | (slot & 1)) << directBits
            if slot < 14 {
                distance += rc.reverseTree(&posDecoders, base: distance - slot, bits: directBits)
            } else {
                distance += Int(rc.directBits(directBits - 4)) << 4
                distance += rc.reverseTree(&align, base: 0, bits: 4)
            }
            return distance & 0xFFFF_FFFF
        }
    }
}
