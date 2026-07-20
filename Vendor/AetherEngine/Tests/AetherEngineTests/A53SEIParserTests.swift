import Testing
@testable import AetherEngine

// #131: A53/ATSC captions ride inside the picture as user_data_registered_itu_t_t35 SEI
// (country 0xB5, provider 0x0031, "GA94", user_data_type_code 0x03).
@Suite("A53SEIParser SEI cc_data extraction")
struct A53SEIParserTests {

    /// T.35 payload carrying one valid field-1 triplet (0x94 0x20) and cc_count 1. 14 bytes.
    static let t35OneTriplet: [UInt8] = [
        0xB5, 0x00, 0x31,               // country, provider
        0x47, 0x41, 0x39, 0x34,         // "GA94"
        0x03,                           // user_data_type_code: cc_data
        0x41,                           // process_cc_data_flag | cc_count = 1
        0xFF,                           // em_data
        0xFC, 0x94, 0x20,               // marker|valid|type0, EDM pair
        0xFF,                           // trailing marker_bits
    ]

    /// SEI RBSP for the payload above: payload_type 4, payload_size 14, trailing bits.
    static let seiRBSPOneTriplet: [UInt8] = [0x04, 0x0E] + t35OneTriplet + [0x80]

    /// Full H.264 Annex B packet: AUD-ish filler NAL, then the SEI NAL (type 6).
    static let h264AnnexBOneTriplet: [UInt8] =
        [0x00, 0x00, 0x00, 0x01, 0x09, 0xF0]
        + [0x00, 0x00, 0x00, 0x01, 0x06] + seiRBSPOneTriplet

    private func parse(_ bytes: [UInt8], codec: A53SEIParser.CodecKind = .h264,
                       framing: A53SEIParser.NALFraming = .annexB) -> [CCDataParser.CCTriplet] {
        bytes.withUnsafeBufferPointer {
            A53SEIParser.triplets(in: $0.baseAddress!, size: $0.count, codec: codec, framing: framing)
        }
    }

    @Test("H.264 Annex B SEI yields the embedded triplet")
    func h264AnnexB() {
        #expect(parse(Self.h264AnnexBOneTriplet) == [.init(type: 0, data0: 0x94, data1: 0x20)])
    }

    @Test("HEVC prefix-SEI NAL (type 39, 2-byte header) yields the embedded triplet")
    func hevcAnnexB() {
        let pkt: [UInt8] = [0x00, 0x00, 0x00, 0x01, 0x4E, 0x01] + Self.seiRBSPOneTriplet
        #expect(parse(pkt, codec: .hevc) == [.init(type: 0, data0: 0x94, data1: 0x20)])
    }

    @Test("Length-prefixed (avcC-style) framing yields the embedded triplet")
    func lengthPrefixed() {
        let nal: [UInt8] = [0x06] + Self.seiRBSPOneTriplet
        let pkt: [UInt8] = [0x00, 0x00, 0x00, UInt8(nal.count)] + nal
        #expect(parse(pkt, framing: .lengthPrefixed(size: 4)) == [.init(type: 0, data0: 0x94, data1: 0x20)])
    }

    @Test("Emulation-prevention bytes inside cc_data are unescaped")
    func epbUnescape() {
        // cc_count 2: valid triplet (04 00 00) + invalid all-zero triplet. The raw tail
        // 04 00 00 00 00 00 FF escapes to 04 00 00 03 00 00 03 00 FF on the wire.
        let t35: [UInt8] = [
            0xB5, 0x00, 0x31, 0x47, 0x41, 0x39, 0x34, 0x03,
            0x42, 0xFF,                                     // cc_count 2, em_data
            0x04, 0x00, 0x00, 0x03, 0x00, 0x00, 0x03, 0x00, // escaped triplets
            0xFF,
        ]
        // payload_size counts RBSP (unescaped) bytes: 8 + 2 + 6 + 1 = 17 (0x11).
        let pkt: [UInt8] = [0x00, 0x00, 0x00, 0x01, 0x06, 0x04, 0x11] + t35 + [0x80]
        #expect(parse(pkt) == [.init(type: 0, data0: 0x00, data1: 0x00)])
    }

    @Test("T.35 payload after another SEI payload is still found")
    func multiPayloadSEI() {
        let rbsp: [UInt8] = [0x01, 0x02, 0xAA, 0xBB] + [0x04, 0x0E] + Self.t35OneTriplet + [0x80]
        let pkt: [UInt8] = [0x00, 0x00, 0x00, 0x01, 0x06] + rbsp
        #expect(parse(pkt) == [.init(type: 0, data0: 0x94, data1: 0x20)])
    }

    @Test("0xFF-extended payload size is honored")
    func extendedPayloadSize() {
        // payload_size 269 = 255 + 14: T.35 content first, then 255 padding bytes.
        let rbsp: [UInt8] = [0x04, 0xFF, 0x0E] + Self.t35OneTriplet + [UInt8](repeating: 0xAA, count: 255) + [0x80]
        let pkt: [UInt8] = [0x00, 0x00, 0x00, 0x01, 0x06] + rbsp
        #expect(parse(pkt) == [.init(type: 0, data0: 0x94, data1: 0x20)])
    }

    @Test("GA94 inside a non-SEI NAL (slice data false positive) is rejected")
    func ga94InSliceData() {
        let pkt: [UInt8] = [0x00, 0x00, 0x00, 0x01, 0x41, 0x9A] + Self.t35OneTriplet
        #expect(parse(pkt).isEmpty)
    }

    @Test("Truncation at every structural boundary returns empty, never traps")
    func truncationFuzz() {
        let full = Self.h264AnnexBOneTriplet
        for cut in 0..<(full.count - 1) {
            _ = parse(Array(full.prefix(cut)))   // must not trap
        }
        // Cutting into the cc_data triplets specifically drops the payload.
        #expect(parse(Array(full.prefix(full.count - 3))).isEmpty)
    }

    @Test("Wrong provider / identifier / type code are rejected")
    func t35Gates() {
        func pkt(mutating index: Int, to value: UInt8) -> [UInt8] {
            var t35 = Self.t35OneTriplet
            t35[index] = value
            return [0x00, 0x00, 0x00, 0x01, 0x06, 0x04, 0x0E] + t35 + [0x80]
        }
        #expect(parse(pkt(mutating: 0, to: 0xB4)).isEmpty)   // country
        #expect(parse(pkt(mutating: 2, to: 0x32)).isEmpty)   // provider
        #expect(parse(pkt(mutating: 3, to: 0x48)).isEmpty)   // identifier
        #expect(parse(pkt(mutating: 7, to: 0x04)).isEmpty)   // user_data_type_code
        #expect(parse(pkt(mutating: 8, to: 0x01)).isEmpty)   // process_cc_data_flag clear
    }

    @Test("Prefilter: no GA94, no parse")
    func prefilter() {
        let noCaptions: [UInt8] = [0x00, 0x00, 0x00, 0x01, 0x06, 0x04, 0x02, 0xAA, 0xBB, 0x80]
        #expect(parse(noCaptions).isEmpty)
        noCaptions.withUnsafeBufferPointer {
            #expect(!A53SEIParser.mayContainA53($0.baseAddress!, $0.count))
        }
        Self.h264AnnexBOneTriplet.withUnsafeBufferPointer {
            #expect(A53SEIParser.mayContainA53($0.baseAddress!, $0.count))
        }
    }

    @Test("NAL framing resolution from extradata")
    func framingResolution() {
        let avcC: [UInt8] = [0x01, 0x64, 0x00, 0x28, 0xFF, 0xE1, 0x00]
        avcC.withUnsafeBufferPointer {
            #expect(A53SEIParser.nalFraming(codec: .h264, extradata: $0.baseAddress, size: $0.count)
                    == .lengthPrefixed(size: 4))
        }
        var hvcC = [UInt8](repeating: 0x00, count: 23)
        hvcC[0] = 0x01
        hvcC[21] = 0xF3
        hvcC.withUnsafeBufferPointer {
            #expect(A53SEIParser.nalFraming(codec: .hevc, extradata: $0.baseAddress, size: $0.count)
                    == .lengthPrefixed(size: 4))
        }
        let annexB: [UInt8] = [0x00, 0x00, 0x00, 0x01, 0x67, 0x64, 0x00]
        annexB.withUnsafeBufferPointer {
            #expect(A53SEIParser.nalFraming(codec: .h264, extradata: $0.baseAddress, size: $0.count) == .annexB)
        }
        #expect(A53SEIParser.nalFraming(codec: .h264, extradata: nil, size: 0) == .annexB)
    }
}
