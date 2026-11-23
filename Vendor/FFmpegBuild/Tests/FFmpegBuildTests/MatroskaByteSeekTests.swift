import Foundation
import Testing
import AetherLibavformat
import AetherLibavutil

/// Proves the matroska byte seek patch (build.sh `patch_ffmpeg_matroska_byte_seek_done`,
/// patches/matroska-byte-seek-done.patch) is in the shipped libavformat.
///
/// matroskadec latches end of stream in its private `done` flag and only its own read_seek
/// cleared it, so after a byte seek every read returned EOF once the file had been read to its
/// end or a read had failed (AetherEngine issue 944: a subtitle side reader read EOF at second 0
/// of an 888 s file). Stock n8.1.3 reads no packets after the seek below.
struct MatroskaByteSeekTests {

    @Test("a byte seek after end of stream reads the file again")
    func byteSeekAfterEndOfStream() throws {
        let data = try #require(Data(base64Encoded: MatroskaSkipAttachmentsTests.frontLayout,
                                     options: .ignoreUnknownCharacters))
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("mkv-byte-seek-\(UUID().uuidString).mkv").path
        try data.write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }

        var ctxIn: UnsafeMutablePointer<AVFormatContext>?
        try #require(avformat_open_input(&ctxIn, path, nil, nil) == 0)
        let ctx = try #require(ctxIn)
        defer { avformat_close_input(&ctxIn) }
        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }

        func drain() -> Int {
            var packets = 0
            while av_read_frame(ctx, packet) >= 0 {
                packets += 1
                av_packet_unref(packet)
            }
            return packets
        }

        #expect(drain() == 2)
        #expect(av_seek_frame(ctx, -1, 0, AVSEEK_FLAG_BYTE) >= 0)
        #expect(drain() == 2, "the end of stream reached before the seek must not outlive it")
    }
}
