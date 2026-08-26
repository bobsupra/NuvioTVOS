import Testing
import AetherLibavcodec
@testable import AetherEngine

/// #365: the framing of a HEVC source is decided from the extradata by both movenc and every NAL
/// walker in the engine. These pin the two predicates that decision now rests on, and the Annex-B to
/// hvcC conversion that keeps the mp4 muxer from rewriting samples it must not touch.
struct VideoConfigRecordFramingTests {

    /// VPS / SPS / PPS of a real 1080p Main10 PQ stream, Annex B with 3-byte start codes, exactly the
    /// shape libavformat synthesises for a Matroska track whose CodecPrivate is missing or Annex B.
    private static let annexBParameterSets: [UInt8] = [
        0x00, 0x00, 0x01, 0x40, 0x01, 0x0c, 0x01, 0xff, 0xff, 0x02, 0x20, 0x00, 0x00, 0x03, 0x00,
        0x90, 0x00, 0x00, 0x03, 0x00, 0x00, 0x03, 0x00, 0x78, 0x95, 0x94, 0x09, 0x00, 0x00, 0x01,
        0x42, 0x01, 0x01, 0x02, 0x20, 0x00, 0x00, 0x03, 0x00, 0x90, 0x00, 0x00, 0x03, 0x00, 0x00,
        0x03, 0x00, 0x78, 0xa0, 0x03, 0xc0, 0x80, 0x11, 0x07, 0xca, 0xd9, 0x65, 0x65, 0x4a, 0x4c,
        0x2f, 0x01, 0x6a, 0x12, 0x20, 0x12, 0x08, 0x00, 0x00, 0x03, 0x00, 0x08, 0x00, 0x00, 0x03,
        0x00, 0xc0, 0x40, 0x00, 0x00, 0x01, 0x44, 0x01, 0xc0, 0x73, 0xc1, 0x89,
    ]

    /// Split a 3-byte-start-code buffer into its NAL payloads.
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

    // MARK: - isAnnexB, the predicate movenc itself uses

    @Test("A config record starting with a start code reads as Annex B, an hvcC does not")
    func detectsAnnexBConfigRecords() {
        #expect(VideoConfigRecord.isAnnexB(Self.annexBParameterSets))
        #expect(VideoConfigRecord.isAnnexB([0x00, 0x00, 0x00, 0x01, 0x40, 0x01, 0x0c, 0x01]))
        // Real hvcC head: configurationVersion 1, Main10, level 120.
        #expect(!VideoConfigRecord.isAnnexB([0x01, 0x02, 0x20, 0x00, 0x00, 0x00, 0x90, 0x00]))
        #expect(!VideoConfigRecord.isAnnexB([0x01, 0x02, 0x20]))   // too short to decide
    }

    // MARK: - Packet framing: the head bytes are not the discriminator

    @Test("A length-prefixed packet is recognised by walking it, not by its head bytes")
    func lengthPrefixedWalkClosesExactly() {
        var bytes: [UInt8] = []
        for nalSize in [40, 900, 17] {
            bytes += [UInt8((nalSize >> 24) & 0xFF), UInt8((nalSize >> 16) & 0xFF),
                      UInt8((nalSize >> 8) & 0xFF), UInt8(nalSize & 0xFF)]
            bytes += [UInt8](repeating: 0x42, count: nalSize)
        }
        bytes.withUnsafeBufferPointer { buf in
            #expect(VideoConfigRecord.walksAsLengthPrefixed(buf.baseAddress!, size: buf.count))
        }
    }

    /// The reason the probe walks instead of sniffing: any NAL of 256 to 511 bytes carries the
    /// length prefix `00 00 01 xx`, which reads as a start code to anything that looks at the head.
    /// SEI and parameter-set NALs land in that band routinely.
    @Test("A 0x00 0x00 0x01 length prefix reads as a start code and must not decide the framing")
    func startCodeLookalikeLengthPrefixStillWalks() {
        let nalSize = 0x0000_0103   // 259 bytes: prefix is 00 00 01 03
        var bytes: [UInt8] = [0x00, 0x00, 0x01, 0x03]
        bytes += [UInt8](repeating: 0x26, count: nalSize)
        bytes.withUnsafeBufferPointer { buf in
            #expect(VideoConfigRecord.startsWithStartCode(buf.baseAddress!, size: buf.count))
            #expect(VideoConfigRecord.walksAsLengthPrefixed(buf.baseAddress!, size: buf.count))
        }
    }

    @Test("Annex-B packet bytes do not walk as length-prefixed")
    func annexBDoesNotWalkAsLengthPrefixed() {
        Self.annexBParameterSets.withUnsafeBufferPointer { buf in
            #expect(!VideoConfigRecord.walksAsLengthPrefixed(buf.baseAddress!, size: buf.count))
            #expect(VideoConfigRecord.startsWithStartCode(buf.baseAddress!, size: buf.count))
        }
    }

    @Test("A truncated length prefix does not close the walk")
    func truncatedLengthPrefixedPacketFailsTheWalk() {
        let bytes: [UInt8] = [0x00, 0x00, 0x00, 0x20, 0x26, 0x01, 0xff]   // declares 32, carries 3
        bytes.withUnsafeBufferPointer { buf in
            #expect(!VideoConfigRecord.walksAsLengthPrefixed(buf.baseAddress!, size: buf.count))
        }
    }

    // MARK: - Annex-B to hvcC

    @Test("Annex-B parameter sets convert into an hvcC carrying all three arrays")
    func buildsHvcCFromAnnexB() throws {
        let hvcC = try #require(VideoConfigRecord.fromAnnexB(
            Self.annexBParameterSets, codecID: AV_CODEC_ID_HEVC, width: 1920, height: 1080))
        #expect(hvcC.count >= 23)
        #expect(hvcC[0] == 1)                       // configurationVersion
        #expect(hvcC[22] == 3)                      // VPS + SPS + PPS arrays
        #expect(Int(hvcC[21] & 0x03) + 1 == 4)      // naluLengthSize the muxer will write samples with
        #expect(!VideoConfigRecord.isAnnexB(hvcC))

        // The record must carry the source parameter sets, not merely claim three arrays: every
        // Annex-B NAL has to appear verbatim inside it.
        for nal in Self.splitAnnexB(Self.annexBParameterSets) {
            let found = hvcC.indices.contains { i in
                i + nal.count <= hvcC.count && Array(hvcC[i..<(i + nal.count)]) == nal
            }
            #expect(found, "NAL type \((nal[0] >> 1) & 0x3F) missing from the rebuilt hvcC")
        }
    }

    @Test("An hvcC input is refused rather than double-wrapped")
    func refusesNonAnnexBInput() {
        let hvcC: [UInt8] = [0x01, 0x02, 0x20, 0x00, 0x00, 0x00, 0x90, 0x00, 0x00, 0x00, 0x00, 0x00,
                             0x78, 0xf0, 0x00, 0xfc, 0xfd, 0xfa, 0xfa, 0x00, 0x00, 0x0f, 0x00]
        #expect(VideoConfigRecord.fromAnnexB(
            hvcC, codecID: AV_CODEC_ID_HEVC, width: 1920, height: 1080) == nil)
    }

    // MARK: - The in-band rebuild gate (#19) must not fire on Annex-B extradata

    @Test("Annex-B extradata is not mistaken for an hvcC with numOfArrays = 0")
    func inBandRebuildGateRejectsAnnexB() {
        Self.annexBParameterSets.withUnsafeBufferPointer { buf in
            let base = buf.baseAddress!
            // The two checks the gate used to rest on both pass on this buffer, which is why the
            // configurationVersion check is load-bearing rather than cosmetic.
            #expect(buf.count > 22)
            #expect(base[22] == 0)
            #expect(Int(base[21] & 0x03) + 1 == 4)
            #expect(!HLSVideoEngine.configRecordNeedsInBandRebuild(base, size: buf.count))
        }
    }

    @Test("A real hvcC with no parameter-set arrays still qualifies for the in-band rebuild")
    func inBandRebuildGateAcceptsEmptyHvcC() {
        var record = [UInt8](repeating: 0, count: 23)
        record[0] = 1        // configurationVersion
        record[21] = 0xF3    // reserved bits set, naluLengthSize 4
        record[22] = 0       // numOfArrays
        record.withUnsafeBufferPointer { buf in
            #expect(HLSVideoEngine.configRecordNeedsInBandRebuild(buf.baseAddress!, size: buf.count))
        }
        record[22] = 3
        record.withUnsafeBufferPointer { buf in
            #expect(!HLSVideoEngine.configRecordNeedsInBandRebuild(buf.baseAddress!, size: buf.count))
        }
    }

    // MARK: - The predicate that has to match movenc's, per codec

    @Test("The reformat predicate mirrors movenc: Annex B for HEVC, anything-but-avcC for H.264")
    func reformatPredicateMatchesMovenc() {
        let hvcC: [UInt8] = [0x01, 0x02, 0x20, 0x00, 0x00, 0x00, 0x90, 0x00]
        Self.annexBParameterSets.withUnsafeBufferPointer { annexB in
            hvcC.withUnsafeBufferPointer { record in
                #expect(VideoConfigRecord.muxerWillReformatPackets(
                    codecID: AV_CODEC_ID_HEVC, extradata: annexB.baseAddress, size: annexB.count))
                #expect(!VideoConfigRecord.muxerWillReformatPackets(
                    codecID: AV_CODEC_ID_HEVC, extradata: record.baseAddress, size: record.count))
                // H.264 reformats on anything that is not an avcC, which is a wider test than
                // "starts with a start code": movenc only checks the first byte.
                #expect(VideoConfigRecord.muxerWillReformatPackets(
                    codecID: AV_CODEC_ID_H264, extradata: annexB.baseAddress, size: annexB.count))
                #expect(!VideoConfigRecord.muxerWillReformatPackets(
                    codecID: AV_CODEC_ID_H264, extradata: record.baseAddress, size: record.count))
                // Codecs the mp4 muxer never reformats, and a track with no extradata at all.
                #expect(!VideoConfigRecord.muxerWillReformatPackets(
                    codecID: AV_CODEC_ID_AV1, extradata: annexB.baseAddress, size: annexB.count))
                #expect(!VideoConfigRecord.muxerWillReformatPackets(
                    codecID: AV_CODEC_ID_HEVC, extradata: nil, size: 0))
            }
        }
    }

    @Test("H.264 Annex-B parameter sets convert into an avcC")
    func buildsAvcCFromAnnexB() throws {
        // SPS + PPS of a real 1280x720 High profile stream, Annex B.
        let annexB: [UInt8] = [
            0x00, 0x00, 0x00, 0x01, 0x67, 0x64, 0x00, 0x1f, 0xac, 0xd9, 0x40, 0x50, 0x05, 0xbb,
            0x01, 0x6a, 0x02, 0x02, 0x02, 0x80, 0x00, 0x00, 0x03, 0x00, 0x80, 0x00, 0x00, 0x1e,
            0x07, 0x8c, 0x18, 0xcb,
            0x00, 0x00, 0x00, 0x01, 0x68, 0xeb, 0xe3, 0xcb, 0x22, 0xc0,
        ]
        let avcC = try #require(VideoConfigRecord.fromAnnexB(
            annexB, codecID: AV_CODEC_ID_H264, width: 1280, height: 720))
        #expect(avcC.count > 7)
        #expect(avcC[0] == 1)                     // configurationVersion
        #expect(Int(avcC[4] & 0x03) + 1 == 4)     // lengthSizeMinusOne
        #expect(!VideoConfigRecord.isAnnexB(avcC))
    }
}
