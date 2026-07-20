import XCTest
@testable import AetherEngine

/// Covers the packed-audio ingest: segment format sniff, ID3v2 PRIV timestamp parser, and synthesized side-audio clock.
final class PackedAudioIngestTests: XCTestCase {

    // MARK: - Segment format classification

    func testClassifyMPEGTS() {
        XCTAssertEqual(LiveSegmentFormat.classify(Data([0x47, 0x40, 0x11, 0x10])), .mpegts)
    }

    func testClassifyADTS() {
        // MPEG-4 ADTS, no CRC (0xFFF1) and with CRC (0xFFF0), plus the
        // MPEG-2 variants (0xFFF9 / 0xFFF8): all match (b1 & 0xF6) == 0xF0.
        for second: UInt8 in [0xF1, 0xF0, 0xF9, 0xF8] {
            XCTAssertEqual(
                LiveSegmentFormat.classify(Data([0xFF, second, 0x50, 0x80])),
                .adtsAAC, "second byte 0x\(String(second, radix: 16))"
            )
        }
        // Layer bits set (not ADTS, e.g. an MP3 sync) must not match.
        XCTAssertNil(LiveSegmentFormat.classify(Data([0xFF, 0xFB, 0x90, 0x00])))
    }

    func testClassifyID3() {
        XCTAssertEqual(LiveSegmentFormat.classify(Data("ID3xxxx".utf8)), .id3PackedAudio)
    }

    func testClassifyGarbageAndShortInputs() {
        XCTAssertNil(LiveSegmentFormat.classify(Data()))
        XCTAssertNil(LiveSegmentFormat.classify(Data([0x00, 0x00, 0x00])))
        XCTAssertNil(LiveSegmentFormat.classify(Data("ID".utf8))) // too short for ID3
        XCTAssertNil(LiveSegmentFormat.classify(Data([0xFF])))    // too short for ADTS
        // fMP4 ftyp box head.
        XCTAssertNil(LiveSegmentFormat.classify(Data([0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70])))
    }

    // MARK: - ID3 PRIV timestamp parsing

    /// 4-byte syncsafe encoding (7 bits per byte).
    private func syncsafe(_ value: Int) -> [UInt8] {
        [UInt8((value >> 21) & 0x7F), UInt8((value >> 14) & 0x7F),
         UInt8((value >> 7) & 0x7F), UInt8(value & 0x7F)]
    }

    /// 4-byte plain big-endian encoding (ID3v2.3 frame sizes).
    private func plain32(_ value: Int) -> [UInt8] {
        [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
         UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    /// Build one ID3v2 frame (v4: syncsafe frame size, v3: plain).
    private func frame(id: String, body: [UInt8], major: UInt8) -> [UInt8] {
        var out = [UInt8](id.utf8)
        out += major == 4 ? syncsafe(body.count) : plain32(body.count)
        out += [0x00, 0x00] // frame flags
        out += body
        return out
    }

    /// PRIV frame body: owner NUL-terminated + 8-byte big-endian payload.
    private func privBody(owner: String, timestamp: UInt64) -> [UInt8] {
        var body = [UInt8](owner.utf8) + [0x00]
        for shift in stride(from: 56, through: 0, by: -8) {
            body.append(UInt8((timestamp >> UInt64(shift)) & 0xFF))
        }
        return body
    }

    /// Assemble a full tag: "ID3" + version + flags + syncsafe size + frames.
    private func id3Tag(major: UInt8, frames: [[UInt8]], padding: Int = 0) -> Data {
        let content = frames.flatMap { $0 } + [UInt8](repeating: 0, count: padding)
        var tag: [UInt8] = [0x49, 0x44, 0x33, major, 0x00, 0x00]
        tag += syncsafe(content.count)
        tag += content
        return Data(tag)
    }

    func testParsePRIVTimestampV24() {
        let ts: UInt64 = 0x1_2345_6789
        let tag = id3Tag(major: 4, frames: [
            frame(id: "PRIV",
                  body: privBody(owner: PackedAudioID3.appleTimestampOwner, timestamp: ts),
                  major: 4)
        ])
        XCTAssertEqual(
            PackedAudioID3.transportStreamTimestamp90k(in: tag + Data([0xFF, 0xF1, 0x50])),
            Int64(ts)
        )
    }

    func testParsePRIVTimestampV23PlainFrameSize() {
        let ts: UInt64 = 900_000 // 10 s on the 90 kHz clock
        let tag = id3Tag(major: 3, frames: [
            frame(id: "PRIV",
                  body: privBody(owner: PackedAudioID3.appleTimestampOwner, timestamp: ts),
                  major: 3)
        ])
        XCTAssertEqual(PackedAudioID3.transportStreamTimestamp90k(in: tag), Int64(ts))
    }

    func testParseMasksTo33Bits() {
        // High bits past bit 32 must be masked off like a TS PTS.
        let raw: UInt64 = 0xFFFF_FFFF_FFFF_FFFF
        let tag = id3Tag(major: 4, frames: [
            frame(id: "PRIV",
                  body: privBody(owner: PackedAudioID3.appleTimestampOwner, timestamp: raw),
                  major: 4)
        ])
        XCTAssertEqual(PackedAudioID3.transportStreamTimestamp90k(in: tag), 0x1_FFFF_FFFF)
    }

    func testParseSkipsWrongOwnerAndFindsLaterPRIV() {
        let ts: UInt64 = 1234
        let tag = id3Tag(major: 4, frames: [
            frame(id: "PRIV", body: privBody(owner: "com.example.other", timestamp: 999), major: 4),
            frame(id: "TXXX", body: [0x03] + [UInt8]("k\0v".utf8), major: 4),
            frame(id: "PRIV",
                  body: privBody(owner: PackedAudioID3.appleTimestampOwner, timestamp: ts),
                  major: 4)
        ], padding: 16)
        XCTAssertEqual(PackedAudioID3.transportStreamTimestamp90k(in: tag), Int64(ts))
    }

    func testParseWrongOwnerOnlyReturnsNil() {
        let tag = id3Tag(major: 4, frames: [
            frame(id: "PRIV", body: privBody(owner: "com.example.other", timestamp: 999), major: 4)
        ])
        XCTAssertNil(PackedAudioID3.transportStreamTimestamp90k(in: tag))
    }

    func testParseMissingPRIVReturnsNil() {
        let tag = id3Tag(major: 4, frames: [
            frame(id: "TXXX", body: [0x03] + [UInt8]("k\0v".utf8), major: 4)
        ])
        XCTAssertNil(PackedAudioID3.transportStreamTimestamp90k(in: tag))
    }

    func testParseRejectsNonID3AndTruncatedInput() {
        XCTAssertNil(PackedAudioID3.transportStreamTimestamp90k(in: Data([0xFF, 0xF1, 0x50])))
        XCTAssertNil(PackedAudioID3.transportStreamTimestamp90k(in: Data("ID3".utf8)))
        // Header claims more content than is present, PRIV truncated.
        let ts: UInt64 = 42
        let full = id3Tag(major: 4, frames: [
            frame(id: "PRIV",
                  body: privBody(owner: PackedAudioID3.appleTimestampOwner, timestamp: ts),
                  major: 4)
        ])
        XCTAssertNil(PackedAudioID3.transportStreamTimestamp90k(in: full.prefix(full.count - 4)))
    }

    func testParseRejectsUnsynchronisedTag() {
        var bytes = [UInt8](id3Tag(major: 4, frames: [
            frame(id: "PRIV",
                  body: privBody(owner: PackedAudioID3.appleTimestampOwner, timestamp: 42),
                  major: 4)
        ]))
        bytes[5] = 0x80 // unsynchronisation flag
        XCTAssertNil(PackedAudioID3.transportStreamTimestamp90k(in: Data(bytes)))
    }

    // MARK: - Packed-audio synth clock

    func testSynthClockStartsAtOffsetAndAccumulatesDurations() {
        // 1024 samples at 48 kHz in the aac demuxer's 1/28224000 TB.
        let frame: Int64 = 602_112
        var clock = HLSSegmentProducer.PackedAudioSynthClock(
            startPts: 1_000_000, fallbackDurationPts: frame)
        XCTAssertEqual(clock.stamp(packetDuration: frame), 1_000_000)
        XCTAssertEqual(clock.stamp(packetDuration: frame), 1_000_000 + frame)
        XCTAssertEqual(clock.stamp(packetDuration: frame), 1_000_000 + 2 * frame)
    }

    func testSynthClockFallsBackOnMissingDuration() {
        let frame: Int64 = 602_112
        var clock = HLSSegmentProducer.PackedAudioSynthClock(
            startPts: 0, fallbackDurationPts: frame)
        XCTAssertEqual(clock.stamp(packetDuration: 0), 0)
        XCTAssertEqual(clock.stamp(packetDuration: -1), frame)
        XCTAssertEqual(clock.stamp(packetDuration: 100), 2 * frame)
        XCTAssertEqual(clock.stamp(packetDuration: 0), 2 * frame + 100)
    }

    func testSynthClockGuardsZeroFallback() {
        // A degenerate fallback of 0 must still advance (no stuck clock).
        var clock = HLSSegmentProducer.PackedAudioSynthClock(
            startPts: 5, fallbackDurationPts: 0)
        XCTAssertEqual(clock.stamp(packetDuration: 0), 5)
        XCTAssertEqual(clock.stamp(packetDuration: 0), 6)
    }
}
