import Foundation
import Testing
@testable import AetherEngine

/// AE#446 round 2: a live window whose source has stopped delivering is served as a finished asset.
///
/// The reason is measured rather than argued (see `VideoSegmentProvider.liveOutageEndlist`): AVPlayer
/// decides "unchanged playlist" from the TAIL, so neither a byte-distinct refresh tag nor a sliding
/// MEDIA-SEQUENCE keeps it fetching, and once it strikes out it abandons segments it never downloaded
/// and that the playlist still lists. ENDLIST is what it acts on.
private final class ScriptedOutageProvider: HLSSegmentProvider, @unchecked Sendable {
    var count: Int
    var firstVisible: Int
    var outage: Bool
    var refresh = 0

    init(count: Int, firstVisible: Int = 0, outage: Bool = false) {
        self.count = count
        self.firstVisible = firstVisible
        self.outage = outage
    }

    func initSegment() -> Data? { Data([0x00]) }
    func mediaSegment(at index: Int) -> Data? { Data([0x00]) }
    var segmentCount: Int { count }
    func segmentDuration(at index: Int) -> Double { 4.0 }
    var playlistType: HLSPlaylistType { .live }
    var liveTargetSegmentDuration: Double? { 4.0 }
    var liveOutageEndlist: Bool { outage }
    func nativeSubtitleVTT(ordinal: Int, segmentIndex: Int) -> String? { "WEBVTT\n" }
    var nativeSubtitleRenditions: [(ordinal: Int, language: String?, name: String, isForced: Bool)] {
        [(0, "en", "English", false)]
    }
    func notePlaylistBuild() -> (visibleCount: Int, firstVisible: Int, refreshCounter: Int,
                                 endlistAdded: Bool, discontinuitySequence: Int) {
        refresh += 1
        return (count, firstVisible, refresh, false, 0)
    }
}

@Suite("AE#446 outage ENDLIST")
struct Issue446OutageEndlistTests {

    private func lines(_ playlist: String) -> [String] {
        playlist.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    @Test("a delivering source keeps an open live playlist")
    func healthySourceStaysOpen() {
        let provider = ScriptedOutageProvider(count: 20)
        let ls = lines(HLSLocalServer.buildMediaPlaylistText(provider: provider))
        #expect(!ls.contains("#EXT-X-ENDLIST"))
        #expect(ls.contains { $0.hasPrefix("#EXT-X-SERVER-CONTROL:") })
        #expect(ls.contains { $0.hasPrefix("#EXT-X-SODALITE-REFRESH:") })
    }

    @Test("a stopped source closes the window it still holds")
    func outageClosesTheWindow() {
        let provider = ScriptedOutageProvider(count: 20, firstVisible: 3, outage: true)
        let ls = lines(HLSLocalServer.buildMediaPlaylistText(provider: provider))
        #expect(ls.last == "#EXT-X-ENDLIST")
        // Every segment the viewer has not reached yet is still listed: closing the window is what
        // lets them be fetched, not a reason to withhold them.
        #expect(ls.filter { $0.hasPrefix("#EXTINF:") }.count == 17)
        #expect(ls.contains("seg19.mp4"))
        // The window's own numbering survives, so the seam is the tag and nothing else.
        #expect(ls.contains("#EXT-X-MEDIA-SEQUENCE:3"))
        #expect(ls.contains("#EXT-X-DISCONTINUITY-SEQUENCE:0"))
    }

    @Test("a closed window advertises no blocking reload and claims no type")
    func outageDropsServerControl() {
        let provider = ScriptedOutageProvider(count: 8, outage: true)
        let ls = lines(HLSLocalServer.buildMediaPlaylistText(provider: provider))
        // A hold that can never be satisfied is what #446 was opened for.
        #expect(!ls.contains { $0.hasPrefix("#EXT-X-SERVER-CONTROL:") })
        // VOD would be a claim about the asset; the source may still come back.
        #expect(!ls.contains { $0.hasPrefix("#EXT-X-PLAYLIST-TYPE") })
        // Nothing left to keep distinct once the client stops polling.
        #expect(!ls.contains { $0.hasPrefix("#EXT-X-SODALITE-REFRESH:") })
    }

    @Test("a subtitle rendition ends with the video it belongs to")
    func subtitleRenditionEndsToo() {
        let live = ScriptedOutageProvider(count: 8)
        #expect(!lines(HLSLocalServer.buildSubtitleMediaPlaylistText(ordinal: 0, provider: live))
            .contains("#EXT-X-ENDLIST"))

        let closed = ScriptedOutageProvider(count: 8, outage: true)
        let ls = lines(HLSLocalServer.buildSubtitleMediaPlaylistText(ordinal: 0, provider: closed))
        #expect(ls.last == "#EXT-X-ENDLIST")
        #expect(ls.filter { $0.hasPrefix("#EXTINF:") }.count == 8)
    }

    @Test("the TARGETDURATION a closed window serves is still the live one")
    func outageKeepsLiveTargetDuration() {
        let live = ScriptedOutageProvider(count: 8)
        let closed = ScriptedOutageProvider(count: 8, outage: true)
        let td: (HLSSegmentProvider) -> String? = { p in
            self.lines(HLSLocalServer.buildMediaPlaylistText(provider: p))
                .first { $0.hasPrefix("#EXT-X-TARGETDURATION:") }
        }
        // RFC 8216 requires it constant for the lifetime of a playlist, and the seam is mid-lifetime.
        #expect(td(live) == td(closed))
    }
}
