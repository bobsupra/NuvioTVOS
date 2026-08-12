import Testing
import Foundation
@testable import AetherEngine

/// A sequential-origin session serves its media playlist append-only with the durations actually
/// muxed (#346). These pin the provider -> playlist-builder half of that: which segments become
/// visible, when ENDLIST lands, and that the zero-duration hole a long GOP leaves in the plan is
/// omitted from the rendered playlist WITHOUT that omission leaking onto the live path, where a
/// dropped URI would shift every later segment's implicit media sequence number - the number a
/// blocking reload (?_HLS_msn=) resolves against.
@Suite("Sequential append playlist")
struct SequentialAppendPlaylistTests {

    private func segments(_ n: Int) -> [HLSVideoEngine.Segment] {
        (0..<n).map { i in
            HLSVideoEngine.Segment(startPts: Int64(i) * 4000, endPts: Int64(i + 1) * 4000,
                                   startSeconds: Double(i) * 4.0, durationSeconds: 4.0)
        }
    }

    private func makeProvider(planCount: Int = 10) -> VideoSegmentProvider {
        VideoSegmentProvider(
            cache: SegmentCache(forwardWindow: 60, backwardWindow: 60),
            segments: segments(planCount),
            codecsString: "avc1.64002A,mp4a.40.2",
            supplementalCodecs: nil,
            resolution: (1920, 1080),
            videoRange: .sdr,
            frameRate: 50,
            hdcpLevel: nil,
            sourceBitrate: 6_000_000,
            isLive: false,
            sequentialAppendPlaylist: true
        )
    }

    private func extinfValues(_ playlist: String) -> [String] {
        playlist.split(separator: "\n").compactMap { line in
            line.hasPrefix("#EXTINF:") ? String(line.dropFirst(8).dropLast()) : nil
        }
    }

    private func segmentURIs(_ playlist: String) -> [String] {
        playlist.split(separator: "\n").filter { $0.hasPrefix("seg") }.map(String.init)
    }

    @Test("only finalized segments are visible, each with its muxed duration")
    func onlyFinalizedSegmentsAreServed() {
        let provider = makeProvider()
        // A 1.92 s-GOP archive against a 4 s cut target: real spans, not the plan's uniform 4.000.
        provider.appendSequentialSegmentDuration(index: 0, durationSeconds: 3.84)
        provider.appendSequentialSegmentDuration(index: 1, durationSeconds: 5.76)

        let playlist = HLSLocalServer.buildMediaPlaylistText(provider: provider)

        #expect(extinfValues(playlist) == ["3.840", "5.760"],
                "the playlist must advertise what was muxed, not the static plan")
        #expect(segmentURIs(playlist) == ["seg0.mp4", "seg1.mp4"],
                "segments the producer has not finalized must not be listed")
        #expect(playlist.contains("#EXT-X-PLAYLIST-TYPE:EVENT"))
        #expect(!playlist.contains("#EXT-X-ENDLIST"),
                "a growing playlist must not claim to be complete")
    }

    @Test("true source EOF completes the playlist")
    func endOfSourceAddsEndlist() {
        let provider = makeProvider()
        provider.appendSequentialSegmentDuration(index: 0, durationSeconds: 3.84)
        provider.markSequentialEnded()

        let playlist = HLSLocalServer.buildMediaPlaylistText(provider: provider)

        #expect(playlist.contains("#EXT-X-ENDLIST"),
                "without ENDLIST an EVENT playlist never reaches end-of-media")
    }

    @Test("a zero-duration hole is omitted from the playlist but keeps the later indices")
    func zeroDurationHoleIsOmitted() {
        let provider = makeProvider()
        // Index 1 is a plan index a long GOP skipped outright: reported as a hole, no media file.
        provider.appendSequentialSegmentDuration(index: 0, durationSeconds: 3.84)
        provider.appendSequentialSegmentDuration(index: 1, durationSeconds: 0)
        provider.appendSequentialSegmentDuration(index: 2, durationSeconds: 5.76)

        let playlist = HLSLocalServer.buildMediaPlaylistText(provider: provider)

        #expect(!playlist.contains("#EXTINF:0.000,"),
                "a hole has no media file; advertising it would 404 the fetch")
        #expect(segmentURIs(playlist) == ["seg0.mp4", "seg2.mp4"],
                "the surviving segments keep their own indices, the hole is simply absent")
        #expect(extinfValues(playlist) == ["3.840", "5.760"])
    }

    @Test("an out-of-order append is refused rather than silently reindexed")
    func outOfOrderAppendIgnored() {
        let provider = makeProvider()
        provider.appendSequentialSegmentDuration(index: 0, durationSeconds: 3.84)
        provider.appendSequentialSegmentDuration(index: 5, durationSeconds: 4.0)

        let playlist = HLSLocalServer.buildMediaPlaylistText(provider: provider)

        #expect(segmentURIs(playlist) == ["seg0.mp4"],
                "index 5 is not segment 1; accepting it would misalign every later EXTINF")
    }

    @Test("the plan bounds the visible count")
    func planBoundsVisibleCount() {
        let provider = makeProvider(planCount: 2)
        for i in 0..<4 { provider.appendSequentialSegmentDuration(index: i, durationSeconds: 4.0) }

        let playlist = HLSLocalServer.buildMediaPlaylistText(provider: provider)

        #expect(segmentURIs(playlist) == ["seg0.mp4", "seg1.mp4"],
                "a source running past its declared window must not outgrow the asset")
    }

    // MARK: - Blast radius

    /// Live playlists must render exactly as before. Their segment URIs carry the media sequence
    /// implicitly (position + EXT-X-MEDIA-SEQUENCE), so dropping one renumbers the rest.
    private final class ZeroDurationLiveProvider: HLSSegmentProvider, @unchecked Sendable {
        func initSegment() -> Data? { Data([0x00]) }
        func mediaSegment(at index: Int) -> Data? { Data([0x00]) }
        var segmentCount: Int { 3 }
        func segmentDuration(at index: Int) -> Double { index == 1 ? 0 : 4.0 }
        func segmentIsDiscontinuous(at index: Int) -> Bool { false }
        var playlistType: HLSPlaylistType { .live }
    }

    @Test("a zero duration on the live path is still rendered, not skipped")
    func liveKeepsZeroDurationEntries() {
        let playlist = HLSLocalServer.buildMediaPlaylistText(provider: ZeroDurationLiveProvider())

        #expect(segmentURIs(playlist) == ["seg0.mp4", "seg1.mp4", "seg2.mp4"],
                "omitting a live URI shifts the media sequence a blocking reload resolves against")
        #expect(extinfValues(playlist) == ["4.000", "0.000", "4.000"])
    }
}
