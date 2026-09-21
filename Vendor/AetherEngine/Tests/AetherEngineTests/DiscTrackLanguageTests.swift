import XCTest
@testable import AetherEngine

/// AetherEngine#527: neither disc format carries a track language in the stream itself. A Blu-ray's clip
/// PMT has no ISO 639 descriptor and a DVD's VOBs have nothing at all, so a demuxed disc reports every
/// track as undetermined and `preferredAudioLanguages` / `preferredSubtitleLanguages` can never match.
/// The languages live in the navigation data (MPLS STN table, VTS IFO attribute tables); these tests pin
/// the path from there to the track list.
final class DiscTrackLanguageTests: XCTestCase {

    // MARK: - The backfill rule

    func test_backfillsAnUndeterminedLanguageFromTheDiscTable() {
        let disc = [0x1100: "eng", 0x1101: "deu"]
        XCTAssertEqual(Demuxer.resolvedLanguage(declared: nil, streamID: 0x1100, discLanguages: disc), "eng")
        XCTAssertEqual(Demuxer.resolvedLanguage(declared: "und", streamID: 0x1101, discLanguages: disc), "deu")
        XCTAssertEqual(Demuxer.resolvedLanguage(declared: "  ", streamID: 0x1100, discLanguages: disc), "eng")
    }

    /// The disc tables describe the authored title; a stream that declares its own language describes
    /// itself, and wins.
    func test_declaredLanguageIsNotOverwritten() {
        let disc = [0x1100: "eng"]
        XCTAssertEqual(Demuxer.resolvedLanguage(declared: "fra", streamID: 0x1100, discLanguages: disc), "fra")
    }

    /// Every non-disc source carries an empty table, where the whole path is a no-op.
    func test_nonDiscSourceKeepsWhateverTheContainerSaid() {
        XCTAssertNil(Demuxer.resolvedLanguage(declared: nil, streamID: 1, discLanguages: [:]))
        XCTAssertEqual(Demuxer.resolvedLanguage(declared: "und", streamID: 1, discLanguages: [:]), "und")
        XCTAssertEqual(Demuxer.resolvedLanguage(declared: "jpn", streamID: 1, discLanguages: [:]), "jpn")
    }

    /// A PID the disc does not declare keeps its undetermined value rather than borrowing a neighbour's.
    func test_undeclaredStreamStaysUndetermined() {
        XCTAssertEqual(Demuxer.resolvedLanguage(declared: "und", streamID: 0x1199,
                                                discLanguages: [0x1100: "eng"]), "und")
    }

    // MARK: - Blu-ray: MPLS STN table through DiscReader.wrap

    private func be16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xff), UInt8(v & 0xff)] }
    private func be32(_ v: Int) -> [UInt8] {
        [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
    }

    /// A length-prefixed STN stream entry (type 1, in the PlayItem's own clip) plus its attributes.
    private func stnStream(pid: Int, coding: Int, language: String) -> [UInt8] {
        let entry: [UInt8] = [1] + be16(pid)
        var attr: [UInt8] = [UInt8(coding)]
        if coding != 0x90 { attr.append(0x11) }        // audio prefixes the code with format / rate
        attr += Array(language.utf8)
        return [UInt8(entry.count)] + entry + [UInt8(attr.count)] + attr
    }

    /// An MPLS with one PlayItem carrying a full 32-byte header and an STN table.
    private func mplsDeclaring(audio: [(pid: Int, language: String)],
                               subtitles: [(pid: Int, language: String)]) -> [UInt8] {
        let audioEntries = audio.flatMap { stnStream(pid: $0.pid, coding: 0x80, language: $0.language) }
        let pgEntries = subtitles.flatMap { stnStream(pid: $0.pid, coding: 0x90, language: $0.language) }
        var stnBody = [UInt8]()
        stnBody += be16(0)                                                   // reserved
        stnBody += [0, UInt8(audio.count), UInt8(subtitles.count), 0]        // video / audio / PG / IG counts
        stnBody += [0, 0, 0]                                                 // secondary audio / video / PiP PG
        stnBody += [UInt8](repeating: 0, count: 5)                           // reserved
        stnBody += audioEntries + pgEntries
        let stn = be16(stnBody.count) + stnBody

        var body = [UInt8]()
        body += Array("00001".utf8)              // clip_id
        body += Array("M2TS".utf8)               // codec_id
        body += be16(0)                          // reserved / is_multi_angle / connection_condition
        body.append(0)                           // ref_to_stc_id
        body += be32(0)                          // in_time
        body += be32(4_500_000)                  // out_time (100 s at 45 kHz)
        body += [UInt8](repeating: 0, count: 8)  // UO mask
        body += [0, 0]                           // random_access_flag + still_mode
        body += be16(0)                          // still_time
        body += stn
        let item = be16(body.count) + body

        var playlist = [UInt8]()
        playlist += be32(0); playlist += be16(0); playlist += be16(1); playlist += be16(0)
        playlist += item
        var mpls = [UInt8]()
        mpls += Array("MPLS".utf8); mpls += Array("0200".utf8)
        mpls += be32(40); mpls += be32(0); mpls += be32(0)
        mpls += [UInt8](repeating: 0, count: 40 - mpls.count)
        mpls += playlist
        return mpls
    }

    func test_bluRayTitleCarriesTheSTNLanguages() throws {
        let mpls = mplsDeclaring(audio: [(0x1100, "eng"), (0x1101, "deu")],
                                 subtitles: [(0x1200, "fra")])
        var m2ts = [UInt8]()
        for _ in 0..<400 { m2ts += [0x00, 0x00, 0x00, 0x00, 0x47] + [UInt8](repeating: 0x10, count: 187) }
        let image = UDFFixture.make(mplsBytes: mpls, m2tsBytes: m2ts)
        let info = try XCTUnwrap(try DiscReader.wrap(DataIOReader(data: image)))
        let title = try XCTUnwrap(info.selectedTitle)
        XCTAssertEqual(title.streamLanguages[0x1100], "eng")
        XCTAssertEqual(title.streamLanguages[0x1101], "deu")
        XCTAssertEqual(title.streamLanguages[0x1200], "fra")
    }

    // MARK: - DVD: VTS IFO attribute tables through DiscReader.wrap

    /// A VTS IFO with the magic and the attribute tables, and no PGCIT: the position-as-substream-number
    /// fallback, which is what the parser tests cover separately.
    private func vtsIFODeclaring(audio: [String], subtitles: [String]) -> [UInt8] {
        var ifo = [UInt8](repeating: 0, count: ISO9660Fixture.sectorSize)
        ifo.replaceSubrange(0..<12, with: Array("DVDVIDEO-VTS".utf8))
        ifo[0x203] = UInt8(audio.count)
        for (n, language) in audio.enumerated() {
            let a = 0x204 + n * 8
            ifo[a] = 0x04                                    // AC-3, lang_type = 1
            ifo[a + 2] = Array(language.utf8)[0]
            ifo[a + 3] = Array(language.utf8)[1]
        }
        ifo[0x255] = UInt8(subtitles.count)
        for (n, language) in subtitles.enumerated() {
            let s = 0x256 + n * 6
            ifo[s] = 0x01                                    // type = 1 (language)
            ifo[s + 2] = Array(language.utf8)[0]
            ifo[s + 3] = Array(language.utf8)[1]
        }
        return ifo
    }

    func test_dvdTitleCarriesTheIFOLanguages() throws {
        let ifo = vtsIFODeclaring(audio: ["en", "de"], subtitles: ["fr"])
        let image = ISO9660Fixture.make(files: [
            .init(name: "VIDEO_TS.IFO", length: 2048),
            .init(name: "VTS_01_0.IFO", length: ISO9660Fixture.sectorSize, content: ifo),
            .init(name: "VTS_01_1.VOB", length: 2048),
        ])
        let info = try XCTUnwrap(try DiscReader.wrap(DataIOReader(data: image)))
        let title = try XCTUnwrap(info.selectedTitle)
        XCTAssertEqual(title.streamLanguages[0x80], "en")
        XCTAssertEqual(title.streamLanguages[0x81], "de")
        XCTAssertEqual(title.streamLanguages[0x20], "fr")
    }

    /// A disc that declares nothing must leave the table empty rather than inventing entries, so the
    /// backfill stays a no-op there.
    func test_discWithoutDeclaredLanguagesCarriesAnEmptyTable() throws {
        let image = ISO9660Fixture.make(files: [
            .init(name: "VTS_01_1.VOB", length: 2048),
        ])
        let info = try XCTUnwrap(try DiscReader.wrap(DataIOReader(data: image)))
        XCTAssertTrue(try XCTUnwrap(info.selectedTitle).streamLanguages.isEmpty)
    }
}
