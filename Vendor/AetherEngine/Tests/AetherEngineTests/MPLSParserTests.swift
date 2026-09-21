import XCTest
@testable import AetherEngine

final class MPLSParserTests: XCTestCase {
    private func makeMPLS() -> [UInt8] {
        func be16(_ v: Int) -> [UInt8] { [UInt8((v>>8)&0xff), UInt8(v&0xff)] }
        func be32(_ v: Int) -> [UInt8] { [UInt8((v>>24)&0xff), UInt8((v>>16)&0xff), UInt8((v>>8)&0xff), UInt8(v&0xff)] }
        func playItem(clip: String, inT: Int, outT: Int) -> [UInt8] {
            var body = [UInt8]()
            body += Array(clip.utf8)
            body += Array("M2TS".utf8)
            body += be16(0)
            body.append(0)
            body += be32(inT)
            body += be32(outT)
            body += [UInt8](repeating: 0, count: 8)
            return be16(body.count) + body
        }
        let items = playItem(clip: "00002", inT: 0, outT: 90000)
                  + playItem(clip: "00005", inT: 0, outT: 180000)
        var playlist = [UInt8]()
        playlist += be32(0)
        playlist += be16(0)
        playlist += be16(2)
        playlist += be16(0)
        playlist += items
        var out = [UInt8]()
        out += Array("MPLS".utf8)
        out += Array("0200".utf8)
        let plStart = 40
        out += be32(plStart)
        out += be32(0)
        out += [UInt8](repeating: 0, count: plStart - out.count)
        out += playlist
        return out
    }

    func test_parsesClipOrderAndDuration() {
        let pl = try! XCTUnwrap(MPLSParser.parse(makeMPLS()))
        XCTAssertEqual(pl.clipIDs, ["00002", "00005"])
        XCTAssertEqual(pl.durationTicks, 270000)
    }

    // AE#105: per-clip in_time and cumulative presentation offset are retained (parallel to clipIDs) so a
    // multi-clip title can fold each clip's discontinuous STC onto one contiguous presentation timeline.
    func test_retainsPerClipInTimesAndCumulativeOffsets() {
        // makeMPLS: item0 in=0/out=90000 (dur 90000), item1 in=0/out=180000 (dur 180000).
        let pl = try! XCTUnwrap(MPLSParser.parse(makeMPLS()))
        XCTAssertEqual(pl.inTimes, [0, 0])
        XCTAssertEqual(pl.cumulativeBefore, [0, 90000])   // item1 starts after item0's 90000-tick duration
    }

    func test_rejectsBadMagic() {
        XCTAssertNil(MPLSParser.parse(Array("NOPE0200".utf8) + [UInt8](repeating: 0, count: 40)))
    }

    // MARK: - PlayListMark chapters (#67 Phase 2)

    private func be16(_ v: Int) -> [UInt8] { [UInt8((v>>8)&0xff), UInt8(v&0xff)] }
    private func be32(_ v: Int) -> [UInt8] {
        [UInt8((v>>24)&0xff), UInt8((v>>16)&0xff), UInt8((v>>8)&0xff), UInt8(v&0xff)]
    }
    private func playItem(clip: String, inT: Int, outT: Int) -> [UInt8] {
        var body = [UInt8]()
        body += Array(clip.utf8); body += Array("M2TS".utf8)
        body += be16(0); body.append(0)
        body += be32(inT); body += be32(outT)
        body += [UInt8](repeating: 0, count: 8)
        return be16(body.count) + body
    }
    private func mark(type: Int, ref: Int, time: Int) -> [UInt8] {
        var e = [UInt8]()
        e.append(0)            // reserved
        e.append(UInt8(type))  // mark_type: 1 = entry (chapter), 2 = link point
        e += be16(ref)         // ref_to_play_item_id
        e += be32(time)        // mark_time_stamp (45 kHz, on the referenced clip's STC)
        e += be16(0xFFFF)      // entry ES PID
        e += be32(0)           // duration
        return e
    }
    /// Two play items (item0 in=0/out=90000, item1 in=10000/out=190000) + 5 marks at header offset 12.
    private func makeMPLSWithMarks() -> [UInt8] {
        let items = playItem(clip: "00002", inT: 0, outT: 90000)
                  + playItem(clip: "00005", inT: 10000, outT: 190000)
        var playlist = [UInt8]()
        playlist += be32(0); playlist += be16(0); playlist += be16(2); playlist += be16(0)
        playlist += items
        let entries = mark(type: 1, ref: 0, time: 0)        // item0 start -> 0
                    + mark(type: 1, ref: 0, time: 45000)    // item0 +1s   -> 45000
                    + mark(type: 2, ref: 0, time: 67500)    // link point  -> ignored
                    + mark(type: 1, ref: 1, time: 100000)   // item1: 90000 + (100000-10000) = 180000
                    + mark(type: 1, ref: 5, time: 0)        // out-of-range play item -> skipped
        var markSection = [UInt8]()
        markSection += be32(2 + entries.count)  // length
        markSection += be16(5)                  // number_of_PlayList_marks
        markSection += entries
        var out = [UInt8]()
        out += Array("MPLS".utf8); out += Array("0200".utf8)
        let plStart = 40
        let plmStart = plStart + playlist.count
        out += be32(plStart)    // @8  PlayListStartAddress
        out += be32(plmStart)   // @12 PlayListMarkStartAddress
        out += be32(0)          // @16 ExtensionDataStartAddress
        out += [UInt8](repeating: 0, count: plStart - out.count)  // reserved up to 40
        out += playlist
        out += markSection
        return out
    }

    func test_parsesEntryMarkChaptersTitleRelative() {
        let pl = try! XCTUnwrap(MPLSParser.parse(makeMPLSWithMarks()))
        XCTAssertEqual(pl.clipIDs, ["00002", "00005"])
        XCTAssertEqual(pl.durationTicks, 270000)
        // Entry marks only (link point dropped, out-of-range ref skipped), each made title-relative:
        // mark_time - in_time(ref) + sum(durations of preceding play items).
        XCTAssertEqual(pl.chapterStartTicks, [0, 45000, 180000])
    }

    func test_noChaptersWhenMarkAddressZero() {
        // The base fixture leaves PlayListMarkStartAddress (offset 12) at 0 -> no chapters.
        let pl = try! XCTUnwrap(MPLSParser.parse(makeMPLS()))
        XCTAssertTrue(pl.chapterStartTicks.isEmpty)
    }

    // MARK: - STN table languages (#527)

    /// One STN stream: a length-prefixed stream_entry naming the PID, then a length-prefixed
    /// stream_attributes block whose language offset depends on the coding type.
    private func stnStream(type: Int, pid: Int, coding: Int, language: String?) -> [UInt8] {
        var entry: [UInt8] = [UInt8(type)]
        entry += be16(pid)
        var attr: [UInt8] = [UInt8(coding)]
        switch coding {
        case 0x80...0x86, 0x03, 0x04, 0xA1, 0xA2: attr.append(0x11)   // audio: format / sample rate
        case 0x92: attr.append(0x00)                                  // text subtitle: character code
        default: break
        }
        if let language { attr += Array(language.utf8) }
        return [UInt8(entry.count)] + entry + [UInt8(attr.count)] + attr
    }

    private func stnTable(video: [[UInt8]] = [], audio: [[UInt8]] = [],
                          pg: [[UInt8]] = [], ig: [[UInt8]] = []) -> [UInt8] {
        var body: [UInt8] = []
        body += be16(0)                                        // reserved
        body += [UInt8(video.count), UInt8(audio.count), UInt8(pg.count), UInt8(ig.count)]
        body += [0, 0, 0]                                      // secondary audio / video / PiP PG counts
        body += [UInt8](repeating: 0, count: 5)                // reserved
        body += (video + audio + pg + ig).flatMap { $0 }
        return be16(body.count) + body
    }

    /// A PlayItem with the full 32-byte fixed header (the short fixture above stops after the UO mask),
    /// optionally a multi-angle block, then an STN table.
    private func fullPlayItem(clip: String, inT: Int, outT: Int,
                              angles: Int = 1, stn: [UInt8]) -> [UInt8] {
        var body = [UInt8]()
        body += Array(clip.utf8)                 // @0  clip_id
        body += Array("M2TS".utf8)               // @5  codec_id
        body += be16(angles > 1 ? 0x0010 : 0)    // @9  11 reserved bits, is_multi_angle, connection_condition
        body.append(0)                           // @11 ref_to_stc_id
        body += be32(inT)                        // @12
        body += be32(outT)                       // @16
        body += [UInt8](repeating: 0, count: 8)  // @20 UO mask
        body.append(0)                           // @28 random_access_flag + reserved
        body.append(0)                           // @29 still_mode
        body += be16(0)                          // @30 still_time
        if angles > 1 {
            body.append(UInt8(angles))           // @32 angle_count
            body.append(0)                       //     flags
            // clip_id(5) + codec_id(4) + stc_id(1) per ADDITIONAL angle
            for _ in 1..<angles { body += Array("00099".utf8) + Array("M2TS".utf8) + [0] }
        }
        body += stn
        return be16(body.count) + body
    }

    private func makeMPLS(items: [[UInt8]]) -> [UInt8] {
        var playlist = [UInt8]()
        playlist += be32(0); playlist += be16(0); playlist += be16(items.count); playlist += be16(0)
        playlist += items.flatMap { $0 }
        var out = [UInt8]()
        out += Array("MPLS".utf8); out += Array("0200".utf8)
        let plStart = 40
        out += be32(plStart); out += be32(0); out += be32(0)
        out += [UInt8](repeating: 0, count: plStart - out.count)
        out += playlist
        return out
    }

    /// A Blu-ray declares its track languages only here: the clip's PMT carries no ISO 639 descriptor,
    /// so without the STN table every track demuxes as undetermined (#527).
    func test_parsesSTNLanguagesByPID() {
        let stn = stnTable(
            video: [stnStream(type: 1, pid: 0x1011, coding: 0x1B, language: nil)],
            audio: [stnStream(type: 1, pid: 0x1100, coding: 0x80, language: "eng"),
                    stnStream(type: 1, pid: 0x1101, coding: 0x86, language: "deu")],
            pg: [stnStream(type: 1, pid: 0x1200, coding: 0x90, language: "fra"),
                 stnStream(type: 1, pid: 0x1201, coding: 0x90, language: "und")],
            ig: [stnStream(type: 1, pid: 0x1400, coding: 0x91, language: "jpn")]
        )
        let pl = try! XCTUnwrap(MPLSParser.parse(
            makeMPLS(items: [fullPlayItem(clip: "00001", inT: 0, outT: 90000, stn: stn)])))
        XCTAssertEqual(pl.clipIDs, ["00001"])
        XCTAssertEqual(pl.streamLanguages[0x1100], "eng")
        XCTAssertEqual(pl.streamLanguages[0x1101], "deu")
        XCTAssertEqual(pl.streamLanguages[0x1200], "fra")
        XCTAssertEqual(pl.streamLanguages[0x1400], "jpn")
        XCTAssertNil(pl.streamLanguages[0x1011])   // video declares no language
        XCTAssertNil(pl.streamLanguages[0x1201])   // an explicit "und" says nothing the container did not
    }

    /// A multi-angle PlayItem pushes the STN table past an angle block whose size depends on the angle
    /// count. Missing that shift lands the walk in the middle of the angle clip names.
    func test_parsesSTNLanguagesPastMultiAngleBlock() {
        let stn = stnTable(audio: [stnStream(type: 1, pid: 0x1100, coding: 0x80, language: "ita")])
        let pl = try! XCTUnwrap(MPLSParser.parse(
            makeMPLS(items: [fullPlayItem(clip: "00001", inT: 0, outT: 90000, angles: 3, stn: stn)])))
        XCTAssertEqual(pl.streamLanguages[0x1100], "ita")
    }

    /// Every PlayItem of a title repeats the table; the first declaration wins, since the demuxer opens
    /// on the first clip's PIDs.
    func test_firstPlayItemWinsForARepeatedPID() {
        let first = fullPlayItem(clip: "00001", inT: 0, outT: 90000,
                                 stn: stnTable(audio: [stnStream(type: 1, pid: 0x1100, coding: 0x80, language: "eng")]))
        let second = fullPlayItem(clip: "00002", inT: 0, outT: 90000,
                                  stn: stnTable(audio: [stnStream(type: 1, pid: 0x1100, coding: 0x80, language: "spa"),
                                                        stnStream(type: 1, pid: 0x1102, coding: 0x80, language: "por")]))
        let pl = try! XCTUnwrap(MPLSParser.parse(makeMPLS(items: [first, second])))
        XCTAssertEqual(pl.streamLanguages[0x1100], "eng")
        XCTAssertEqual(pl.streamLanguages[0x1102], "por")   // a PID only the later item declares still lands
    }

    /// The playlist must survive a PlayItem that ends before the STN table (the short fixture above):
    /// no languages, but clips, duration and chapters unaffected.
    func test_noLanguagesWhenPlayItemStopsBeforeSTNTable() {
        let pl = try! XCTUnwrap(MPLSParser.parse(makeMPLS()))
        XCTAssertTrue(pl.streamLanguages.isEmpty)
        XCTAssertEqual(pl.clipIDs, ["00002", "00005"])
        XCTAssertEqual(pl.durationTicks, 270000)
    }

    /// A truncated STN table contributes what it resolved before the cut and never fails the playlist.
    func test_truncatedSTNTableDegrades() {
        let stn = stnTable(audio: [stnStream(type: 1, pid: 0x1100, coding: 0x80, language: "eng"),
                                   stnStream(type: 1, pid: 0x1101, coding: 0x80, language: "deu")])
        var item = fullPlayItem(clip: "00001", inT: 0, outT: 90000, stn: stn)
        item.removeLast(6)                                   // cut into the second stream's attributes
        item[0] = UInt8((item.count - 2) >> 8)               // restate the PlayItem length
        item[1] = UInt8((item.count - 2) & 0xff)
        let pl = try! XCTUnwrap(MPLSParser.parse(makeMPLS(items: [item])))
        XCTAssertEqual(pl.streamLanguages[0x1100], "eng")
        XCTAssertNil(pl.streamLanguages[0x1101])
    }
}
