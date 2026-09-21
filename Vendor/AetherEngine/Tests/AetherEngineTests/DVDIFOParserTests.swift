import XCTest
@testable import AetherEngine

/// Parsing the DVD-Video VMGI (VIDEO_TS.IFO) TT_SRPT into the title->VTS map (#67 Phase 3).
final class DVDIFOParserTests: XCTestCase {
    private func be16(_ v: Int) -> [UInt8] { [UInt8((v>>8)&0xff), UInt8(v&0xff)] }
    private func be32(_ v: Int) -> [UInt8] {
        [UInt8((v>>24)&0xff), UInt8((v>>16)&0xff), UInt8((v>>8)&0xff), UInt8(v&0xff)]
    }
    /// One 12-byte TT_SRPT title entry: playback(1) angles(1) nr_ptts(2) parental(2) vtsn(1) vts_ttn(1) sector(4).
    private func ttEntry(angles: Int, ptts: Int, vtsn: Int, ttn: Int) -> [UInt8] {
        var e = [UInt8]()
        e.append(0)
        e.append(UInt8(angles))
        e += be16(ptts)
        e += be16(0)
        e.append(UInt8(vtsn))
        e.append(UInt8(ttn))
        e += be32(0)
        return e
    }
    /// VMGI with "DVDVIDEO-VMG" magic, tt_srpt sector pointer at 0xC4, and the TT_SRPT table at that sector.
    private func makeVMGI(entries: [[UInt8]], ttSrptSector: Int = 1) -> [UInt8] {
        let flat = entries.flatMap { $0 }
        var ttSrpt = [UInt8]()
        ttSrpt += be16(entries.count)             // nr_of_titles
        ttSrpt += be16(0)                         // reserved
        ttSrpt += be32(8 + flat.count - 1)        // last_byte (end address)
        ttSrpt += flat
        var ifo = [UInt8]()
        ifo += Array("DVDVIDEO-VMG".utf8)         // 12 bytes @ 0
        ifo += [UInt8](repeating: 0, count: 0xC4 - ifo.count)
        ifo += be32(ttSrptSector)                 // @ 0xC4 tt_srpt start sector
        let ttSrptOffset = ttSrptSector * 2048
        ifo += [UInt8](repeating: 0, count: ttSrptOffset - ifo.count)
        ifo += ttSrpt
        return ifo
    }

    func test_parsesTitlesWithVTSAndChapterCount() {
        let ifo = makeVMGI(entries: [
            ttEntry(angles: 1, ptts: 5, vtsn: 1, ttn: 1),   // main feature, VTS 1, 5 chapters
            ttEntry(angles: 1, ptts: 3, vtsn: 2, ttn: 1),   // extra, VTS 2, 3 chapters
        ])
        let titles = try! XCTUnwrap(DVDIFOParser.parseTitles(ifo))
        XCTAssertEqual(titles.map(\.vtsn), [1, 2])
        XCTAssertEqual(titles.map(\.chapterCount), [5, 3])
    }

    func test_episodicTitlesShareAVTS() {
        // Two PGC titles in the same VTS (episodic TV): the raw list keeps both; whole-VTS dedup is the caller's job.
        let ifo = makeVMGI(entries: [
            ttEntry(angles: 1, ptts: 6, vtsn: 1, ttn: 1),
            ttEntry(angles: 1, ptts: 6, vtsn: 1, ttn: 2),
        ])
        let titles = try! XCTUnwrap(DVDIFOParser.parseTitles(ifo))
        XCTAssertEqual(titles.map(\.vtsn), [1, 1])
    }

    func test_nilOnBadMagic() {
        XCTAssertNil(DVDIFOParser.parseTitles(Array("NOTADVDVIDEO".utf8) + [UInt8](repeating: 0, count: 4096)))
    }

    func test_nilWhenTTSrptSectorOutOfRange() {
        let ifo = makeVMGI(entries: [ttEntry(angles: 1, ptts: 2, vtsn: 1, ttn: 1)], ttSrptSector: 999)
        // The pointer references a sector far past the truncated buffer.
        XCTAssertNil(DVDIFOParser.parseTitles(Array(ifo.prefix(4096))))
    }

    // MARK: - VTS IFO PGC: per-title duration + chapters

    /// dvd_time_t: BCD hour/min/sec + frame byte (top 2 bits = frame-rate code 3 = 29.97, 1 = 25).
    private func dvdTime(h: Int, m: Int, s: Int, frames: Int = 0, fpsCode: Int = 3) -> [UInt8] {
        func bcd(_ v: Int) -> Int { ((v / 10) << 4) | (v % 10) }
        return [UInt8(bcd(h)), UInt8(bcd(m)), UInt8(bcd(s)), UInt8((fpsCode << 6) | bcd(frames))]
    }
    private func cell(seconds: Int) -> [UInt8] {
        var c = [UInt8](repeating: 0, count: 24)
        let t = dvdTime(h: seconds / 3600, m: (seconds % 3600) / 60, s: seconds % 60)
        c[4] = t[0]; c[5] = t[1]; c[6] = t[2]; c[7] = t[3]   // cell playback_time @ +4
        return c
    }
    /// A PGC with `playback_time`, a program map (program -> entry cell), and a cell playback table.
    private func makePGC(playbackSeconds: Int, programEntryCells: [Int], cellSeconds: [Int]) -> [UInt8] {
        var pgc = [UInt8](repeating: 0, count: 0xEC)        // PGC header (through cell_position_offset)
        pgc[2] = UInt8(programEntryCells.count)             // nr_of_programs
        pgc[3] = UInt8(cellSeconds.count)                   // nr_of_cells
        let pt = dvdTime(h: playbackSeconds / 3600, m: (playbackSeconds % 3600) / 60, s: playbackSeconds % 60)
        pgc[4] = pt[0]; pgc[5] = pt[1]; pgc[6] = pt[2]; pgc[7] = pt[3]   // playback_time @ +4
        let programMapOffset = 0xEC
        let cellPlaybackOffset = 0xEC + programEntryCells.count
        pgc[0xE6] = UInt8((programMapOffset >> 8) & 0xff); pgc[0xE7] = UInt8(programMapOffset & 0xff)
        pgc[0xE8] = UInt8((cellPlaybackOffset >> 8) & 0xff); pgc[0xE9] = UInt8(cellPlaybackOffset & 0xff)
        pgc += programEntryCells.map { UInt8($0) }          // program map (1-based entry cell per program)
        for s in cellSeconds { pgc += cell(seconds: s) }    // cell playback table
        return pgc
    }
    /// VTS IFO ("DVDVIDEO-VTS") whose VTS_PGCIT (sector pointer @ 0xCC) holds the given PGCs.
    private func makeVTSIFO(pgcs: [[UInt8]], vtsPgcitSector: Int = 1) -> [UInt8] {
        let srpSize = 8
        let headerSize = 8 + pgcs.count * srpSize
        var srps = [UInt8]()
        var body = [UInt8]()
        for pgc in pgcs {
            let pgcStartByte = headerSize + body.count
            srps += [0x81, 0, 0, 0]          // entry_id (entry PGC) + unknown
            srps += be32(pgcStartByte)
            body += pgc
        }
        var pgcit = [UInt8]()
        pgcit += be16(pgcs.count)            // nr_of_pgci_srp
        pgcit += be16(0)                     // reserved
        pgcit += be32(headerSize + body.count - 1)  // last_byte
        pgcit += srps
        pgcit += body
        var ifo = [UInt8]()
        ifo += Array("DVDVIDEO-VTS".utf8)    // 12-byte magic
        ifo += [UInt8](repeating: 0, count: 0xCC - ifo.count)
        ifo += be32(vtsPgcitSector)          // @ 0xCC vts_pgcit start sector
        ifo += [UInt8](repeating: 0, count: vtsPgcitSector * 2048 - ifo.count)
        ifo += pgcit
        return ifo
    }

    func test_parsesPGCDurationAndChapters() {
        // One PGC: 120s total, 3 cells of 40s, programs entering at cells 1 and 2.
        let pgc = makePGC(playbackSeconds: 120, programEntryCells: [1, 2], cellSeconds: [40, 40, 40])
        let detail = try! XCTUnwrap(DVDIFOParser.parseTitleDetail(makeVTSIFO(pgcs: [pgc])))
        XCTAssertEqual(detail.durationTicks, 120 * 45_000)               // PGC playback_time
        XCTAssertEqual(detail.chapterStartTicks, [0, 40 * 45_000] as [UInt64])  // program 2 starts after cell 1 (40s)
    }

    func test_picksLongestPGCInVTS() {
        // Two PGCs in the VTS; the title duration/chapters come from the longest (the main feature).
        let shortPGC = makePGC(playbackSeconds: 30, programEntryCells: [1], cellSeconds: [30])
        let longPGC = makePGC(playbackSeconds: 100, programEntryCells: [1, 2], cellSeconds: [60, 40])
        let detail = try! XCTUnwrap(DVDIFOParser.parseTitleDetail(makeVTSIFO(pgcs: [shortPGC, longPGC])))
        XCTAssertEqual(detail.durationTicks, 100 * 45_000)
        XCTAssertEqual(detail.chapterStartTicks, [0, 60 * 45_000] as [UInt64])
    }

    func test_titleDetailNilOnBadMagic() {
        XCTAssertNil(DVDIFOParser.parseTitleDetail(Array("NOTAVTSIFO!!!".utf8) + [UInt8](repeating: 0, count: 4096)))
    }

    // MARK: - VTS IFO stream languages (#527)

    /// audio_attr_t byte 0: audio_format(3) multichannel_extension(1) lang_type(2) application_mode(2).
    /// `format` 0 = AC-3, 2/3 = MPEG audio, 4 = LPCM, 6 = DTS. `language` nil leaves lang_type at 0.
    private func audioAttr(format: Int, language: String?) -> [UInt8] {
        var a = [UInt8](repeating: 0, count: 8)
        a[0] = UInt8((format << 5) | ((language == nil ? 0 : 1) << 2))
        if let language { a[2] = Array(language.utf8)[0]; a[3] = Array(language.utf8)[1] }
        return a
    }
    /// subp_attr_t byte 0: code_mode(3) reserved(3) type(2); type 1 means the language code is set.
    private func subpAttr(language: String?) -> [UInt8] {
        var a = [UInt8](repeating: 0, count: 6)
        a[0] = language == nil ? 0 : 1
        if let language { a[2] = Array(language.utf8)[0]; a[3] = Array(language.utf8)[1] }
        return a
    }
    /// Write the VTS audio / subpicture attribute tables into a VTSI_MAT (RBP 0x0203 / 0x0255 onward).
    private func withStreamAttributes(_ ifo: [UInt8], audio: [[UInt8]], subpicture: [[UInt8]]) -> [UInt8] {
        var out = ifo
        out[0x203] = UInt8(audio.count)
        for (n, attr) in audio.enumerated() {
            out.replaceSubrange((0x204 + n * 8)..<(0x204 + n * 8 + 8), with: attr)
        }
        out[0x255] = UInt8(subpicture.count)
        for (n, attr) in subpicture.enumerated() {
            out.replaceSubrange((0x256 + n * 6)..<(0x256 + n * 6 + 6), with: attr)
        }
        return out
    }
    /// Write a PGC's stream control tables (audio_control @ +0x0C, subp_control @ +0x1C). The PGC sits
    /// inside the PGCIT, so patch the assembled IFO at the offset `makeVTSIFO` placed it at.
    private func withStreamControls(_ ifo: [UInt8], pgcOffset: Int,
                                    audio: [Int] = [], subpicture: [Int] = []) -> [UInt8] {
        var out = ifo
        for (n, control) in audio.enumerated() {
            out.replaceSubrange((pgcOffset + 0x0C + n * 2)..<(pgcOffset + 0x0C + n * 2 + 2), with: be16(control))
        }
        for (n, control) in subpicture.enumerated() {
            out.replaceSubrange((pgcOffset + 0x1C + n * 4)..<(pgcOffset + 0x1C + n * 4 + 4), with: be32(control))
        }
        return out
    }
    /// Byte offset of the first PGC inside an IFO built by `makeVTSIFO(pgcs:)` with one PGC.
    private func firstPGCOffset(vtsPgcitSector: Int = 1, pgcCount: Int = 1) -> Int {
        vtsPgcitSector * 2048 + 8 + pgcCount * 8
    }
    /// Control word marking a stream present at substream number `number`.
    private func audioControl(number: Int) -> Int { 0x8000 | (number << 8) }
    private func subpictureControl(fourThree: Int, wide: Int = 0, letterbox: Int = 0, panScan: Int = 0) -> Int {
        0x8000_0000 | (fourThree << 24) | (wide << 16) | (letterbox << 8) | panScan
    }

    /// A DVD's VOBs carry no language anywhere in the bitstream, so the IFO attribute tables are the only
    /// source. The key is the MPEG-PS stream id FFmpeg reports, which is codec-dependent (#527).
    func test_parsesAudioAndSubpictureLanguagesByStreamID() {
        let pgc = makePGC(playbackSeconds: 120, programEntryCells: [1], cellSeconds: [120])
        var ifo = withStreamAttributes(makeVTSIFO(pgcs: [pgc]),
                                       audio: [audioAttr(format: 0, language: "en"),    // AC-3   -> 0x80 + n
                                               audioAttr(format: 6, language: "de"),    // DTS    -> 0x88 + n
                                               audioAttr(format: 4, language: "fr"),    // LPCM   -> 0xA0 + n
                                               audioAttr(format: 2, language: "it")],   // MPEG   -> 0x1C0 + n
                                       subpicture: [subpAttr(language: "en"), subpAttr(language: "nl")])
        ifo = withStreamControls(ifo, pgcOffset: firstPGCOffset(),
                                 audio: (0..<4).map { audioControl(number: $0) },
                                 subpicture: [subpictureControl(fourThree: 0), subpictureControl(fourThree: 1)])
        let languages = DVDIFOParser.parseStreamLanguages(ifo)
        XCTAssertEqual(languages[0x80], "en")
        XCTAssertEqual(languages[0x89], "de")
        XCTAssertEqual(languages[0xA2], "fr")
        XCTAssertEqual(languages[0x1C3], "it")
        XCTAssertEqual(languages[0x20], "en")
        XCTAssertEqual(languages[0x21], "nl")
    }

    /// The substream number is what the PGC's control table says, not the attribute's position: a disc
    /// that authors its second audio attribute as substream 5 must not have its language put on 0x81.
    func test_audioControlNamesTheSubstreamNumber() {
        let pgc = makePGC(playbackSeconds: 120, programEntryCells: [1], cellSeconds: [120])
        var ifo = withStreamAttributes(makeVTSIFO(pgcs: [pgc]),
                                       audio: [audioAttr(format: 0, language: "en"),
                                               audioAttr(format: 0, language: "es")],
                                       subpicture: [])
        ifo = withStreamControls(ifo, pgcOffset: firstPGCOffset(),
                                 audio: [audioControl(number: 0), audioControl(number: 5)])
        let languages = DVDIFOParser.parseStreamLanguages(ifo)
        XCTAssertEqual(languages[0x80], "en")
        XCTAssertEqual(languages[0x85], "es")
        XCTAssertNil(languages[0x81])
    }

    /// A stream the PGC does not mark present is not in this title's VOBs, so it contributes nothing.
    func test_skipsStreamThePGCMarksUnavailable() {
        let pgc = makePGC(playbackSeconds: 120, programEntryCells: [1], cellSeconds: [120])
        var ifo = withStreamAttributes(makeVTSIFO(pgcs: [pgc]),
                                       audio: [audioAttr(format: 0, language: "en")],
                                       subpicture: [subpAttr(language: "sv")])
        ifo = withStreamControls(ifo, pgcOffset: firstPGCOffset(), audio: [0x0000], subpicture: [0x0000_0000])
        XCTAssertTrue(DVDIFOParser.parseStreamLanguages(ifo).isEmpty)
    }

    /// One subtitle is authored once per display mode, so every substream number the entry names carries
    /// the same language. The three secondary fields are skipped when zero, where an unused field and
    /// stream 0 are indistinguishable.
    func test_subpictureControlMapsEveryDisplayModeNumber() {
        let pgc = makePGC(playbackSeconds: 120, programEntryCells: [1], cellSeconds: [120])
        var ifo = withStreamAttributes(makeVTSIFO(pgcs: [pgc]),
                                       audio: [], subpicture: [subpAttr(language: "en"), subpAttr(language: "da")])
        ifo = withStreamControls(ifo, pgcOffset: firstPGCOffset(),
                                 subpicture: [subpictureControl(fourThree: 0, wide: 1, letterbox: 2, panScan: 3),
                                              subpictureControl(fourThree: 4)])
        let languages = DVDIFOParser.parseStreamLanguages(ifo)
        XCTAssertEqual(languages[0x20], "en")
        XCTAssertEqual(languages[0x21], "en")
        XCTAssertEqual(languages[0x22], "en")
        XCTAssertEqual(languages[0x23], "en")
        XCTAssertEqual(languages[0x24], "da")   // the second entry's padded-out fields claim nothing
    }

    /// An unreadable PGCIT must not cost the languages: the attribute position is the substream number
    /// on the great majority of discs, so it is the fallback.
    func test_fallsBackToAttributePositionWithoutAPGC() {
        var ifo = [UInt8](repeating: 0, count: 4096)
        ifo.replaceSubrange(0..<12, with: Array("DVDVIDEO-VTS".utf8))   // magic, but vts_pgcit stays 0
        ifo = withStreamAttributes(ifo,
                                   audio: [audioAttr(format: 0, language: "en"), audioAttr(format: 0, language: "de")],
                                   subpicture: [subpAttr(language: "fr")])
        let languages = DVDIFOParser.parseStreamLanguages(ifo)
        XCTAssertEqual(languages[0x80], "en")
        XCTAssertEqual(languages[0x81], "de")
        XCTAssertEqual(languages[0x20], "fr")
    }

    /// An attribute whose lang_type / type says no language is declared contributes nothing, and neither
    /// does a reserved coding mode whose carriage is undefined.
    func test_ignoresAttributesWithoutADeclaredLanguage() {
        var ifo = [UInt8](repeating: 0, count: 4096)
        ifo.replaceSubrange(0..<12, with: Array("DVDVIDEO-VTS".utf8))
        ifo = withStreamAttributes(ifo,
                                   audio: [audioAttr(format: 0, language: nil),
                                           audioAttr(format: 7, language: "en")],   // reserved coding mode
                                   subpicture: [subpAttr(language: nil)])
        XCTAssertTrue(DVDIFOParser.parseStreamLanguages(ifo).isEmpty)
    }

    func test_streamLanguagesEmptyOnBadMagic() {
        XCTAssertTrue(DVDIFOParser.parseStreamLanguages([UInt8](repeating: 0, count: 4096)).isEmpty)
    }
}
