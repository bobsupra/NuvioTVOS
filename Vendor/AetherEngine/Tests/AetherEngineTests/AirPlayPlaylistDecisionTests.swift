import Foundation
import Testing
@testable import AetherEngine

struct AirPlayPlaylistDecisionTests {

    @Test("#227: an SDR source keeps its master, so its subtitle renditions travel")
    func sdrKeepsMaster() {
        #expect(AirPlayPlaylistDecision.playlistForReceiver(
            servingMasterPlaylist: true, sourceIsHDR: false) == .master)
    }

    @Test("#227: an HDR source is offered the master; a receiver in HDR mode can take it")
    func hdrIsOfferedTheMaster() {
        #expect(AirPlayPlaylistDecision.playlistForReceiver(
            servingMasterPlaylist: true, sourceIsHDR: true) == .master)
    }

    @Test("#227: a receiver that already refused an HDR master is not made to wait again")
    func refusingReceiverGoesStraightToMedia() {
        #expect(AirPlayPlaylistDecision.playlistForReceiver(
            servingMasterPlaylist: true, sourceIsHDR: true, receiverRefusedHDRMaster: true) == .media)
        // The memory is about HDR only; an SDR master was never the problem.
        #expect(AirPlayPlaylistDecision.playlistForReceiver(
            servingMasterPlaylist: true, sourceIsHDR: false, receiverRefusedHDRMaster: true) == .master)
    }

    @Test("A session already on the media playlist has no master to hand over")
    func mediaSessionStaysMedia() {
        #expect(AirPlayPlaylistDecision.playlistForReceiver(
            servingMasterPlaylist: false, sourceIsHDR: false) == .media)
        #expect(AirPlayPlaylistDecision.playlistForReceiver(
            servingMasterPlaylist: false, sourceIsHDR: true) == .media)
    }

    @Test("Only the media playlist is without subtitle renditions")
    func renditionCarriers() {
        #expect(AirPlayPlaylistDecision.carriesSubtitleRenditions(.master))
        #expect(!AirPlayPlaylistDecision.carriesSubtitleRenditions(.media))
    }

    @Test("#86: the rewrite swaps the loopback host for the LAN IP and keeps the port")
    func rewritesHostKeepsPort() throws {
        let base = try #require(URL(string: "http://127.0.0.1:52341/master.m3u8"))
        let url = try #require(AirPlayPlaylistDecision.receiverURL(
            base: base, lanIP: "192.168.8.166", playlist: .master))
        #expect(url.absoluteString == "http://192.168.8.166:52341/master.m3u8")
    }

    @Test("#227: the media choice forces the media path")
    func mediaChoiceForcesPath() throws {
        let base = try #require(URL(string: "http://127.0.0.1:52341/master.m3u8"))
        let media = try #require(AirPlayPlaylistDecision.receiverURL(
            base: base, lanIP: "192.168.8.166", playlist: .media))
        #expect(media.absoluteString == "http://192.168.8.166:52341/media.m3u8")
    }

    @Test("#227: rewriting the media URL again (the fallback path) is idempotent")
    func mediaRewriteIsIdempotent() throws {
        let base = try #require(URL(string: "http://127.0.0.1:52341/media.m3u8"))
        let url = try #require(AirPlayPlaylistDecision.receiverURL(
            base: base, lanIP: "192.168.8.166", playlist: .media))
        #expect(url.absoluteString == "http://192.168.8.166:52341/media.m3u8")
    }
}
