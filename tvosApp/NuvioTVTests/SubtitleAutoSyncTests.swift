import Compression
import XCTest
@testable import NuvioTV

final class SubtitleAutoSyncTests: XCTestCase {
    // MARK: Reading subtitles

    func testSRTAndWebVTTTimes() {
        let srt = """
        1
        00:00:01,500 --> 00:00:03,000
        Ahoj.

        2
        00:01:02.250 --> 00:01:04,000
        Druhá replika.
        """
        let cues = SubtitleTiming.cues(in: srt, format: SubtitleTiming.format(of: srt)!)
        XCTAssertEqual(SubtitleTiming.format(of: srt), .srt)
        XCTAssertEqual(cues.map(\.start), [1.5, 62.25])
        XCTAssertEqual(cues.map(\.end), [3, 64])

        let vtt = "WEBVTT\n\n00:05.000 --> 00:07.500\nHi\n\n01:00:00.100 --> 01:00:01.000 align:start\nLate"
        XCTAssertEqual(SubtitleTiming.format(of: vtt), .vtt)
        let vttCues = SubtitleTiming.cues(in: vtt, format: .vtt)
        XCTAssertEqual(vttCues.map(\.start), [5, 3600.1])
        XCTAssertEqual(vttCues.map(\.end), [7.5, 3601])
    }

    func testASSDialogueAndTypesetting() {
        let ass = """
        [Script Info]
        Title: Test

        [V4+ Styles]
        Format: Name, Fontname
        Style: Default,Arial

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:01.00,0:00:03.50,Default,,0,0,0,,Ahoj, jak se máš?
        Dialogue: 1,0:00:01.00,0:00:03.50,Default,,0,0,0,,Ahoj, jak se máš?
        Dialogue: 0,0:00:05.00,0:00:06.00,Signs,,0,0,0,,{\\an8}Nápis
        Dialogue: 0,0:00:07.00,0:00:08.00,Default,,0,0,0,,{\\pos(10,20)}Cedule
        Dialogue: 0,0:00:09.00,0:00:10.00,OP,,0,0,0,,{\\k20}La {\\k30}la
        Comment: 0,0:00:11.00,0:00:12.00,Default,,0,0,0,,poznámka
        Dialogue: 0,1:02:03.45,1:02:05.00,Default,,0,0,0,,Konec
        """
        XCTAssertEqual(SubtitleTiming.format(of: ass), .ass)
        let cues = SubtitleTiming.cues(in: ass, format: .ass)
        XCTAssertEqual(cues.count, 5, "the line drawn twice counts once, the comment not at all")
        XCTAssertEqual(cues.filter(\.isDialogue).map(\.start), [1, 3723.45])
        XCTAssertEqual(cues.filter { !$0.isDialogue }.map(\.start), [5, 7, 9])
    }

    func testCzechTextInWindows1250AndGzip() throws {
        let text = "1\n00:00:01,000 --> 00:00:02,000\nŽluťoučký kůň\n"
        let windows1250 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.windowsLatin2.rawValue)))
        let legacy = try XCTUnwrap(text.data(using: windows1250))
        XCTAssertNil(String(data: legacy, encoding: .utf8), "not valid UTF-8, so the fallback is exercised")
        XCTAssertEqual(SubtitleTiming.decodeText(legacy), text)

        let gzipped = try XCTUnwrap(Self.gzip(Data(text.utf8)))
        XCTAssertEqual(SubtitleTiming.decodeText(gzipped), text)
    }

    // MARK: Rewriting times

    func testRetimedSRTKeepsItsText() throws {
        let srt = "1\r\n00:00:01,000 --> 00:00:02,500\r\n<i>Ahoj</i>\r\n\r\n2\r\n00:00:10,000 --> 00:00:11,000\r\nSvět\r\n"
        let retimed = try XCTUnwrap(SubtitleRetimer.retime(srt, format: .srt, mapping: SubtitleSyncMapping(scale: 1, offset: -1.5)))
        XCTAssertEqual(retimed, "1\r\n00:00:00,000 --> 00:00:01,000\r\n<i>Ahoj</i>\r\n\r\n2\r\n00:00:08,500 --> 00:00:09,500\r\nSvět\r\n")
    }

    func testRetimedASSKeepsStylesAndEffects() throws {
        let ass = """
        [Script Info]
        PlayResX: 1920

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:10.00,0:00:12.00,Default,,0,0,0,,{\\pos(10,20)\\t(0,500,\\fscx120)}Text, s čárkou
        Comment: 0,0:00:20.00,0:00:21.00,Default,,0,0,0,,note
        """
        let mapping = SubtitleSyncMapping(scale: 25 / 23.976, offset: 2)
        let retimed = try XCTUnwrap(SubtitleRetimer.retime(ass, format: .ass, mapping: mapping))
        let lines = retimed.components(separatedBy: "\n")
        XCTAssertEqual(lines[0...4].joined(separator: "\n"), ass.components(separatedBy: "\n")[0...4].joined(separator: "\n"))
        XCTAssertEqual(lines[5], "Dialogue: 0,0:00:12.43,0:00:14.51,Default,,0,0,0,,{\\pos(10,20)\\t(0,500,\\fscx120)}Text, s čárkou")
        XCTAssertEqual(lines[6], "Comment: 0,0:00:22.85,0:00:23.90,Default,,0,0,0,,note")
    }

    // MARK: The video's subtitle index

    func testMatroskaIndexReadsTheSubtitleTracksAndTheirTiming() async throws {
        let file = Self.matroska(cuesInSeekHead: true)
        let source = MemorySource(bytes: file)
        let index = try await MatroskaSubtitleIndex.load(from: source)
        XCTAssertEqual(index.tracks.map(\.number), [2, 3, 4], "subtitle tracks only")
        let ass = try XCTUnwrap(index.tracks.first { $0.number == 2 })
        XCTAssertEqual(ass.codecID, "S_TEXT/ASS")
        XCTAssertEqual(ass.language, "cze")
        XCTAssertEqual(ass.events.count, 40)
        XCTAssertEqual(ass.events[1].start, 6, accuracy: 0.0001)
        XCTAssertEqual(ass.events[1].duration ?? 0, 2, accuracy: 0.0001)
        XCTAssertEqual(ass.summary, "ASS cze Dialogue")
        XCTAssertTrue(index.tracks.first { $0.number == 4 }?.isForced ?? false)
        XCTAssertLessThanOrEqual(index.requests, 4, "the head, then the Cues past it")
        XCTAssertLessThan(index.bytes, Int64(file.count), "never the whole file")
    }

    func testCuesWrittenAfterTheClustersAreFoundWithoutTheSeekHead() async throws {
        let index = try await MatroskaSubtitleIndex.load(from: MemorySource(bytes: Self.matroska(cuesInSeekHead: false)))
        XCTAssertEqual(index.tracks.first { $0.number == 2 }?.events.count, 40)
    }

    func testAnythingElseIsNotMatroska() async {
        do {
            _ = try await MatroskaSubtitleIndex.load(from: MemorySource(bytes: Data("not a video".utf8)))
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? SubtitleIndexError, .notMatroska)
        }
    }

    func testTheReferenceSkipsSignsForcedAndKaraokeTracks() {
        func track(_ number: UInt64, _ codec: String, name: String?, forced: Bool = false, events: Int, step: Double = 3) -> MatroskaSubtitleTrack {
            MatroskaSubtitleTrack(
                number: number, codecID: codec, language: "eng", name: name, isDefault: number == 2,
                isForced: forced, isHearingImpaired: false, isCommentary: false,
                events: (0..<events).map { (start: 10 + Double($0) * step, duration: 2) })
        }
        let index = MatroskaSubtitleIndex(tracks: [
            track(2, "S_TEXT/UTF8", name: "English", events: 300),
            track(3, "S_TEXT/ASS", name: "English", events: 310),
            track(4, "S_TEXT/ASS", name: "Signs & Songs", events: 2000, step: 0.4),
            track(5, "S_TEXT/ASS", name: nil, forced: true, events: 50),
            track(6, "S_TEXT/ASS", name: "Karaoke FX", events: 8000, step: 0.1),
            track(7, "S_HDMV/PGS", name: nil, events: 600),
        ])
        let candidates = SubtitleSyncReference.candidates(in: index, targetLineCount: 305)
        XCTAssertEqual(candidates.map(\.track.number), [3, 2], "ASS before SRT; no signs, forced, karaoke; PGS only without text")

        let onlyPGS = MatroskaSubtitleIndex(tracks: [track(7, "S_HDMV/PGS", name: nil, events: 600)])
        let pgs = SubtitleSyncReference.candidates(in: onlyPGS, targetLineCount: 300)
        XCTAssertEqual(pgs.map(\.track.number), [7])
        XCTAssertEqual(pgs[0].cues.count, 300, "shown and cleared pictures pair into lines")
        XCTAssertEqual(pgs[0].cues[0].start, 10)
        XCTAssertEqual(pgs[0].cues[0].end, 13)
    }

    func testTheDiagnosticsSayWhyATrackIsLeftOut() {
        func track(_ number: UInt64, _ codec: String, name: String?, forced: Bool = false, events: Int) -> MatroskaSubtitleTrack {
            MatroskaSubtitleTrack(
                number: number, codecID: codec, language: "eng", name: name, isDefault: false,
                isForced: forced, isHearingImpaired: false, isCommentary: false,
                events: (0..<events).map { (start: 10 + Double($0) * 3, duration: 2) })
        }
        let index = MatroskaSubtitleIndex(tracks: [
            track(2, "S_TEXT/UTF8", name: "English", events: 300),
            track(3, "S_TEXT/ASS", name: "English", events: 310),
            track(4, "S_TEXT/ASS", name: "Dialogue + Signs", events: 320),
            track(5, "S_TEXT/ASS", name: nil, forced: true, events: 50),
            track(7, "S_HDMV/PGS", name: nil, events: 600),
            track(8, "S_VOBSUB", name: nil, events: 400),
            track(9, "S_TEXT/ASS", name: "Full", events: 5),
            track(11, "S_TEXT/UTF8", name: "English SRT", events: 300),
        ])
        let review = SubtitleSyncReference.review(in: index, targetLineCount: 305)
        XCTAssertEqual(review.candidates.map(\.track.number), [3, 2])
        XCTAssertEqual(review.skipped, [
            4: "name (signs, songs…)",
            5: "forced",
            7: "PGS, text tracks first",
            8: "picture subtitles (S_VOBSUB)",
            9: "only 5 lines in the index",
            11: "same timing as another track",
        ])
    }

    func testAForcedTrackIsTriedWhenItIsTheOnlyOne() {
        func track(_ number: UInt64, name: String?, forced: Bool, events: Int) -> MatroskaSubtitleTrack {
            MatroskaSubtitleTrack(
                number: number, codecID: "S_TEXT/ASS", language: "eng", name: name, isDefault: true,
                isForced: forced, isHearingImpaired: false, isCommentary: false,
                events: (0..<events).map { (start: 10 + Double($0) * 3, duration: 2) })
        }
        // One English track, marked forced by the release, with the whole dialogue.
        let only = MatroskaSubtitleIndex(tracks: [track(2, name: nil, forced: true, events: 300)])
        let review = SubtitleSyncReference.review(in: only, targetLineCount: 320)
        XCTAssertEqual(review.candidates.map(\.track.number), [2])
        XCTAssertNil(review.skipped[2])

        // Signs marked forced stay out even then, by their name.
        let signs = MatroskaSubtitleIndex(tracks: [track(2, name: "Signs & Songs", forced: true, events: 40)])
        XCTAssertEqual(SubtitleSyncReference.review(in: signs, targetLineCount: 320).candidates.count, 0)

        // With a full track that isn't forced, the forced one is left out.
        let both = MatroskaSubtitleIndex(tracks: [
            track(2, name: nil, forced: true, events: 300),
            track(3, name: "Full", forced: false, events: 310),
        ])
        let picked = SubtitleSyncReference.review(in: both, targetLineCount: 320)
        XCTAssertEqual(picked.candidates.map(\.track.number), [3])
        XCTAssertEqual(picked.skipped[2], "forced")
    }

    func testTheChanceOfALineStartOnAReferenceStart() {
        // Windows of ±0.5 s: 9.5…10.9 (two that overlap) and 19.5…20.5, of 100 s.
        XCTAssertEqual(SubtitleSyncAligner.startWindowShare([10, 10.4, 20], from: 0, to: 100), 0.024, accuracy: 0.0001)
        XCTAssertEqual(SubtitleSyncAligner.startWindowShare([0.2], from: 0, to: 10), 0.07, accuracy: 0.0001, "cut at the span's edge")
        XCTAssertEqual(SubtitleSyncAligner.startWindowShare([], from: 0, to: 10), 0)
    }

    // MARK: Lining up

    func testAConstantShiftIsFoundAndMeasured() {
        let reference = Self.dialogue(seed: 1, count: 400)
        var target = reference.enumerated().compactMap { index, cue -> SubtitleTimingCue? in
            guard index % 10 != 3 else { return nil } // lines the translation dropped
            return SubtitleTimingCue(start: cue.start - 2.43, end: cue.end - 2.43)
        }
        // Two lines merged into one, as translations do.
        target[20] = SubtitleTimingCue(start: target[20].start, end: target[21].end)
        target.remove(at: 21)
        let alignment = SubtitleSyncAligner.align(target: target, reference: reference)
        XCTAssertEqual(alignment.verdict, .confident)
        let fit = try! XCTUnwrap(alignment.fit)
        XCTAssertEqual(fit.mapping.scale, 1)
        XCTAssertEqual(fit.mapping.offset, 2.43, accuracy: 0.03)
        XCTAssertGreaterThan(fit.coverage, 0.95)
        XCTAssertEqual(alignment.plan?.parts.count, 1, "one shift for the whole subtitle")
        XCTAssertFalse(alignment.remarks.contains { $0.isWarning })
    }

    func testAFrameRateChangeIsFound() {
        let target = Self.dialogue(seed: 7, count: 350)
        let scale = 25 / 23.976
        let reference = target.map { SubtitleTimingCue(start: $0.start * scale + 1, end: $0.end * scale + 1) }
        let alignment = SubtitleSyncAligner.align(target: target, reference: reference)
        XCTAssertEqual(alignment.verdict, .confident)
        XCTAssertEqual(alignment.fit?.mapping.scale ?? 0, scale, accuracy: 0.00001)
        XCTAssertEqual(alignment.fit?.mapping.offset ?? 0, 1, accuracy: 0.05)
    }

    func testAnotherFilmsSubtitleIsNotUsed() {
        let alignment = SubtitleSyncAligner.align(
            target: Self.dialogue(seed: 3, count: 400),
            reference: Self.dialogue(seed: 11, count: 400))
        XCTAssertNotEqual(alignment.verdict, .confident)
    }

    func testTooFewLinesAreNotJudged() {
        let few = Self.dialogue(seed: 5, count: 10)
        XCTAssertEqual(SubtitleSyncAligner.align(target: few, reference: Self.dialogue(seed: 5, count: 400)).verdict, .tooFewLines)
    }

    func testTheLargestShiftOfAMapping() {
        let mapping = SubtitleSyncMapping(scale: 1.001, offset: -0.5)
        XCTAssertEqual(mapping.largestShift(over: 0...1000), 0.5, accuracy: 0.0001)
        XCTAssertEqual(SubtitleSyncMapping(scale: 1.04, offset: 0).largestShift(over: 0...100), 4, accuracy: 0.0001)
    }

    // MARK: Parts

    func testPGSEventsPairEvenWithALoneEventAndReplacements() {
        // A lone event at 0:00, then lines shown and cleared; every 7th is replaced without a clear.
        var times: [Double] = [0]
        var starts: [Double] = []
        var time = 5.0
        for index in 0..<200 {
            time += index % 2 == 0 ? 0.2 : 3
            starts.append(time)
            times.append(time)
            time += 2.5
            if index % 7 != 3 { times.append(time) }
        }
        let lines = SubtitleSyncReference.pgsLines(times)
        let right = lines.filter { line in starts.contains { abs($0 - line.start) < 0.001 } }.count
        XCTAssertGreaterThanOrEqual(Double(right) / Double(starts.count), 0.9)
    }

    func testSongsAreLeftOutOfMatching() {
        var cues = (0..<40).map { SubtitleTimingCue(start: 200 + Double($0) * 5, end: 202 + Double($0) * 5) }
        for k in 0..<30 {
            let start = 54 + Double(k) * 3
            cues.append(SubtitleTimingCue(start: start, end: start + 3, isDialogue: false, isSongLike: true))
            // The translation of the lyrics, in the dialogue style.
            if k % 2 == 0 { cues.append(SubtitleTimingCue(start: start + 0.1, end: start + 3)) }
        }
        let target = SubtitleSyncParts.Target(cues)
        XCTAssertEqual(target.songs.count, 1)
        XCTAssertEqual(target.songs.first?.lowerBound ?? 0, 54, accuracy: 0.001)
        XCTAssertEqual(target.lines.count, 40, "the song and its translation are left out")
        XCTAssertEqual(target.excluded, 45)
    }

    func testADifferentIntroGetsAShiftOfItsOwn() throws {
        for srt in [false, true] {
            let scenario = Self.introCase(srt: srt)
            let alignment = SubtitleSyncAligner.align(target: scenario.target, reference: scenario.reference)
            let name = srt ? "SRT (lyrics as dialogue)" : "ASS (song styles)"
            XCTAssertEqual(alignment.verdict, .confident, name)
            let plan = try XCTUnwrap(alignment.plan, name)
            XCTAssertEqual(plan.parts.count, 2, name)
            XCTAssertEqual(plan(1) - 1, -0.9, accuracy: 0.15, name)
            XCTAssertEqual(plan(40) - 40, -0.9, accuracy: 0.15, name)
            XCTAssertEqual(plan(60) - 60, -0.9, accuracy: 0.15, "\(name): the opening goes with the intro")
            XCTAssertEqual(plan(500) - 500, -9.3, accuracy: 0.15, name)
            XCTAssertTrue(alignment.remarks.contains { $0.isPart }, name)
        }
    }

    func testACutSceneSplitsTheSubtitle() throws {
        let lines = Self.lines(seed: 31, from: 5, to: 1400)
        let target = lines.map { SubtitleTimingCue(start: $0.start, end: $0.end) }
        // The TV version has a 5.2 s scene at 12:00 the video doesn't.
        let reference = lines.filter { !(719 < $0.start && $0.start < 725.2) }.map { line -> SubtitleTimingCue in
            let shift = line.start < 720 ? 2.0 : -3.2
            return SubtitleTimingCue(start: line.start + shift, end: line.end + shift)
        }
        let alignment = SubtitleSyncAligner.align(target: target, reference: reference)
        XCTAssertEqual(alignment.verdict, .confident, "the other half's mapping is a part, not a rival")
        let plan = try XCTUnwrap(alignment.plan)
        XCTAssertEqual(plan(100) - 100, 2.0, accuracy: 0.15)
        XCTAssertEqual(plan(700) - 700, 2.0, accuracy: 0.15)
        XCTAssertEqual(plan(1300) - 1300, -3.2, accuracy: 0.15)
    }

    func testATrailerTheVideoLacksKeepsTheShiftAroundIt() throws {
        let lines = Self.lines(seed: 41, from: 5, to: 1300)
        var target = lines.map { SubtitleTimingCue(start: $0.start, end: $0.end) }
        for k in 0..<20 {
            let start = 1310 + Double(k) * 3
            target.append(SubtitleTimingCue(start: start, end: start + 3, isDialogue: false, isSongLike: true))
        }
        target += (0..<6).map { SubtitleTimingCue(start: 1463 + Double($0) * 2.5, end: 1465 + Double($0) * 2.5) }
        let reference = lines.map { SubtitleTimingCue(start: $0.start - 1.2, end: $0.end - 1.2) }
        let alignment = SubtitleSyncAligner.align(target: target, reference: reference)
        XCTAssertEqual(alignment.verdict, .confident)
        let plan = try XCTUnwrap(alignment.plan)
        XCTAssertEqual(plan(1465) - 1465, -1.2, accuracy: 0.15)
        XCTAssertTrue(alignment.remarks.contains { remark in
            if case .noReference = remark { return true }
            return false
        })
    }

    func testEachPartMovesByItsOwnShift() throws {
        let srt = "1\n00:00:01,000 --> 00:00:02,000\nÚvod\n\n2\n00:01:00,000 --> 00:01:02,000\nOpening\n\n3\n00:02:40,000 --> 00:02:42,000\nPo openingu\n"
        let plan = SubtitleSyncPlan(parts: [
            SubtitleSyncPart(from: 1, mapping: SubtitleSyncMapping(scale: 1, offset: -0.9), lines: 8),
            SubtitleSyncPart(from: 150, mapping: SubtitleSyncMapping(scale: 1, offset: -9.3), lines: 300),
        ])
        let retimed = try XCTUnwrap(SubtitleRetimer.retime(srt, format: .srt, plan: plan))
        XCTAssertEqual(retimed, "1\n00:00:00,100 --> 00:00:01,100\nÚvod\n\n2\n00:00:59,100 --> 00:01:01,100\nOpening\n\n3\n00:02:30,700 --> 00:02:32,700\nPo openingu\n")
        XCTAssertEqual(plan.main, SubtitleSyncMapping(scale: 1, offset: -9.3))
        XCTAssertEqual(plan.largestShift(over: 0...200), 9.3, accuracy: 0.0001)
        XCTAssertEqual(plan.largestShift(over: 0...100), 0.9, accuracy: 0.0001)
        XCTAssertNotEqual(plan.signature, SubtitleSyncPlan.single(SubtitleSyncMapping(scale: 1, offset: -9.3)).signature)
    }

    // MARK: The player

    func testTheSyncedCopyTakesItsOriginalsPlace() {
        let tracks = [
            SubtitleTrack(id: "1", name: "Built in", language: "eng", isSelected: false),
            SubtitleTrack(id: "2", name: "CZ", language: "cze", isSelected: false, externalFilename: "https://addon/sub.srt"),
            SubtitleTrack(id: "3", name: "CZ", language: "cze", isSelected: true, externalFilename: "file:///cache/a.srt"),
        ]
        let copies = ["file:///cache/a.srt": "https://addon/sub.srt"]
        let synced = SubtitleAutoSyncTracks.present(tracks, copies: copies, originals: [])
        XCTAssertEqual(synced.map(\.id), ["1", "3"])
        XCTAssertEqual(synced[1].externalFilename, "https://addon/sub.srt")
        XCTAssertTrue(synced[1].isSelected)

        let original = SubtitleAutoSyncTracks.present(tracks, copies: copies, originals: ["https://addon/sub.srt"])
        XCTAssertEqual(original.map(\.id), ["1", "2"])
    }

    func testSettingsAreOffUntilTurnedOnAndSync() throws {
        let suite = "SubtitleAutoSyncTests.settings"
        let settings = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { settings.removePersistentDomain(forName: suite) }
        XCTAssertFalse(SubtitleAutoSyncSettings.isEnabled(in: settings))
        XCTAssertEqual(SubtitleAutoSyncSettings.toleranceMs(in: settings), 0)
        settings.set(true, forKey: SettingsKey.subtitleAutoSync)
        settings.set(250, forKey: SettingsKey.subtitleAutoSyncToleranceMs)
        XCTAssertTrue(SubtitleAutoSyncSettings.isEnabled(in: settings))
        XCTAssertEqual(SubtitleAutoSyncSettings.toleranceMs(in: settings), 0, "only the offered choices")
        settings.set(200, forKey: SettingsKey.subtitleAutoSyncToleranceMs)
        XCTAssertEqual(SubtitleAutoSyncSettings.toleranceMs(in: settings), 200)
        XCTAssertTrue(SettingsKey.all.contains(SettingsKey.subtitleAutoSync))
        XCTAssertTrue(SettingsKey.all.contains(SettingsKey.subtitleAutoSyncToleranceMs))
        XCTAssertEqual(
            SubtitleAutoSync.cacheKey(fileKey: "file", subtitleURL: "https://a"),
            SubtitleAutoSync.cacheKey(fileKey: "file", subtitleURL: "https://a"))
        XCTAssertNotEqual(
            SubtitleAutoSync.cacheKey(fileKey: "file", subtitleURL: "https://a"),
            SubtitleAutoSync.cacheKey(fileKey: "other", subtitleURL: "https://a"))
    }

    // MARK: Helpers

    struct MemorySource: SubtitleIndexByteSource {
        let bytes: Data

        func read(offset: Int64, length: Int) async throws -> (data: Data, totalSize: Int64?) {
            let start = Int(offset)
            guard start < bytes.count else { return (Data(), Int64(bytes.count)) }
            return (bytes.subdata(in: start..<min(bytes.count, start + length)), Int64(bytes.count))
        }
    }

    /// Dialogue-like lines between `start` and `end` (same generator as `dialogue`).
    static func lines(seed: UInt64, from start: Double, to end: Double) -> [(start: Double, end: Double)] {
        var state = seed
        func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(UInt64(1) << 53)
        }
        var result: [(start: Double, end: Double)] = []
        var time = start
        while true {
            time += 0.3 + next() * 4
            let lineStart = time
            time += 1 + next() * 3
            if time > end { break }
            result.append((lineStart, time))
        }
        return result
    }

    static let introStarts: [Double] = [0.9, 4.7, 6.9, 9.5, 28.4, 32.9, 39.7, 42.0]

    /// Ladies versus Butlers E7 (anime-titulky) as a test: the intro needs −0.9 s, everything
    /// after the opening −9.3 s (the TV sponsor card is gone from the Blu-ray).
    static func introCase(srt: Bool) -> (target: [SubtitleTimingCue], reference: [SubtitleTimingCue]) {
        let rest = lines(seed: 21, from: 150, to: 1380)
        var target = introStarts.map { SubtitleTimingCue(start: $0, end: $0 + 2) }
            + rest.map { SubtitleTimingCue(start: $0.start, end: $0.end) }
        for k in 0..<30 {
            let start = 54 + Double(k) * 3
            target.append(SubtitleTimingCue(start: start, end: start + 3, isDialogue: srt, isSongLike: !srt))
            if k % 2 == 0 { target.append(SubtitleTimingCue(start: start + 0.1, end: start + 3)) }
        }
        for k in 0..<20 {
            let start = 1390 + Double(k) * 3
            target.append(SubtitleTimingCue(start: start, end: start + 3, isDialogue: srt, isSongLike: !srt))
        }
        let reference = introStarts.map { SubtitleTimingCue(start: $0 - 0.9, end: $0 + 1.1) }
            + rest.map { SubtitleTimingCue(start: $0.start - 9.3, end: $0.end - 9.3) }
        return (target, reference)
    }

    /// Dialogue-like lines: a gap of 0.3 to 4.3 s, then 1 to 4 s of speech.
    static func dialogue(seed: UInt64, count: Int) -> [SubtitleTimingCue] {
        var state = seed
        func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(UInt64(1) << 53)
        }
        var time = 5.0
        return (0..<count).map { _ in
            time += 0.3 + next() * 4
            let start = time
            time += 1 + next() * 3
            return SubtitleTimingCue(start: start, end: time)
        }
    }

    static func gzip(_ data: Data) -> Data? {
        let input = [UInt8](data)
        let capacity = input.count + 1024
        var output = [UInt8](repeating: 0, count: capacity)
        let written = compression_encode_buffer(&output, capacity, input, input.count, nil, COMPRESSION_ZLIB)
        guard written > 0 else { return nil }
        var gzip: [UInt8] = [0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 3]
        gzip += output.prefix(written)
        gzip += [0, 0, 0, 0] // CRC, not checked
        let size = UInt32(input.count)
        gzip += [UInt8(size & 0xFF), UInt8(size >> 8 & 0xFF), UInt8(size >> 16 & 0xFF), UInt8(size >> 24)]
        return Data(gzip)
    }

    // A small Matroska file: header, SeekHead, Info, Tracks (video, two ASS, one PGS), a large
    // Cluster, then the Cues.
    static func matroska(cuesInSeekHead: Bool) -> Data {
        func size(_ count: Int) -> [UInt8] { [0x01] + (0..<7).reversed().map { UInt8(truncatingIfNeeded: count >> ($0 * 8)) } }
        func element(_ id: [UInt8], _ body: [UInt8]) -> [UInt8] { id + size(body.count) + body }
        func uint(_ value: UInt64, bytes: Int = 8) -> [UInt8] { (0..<bytes).reversed().map { UInt8(truncatingIfNeeded: value >> (UInt64($0) * 8)) } }
        func text(_ value: String) -> [UInt8] { Array(value.utf8) }

        let ebml = element([0x1A, 0x45, 0xDF, 0xA3], element([0x42, 0x82], text("matroska")))
        let info = element([0x15, 0x49, 0xA9, 0x66], element([0x2A, 0xD7, 0xB1], uint(1_000_000, bytes: 3)))
        func track(_ number: UInt64, type: UInt64, codec: String, language: String, name: String?, forced: Bool = false) -> [UInt8] {
            var body = element([0xD7], uint(number, bytes: 1)) + element([0x83], uint(type, bytes: 1))
                + element([0x86], text(codec)) + element([0x22, 0xB5, 0x9C], text(language))
            if let name { body += element([0x53, 0x6E], text(name)) }
            if forced { body += element([0x55, 0xAA], uint(1, bytes: 1)) }
            return element([0xAE], body)
        }
        let tracks = element([0x16, 0x54, 0xAE, 0x6B],
            track(1, type: 1, codec: "V_MPEG4/ISO/AVC", language: "und", name: nil)
            + track(2, type: 0x11, codec: "S_TEXT/ASS", language: "cze", name: "Dialogue")
            + track(3, type: 0x11, codec: "S_HDMV/PGS", language: "eng", name: nil)
            + track(4, type: 0x11, codec: "S_TEXT/ASS", language: "eng", name: "Signs", forced: true))
        let cluster = element([0x1F, 0x43, 0xB6, 0x75], [UInt8](repeating: 0, count: 300 * 1024))
        var points: [UInt8] = []
        for index in 0..<40 {
            let time = UInt64(1000 + index * 5000)
            points += element([0xBB], element([0xB3], uint(time, bytes: 4))
                + element([0xB7], element([0xF7], uint(2, bytes: 1)) + element([0xF1], uint(100, bytes: 4)) + element([0xB2], uint(2000, bytes: 2)))
                + element([0xB7], element([0xF7], uint(3, bytes: 1)) + element([0xF1], uint(100, bytes: 4))))
            points += element([0xBB], element([0xB3], uint(time + 2500, bytes: 4))
                + element([0xB7], element([0xF7], uint(3, bytes: 1)) + element([0xF1], uint(100, bytes: 4))))
            points += element([0xBB], element([0xB3], uint(time, bytes: 4))
                + element([0xB7], element([0xF7], uint(1, bytes: 1)) + element([0xF1], uint(100, bytes: 4))))
        }
        let cues = element([0x1C, 0x53, 0xBB, 0x6B], points)

        func seekHead(info: Int, tracks: Int, cues: Int?) -> [UInt8] {
            func seek(_ id: [UInt8], _ position: Int) -> [UInt8] {
                element([0x4D, 0xBB], element([0x53, 0xAB], id) + element([0x53, 0xAC], uint(UInt64(position))))
            }
            var body = seek([0x15, 0x49, 0xA9, 0x66], info) + seek([0x16, 0x54, 0xAE, 0x6B], tracks)
            if let cues { body += seek([0x1C, 0x53, 0xBB, 0x6B], cues) }
            return element([0x11, 0x4D, 0x9B, 0x74], body)
        }
        let placeholder = seekHead(info: 0, tracks: 0, cues: cuesInSeekHead ? 0 : nil)
        let infoAt = placeholder.count
        let tracksAt = infoAt + info.count
        let cuesAt = tracksAt + tracks.count + cluster.count
        let head = seekHead(info: infoAt, tracks: tracksAt, cues: cuesInSeekHead ? cuesAt : nil)
        let segmentBody = head + info + tracks + cluster + cues
        let segment = [0x18, 0x53, 0x80, 0x67] + [0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF] + segmentBody
        return Data(ebml + segment)
    }
}
