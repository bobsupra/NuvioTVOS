import Foundation
import XCTest
@testable import AetherEngine

/// A seek-preview extractor whose source cannot give a still must not read the source again on
/// every request. The case seen on device: a 4K HEVC source, which the software still path refuses
/// ("no decoder for the video codec"), re-read over the network about 1.6 times a second.
final class FrameDecodeContextOpenFailureTests: XCTestCase {
    /// Counts the reads that reach the source.
    private final class CountingReader: IOReader, @unchecked Sendable {
        private let bytes: Data
        private let lock = NSLock()
        private var position = 0
        private var readCount = 0

        init(bytes: Data) { self.bytes = bytes }

        var reads: Int { lock.withLock { readCount } }

        func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
            guard let buffer, size > 0 else { return -1 }
            return lock.withLock {
                readCount += 1
                let n = min(Int(size), bytes.count - position)
                guard n > 0 else { return 0 }
                bytes.withUnsafeBytes { raw in _ = memcpy(buffer, raw.baseAddress! + position, n) }
                position += n
                return Int32(n)
            }
        }

        func seek(offset: Int64, whence: Int32) -> Int64 {
            lock.withLock {
                switch whence {
                case 0x10000: return Int64(bytes.count)  // AVSEEK_SIZE
                case SEEK_SET where offset >= 0 && offset <= Int64(bytes.count): position = Int(offset)
                case SEEK_CUR where position + Int(offset) >= 0 && position + Int(offset) <= bytes.count:
                    position += Int(offset)
                case SEEK_END where offset <= 0 && bytes.count + Int(offset) >= 0:
                    position = bytes.count + Int(offset)
                default: return -1
                }
                return Int64(position)
            }
        }

        func close() {}
        var discImageProbeEnabled: Bool { false }
    }

    func testRefusedSourceIsNotReadAgain() throws {
        let data = try XCTUnwrap(Data(base64Encoded: Self.hevc4KFixtureBase64, options: .ignoreUnknownCharacters))
        let reader = CountingReader(bytes: data)
        let context = FrameDecodeContext(reader: reader, formatHint: "mp4", allowsHardwareDecode: false)
        defer { context.close() }

        XCTAssertThrowsError(try context.ensureOpen()) { error in
            XCTAssertEqual("\(error)", "\(FrameDecodeError.unsupportedCodec)")
        }
        let readsAfterFirstOpen = reader.reads
        XCTAssertGreaterThan(readsAfterFirstOpen, 0, "the first open read the source")

        for _ in 0..<5 {
            XCTAssertThrowsError(try context.ensureOpen()) { error in
                XCTAssertEqual("\(error)", "\(FrameDecodeError.unsupportedCodec)")
            }
        }
        XCTAssertEqual(reader.reads, readsAfterFirstOpen, "later opens did not read the source again")
        XCTAssertFalse(context.isOpen)
    }

    func testOnlyFailuresOfTheSourceArePermanent() {
        XCTAssertTrue(FrameDecodeContext.isPermanentOpenFailure(FrameDecodeError.noVideoStream))
        XCTAssertTrue(FrameDecodeContext.isPermanentOpenFailure(FrameDecodeError.noCodecParameters))
        XCTAssertTrue(FrameDecodeContext.isPermanentOpenFailure(FrameDecodeError.unsupportedCodec))
        XCTAssertFalse(FrameDecodeContext.isPermanentOpenFailure(FrameDecodeError.allocationFailed))
        XCTAssertFalse(FrameDecodeContext.isPermanentOpenFailure(FrameDecodeError.decoderOpenFailed))
        XCTAssertFalse(FrameDecodeContext.isPermanentOpenFailure(DemuxerError.openFailed(code: -1)))
    }

    /// One black 3840x2160 HEVC frame in MP4 (5 KB), made with ffmpeg + libx265.
    private static let hevc4KFixtureBase64 = """
        AAAAHGZ0eXBpc29tAAACAGlzb21pc28ybXA0MQAADHNtb292AAAAbG12aGQAAAAAAAAAAAAAAAAAAAPoAAAD6AABAAABAAAAAAAA
        AAAAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAAALnnRy
        YWsAAABcdGtoZAAAAAMAAAAAAAAAAAAAAAEAAAAAAAAD6AAAAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAA
        AAAAAAAAAEAAAAAPAAAACHAAAAAAACRlZHRzAAAAHGVsc3QAAAAAAAAAAQAAA+gAAAAAAAEAAAAACxZtZGlhAAAAIG1kaGQAAAAA
        AAAAAAAAAAAAAEAAAABAAFXEAAAAAAAtaGRscgAAAAAAAAAAdmlkZQAAAAAAAAAAAAAAAFZpZGVvSGFuZGxlcgAAAArBbWluZgAA
        ABR2bWhkAAAAAQAAAAAAAAAAAAAAJGRpbmYAAAAcZHJlZgAAAAAAAAABAAAADHVybCAAAAABAAAKgXN0YmwAAAodc3RzZAAAAAAA
        AAABAAAKDWh2YzEAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAAPAAhwAEgAAABIAAAAAAAAAAEUTGF2YzYzLjEuMTAyIGxpYngyNjUA
        AAAAAAAAAAAAAAAY//8AAAmJaHZjQwEBYAAAAJAAAAAAAJbwAPz9+PgAAA8EoAABABhAAQwB//8BYAAAAwCQAAADAAADAJaVmAmh
        AAEALEIBAQFgAAADAJAAAAMAAAMAlqAB4CACHFllZpJMrwFoCAAAAwAIAAADAAhAogABAAdEAcFytGJAJwABCQtOAQX/////////
        //8GLKLeCbUXR9u7VaT+f8L8TngyNjUgKGJ1aWxkIDIxNykgLSA0LjMrMS1lOWI4ODEyOltNYWMgT1MgWF1bY2xhbmcgMjEuMC4w
        XVs2NCBiaXRdIDhiaXQrMTBiaXQrMTJiaXQgLSBILjI2NS9IRVZDIGNvZGVjIC0gQ29weXJpZ2h0IDIwMTMtMjAxOCAoYykgTXVs
        dGljb3Jld2FyZSwgSW5jIC0gaHR0cDovL3gyNjUub3JnIC0gb3B0aW9uczogY3B1aWQ9OTggZnJhbWUtdGhyZWFkcz00IHdwcCBu
        by1wbW9kZSBuby1wbWUgbm8tcHNuciBuby1zc2ltIGxvZy1sZXZlbD0wIGJpdGRlcHRoPTggaW5wdXQtY3NwPTEgZnBzPTEvMSBp
        bnB1dC1yZXM9Mzg0MHgyMTYwIGludGVybGFjZT0wIHRvdGFsLWZyYW1lcz0wIGxldmVsLWlkYz0wIGhpZ2gtdGllcj0xIHVoZC1i
        ZD0wIHJlZj0zIG5vLWFsbG93LW5vbi1jb25mb3JtYW5jZSBuby1yZXBlYXQtaGVhZGVycyBhbm5leGIgbm8tYXVkIG5vLWVvYiBu
        by1lb3Mgbm8taHJkIGluZm8gaGFzaD0wIHRlbXBvcmFsLWxheWVycz0wIG9wZW4tZ29wIG1pbi1rZXlpbnQ9MSBrZXlpbnQ9MjUw
        IGdvcC1sb29rYWhlYWQ9MCBiZnJhbWVzPTQgYi1hZGFwdD0yIGItcHlyYW1pZCBiZnJhbWUtYmlhcz0wIHJjLWxvb2thaGVhZD0y
        MCBsb29rYWhlYWQtc2xpY2VzPTggc2NlbmVjdXQ9NDAgbm8taGlzdC1zY2VuZWN1dCByYWRsPTAgbm8tc3BsaWNlIG5vLWludHJh
        LXJlZnJlc2ggY3R1PTY0IG1pbi1jdS1zaXplPTggbm8tcmVjdCBuby1hbXAgbWF4LXR1LXNpemU9MzIgdHUtaW50ZXItZGVwdGg9
        MSB0dS1pbnRyYS1kZXB0aD0xIGxpbWl0LXR1PTAgcmRvcS1sZXZlbD0wIGR5bmFtaWMtcmQ9MC4wMCBuby1zc2ltLXJkIHNpZ25o
        aWRlIG5vLXRza2lwIG5yLWludHJhPTAgbnItaW50ZXI9MCBuby1jb25zdHJhaW5lZC1pbnRyYSBzdHJvbmctaW50cmEtc21vb3Ro
        aW5nIG1heC1tZXJnZT0zIGxpbWl0LXJlZnM9MSBuby1saW1pdC1tb2RlcyBtZT0xIHN1Ym1lPTIgbWVyYW5nZT01NyB0ZW1wb3Jh
        bC1tdnAgbm8tZnJhbWUtZHVwIG5vLWhtZSB3ZWlnaHRwIG5vLXdlaWdodGIgbm8tYW5hbHl6ZS1zcmMtcGljcyBkZWJsb2NrPTA6
        MCBzYW8gbm8tc2FvLW5vbi1kZWJsb2NrIHJkPTMgc2VsZWN0aXZlLXNhbz00IGVhcmx5LXNraXAgcnNraXAgbm8tZmFzdC1pbnRy
        YSBuby10c2tpcC1mYXN0IG5vLWN1LWxvc3NsZXNzIGItaW50cmEgbm8tc3BsaXRyZC1za2lwIHJkcGVuYWx0eT0wIHBzeS1yZD0y
        LjAwIHBzeS1yZG9xPTAuMDAgbm8tcmQtcmVmaW5lIG5vLWxvc3NsZXNzIGNicXBvZmZzPTAgY3JxcG9mZnM9MCByYz1jcmYgY3Jm
        PTI4LjAgcWNvbXA9MC42MCBxcHN0ZXA9NCBzdGF0cy13cml0ZT0wIHN0YXRzLXJlYWQ9MCBpcHJhdGlvPTEuNDAgcGJyYXRpbz0x
        LjMwIGFxLW1vZGU9MiBhcS1zdHJlbmd0aD0xLjAwIGN1dHJlZSB6b25lLWNvdW50PTAgbm8tc3RyaWN0LWNiciBxZy1zaXplPTMy
        IG5vLXJjLWdyYWluIHFwbWF4PTY5IHFwbWluPTAgbm8tY29uc3QtdmJ2IHNhcj0xIG92ZXJzY2FuPTAgdmlkZW9mb3JtYXQ9NSBy
        YW5nZT0wIGNvbG9ycHJpbT0yIHRyYW5zZmVyPTIgY29sb3JtYXRyaXg9MiBjaHJvbWFsb2M9MCBkaXNwbGF5LXdpbmRvdz0wIGNs
        bD0wLDAgbWluLWx1bWE9MCBtYXgtbHVtYT0yNTUgbG9nMi1tYXgtcG9jLWxzYj04IHZ1aS10aW1pbmctaW5mbyB2dWktaHJkLWlu
        Zm8gc2xpY2VzPTEgbm8tb3B0LXFwLXBwcyBuby1vcHQtcmVmLWxpc3QtbGVuZ3RoLXBwcyBuby1tdWx0aS1wYXNzLW9wdC1ycHMg
        c2NlbmVjdXQtYmlhcz0wLjA1IG5vLW9wdC1jdS1kZWx0YS1xcCBuby1hcS1tb3Rpb24gbm8taGRyMTAgbm8taGRyMTAtb3B0IG5v
        LWRoZHIxMC1vcHQgbm8taWRyLXJlY292ZXJ5LXNlaSBhbmFseXNpcy1yZXVzZS1sZXZlbD0wIGFuYWx5c2lzLXNhdmUtcmV1c2Ut
        bGV2ZWw9MCBhbmFseXNpcy1sb2FkLXJldXNlLWxldmVsPTAgc2NhbGUtZmFjdG9yPTAgcmVmaW5lLWludHJhPTAgcmVmaW5lLWlu
        dGVyPTAgcmVmaW5lLW12PTEgcmVmaW5lLWN0dS1kaXN0b3J0aW9uPTAgbm8tbGltaXQtc2FvIGN0dS1pbmZvPTAgbm8tbG93cGFz
        cy1kY3QgcmVmaW5lLWFuYWx5c2lzLXR5cGU9MCBjb3B5LXBpYz0xIG1heC1hdXNpemUtZmFjdG9yPTEuMCBuby1keW5hbWljLXJl
        ZmluZSBuby1zaW5nbGUtc2VpIG5vLWhldmMtYXEgbm8tc3Z0IG5vLWZpZWxkIHFwLWFkYXB0YXRpb24tcmFuZ2U9MS4wMCBzY2Vu
        ZWN1dC1hd2FyZS1xcD0wY29uZm9ybWFuY2Utd2luZG93LW9mZnNldHMgcmlnaHQ9MCBib3R0b209MCBkZWNvZGVyLW1heC1yYXRl
        PTAgbm8tdmJ2LWxpdmUtbXVsdGktcGFzcyBuby1tY3N0ZiBuby1zYnJjIG5vLWZyYW1lLXJjgAAAAApmaWVsAQAAAAAQcGFzcAAA
        AAEAAAABAAAAFGJ0cnQAAAAAAAA9mAAAAAAAAAAYc3R0cwAAAAAAAAABAAAAAQAAQAAAAAAcc3RzYwAAAAAAAAABAAAAAQAAAAEA
        AAABAAAAFHN0c3oAAAAAAAAHswAAAAEAAAAUc3RjbwAAAAAAAAABAAAMnwAAAGF1ZHRhAAAAWW1ldGEAAAAAAAAAIWhkbHIAAAAA
        AAAAAG1kaXJhcHBsAAAAAAAAAAAAAAAALGlsc3QAAAAkqXRvbwAAABxkYXRhAAAAAQAAAABMYXZmNjMuMS4xMDIAAAAIZnJlZQAA
        B7ttZGF0AAAHrygBrxMER5T947cuHDhu2bNmzZs2bNmzVq1atWrVq1atWrVr5mjj//0Xz8f2QC1YmO2u+AJADNDyAAADAAADAAAD
        AAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAF/Ape9yuAXAHyJgAAADAAADAAADAAADAAADAAADAAAD
        AAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAACFgJMChCpAAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAAD
        AAADAAADAAADAAADAAADAAADAzKHAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAAD
        AAADApIAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAYMAAADAAADAAADAAAD
        AAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAGrAAADAAADAAADAAADAAADAAADAAADAAADAAADAAAD
        AAADAAADAAADAAADAAADAAADAAADAAADABWQAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAAD
        AAADAAADAIOAAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAiYAAAMAAAMAAAMA
        AAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAARUAAADAAADAAADAAADAAADAAADAAADAAADAAADAAAD
        AAADAAADAAADAAADAAADAAADAAADAAAJCAAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAA
        AwAAD6gAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAByQAAADAAADAAADAAADAAAD
        AAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAAroAAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAA
        AwAAAwAAAwAAAwAAAwAAAwAAQ0AAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAF/A
        AAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAACKgAAAAwAAAwAAAwAAAwAAAwAAAwAA
        AwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAAwAAtoAAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMA
        AAMAAAMAAAMAAAMAAOeAAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAEpAAADAAAD
        AAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAF1AAADAAADAAADAAADAAADAAADAAADAAADAAAD
        AAADAAADAAADAAADAAADAAADAAADAAADAAHTAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAAD
        AAADAAIWAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAJqAAADAAADAAADAAADAAAD
        AAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAKuAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAAD
        AAADAAADAAADAAADAAADAAL6AAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAANOAAAD
        AAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAOSAAADAAADAAADAAADAAADAAADAAADAAAD
        AAADAAADAAADAAADAAADAAADAAADAAADAAADAAPOAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAAD
        AAADAAADAAPqAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAQsAAADAAADAAADAAAD
        AAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAARMAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAAD
        AAADAAADAAADAAADAAADAAADAAR0AAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAADAAAD
        AAADAAADAAADAAADAAADAAADAAADAAADAICA
        """
}
