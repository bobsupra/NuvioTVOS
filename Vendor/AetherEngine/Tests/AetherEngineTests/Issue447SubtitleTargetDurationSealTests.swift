// Tests/AetherEngineTests/Issue447SubtitleTargetDurationSealTests.swift
// AE#447 follow-up: a subtitle rendition is a Media Playlist, so RFC 8216 forbids its TARGETDURATION
// to change for its lifetime just as firmly as the video one's. The rendition builder rebuilt the
// derivation by hand and read the live cadence floor on every render, so a floor that rose mid-session
// (which is what a floor is for) moved the served value. AE#209 measured what that costs on the video
// playlist: readyToPlay, a first frame, and then waitingToPlay at time zero for the rest of the session.
import Testing
import Foundation
@testable import AetherEngine

/// Says one thing through the sealed accessor and a contradicting thing through the raw floor, so a
/// builder that rebuilds the derivation cannot pass by arriving at the same number by accident.
private final class SentinelSealProvider: HLSSegmentProvider, @unchecked Sendable {
    func initSegment() -> Data? { Data([0x00]) }
    func mediaSegment(at index: Int) -> Data? { Data([0x00]) }
    var segmentCount: Int { 6 }
    func segmentDuration(at index: Int) -> Double { 4.0 }
    var playlistType: HLSPlaylistType { .live }
    var liveTargetSegmentDuration: Double? { 4.0 }
    var liveTargetDurationFloorSeconds: Double? { 20.0 }
    func liveTargetDurationSeconds(maxSegmentDuration: Double) -> Int { 7 }
    func nativeSubtitleVTT(ordinal: Int, segmentIndex: Int) -> String? { "WEBVTT\n" }
    var nativeSubtitleRenditions: [(ordinal: Int, language: String?, name: String, isForced: Bool)] {
        [(0, "en", "English", false)]
    }
    func notePlaylistBuild() -> (visibleCount: Int, firstVisible: Int, refreshCounter: Int,
                                 endlistAdded: Bool, discontinuitySequence: Int) {
        (6, 0, 1, false, 0)
    }
}

private final class ScriptedFloor: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Double?
    var value: Double? {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}

@Suite("AE#447 subtitle rendition TARGETDURATION seal")
struct Issue447SubtitleTargetDurationSealTests {

    private func targetDuration(_ playlist: String) -> Int? {
        playlist.split(separator: "\n")
            .first { $0.hasPrefix("#EXT-X-TARGETDURATION:") }
            .flatMap { Int($0.dropFirst("#EXT-X-TARGETDURATION:".count)) }
    }

    @Test("the rendition serves the sealed value, not a rebuilt one")
    func renditionReadsTheSeal() {
        let provider = SentinelSealProvider()
        let subs = HLSLocalServer.buildSubtitleMediaPlaylistText(ordinal: 0, provider: provider)
        #expect(targetDuration(subs) == 7)
        #expect(targetDuration(subs) == targetDuration(HLSLocalServer.buildMediaPlaylistText(provider: provider)))
    }

    @Test("a cadence floor that rises mid-session does not move the rendition")
    func renditionDoesNotDriftWithTheFloor() {
        let floor = ScriptedFloor()
        floor.value = 0.9
        let cache = SegmentCache(forwardWindow: 10, backwardWindow: 10)
        defer { cache.close() }
        let provider = VideoSegmentProvider(
            cache: cache,
            segments: [],
            codecsString: "avc1.64002A,mp4a.40.2",
            supplementalCodecs: nil,
            resolution: (1920, 1080),
            videoRange: .sdr,
            frameRate: 50,
            hdcpLevel: nil,
            sourceBitrate: 6_000_000,
            isLive: true,
            liveWindowSizing: LiveWindowSizing(targetSegmentDurationSeconds: 0.5, dvrWindowSeconds: nil),
            liveCadencePolicy: LiveCadencePolicy(
                observe: { floor.value },
                cutTargetSeconds: 0.5,
                observeSealEvidence: { LiveCadenceEvidence(closedCadenceSeconds: floor.value,
                                                           servedSegmentDurationSeconds: nil) },
                clock: { 0 }
            )
        )
        for i in 0..<6 {
            provider.appendLiveSegment(index: i, startSeconds: Double(i) * 0.9, durationSeconds: 0.9)
        }

        let videoBefore = targetDuration(HLSLocalServer.buildMediaPlaylistText(provider: provider))
        let subsBefore = targetDuration(HLSLocalServer.buildSubtitleMediaPlaylistText(ordinal: 0, provider: provider))
        #expect(videoBefore == subsBefore)

        // The floor does what a floor does: a batch arrives late and it widens. The video playlist is
        // sealed against exactly this, and the rendition rode along on the raw value.
        floor.value = 30.0
        let videoAfter = targetDuration(HLSLocalServer.buildMediaPlaylistText(provider: provider))
        let subsAfter = targetDuration(HLSLocalServer.buildSubtitleMediaPlaylistText(ordinal: 0, provider: provider))
        #expect(videoAfter == videoBefore)
        #expect(subsAfter == subsBefore)
    }
}
