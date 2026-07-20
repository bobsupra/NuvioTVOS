import Testing
import AetherLibavcodec
@testable import AetherEngine

// #77: `CCDataParser` reads the bare cc_data triplet stream FFmpeg's MOV demuxer emits for a demuxable
// CEA-608 caption track (`eia_608` / QuickTime `c608`), the path that ships.
@Suite("CCDataParser cc_data triplet parsing")
struct CCDataParserTests {

    /// Run `parseCCDataTriplets` over a raw byte buffer via a stack AVPacket pointing at it.
    private func triplets(of bytes: [UInt8]) -> [CCDataParser.CCTriplet] {
        var buf = bytes
        return buf.withUnsafeMutableBufferPointer { p in
            var pkt = AVPacket()
            pkt.data = p.baseAddress
            pkt.size = Int32(p.count)
            return withUnsafePointer(to: &pkt) { CCDataParser.parseCCDataTriplets(packet: $0) }
        }
    }

    @Test("Reads bare cc_data triplets, honoring cc_valid and cc_type")
    func ccDataTriplets() {
        // 0xFC = marker|cc_valid|type0 (field1); 0xFD = type1 (field2); 0xF8 = cc_valid clear (invalid).
        let out = triplets(of: [0xFC, 0x94, 0x20,
                                0xFD, 0x41, 0x42,
                                0xF8, 0x55, 0x66,
                                0xFC, 0x13, 0xF2])
        #expect(out == [
            .init(type: 0, data0: 0x94, data1: 0x20),
            .init(type: 1, data0: 0x41, data1: 0x42),   // field 2 surfaced (caller filters type==0)
            .init(type: 0, data0: 0x13, data1: 0xF2),    // the cc_valid=0 triplet is dropped
        ])
    }

    @Test("Ignores a trailing partial triplet and tiny packets")
    func ccDataTripletsBounds() {
        #expect(triplets(of: [0xFC, 0x94]).isEmpty)                       // < 3 bytes
        #expect(triplets(of: [0xFC, 0x94, 0x20, 0xFC, 0x13]).count == 1)  // trailing 2-byte remainder dropped
        #expect(triplets(of: []).isEmpty)
    }

    @Test("Byte-level overload matches the packet path (#131)")
    func byteLevelOverload() {
        let bytes: [UInt8] = [0xFC, 0x94, 0x20,
                              0xFD, 0x41, 0x42,
                              0xF8, 0x55, 0x66]
        let out = bytes.withUnsafeBufferPointer {
            CCDataParser.parseCCDataTriplets(bytes: $0.baseAddress!, count: $0.count)
        }
        #expect(out == [
            .init(type: 0, data0: 0x94, data1: 0x20),
            .init(type: 1, data0: 0x41, data1: 0x42),
        ])
        #expect(CCDataParser.parseCCDataTriplets(bytes: bytes, count: 2).isEmpty)
    }
}
