import Testing
import Foundation
@testable import AetherEngine

/// `LoadOptions.sequentialOrigin`: origins that fabricate range answers (IPTV timeshift archives
/// answer any `Range: bytes=X-` with a plausible 206 whose body actually sits on a coarse internal
/// chunk boundary; ~1.9 s of content vanished at every 32 MB range rotation, heard as a
/// once-a-minute audio desync). Headers cannot expose the lie, so the caller declares it and the
/// reader must run ONE unranged GET from byte 0 - no bounded-range windowing, no suffix/tail
/// probe, no size probe, no detour fills - and must report a lost connection as EIO, never EOF
/// (the consumer treats EOF as played-to-the-end and deliberately never retries it).
@Suite("Sequential-origin reader")
struct SequentialOriginReaderTests {

    private func drain(_ reader: AVIOReader, upTo target: Int64, chunk: Int = 256 * 1024) -> (read: Int64, lastReturn: Int32) {
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { buf.deallocate() }
        var read: Int64 = 0
        var last: Int32 = 0
        while read < target {
            last = reader.read(into: buf, size: Int32(chunk))
            if last <= 0 { break }
            read += Int64(last)
        }
        return (read, last)
    }

    @Test("one unranged request serves a read well past the 32 MB rotation point")
    func singleUnrangedConnection() throws {
        let total: Int64 = 40 * 1024 * 1024
        let server = try #require(ThrottledOriginServer(totalSize: total, throttleUs: 500))
        defer { server.stop() }
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/archive.ts")!,
                                sequentialOnly: true)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        // Read past where the persistent reader would have rotated its first 32 MB range.
        let (read, _) = drain(reader, upTo: 36 * 1024 * 1024)
        #expect(read >= 36 * 1024 * 1024)

        // The whole contract: exactly one data request, and it carried no Range header at all
        // (which also proves no suffix/tail probe and no size probe ever went out - any of
        // those would be a second, ranged, request).
        #expect(server.requestLog.count == 1)
        #expect(server.rangeHeaderPresence == [false])
    }

    @Test("a body that ends short of its Content-Length reports EIO, not EOF")
    func shortBodyReportsEIO() throws {
        let total: Int64 = 8 * 1024 * 1024
        let servedBeforeDrop: Int64 = 2 * 1024 * 1024
        let maybeServer = ThrottledOriginServer(totalSize: total, throttleUs: 0,
                                                respond: { _, _, _ in .serveThenDrop(afterBytes: servedBeforeDrop) })
        let server = try #require(maybeServer)
        defer { server.stop() }
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/archive.ts")!,
                                sequentialOnly: true)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        let (read, last) = drain(reader, upTo: total)
        // Whatever arrived is short of the promise, and the assertions stop there. How much
        // arrives is URLSession's call: it hands over what it has buffered when the body is cut
        // off, and on a loaded runner that can be nothing at all. `>= 1 MiB` fell first
        // (2026-08-11 CI: 327212 arrived, measured locally at 1790200 of 2097152 on an idle
        // machine), then the relaxed `> 0` fell the same way (2026-08-13 CI: 0 arrived). There is
        // no floor to find, because the transport owns that number; what the reader owns is the
        // ceiling (it cannot deliver more than the server sent) and the error it ends on.
        #expect(read <= servedBeforeDrop)
        #expect(read < total)
        // AVERROR(EIO) = -5: a sequential origin cannot be resumed at an offset, so the loss must
        // surface as a read error the session can act on. FFmpegErr.eof here would read as
        // end-of-media 75 % early and the consumer would never retry it.
        #expect(last == -5)
        #expect(last != FFmpegErr.eof)
    }

    @Test("a complete body still ends in clean EOF")
    func completeBodyReportsEOF() throws {
        let total: Int64 = 4 * 1024 * 1024
        let server = try #require(ThrottledOriginServer(totalSize: total, throttleUs: 0))
        defer { server.stop() }
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/archive.ts")!,
                                sequentialOnly: true)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        // Ask for more than the file holds so the final read hits the end-of-stream path.
        let (read, last) = drain(reader, upTo: total + 1024)
        #expect(read == total)
        #expect(last == FFmpegErr.eof)
    }

    // MARK: - Profile plumbing

    @Test("withSequentialOrigin carries the pair and touches nothing else")
    func profileCopyHelper() {
        let base = DemuxerOpenProfile.restartReopen
        let p = base.withSequentialOrigin(true, declaredDuration: 8100)
        #expect(p.avioSequentialOnly == true)
        #expect(p.declaredDurationSeconds == 8100)
        #expect(p.probesize == base.probesize)
        #expect(p.maxAnalyzeDuration == base.maxAnalyzeDuration)
        #expect(p.boundedInitialFetch == base.boundedInitialFetch)
        #expect(p.readerLabel == base.readerLabel)

        let off = base.withSequentialOrigin(false, declaredDuration: nil)
        #expect(off.avioSequentialOnly == false)
        #expect(off.declaredDurationSeconds == nil)
    }

    @Test("playback profile defaults to ranged mode")
    func playbackDefaultsOff() {
        #expect(DemuxerOpenProfile.playback.avioSequentialOnly == false)
        #expect(DemuxerOpenProfile.playback.declaredDurationSeconds == nil)
        let opts = LoadOptions()
        #expect(opts.sequentialOrigin == false)
        #expect(opts.declaredDurationSeconds == nil)
    }

    // MARK: - Duration precedence

    @Test("a declared duration outranks reader, disc and container values")
    func declaredDurationWins() {
        // The motivating field case: a 135-min timeshift window whose fabricated tail read
        // produced a 9.5 h container estimate.
        #expect(Demuxer.effectiveDurationSeconds(
            declared: 8100, readerDuration: nil, discTitle: nil, container: 34_213.1) == 8100)
        #expect(Demuxer.effectiveDurationSeconds(
            declared: 8100, readerDuration: 500, discTitle: 42, container: 34_213.1) == 8100)
    }

    @Test("without a declared duration the existing chain is untouched")
    func declaredNilKeepsChain() {
        #expect(Demuxer.effectiveDurationSeconds(
            declared: nil, readerDuration: 500, discTitle: 42, container: 7508) == 500)
        #expect(Demuxer.effectiveDurationSeconds(
            declared: nil, readerDuration: nil, discTitle: 42, container: 7508) == 42)
        #expect(Demuxer.effectiveDurationSeconds(
            declared: nil, readerDuration: nil, discTitle: nil, container: 7508) == 7508)
        // 0/negative declared values are ignored, not honored.
        #expect(Demuxer.effectiveDurationSeconds(
            declared: 0, readerDuration: nil, discTitle: nil, container: 7508) == 7508)
    }
}
