import Testing
import Foundation
@testable import AetherEngine

/// #179: container (Matroska/MP4) chapters published as `mediaChapters`. The read side needs an
/// AVFormatContext, so the mapping is a pure function over the values read off `AVChapter` and these
/// cover it: ordering, ids, naming, and the duration rules that exist because real-world muxes write
/// degenerate chapter ends.
struct ContainerChapterMappingTests {

    private func raw(_ start: Double, _ end: Double, _ title: String? = nil)
        -> Demuxer.RawContainerChapter {
        Demuxer.RawContainerChapter(start: start, end: end, title: title)
    }

    @Test("Chapters sort by start and take sequential ids")
    func sortingAndIDs() {
        let chapters = Demuxer.chapterInfos(
            from: [raw(120, 240, "Third"), raw(0, 60, "First"), raw(60, 120, "Second")],
            containerDuration: 300)
        #expect(chapters.map(\.id) == [0, 1, 2])
        #expect(chapters.map(\.name) == ["First", "Second", "Third"])
        #expect(chapters.map(\.startSeconds) == [0, 60, 120])
    }

    @Test("A duration runs to the next chapter's start, not to the declared end")
    func durationRunsToNextStart() {
        // The end==start shape a Matroska mux routinely writes: without the next-start rule every
        // duration would be 0.
        let chapters = Demuxer.chapterInfos(
            from: [raw(0, 0, "A"), raw(90, 90, "B"), raw(150, 150, "C")],
            containerDuration: 200)
        #expect(chapters.map(\.durationSeconds) == [90, 60, 50])
    }

    @Test("The last chapter uses its declared end when that end is real")
    func lastChapterUsesDeclaredEnd() {
        let chapters = Demuxer.chapterInfos(
            from: [raw(0, 60, "A"), raw(60, 95, "B")], containerDuration: 300)
        #expect(chapters[1].durationSeconds == 35)
    }

    @Test("A degenerate last end falls back to the container duration")
    func lastChapterFallsBackToContainerDuration() {
        let chapters = Demuxer.chapterInfos(
            from: [raw(0, 60, "A"), raw(60, 60, "B")], containerDuration: 300)
        #expect(chapters[1].durationSeconds == 240)
    }

    @Test("With no usable container duration a degenerate last chapter stays zero, never negative")
    func lastChapterWithoutDuration() {
        #expect(Demuxer.chapterInfos(
            from: [raw(0, 60, "A"), raw(60, 60, "B")], containerDuration: nil)[1].durationSeconds == 0)
        // A container duration that precedes the chapter start cannot bound it either.
        #expect(Demuxer.chapterInfos(
            from: [raw(0, 60, "A"), raw(60, 60, "B")], containerDuration: 30)[1].durationSeconds == 0)
    }

    @Test("Untitled, empty and whitespace-only chapters are numbered in list order")
    func namingFallback() {
        let chapters = Demuxer.chapterInfos(
            from: [raw(0, 10, nil), raw(10, 20, ""), raw(20, 30, "   "), raw(30, 40, "  Real  ")],
            containerDuration: 40)
        #expect(chapters.map(\.name) == ["Chapter 1", "Chapter 2", "Chapter 3", "Real"])
    }

    @Test("An empty chapter list maps to an empty result")
    func emptyInput() {
        #expect(Demuxer.chapterInfos(from: [], containerDuration: 300).isEmpty)
    }

    @Test("A single chapter is bounded by the container duration")
    func singleChapter() {
        let chapters = Demuxer.chapterInfos(from: [raw(0, 0, "Only")], containerDuration: 120)
        #expect(chapters.count == 1)
        #expect(chapters[0].startSeconds == 0)
        #expect(chapters[0].durationSeconds == 120)
    }
}
