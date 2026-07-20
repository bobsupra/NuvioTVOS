import Testing
import Foundation
import AetherLibavutil
import AetherLibavformat
@testable import AetherEngine

// #75: a remote MP4 with an embedded cover-art stream (mjpeg, unresolvable 0x0) made
// avformat_find_stream_info read to the full probe budget (tens of MB) chasing codec
// parameters that never resolve, dominating remote open. The fix reclassifies attached-picture
// streams to AVMEDIA_TYPE_ATTACHMENT before find_stream_info, so has_codec_parameters resolves
// them immediately and the probe stops once the real streams are known. Cover extraction is
// disposition-based and unaffected.
@Suite("Demuxer attached-picture probe handling")
struct AttachedPictureProbeTests {

    @Test("isAttachedPicture only matches the ATTACHED_PIC disposition bit")
    func predicate() {
        #expect(Demuxer.isAttachedPicture(disposition: 0) == false)
        #expect(Demuxer.isAttachedPicture(disposition: AV_DISPOSITION_ATTACHED_PIC) == true)
        #expect(Demuxer.isAttachedPicture(disposition: AV_DISPOSITION_DEFAULT) == false)
        // attached_pic combined with another flag still matches.
        #expect(Demuxer.isAttachedPicture(
            disposition: AV_DISPOSITION_ATTACHED_PIC | AV_DISPOSITION_DEFAULT) == true)
    }

    // Minimal MP4 (faststart): stream 0 = H.264 32x32, stream 1 = mjpeg 1x1 attached_pic cover.
    private static let coverMP4Base64 = """
    AAAAIGZ0eXBpc29tAAACAGlzb21pc28yYXZjMW1wNDEAAAQMbW9vdgAAAGxtdmhkAAAAAAAAAAAA
    AAAAAAAD6AAAAGQAAQAAAQAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAA
    AABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAAj90cmFrAAAAXHRraGQAAAADAAAA
    AAAAAAAAAAABAAAAAAAAAGQAAAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAA
    AAAAAAAAAABAAAAAACAAAAAgAAAAAAAkZWR0cwAAABxlbHN0AAAAAAAAAAEAAABkAAAAAAABAAAA
    AAG3bWRpYQAAACBtZGhkAAAAAAAAAAAAAAAAAAAoAAAABABVxAAAAAAALWhkbHIAAAAAAAAAAHZp
    ZGUAAAAAAAAAAAAAAABWaWRlb0hhbmRsZXIAAAABYm1pbmYAAAAUdm1oZAAAAAEAAAAAAAAAAAAA
    ACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAAAQAAASJzdGJsAAAAvnN0c2QAAAAAAAAA
    AQAAAK5hdmMxAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAACAAIABIAAAASAAAAAAAAAABFUxhdmM2
    Mi4yOC4xMDEgbGlieDI2NAAAAAAAAAAAAAAAGP//AAAANGF2Y0MBZAAK/+EAF2dkAAqs2UlsBEAA
    AAMAQAAABQPEiWWAAQAGaOvjyyLA/fj4AAAAABBwYXNwAAAAAQAAAAEAAAAUYnRydAAAAAAAAOEA
    AADhAAAAABhzdHRzAAAAAAAAAAEAAAABAAAEAAAAABxzdHNjAAAAAAAAAAEAAAABAAAAAQAAAAEA
    AAAUc3RzegAAAAAAAALQAAAAAQAAABRzdGNvAAAAAAAAAAEAAAQ8AAABWXVkdGEAAAFRbWV0YQAA
    AAAAAAAhaGRscgAAAAAAAAAAbWRpcmFwcGwAAAAAAAAAAAAAAAEkaWxzdAAAACWpdG9vAAAAHWRh
    dGEAAAABAAAAAExhdmY2Mi4xMi4xMDEAAAD3Y292cgAAAO9kYXRhAAAADQAAAAD/2P/gABBKRklG
    AAECAAABAAEAAP/+ABBMYXZjNjIuMjguMTAxAP/bAEMACAQEBAQEBQUFBQUFBgYGBgYGBgYGBgYG
    BgcHBwgICAcHBwYGBwcICAgICQkJCAgICAkJCgoKDAwLCw4ODhERFP/EAEsAAQEAAAAAAAAAAAAA
    AAAAAAAGAQEAAAAAAAAAAAAAAAAAAAAGEAEAAAAAAAAAAAAAAAAAAAAAEQEAAAAAAAAAAAAAAAAA
    AAAA/8AAEQgAAQABAwEiAAIRAAMRAP/aAAwDAQACEQMRAD8AiwBQJf/ZAAAACGZyZWUAAALYbWRh
    dAAAAq4GBf//qtxF6b3m2Ui3lizYINkj7u94MjY0IC0gY29yZSAxNjUgcjMyMjIgYjM1NjA1YSAt
    IEguMjY0L01QRUctNCBBVkMgY29kZWMgLSBDb3B5bGVmdCAyMDAzLTIwMjUgLSBodHRwOi8vd3d3
    LnZpZGVvbGFuLm9yZy94MjY0Lmh0bWwgLSBvcHRpb25zOiBjYWJhYz0xIHJlZj0zIGRlYmxvY2s9
    MTowOjAgYW5hbHlzZT0weDM6MHgxMTMgbWU9aGV4IHN1Ym1lPTcgcHN5PTEgcHN5X3JkPTEuMDA6
    MC4wMCBtaXhlZF9yZWY9MSBtZV9yYW5nZT0xNiBjaHJvbWFfbWU9MSB0cmVsbGlzPTEgOHg4ZGN0
    PTEgY3FtPTAgZGVhZHpvbmU9MjEsMTEgZmFzdF9wc2tpcD0xIGNocm9tYV9xcF9vZmZzZXQ9LTIg
    dGhyZWFkcz0xIGxvb2thaGVhZF90aHJlYWRzPTEgc2xpY2VkX3RocmVhZHM9MCBucj0wIGRlY2lt
    YXRlPTEgaW50ZXJsYWNlZD0wIGJsdXJheV9jb21wYXQ9MCBjb25zdHJhaW5lZF9pbnRyYT0wIGJm
    cmFtZXM9MyBiX3B5cmFtaWQ9MiBiX2FkYXB0PTEgYl9iaWFzPTAgZGlyZWN0PTEgd2VpZ2h0Yj0x
    IG9wZW5fZ29wPTAgd2VpZ2h0cD0yIGtleWludD0yNTAga2V5aW50X21pbj0xMCBzY2VuZWN1dD00
    MCBpbnRyYV9yZWZyZXNoPTAgcmNfbG9va2FoZWFkPTQwIHJjPWNyZiBtYnRyZWU9MSBjcmY9MjMu
    MCBxY29tcD0wLjYwIHFwbWluPTAgcXBtYXg9NjkgcXBzdGVwPTQgaXBfcmF0aW89MS40MCBhcT0x
    OjEuMDAAgAAAABpliIQAN//+4QP4FNdN/mOPQ9kBaFXLXBbT+Q==
    """

    @Test("Cover-art stream is reclassified, real video resolves, cover stays extractable")
    func reclassifiesCoverAndKeepsRealStreams() throws {
        let data = Data(base64Encoded: Self.coverMP4Base64, options: .ignoreUnknownCharacters)
        let mp4 = try #require(data)
        let demuxer = Demuxer()
        try demuxer.open(reader: DataIOReader(data: mp4))
        defer { demuxer.close() }

        // The fix ran and reclassified exactly the one attached-picture (cover) stream.
        #expect(demuxer.attachedPictureStreamsReclassified == 1)

        // The real video stream still resolves to full codec parameters.
        #expect(demuxer.videoStreamIndex == 0)
        #expect(demuxer.stream(at: 0)?.pointee.codecpar?.pointee.width == 32)
        #expect(demuxer.stream(at: 0)?.pointee.codecpar?.pointee.height == 32)

        // Cover art is disposition-based and survives the reclassification.
        #expect(demuxer.mediaMetadata().artworkData != nil)
    }
}
