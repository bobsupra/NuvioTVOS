import Testing
import AetherLibavcodec
@testable import AetherEngine

/// #365 round 2: when the source config record is Annex B and the packets are Annex B too, the record
/// is forwarded and **movenc builds the hvcC itself**. `ff_isom_write_hvcc` collects five NAL types,
/// not three (`array_idx_to_type` in libavformat/hevc.c: VPS, SPS, PPS, SEI_PREFIX, SEI_SUFFIX), so a
/// prefix SEI in the CodecPrivate lands in the init sample description. That is exactly the record
/// Apple TV hardware rejects (AE#187), and `canonicalizeHEVCConfigRecord` cannot defend this door: it
/// guards on `configurationVersion == 1`, which an Annex-B buffer fails by construction, and the
/// muxer-built record never passes through the engine at all.
struct Issue365AnnexBSEILeakTests {

    /// VPS / SPS / PPS of a real 1080p Main10 PQ stream, Annex B with 3-byte start codes.
    private static let parameterSets: [UInt8] = [
        0x00, 0x00, 0x01, 0x40, 0x01, 0x0c, 0x01, 0xff, 0xff, 0x02, 0x20, 0x00, 0x00, 0x03, 0x00,
        0x90, 0x00, 0x00, 0x03, 0x00, 0x00, 0x03, 0x00, 0x78, 0x95, 0x94, 0x09, 0x00, 0x00, 0x01,
        0x42, 0x01, 0x01, 0x02, 0x20, 0x00, 0x00, 0x03, 0x00, 0x90, 0x00, 0x00, 0x03, 0x00, 0x00,
        0x03, 0x00, 0x78, 0xa0, 0x03, 0xc0, 0x80, 0x11, 0x07, 0xca, 0xd9, 0x65, 0x65, 0x4a, 0x4c,
        0x2f, 0x01, 0x6a, 0x12, 0x20, 0x12, 0x08, 0x00, 0x00, 0x03, 0x00, 0x08, 0x00, 0x00, 0x03,
        0x00, 0xc0, 0x40, 0x00, 0x00, 0x01, 0x44, 0x01, 0xc0, 0x73, 0xc1, 0x89,
    ]

    /// A prefix SEI (NAL type 39) carrying an unregistered user-data payload, the shape x265 writes its
    /// options string in. 500 payload bytes so the blob lands near the 726 B the #365 reporter's
    /// CodecPrivate carries, which is far more than VPS + SPS + PPS can account for on their own.
    private static func userDataSEI(payloadBytes: Int = 500) -> [UInt8] {
        var nal: [UInt8] = [0x4E, 0x01]           // nal_type 39, nuh_layer_id 0, temporal_id_plus1 1
        nal.append(0x05)                          // payloadType: user_data_unregistered
        var remaining = payloadBytes
        while remaining >= 255 { nal.append(0xFF); remaining -= 255 }
        nal.append(UInt8(remaining))
        nal += [UInt8](repeating: 0x42, count: payloadBytes)   // 0x42 filler cannot emulate a start code
        nal.append(0x80)                          // rbsp_trailing_bits
        return [0x00, 0x00, 0x01] + nal
    }

    /// NAL types of the arrays in an hvcC, in the order the record lists them.
    private static func hvcCArrayTypes(_ record: [UInt8]) -> [Int] {
        guard record.count >= 23, record[0] == 1 else { return [] }
        var types: [Int] = []
        var offset = 23
        for _ in 0..<Int(record[22]) {
            guard offset + 3 <= record.count else { return types }
            types.append(Int(record[offset]) & 0x3F)
            let numNalus = (Int(record[offset + 1]) << 8) | Int(record[offset + 2])
            offset += 3
            for _ in 0..<numNalus {
                guard offset + 2 <= record.count else { return types }
                offset += 2 + ((Int(record[offset]) << 8) | Int(record[offset + 1]))
            }
        }
        return types
    }

    private static func splitAnnexB(_ bytes: [UInt8]) -> [[UInt8]] {
        var starts: [Int] = []
        var i = 0
        while i + 3 <= bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                starts.append(i + 3)
                i += 3
            } else {
                i += 1
            }
        }
        return starts.enumerated().map { idx, start in
            let end = idx + 1 < starts.count ? starts[idx + 1] - 3 : bytes.count
            return Array(bytes[start..<end])
        }
    }

    private static func nalTypes(_ annexB: [UInt8]) -> [Int] {
        splitAnnexB(annexB).map { (Int($0[0]) >> 1) & 0x3F }
    }

    // MARK: - The leak, measured on the muxer rather than assumed

    @Test("movenc writes the prefix SEI into the hvcC it builds from an Annex-B record")
    func muxerBuiltRecordCarriesTheSEIArray() throws {
        let withSEI = Self.parameterSets + Self.userDataSEI()
        let record = try #require(VideoConfigRecord.fromAnnexB(
            withSEI, codecID: AV_CODEC_ID_HEVC, width: 1920, height: 1080))
        // Four arrays, the fourth being SEI_PREFIX: this is the AE#187 record shape, reached through a
        // door the AE#187 defense does not cover.
        #expect(Self.hvcCArrayTypes(record) == [32, 33, 34, 39])
    }

    // MARK: - The fix

    @Test("Canonicalizing the Annex-B record drops the SEI and keeps VPS/SPS/PPS")
    func canonicalizationDropsTheSEINAL() throws {
        let withSEI = Self.parameterSets + Self.userDataSEI()
        let canonical = try #require(VideoConfigRecord.canonicalizeAnnexBHEVCConfigRecord(withSEI))

        #expect(Self.nalTypes(canonical) == [32, 33, 34])
        // Still Annex B, so movenc makes the same call about the samples it made before: these packets
        // are Annex B and have to be converted. Handing it an hvcC here would leave them unconverted.
        #expect(VideoConfigRecord.isAnnexB(canonical))
        // The parameter sets themselves are untouched, byte for byte.
        #expect(Self.splitAnnexB(canonical) == Self.splitAnnexB(Self.parameterSets))
    }

    @Test("The record movenc builds from the canonicalized blob has no SEI array")
    func canonicalizedRecordSurvivesTheMuxer() throws {
        let withSEI = Self.parameterSets + Self.userDataSEI()
        let canonical = try #require(VideoConfigRecord.canonicalizeAnnexBHEVCConfigRecord(withSEI))
        let record = try #require(VideoConfigRecord.fromAnnexB(
            canonical, codecID: AV_CODEC_ID_HEVC, width: 1920, height: 1080))

        #expect(Self.hvcCArrayTypes(record) == [32, 33, 34])
        #expect(record[22] == 3)
    }

    @Test("Also drops a suffix SEI and leaves an unknown NAL type out")
    func dropsSuffixSEIAndUnknownTypes() throws {
        var blob = Self.parameterSets
        blob += [0x00, 0x00, 0x01, 0x50, 0x01, 0x03, 0x04, 0x80]   // nal_type 40, SEI_SUFFIX
        blob += [0x00, 0x00, 0x01, 0x7C, 0x01, 0x11, 0x22]         // nal_type 62, unspecified (DV RPU)
        let canonical = try #require(VideoConfigRecord.canonicalizeAnnexBHEVCConfigRecord(blob))
        #expect(Self.nalTypes(canonical) == [32, 33, 34])
    }

    @Test("A record that is already parameter-sets-only returns nil (nothing to rewrite)")
    func alreadyCanonicalReturnsNil() {
        #expect(VideoConfigRecord.canonicalizeAnnexBHEVCConfigRecord(Self.parameterSets) == nil)
    }

    @Test("An hvcC is refused: this canonicalizer only speaks Annex B")
    func refusesAnHvcC() throws {
        let record = try #require(VideoConfigRecord.fromAnnexB(
            Self.parameterSets, codecID: AV_CODEC_ID_HEVC, width: 1920, height: 1080))
        #expect(VideoConfigRecord.canonicalizeAnnexBHEVCConfigRecord(record) == nil)
    }

    @Test("A blob with no parameter sets at all is left alone rather than emptied")
    func refusesToEmitAnEmptyRecord() {
        #expect(VideoConfigRecord.canonicalizeAnnexBHEVCConfigRecord(Self.userDataSEI()) == nil)
    }

    // MARK: - The witness

    @Test("The Annex-B summary names every NAL type and what it costs in bytes")
    func summaryNamesTypesAndSizes() {
        var blob: [UInt8] = []
        blob += [0, 0, 1, 0x40, 0x01] + [UInt8](repeating: 0x11, count: 20)   // VPS, 22 B
        blob += [0, 0, 1, 0x42, 0x01] + [UInt8](repeating: 0x22, count: 50)   // SPS, 52 B
        blob += [0, 0, 1, 0x44, 0x01] + [UInt8](repeating: 0x33, count: 5)    // PPS, 7 B
        blob += [0, 0, 1, 0x4E, 0x01] + [UInt8](repeating: 0x44, count: 400)  // SEI_PREFIX, 402 B
        #expect(VideoConfigRecord.annexBNALSummary(blob)
                == "VPS×1 (22 B), SPS×1 (52 B), PPS×1 (7 B), SEI_PREFIX×1 (402 B)")
    }

    @Test("Repeated NAL types are counted together, unknown types are named by number")
    func summaryCountsRepeatsAndNamesUnknownTypes() {
        var blob: [UInt8] = []
        blob += [0, 0, 1, 0x42, 0x01] + [UInt8](repeating: 0x22, count: 10)   // SPS, 12 B
        blob += [0, 0, 1, 0x42, 0x01] + [UInt8](repeating: 0x22, count: 20)   // SPS, 22 B
        blob += [0, 0, 1, 0x7C, 0x01] + [UInt8](repeating: 0x33, count: 4)    // type 62, 6 B
        #expect(VideoConfigRecord.annexBNALSummary(blob) == "SPS×2 (34 B), NAL62×1 (6 B)")
    }

    @Test("Four-byte start codes are handled the same as three-byte ones")
    func handlesFourByteStartCodes() throws {
        var blob: [UInt8] = []
        for nal in Self.splitAnnexB(Self.parameterSets) { blob += [0x00, 0x00, 0x00, 0x01] + nal }
        blob += [0x00, 0x00, 0x00, 0x01] + Array(Self.userDataSEI().dropFirst(3))
        let canonical = try #require(VideoConfigRecord.canonicalizeAnnexBHEVCConfigRecord(blob))
        #expect(Self.nalTypes(canonical) == [32, 33, 34])
        #expect(VideoConfigRecord.isAnnexB(canonical))
    }
}
