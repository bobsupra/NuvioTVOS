import Testing
import Foundation
import CoreGraphics
@testable import AetherEngine

/// AE#266: an external subtitle URL can be a container holding several subtitle streams, and a host
/// registers one `ExternalSubtitleTrack` per stream against that same URL. Without an index every
/// track decoded the first subtitle stream and refetched the whole container.
@Suite("AE#266 external subtitle stream index")
struct Issue266ExternalSubtitleStreamIndexTests {

    // MARK: - Single-stream decode

    @Test("no index keeps decoding the first subtitle stream")
    func defaultPicksFirstSubtitleStream() async throws {
        try await MultiSubtitleContainerFixture.withFixture { url in
            let result = try await SubtitleDecoder.decodeFile(url: url)
            #expect(result.cues.compactMap(\.text) == MultiSubtitleContainerFixture.englishLines)
        }
    }

    @Test("an explicit index decodes that stream, not the first subtitle stream")
    func explicitIndexPicksRequestedStream() async throws {
        try await MultiSubtitleContainerFixture.withFixture { url in
            let result = try await SubtitleDecoder.decodeFile(
                url: url, sourceStreamIndex: MultiSubtitleContainerFixture.spanishStreamIndex)
            #expect(result.cues.compactMap(\.text) == MultiSubtitleContainerFixture.spanishLines)
        }
    }

    /// The fixture's first subtitle stream sits at AVStream index 1, so an ordinal-based reading of
    /// the same number would land on the Spanish stream instead.
    @Test("the index is an absolute AVStream index, not the Nth subtitle stream")
    func indexIsAbsoluteNotSubtitleOrdinal() async throws {
        try await MultiSubtitleContainerFixture.withFixture { url in
            let result = try await SubtitleDecoder.decodeFile(
                url: url, sourceStreamIndex: MultiSubtitleContainerFixture.englishStreamIndex)
            #expect(result.cues.compactMap(\.text) == MultiSubtitleContainerFixture.englishLines)
        }
    }

    @Test("a non-subtitle stream index is reported, never silently replaced by the first subtitle stream")
    func nonSubtitleIndexThrows() async throws {
        try await MultiSubtitleContainerFixture.withFixture { url in
            await expectStreamIndexError(
                index: MultiSubtitleContainerFixture.videoStreamIndex, url: url)
        }
    }

    @Test("an out-of-range stream index is reported")
    func outOfRangeIndexThrows() async throws {
        try await MultiSubtitleContainerFixture.withFixture { url in
            await expectStreamIndexError(index: 99, url: url)
        }
    }

    private func expectStreamIndexError(index: Int32, url: URL) async {
        do {
            _ = try await SubtitleDecoder.decodeFile(url: url, sourceStreamIndex: index)
            Issue.record("expected .streamIndexNotSubtitle for index \(index)")
        } catch let error as SubtitleDecoderError {
            guard case .streamIndexNotSubtitle(let reported) = error else {
                Issue.record("wrong error for index \(index): \(error)")
                return
            }
            #expect(reported == index)
        } catch {
            Issue.record("wrong error type for index \(index): \(error)")
        }
    }

    // MARK: - One-pass multi-stream decode

    /// The result is positional so a caller can map it back onto its own targets without having to
    /// resolve what a nil request turned into.
    @Test("several streams decode from a single container pass, each keeping its own cues")
    func multiStreamDecodeSeparatesStreams() async throws {
        try await MultiSubtitleContainerFixture.withFixture { url in
            let results = try await SubtitleDecoder.decodeFile(
                url: url,
                sourceStreamIndices: [MultiSubtitleContainerFixture.spanishStreamIndex,
                                      MultiSubtitleContainerFixture.englishStreamIndex])

            #expect(results.count == 2)
            #expect(results.first?.cues.compactMap(\.text) == MultiSubtitleContainerFixture.spanishLines)
            #expect(results.last?.cues.compactMap(\.text) == MultiSubtitleContainerFixture.englishLines)
            // Timing must stay per-stream too: the two streams are offset by 0.5 s in the fixture.
            #expect(results.first?.cues.first?.startTime == 1.5)
            #expect(results.last?.cues.first?.startTime == 1.0)
        }
    }

    @Test("a nil entry in a multi-stream request resolves to the first subtitle stream")
    func multiStreamDecodeResolvesNilToFirstSubtitleStream() async throws {
        try await MultiSubtitleContainerFixture.withFixture { url in
            let results = try await SubtitleDecoder.decodeFile(
                url: url, sourceStreamIndices: [nil, MultiSubtitleContainerFixture.spanishStreamIndex])
            #expect(results.count == 2)
            #expect(results.first?.cues.compactMap(\.text) == MultiSubtitleContainerFixture.englishLines)
            #expect(results.last?.cues.compactMap(\.text) == MultiSubtitleContainerFixture.spanishLines)
        }
    }

    /// Two targets on one stream must each get the cues, and the stream must still be decoded once.
    @Test("a repeated index yields the same cues at both positions")
    func multiStreamDecodeRepeatsSharedStream() async throws {
        try await MultiSubtitleContainerFixture.withFixture { url in
            let spanish = MultiSubtitleContainerFixture.spanishStreamIndex
            let results = try await SubtitleDecoder.decodeFile(
                url: url, sourceStreamIndices: [spanish, spanish])
            #expect(results.count == 2)
            #expect(results.first?.cues.compactMap(\.text) == MultiSubtitleContainerFixture.spanishLines)
            #expect(results.last?.cues.compactMap(\.text) == MultiSubtitleContainerFixture.spanishLines)
        }
    }

    @Test("an invalid index in a multi-stream request is reported, not skipped")
    func multiStreamDecodeReportsInvalidIndex() async throws {
        try await MultiSubtitleContainerFixture.withFixture { url in
            do {
                _ = try await SubtitleDecoder.decodeFile(
                    url: url,
                    sourceStreamIndices: [MultiSubtitleContainerFixture.spanishStreamIndex,
                                          MultiSubtitleContainerFixture.videoStreamIndex])
                Issue.record("expected .streamIndexNotSubtitle")
            } catch let error as SubtitleDecoderError {
                guard case .streamIndexNotSubtitle = error else {
                    Issue.record("wrong error: \(error)")
                    return
                }
            }
        }
    }

    // MARK: - Per-stream PlayRes

    /// The decode state a shared pass could accidentally share is not the header, it is the ASS
    /// PlayRes that `\pos` normalizes against. Both streams of this fixture carry the SAME
    /// `\pos(320,240)` under DIFFERENT declared resolutions, so one pinned PlayRes yields two equal
    /// positions. A header comparison passes either way, which is why it cannot stand in for this.
    @Test("each stream normalizes \\pos against its own declared PlayRes in a shared pass")
    func multiStreamDecodeKeepsPlayResPerStream() async throws {
        try await MultiASSPlayResFixture.withFixture { url in
            let results = try await SubtitleDecoder.decodeFile(
                url: url,
                sourceStreamIndices: [MultiASSPlayResFixture.englishStreamIndex,
                                      MultiASSPlayResFixture.spanishStreamIndex])

            #expect(results.count == 2)
            expectPosition(results.first?.cues.first?.placement?.position,
                           MultiASSPlayResFixture.englishPosition, "english")
            expectPosition(results.last?.cues.first?.placement?.position,
                           MultiASSPlayResFixture.spanishPosition, "spanish")
            // The cues are the right way round, and the tag really is identical in both scripts.
            #expect(results.first?.cues.compactMap(\.text) == MultiASSPlayResFixture.englishLines)
            #expect(results.last?.cues.compactMap(\.text) == MultiASSPlayResFixture.spanishLines)
            #expect(MultiASSPlayResFixture.englishPosition != MultiASSPlayResFixture.spanishPosition)
            // A placement belongs to the cue that asked for it: the second cue carries no \pos.
            #expect(results.first?.cues.last?.placement?.position == nil)
        }
    }

    /// The single-stream path resolves its own header too, rather than the container's first.
    @Test("a single-stream decode normalizes against the requested stream's PlayRes")
    func singleStreamDecodeUsesRequestedStreamPlayRes() async throws {
        try await MultiASSPlayResFixture.withFixture { url in
            let result = try await SubtitleDecoder.decodeFile(
                url: url, sourceStreamIndex: MultiASSPlayResFixture.spanishStreamIndex)
            expectPosition(result.cues.first?.placement?.position,
                           MultiASSPlayResFixture.spanishPosition, "spanish")
        }
    }

    /// The header stays per stream as well, which is the weaker property but the one a host reads
    /// off `TrackInfo.assHeader` when it renders the markup itself.
    @Test("preserved ASS headers stay per stream")
    func multiStreamDecodeKeepsHeaderPerStream() async throws {
        try await MultiASSPlayResFixture.withFixture { url in
            let results = try await SubtitleDecoder.decodeFile(
                url: url, preserveASSMarkup: true,
                sourceStreamIndices: [MultiASSPlayResFixture.englishStreamIndex,
                                      MultiASSPlayResFixture.spanishStreamIndex])

            #expect(results.first?.assHeader?.contains("PlayResX: 640") == true)
            #expect(results.last?.assHeader?.contains("PlayResX: 1920") == true)
        }
    }

    /// The same, through the production route: a fill job over a shared container writes each
    /// stream's normalized placement into its own store.
    @Test("a shared fill job keeps each store's placement on its own PlayRes")
    func fillRunKeepsPlayResPerTarget() async throws {
        try await MultiASSPlayResFixture.withFixture { url in
            let english = NativeSubtitleCueStore()
            let spanish = NativeSubtitleCueStore()
            let job = AetherEngine.ExternalSubtitleFillJob(
                url: url, headers: [:],
                targets: [.init(streamIndex: MultiASSPlayResFixture.englishStreamIndex, store: english),
                          .init(streamIndex: MultiASSPlayResFixture.spanishStreamIndex, store: spanish)])

            await AetherEngine.runExternalSubtitleFill(job: job)

            expectPosition(english.snapshotCues().first?.placement?.position,
                           MultiASSPlayResFixture.englishPosition, "english store")
            expectPosition(spanish.snapshotCues().first?.placement?.position,
                           MultiASSPlayResFixture.spanishPosition, "spanish store")
        }
    }

    private func expectPosition(_ actual: CGPoint?, _ expected: CGPoint, _ label: String) {
        guard let actual else {
            Issue.record("\(label): expected a \\pos placement, got none")
            return
        }
        #expect(abs(actual.x - expected.x) < 1e-6, "\(label) x: \(actual.x) vs \(expected.x)")
        #expect(abs(actual.y - expected.y) < 1e-6, "\(label) y: \(actual.y) vs \(expected.y)")
    }

    // MARK: - Track identity

    @Test("tracks differing only in stream index are distinct")
    func tracksDifferingInStreamIndexAreNotEqual() {
        let url = URL(string: "https://example.test/movie.mkv")!
        let first = ExternalSubtitleTrack(url: url, name: "English", sourceStreamIndex: 1)
        let second = ExternalSubtitleTrack(url: url, name: "English", sourceStreamIndex: 2)
        #expect(first != second)
    }

    // MARK: - Native store fill grouping

    @Test("tracks sharing a container are filled by one pass over that container")
    func fillJobsGroupTracksSharingAContainer() {
        let url = URL(string: "https://example.test/movie.mkv")!
        let registry: [Int: ExternalSubtitleTrack] = [
            100_000: ExternalSubtitleTrack(url: url, sourceStreamIndex: 1),
            100_001: ExternalSubtitleTrack(url: url, sourceStreamIndex: 2),
        ]
        let table = [
            AetherEngine.NativeSubtitleTrackEntry(sourceStreamIndex: nil, externalID: 100_000, language: "eng"),
            AetherEngine.NativeSubtitleTrackEntry(sourceStreamIndex: nil, externalID: 100_001, language: "spa"),
        ]
        let stores = [NativeSubtitleCueStore(), NativeSubtitleCueStore()]

        let jobs = AetherEngine.externalSubtitleFillJobs(
            table: table, registry: registry, stores: stores, defaultHeaders: [:])

        #expect(jobs.count == 1)
        #expect(jobs.first?.url == url)
        #expect(jobs.first?.targets.map(\.streamIndex) == [1, 2])
        #expect(jobs.first?.targets.first?.store === stores[0])
        #expect(jobs.first?.targets.last?.store === stores[1])
    }

    @Test("tracks on different containers stay separate passes")
    func fillJobsKeepDistinctContainersSeparate() {
        let first = URL(string: "https://example.test/a.mkv")!
        let second = URL(string: "https://example.test/b.srt")!
        let registry: [Int: ExternalSubtitleTrack] = [
            100_000: ExternalSubtitleTrack(url: first, sourceStreamIndex: 2),
            100_001: ExternalSubtitleTrack(url: second),
        ]
        let table = [
            AetherEngine.NativeSubtitleTrackEntry(sourceStreamIndex: nil, externalID: 100_000, language: "eng"),
            AetherEngine.NativeSubtitleTrackEntry(sourceStreamIndex: nil, externalID: 100_001, language: "spa"),
        ]
        let stores = [NativeSubtitleCueStore(), NativeSubtitleCueStore()]

        let jobs = AetherEngine.externalSubtitleFillJobs(
            table: table, registry: registry, stores: stores, defaultHeaders: [:])

        #expect(jobs.count == 2)
        #expect(jobs.map(\.url) == [first, second])
        #expect(jobs.first?.targets.map(\.streamIndex) == [2])
        #expect(jobs.last?.targets.map(\.streamIndex) == [nil])
    }

    /// Differing auth headers mean differing requests, so they must not collapse into one pass.
    @Test("same container with different headers stays two passes")
    func fillJobsKeepDifferingHeadersSeparate() {
        let url = URL(string: "https://example.test/movie.mkv")!
        let registry: [Int: ExternalSubtitleTrack] = [
            100_000: ExternalSubtitleTrack(url: url, httpHeaders: ["X-Token": "a"], sourceStreamIndex: 1),
            100_001: ExternalSubtitleTrack(url: url, httpHeaders: ["X-Token": "b"], sourceStreamIndex: 2),
        ]
        let table = [
            AetherEngine.NativeSubtitleTrackEntry(sourceStreamIndex: nil, externalID: 100_000, language: "eng"),
            AetherEngine.NativeSubtitleTrackEntry(sourceStreamIndex: nil, externalID: 100_001, language: "spa"),
        ]
        let stores = [NativeSubtitleCueStore(), NativeSubtitleCueStore()]

        let jobs = AetherEngine.externalSubtitleFillJobs(
            table: table, registry: registry, stores: stores, defaultHeaders: [:])

        #expect(jobs.count == 2)
    }

    // MARK: - Running a fill job

    @Test("one pass fills every store of a shared container")
    func fillRunFillsAllTargets() async throws {
        try await MultiSubtitleContainerFixture.withFixture { url in
            let english = NativeSubtitleCueStore()
            let spanish = NativeSubtitleCueStore()
            let job = AetherEngine.ExternalSubtitleFillJob(
                url: url, headers: [:],
                targets: [.init(streamIndex: MultiSubtitleContainerFixture.englishStreamIndex, store: english),
                          .init(streamIndex: MultiSubtitleContainerFixture.spanishStreamIndex, store: spanish)])

            await AetherEngine.runExternalSubtitleFill(job: job)

            #expect(english.snapshotCues().compactMap(\.text) == MultiSubtitleContainerFixture.englishLines)
            #expect(spanish.snapshotCues().compactMap(\.text) == MultiSubtitleContainerFixture.spanishLines)
            #expect(english.isFinished)
            #expect(spanish.isFinished)
        }
    }

    /// One host-side index mistake must not cost the container's other tracks their cues, which is
    /// what a single failing pass would do.
    @Test("a bad index in a shared container leaves the other targets filled")
    func fillRunSurvivesOneBadIndex() async throws {
        try await MultiSubtitleContainerFixture.withFixture { url in
            let good = NativeSubtitleCueStore()
            let bad = NativeSubtitleCueStore()
            let job = AetherEngine.ExternalSubtitleFillJob(
                url: url, headers: [:],
                targets: [.init(streamIndex: MultiSubtitleContainerFixture.spanishStreamIndex, store: good),
                          .init(streamIndex: MultiSubtitleContainerFixture.videoStreamIndex, store: bad)])

            await AetherEngine.runExternalSubtitleFill(job: job)

            #expect(good.snapshotCues().compactMap(\.text) == MultiSubtitleContainerFixture.spanishLines)
            #expect(good.isFinished)
            // An unfilled store must stay unfinished: a finished empty store would serve a complete
            // but blank WebVTT rendition.
            #expect(bad.snapshotCues().isEmpty)
            #expect(!bad.isFinished)
        }
    }

    /// Two registrations of the same stream must both get their store filled, not be deduplicated.
    @Test("duplicate registrations of one stream each receive the cues")
    func fillJobsKeepDuplicateTargets() {
        let url = URL(string: "https://example.test/movie.mkv")!
        let registry: [Int: ExternalSubtitleTrack] = [
            100_000: ExternalSubtitleTrack(url: url, sourceStreamIndex: 2),
            100_001: ExternalSubtitleTrack(url: url, sourceStreamIndex: 2),
        ]
        let table = [
            AetherEngine.NativeSubtitleTrackEntry(sourceStreamIndex: nil, externalID: 100_000, language: "eng"),
            AetherEngine.NativeSubtitleTrackEntry(sourceStreamIndex: nil, externalID: 100_001, language: "spa"),
        ]
        let stores = [NativeSubtitleCueStore(), NativeSubtitleCueStore()]

        let jobs = AetherEngine.externalSubtitleFillJobs(
            table: table, registry: registry, stores: stores, defaultHeaders: [:])

        #expect(jobs.count == 1)
        #expect(jobs.first?.targets.count == 2)
    }
}
