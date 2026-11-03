import XCTest
@testable import NuvioTV

final class PlaybackChaptersTests: XCTestCase {
    private func chapter(_ id: Int, _ name: String, _ start: Double, _ end: Double) -> PlaybackChapter {
        PlaybackChapter(id: id, name: name, startSeconds: start, endSeconds: end)
    }

    func testChaptersAreSortedAndEndWhereTheNextStarts() {
        let chapters = PlaybackChapters.chapters(
            from: [
                (id: 2, name: "Part B", start: 600, duration: 0),
                (id: 0, name: "Opening", start: 0, duration: 90),
                (id: 1, name: "Part A", start: 90, duration: 0),
            ],
            totalDuration: 1420
        )
        XCTAssertEqual(chapters.map(\.id), [0, 1, 2])
        XCTAssertEqual(chapters.map(\.endSeconds), [90, 600, 1420])
        // A length past the next chapter is cut at it.
        let overlapping = PlaybackChapters.chapters(
            from: [(id: 0, name: "", start: 0, duration: 200), (id: 1, name: "", start: 120, duration: 0)],
            totalDuration: 300
        )
        XCTAssertEqual(overlapping.map(\.endSeconds), [120, 300])
    }

    func testASingleChapterIsNoChapterList() {
        XCTAssertTrue(PlaybackChapters.chapters(from: [(id: 0, name: "Movie", start: 0, duration: 0)], totalDuration: 5400).isEmpty)
        XCTAssertTrue(PlaybackChapters.chapters(from: [], totalDuration: 5400).isEmpty)
        XCTAssertEqual(
            PlaybackChapters.chapters(
                from: [(id: 0, name: "A", start: 0, duration: 0), (id: 1, name: "B", start: 600, duration: 0)],
                totalDuration: 5400
            ).count,
            2
        )
    }

    func testGenericNamesBecomeChapterNumbers() {
        XCTAssertEqual(PlaybackChapters.displayName(chapter(0, "Opening", 0, 90), index: 0), "Opening")
        XCTAssertEqual(PlaybackChapters.displayName(chapter(1, "Chapter 03", 90, 200), index: 2), "Chapter 3")
        XCTAssertEqual(PlaybackChapters.displayName(chapter(2, "  ", 90, 200), index: 4), "Chapter 5")
        XCTAssertEqual(PlaybackChapters.displayName(chapter(3, "00:12:30.000", 750, 900), index: 1), "Chapter 2")
    }

    func testChapterAtThePlayhead() {
        let chapters = [chapter(0, "A", 0, 90), chapter(1, "B", 90, 600), chapter(2, "C", 600, 1420)]
        XCTAssertEqual(PlaybackChapters.index(at: 0, in: chapters), 0)
        XCTAssertEqual(PlaybackChapters.index(at: 89.5, in: chapters), 0)
        XCTAssertEqual(PlaybackChapters.index(at: 300, in: chapters), 1)
        XCTAssertEqual(PlaybackChapters.index(at: 1500, in: chapters), 2)
        XCTAssertNil(PlaybackChapters.index(at: 10, in: []))
    }

    func testMarkersLeaveOutTheFirstChapter() {
        let chapters = [chapter(0, "A", 0, 90), chapter(1, "B", 90, 600), chapter(2, "C", 600, 1200)]
        XCTAssertEqual(PlaybackChapters.markers(chapters, duration: 1200), [0.075, 0.5])
        XCTAssertEqual(PlaybackChapters.markers([chapter(0, "A", 0, 1200)], duration: 1200), [])
        XCTAssertEqual(PlaybackChapters.markers(chapters, duration: 0), [])
    }

    func testChapterNamesForOpeningAndEnding() {
        for name in ["Opening", "OP", "OP2", "op 2", "Intro", "Opening Credits", "Opening Song", "OP - 1"] {
            XCTAssertEqual(PlaybackChapters.kind(ofName: name), .opening, name)
        }
        for name in ["Ending", "ED", "ED1", "Credits", "End Credits", "Outro", "Ending Song"] {
            XCTAssertEqual(PlaybackChapters.kind(ofName: name), .ending, name)
        }
        for name in ["Part A", "Prologue", "Preview", "Chapter 3", "Opera", "Edge", "Intro Scene", "Avant", ""] {
            XCTAssertNil(PlaybackChapters.kind(ofName: name), name)
        }
    }

    func testSkipOnlyFromShortNamedChapters() {
        let anime = [
            chapter(0, "Prologue", 0, 75),
            chapter(1, "Opening", 75, 165),
            chapter(2, "Part A", 165, 700),
            chapter(3, "Ending", 1290, 1380),
            chapter(4, "Preview", 1380, 1420),
        ]
        let intervals = PlaybackChapters.skipIntervals(from: anime)
        XCTAssertEqual(intervals.count, 2)
        XCTAssertTrue(intervals[0].isIntro)
        XCTAssertEqual(intervals[0].startTime, 75)
        XCTAssertEqual(intervals[0].endTime, 165)
        XCTAssertTrue(intervals[1].isEnding)
        XCTAssertEqual(intervals[1].startTime, 1290)
        XCTAssertEqual(intervals[1].provider, "chapters")

        // Too long to be an opening, or too short to be one: no button.
        XCTAssertTrue(PlaybackChapters.skipIntervals(from: [chapter(0, "Intro", 0, 600)]).isEmpty)
        XCTAssertTrue(PlaybackChapters.skipIntervals(from: [chapter(0, "OP", 0, 5)]).isEmpty)
    }

    func testOpeningAndEndingOnTheTimeline() {
        let segments = PlaybackChapters.timelineSegments([
            SkipInterval(startTime: 60, endTime: 150, type: "intro", provider: "introdb"),
            SkipInterval(startTime: 0, endTime: 30, type: "recap", provider: "introdb"),
            SkipInterval(startTime: 1290, endTime: 1500, type: "outro", provider: "chapters"),
        ], duration: 1400)
        XCTAssertEqual(segments.map(\.kind), [.opening, .ending])
        XCTAssertEqual(segments[0].start, 60.0 / 1400, accuracy: 0.0001)
        XCTAssertEqual(segments[0].end, 150.0 / 1400, accuracy: 0.0001)
        // Past the end of the video: cut at the end.
        XCTAssertEqual(segments[1].end, 1)
        XCTAssertTrue(PlaybackChapters.timelineSegments(
            [SkipInterval(startTime: 60, endTime: 150, type: "intro", provider: "introdb")], duration: 0
        ).isEmpty)
    }

    func testChapterBadgeFromNameOrFromTheMatchingSegment() {
        let introDB = [SkipInterval(startTime: 61, endTime: 151, type: "intro", provider: "introdb")]
        XCTAssertEqual(PlaybackChapters.kind(of: chapter(0, "Opening", 300, 390), segments: []), .opening)
        XCTAssertEqual(PlaybackChapters.kind(of: chapter(1, "Chapter 2", 60, 150), segments: introDB), .opening)
        XCTAssertNil(PlaybackChapters.kind(of: chapter(2, "Chapter 3", 150, 600), segments: introDB))
    }

    func testThumbnailIsAFewSecondsIntoTheChapter() {
        XCTAssertEqual(PlaybackChapters.thumbnailTime(for: chapter(0, "A", 100, 400)), 105)
        XCTAssertEqual(PlaybackChapters.thumbnailTime(for: chapter(1, "B", 100, 108)), 102)
        XCTAssertEqual(PlaybackChapters.thumbnailTime(for: chapter(2, "C", 100, 100)), 100)
    }

    func testALengthThatMovesSlightlyKeepsTheSameChapterList() {
        let items: [(id: Int, name: String, start: Double, duration: Double)] = [
            (id: 0, name: "Opening", start: 0, duration: 0),
            (id: 1, name: "Part A", start: 90, duration: 0),
        ]
        let first = PlaybackChapters.chapters(from: items, totalDuration: 1420.0)
        let moved = PlaybackChapters.chapters(from: items, totalDuration: 1420.4)
        XCTAssertNotEqual(first, moved)
        XCTAssertTrue(PlaybackChapters.isSameList(first, moved))
        let renamed = PlaybackChapters.chapters(
            from: [(id: 0, name: "OP", start: 0, duration: 0), (id: 1, name: "Part A", start: 90, duration: 0)],
            totalDuration: 1420.0)
        XCTAssertFalse(PlaybackChapters.isSameList(first, renamed))
        XCTAssertFalse(PlaybackChapters.isSameList(first, Array(first.prefix(1))))
    }

    func testTheFocusedChapterLoadsNextThenTheClosest() {
        XCTAssertEqual(PlaybackChapters.nextThumbnailIndex(missing: [0, 3, 7, 12], anchor: 7), 7)
        XCTAssertEqual(PlaybackChapters.nextThumbnailIndex(missing: [0, 5, 9, 12], anchor: 7), 9, "a tie goes to the later chapter")
        XCTAssertEqual(PlaybackChapters.nextThumbnailIndex(missing: [0, 2, 30], anchor: 20), 30)
        XCTAssertNil(PlaybackChapters.nextThumbnailIndex(missing: [], anchor: 4))
    }

    func testThumbnailsLoadFromThePlayingChapterOutward() {
        XCTAssertEqual(PlaybackChapters.thumbnailOrder(count: 6, from: 2), [2, 3, 1, 4, 0, 5])
        XCTAssertEqual(PlaybackChapters.thumbnailOrder(count: 4, from: 0), [0, 1, 2, 3])
        XCTAssertEqual(PlaybackChapters.thumbnailOrder(count: 3, from: 9), [2, 1, 0])
        XCTAssertEqual(PlaybackChapters.thumbnailOrder(count: 0, from: 0), [])
    }

    func testNamedChaptersTakeThePlaceOfIntroDB() {
        let introDB = [
            SkipInterval(startTime: 80, endTime: 168, type: "intro", provider: "introdb"),
            SkipInterval(startTime: 1300, endTime: 1385, type: "outro", provider: "introdb"),
        ]
        let fromChapters = [SkipInterval(startTime: 75, endTime: 165, type: "intro", provider: "chapters")]
        let merged = PlaybackChapters.merged(introDB: introDB, chapters: fromChapters)
        // The file's "Opening" replaces IntroDB's; IntroDB keeps the ending the names don't have.
        XCTAssertEqual(merged.map(\.provider), ["chapters", "introdb"])
        XCTAssertEqual(merged.map(\.startTime), [75, 1300])
        XCTAssertEqual(PlaybackChapters.merged(introDB: [], chapters: fromChapters), fromChapters)
        XCTAssertEqual(PlaybackChapters.merged(introDB: introDB, chapters: []), introDB)
    }

    func testIntroDBLinesUpWithTheFileChapters() {
        let chapters = [
            chapter(0, "Chapter 1", 0, 92),
            chapter(1, "Chapter 2", 92, 182),     // the opening, unnamed
            chapter(2, "Chapter 3", 182, 1290),
            chapter(3, "Chapter 4", 1290, 1380),  // the ending, unnamed
            chapter(4, "Chapter 5", 1380, 1420),
        ]
        // IntroDB from another release: the opening 20 s late, the ending a few seconds off.
        let introDB = [
            SkipInterval(startTime: 112, endTime: 182, type: "intro", provider: "introdb"),
            SkipInterval(startTime: 1286, endTime: 1377, type: "outro", provider: "introdb"),
        ]
        let merged = PlaybackChapters.merged(introDB: introDB, chapters: [], chapterList: chapters)
        XCTAssertEqual(merged.map(\.startTime), [92, 1290])
        XCTAssertEqual(merged.map(\.endTime), [182, 1380])
        XCTAssertEqual(merged.map(\.provider), ["introdb", "introdb"])
        XCTAssertEqual(merged.map(\.type), ["intro", "outro"])
    }

    func testIntroDBKeepsItsTimesWithoutAMatchingChapter() {
        // The opening sits inside a long part: no chapter to line it up with.
        let long = [chapter(0, "Part A", 0, 600), chapter(1, "Part B", 600, 1400)]
        let opening = SkipInterval(startTime: 90, endTime: 180, type: "intro", provider: "introdb")
        XCTAssertEqual(PlaybackChapters.aligned(opening, to: long), opening)
        // A chapter of the right length that covers too little of it.
        let shifted = [chapter(0, "Chapter 1", 0, 150), chapter(1, "Chapter 2", 150, 240), chapter(2, "Chapter 3", 240, 1400)]
        XCTAssertEqual(PlaybackChapters.aligned(opening, to: shifted), opening)
        // Recaps and other kinds are left alone.
        let recap = SkipInterval(startTime: 0, endTime: 90, type: "recap", provider: "introdb")
        XCTAssertEqual(PlaybackChapters.aligned(recap, to: [chapter(0, "Chapter 1", 0, 92), chapter(1, "Chapter 2", 92, 900)]), recap)
    }

    func testTheTimelineIsCutWhereChaptersStart() {
        let pieces = PlaybackChapters.timelinePieces(markers: [0.5, 0.25, 0.75], segments: [(start: 0.1, end: 0.2)])
        XCTAssertEqual(pieces.map(\.start), [0, 0.25, 0.5, 0.75])
        XCTAssertEqual(pieces.map(\.end), [0.25, 0.5, 0.75, 1])
    }

    func testWithoutChaptersTheOpeningAndEndingCutTheTimeline() {
        let pieces = PlaybackChapters.timelinePieces(
            markers: [],
            segments: [(start: 0.05, end: 0.12), (start: 0.9, end: 1)]
        )
        // The ending runs to the very end: no piece after it.
        XCTAssertEqual(pieces.map(\.start), [0, 0.05, 0.12, 0.9])
        XCTAssertEqual(pieces.map(\.end), [0.05, 0.12, 0.9, 1])
    }

    func testNothingToCutAtLeavesOneBar() {
        XCTAssertEqual(PlaybackChapters.timelinePieces(markers: [], segments: []), [])
        XCTAssertEqual(PlaybackChapters.timelinePieces(markers: [], segments: [(start: 0, end: 1)]), [])
        // Cuts on top of each other make one cut.
        XCTAssertEqual(PlaybackChapters.timelinePieces(markers: [0.4, 0.4005], segments: []).count, 2)
    }

    func testThePieceUnderThePlayhead() {
        let pieces = PlaybackChapters.timelinePieces(markers: [0.25, 0.5], segments: [])
        XCTAssertEqual(PlaybackChapters.pieceIndex(at: 0, in: pieces), 0)
        XCTAssertEqual(PlaybackChapters.pieceIndex(at: 0.3, in: pieces), 1)
        XCTAssertEqual(PlaybackChapters.pieceIndex(at: 0.5, in: pieces), 2, "a chapter's start belongs to it")
        XCTAssertEqual(PlaybackChapters.pieceIndex(at: 1, in: pieces), 2)
        XCTAssertNil(PlaybackChapters.pieceIndex(at: 0.3, in: []))
    }

    func testOpeningAndEndingColorsFromTheSettings() throws {
        let suite = "PlaybackChaptersTests.colors"
        let settings = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { settings.removePersistentDomain(forName: suite) }
        XCTAssertEqual(PlaybackChapters.colorHex(for: .opening, in: settings), PlaybackChapters.defaultOpeningColor)
        XCTAssertEqual(PlaybackChapters.colorHex(for: .ending, in: settings), PlaybackChapters.defaultEndingColor)
        settings.set("#f78fb3", forKey: SettingsKey.timelineOpeningColor)
        settings.set("blue", forKey: SettingsKey.timelineEndingColor)
        XCTAssertEqual(PlaybackChapters.colorHex(for: .opening, in: settings), "#F78FB3")
        XCTAssertEqual(PlaybackChapters.colorHex(for: .ending, in: settings), PlaybackChapters.defaultEndingColor)
        // Red is the mark of where playback is: no longer offered, so back to the default.
        settings.set("#EB5757", forKey: SettingsKey.timelineEndingColor)
        XCTAssertEqual(PlaybackChapters.colorHex(for: .ending, in: settings), PlaybackChapters.defaultEndingColor)
        XCTAssertFalse(PlaybackChapters.colorChoices.contains("#EB5757"))
        XCTAssertTrue(PlaybackChapters.colorChoices.contains(PlaybackChapters.defaultOpeningColor))
        XCTAssertTrue(PlaybackChapters.colorChoices.contains(PlaybackChapters.defaultEndingColor))
        XCTAssertTrue(SettingsKey.all.contains(SettingsKey.timelineOpeningColor))
        XCTAssertTrue(SettingsKey.all.contains(SettingsKey.timelineEndingColor))
    }

    func testBadgeTextReadsOnEveryColor() {
        // Black on the light colors, white on the dark ones.
        let dark = PlaybackChapters.colorChoices.filter { PlaybackChapters.prefersDarkText(on: $0) }
        XCTAssertEqual(dark, ["#F2C94C", "#56CCF2", "#F78FB3", "#6FCF97", "#F2994A"])
    }

    func testSwipeSnapsToChapterAndOpeningEdges() {
        let chapters = [chapter(0, "Prologue", 0, 86), chapter(1, "Opening", 86, 181), chapter(2, "Part A", 181, 1300)]
        let segments = [
            SkipInterval(startTime: 86, endTime: 181, type: "intro", provider: "chapters"),
            SkipInterval(startTime: 1300, endTime: 1440, type: "outro", provider: "introdb"),
            SkipInterval(startTime: 0, endTime: 60, type: "recap", provider: "introdb")
        ]
        // The very start and the end of the video are no edges; the recap is no edge.
        let edges = PlaybackChapters.snapEdges(chapters: chapters, segments: segments, duration: 1440)
        XCTAssertEqual(edges, [86, 181, 1300])
        XCTAssertEqual(PlaybackChapters.snapRadius(duration: 1440), 10)
        XCTAssertEqual(PlaybackChapters.snapRadius(duration: 120), 3)
        XCTAssertEqual(PlaybackChapters.snapRadius(duration: 600), 6)
        XCTAssertEqual(PlaybackChapters.snapPush(duration: 1440), 30)
        XCTAssertEqual(PlaybackChapters.snapEdges(chapters: [], segments: [], duration: 0), [])
    }

    func testASwipeStaysOnAnEdgeUntilItCarriesOnPastIt() {
        var seek = PlaybackChapters.SnappingSeek(from: 150, edges: [181, 1300], radius: 10, push: 30)
        XCTAssertEqual(seek.move(by: 20, upTo: 1439), 170, "out of reach")
        XCTAssertEqual(seek.move(by: 5, upTo: 1439), 181, "6 s before it: on the edge")
        XCTAssertEqual(seek.move(by: 20, upTo: 1439), 181, "14 s past it: still there")
        XCTAssertEqual(seek.move(by: 16, upTo: 1439), 181, "30 s past it: still there")
        XCTAssertEqual(seek.move(by: 6, upTo: 1439), 187, "moves on from the edge, no jump")
        XCTAssertEqual(seek.move(by: -2, upTo: 1439), 185, "the edge just left doesn't catch it again")
        XCTAssertEqual(seek.move(by: 1110, upTo: 1439), 1300, "a long swipe stops on the next edge")
        XCTAssertEqual(seek.move(by: -50, upTo: 1439), 1275, "and leaves it backwards too")
    }

    func testASwipeFromAnEdgeIsNotHeldByIt() {
        var seek = PlaybackChapters.SnappingSeek(from: 181, edges: [181], radius: 10, push: 30)
        XCTAssertEqual(seek.move(by: 5, upTo: 1439), 186)
        // Fine-tuning moved the target: the swipe starts over there.
        seek.reset(to: 150)
        XCTAssertEqual(seek.move(by: 25, upTo: 1439), 181)
        // Never past the end.
        var end = PlaybackChapters.SnappingSeek(from: 1430, edges: [100], radius: 10, push: 30)
        XCTAssertEqual(end.move(by: 50, upTo: 1439), 1439)
    }

    func testTimelineSegmentsDefaultOffAndSeekingSnapStaysOn() throws {
        let suite = "PlaybackChaptersTests.switches"
        let settings = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { settings.removePersistentDomain(forName: suite) }
        XCTAssertFalse(PlaybackChapters.showsSegmentsOnTimeline(in: settings))
        XCTAssertTrue(PlaybackChapters.snapsWhileSeeking(in: settings))
        settings.set(true, forKey: SettingsKey.timelineSegmentsEnabled)
        settings.set(false, forKey: SettingsKey.timelineSnapEnabled)
        XCTAssertTrue(PlaybackChapters.showsSegmentsOnTimeline(in: settings))
        XCTAssertTrue(PlaybackChapters.snapsWhileSeeking(in: settings))
        XCTAssertTrue(SettingsKey.all.contains(SettingsKey.timelineSegmentsEnabled))
        XCTAssertTrue(SettingsKey.all.contains(SettingsKey.timelineSnapEnabled))
    }

    func testChaptersAreAnInSightSectionOfTheirOwn() throws {
        let suite = "PlaybackChaptersTests.sections"
        let settings = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { settings.removePersistentDomain(forName: suite) }
        // First by default; after the others in an order saved before Chapters was a section.
        XCTAssertEqual(TVSceneTabOrder.currentOrder(in: settings).first, .chapters)
        settings.set(try JSONEncoder().encode(["info", "scene"]), forKey: SettingsKey.sceneTabOrder)
        XCTAssertEqual(TVSceneTabOrder.currentOrder(in: settings), [.info, .scene, .chapters, .autoSync, .upNext, .watchParty])
        // Switched off and on, and moved, like the other sections.
        TVSceneTabOrder.setTabEnabled(.chapters, isEnabled: false, in: settings)
        XCTAssertTrue(TVSceneTabOrder.disabledTabs(in: settings).contains(.chapters))
        TVSceneTabOrder.saveOrder([.chapters, .info], in: settings)
        XCTAssertEqual(TVSceneTabOrder.currentOrder(in: settings).first, .chapters)
        TVSceneTabOrder.setTabEnabled(.chapters, isEnabled: true, in: settings)
        XCTAssertFalse(TVSceneTabOrder.disabledTabs(in: settings).contains(.chapters))
    }

    @MainActor
    func testTheChaptersTabOnlyForAFileWithChapters() {
        let sceneVM = SceneViewModel(coordinator: SceneCoordinator(frameProvider: UnsupportedSceneFrameProvider()))
        sceneVM.setMetadata(title: "Show", year: nil, overview: nil, runtime: nil, nextEpisode: nil)
        XCTAssertFalse(sceneVM.availableTabs.contains(.chapters))
        sceneVM.setMetadata(title: "Show", year: nil, overview: nil, runtime: nil, nextEpisode: nil, hasChapters: true)
        XCTAssertTrue(sceneVM.availableTabs.contains(.chapters))
    }

    func testThePlayingChapterStandsAboutTwiceAsTallAsTheOthers() {
        // At rest the track is 7 tall, seeking 12; the playing piece is 4 more.
        XCTAssertEqual(PlayerProgressTrack.otherPieceHeight(for: 7), 5)
        XCTAssertEqual(PlayerProgressTrack.otherPieceHeight(for: 12), 8)
        XCTAssertEqual(12 + PlayerProgressTrack.currentPieceLift, 2 * PlayerProgressTrack.otherPieceHeight(for: 12))
        XCTAssertEqual(PlayerProgressTrack.otherPieceHeight(for: 2), 3)
    }
}
