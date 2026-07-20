import XCTest
@testable import AetherEngine

/// Live network integration test for AES-128 clear-key direct play.
/// Skipped unless `AETHER_LIVE_URL` is set (a real FAST-channel HLS
/// playlist, e.g. a Pluto/Samsung-TV+ stitcher URL), so CI and the
/// default `swift test` run never depend on a transient, geo-gated,
/// token-expiring upstream. Run manually:
///
///   AETHER_LIVE_URL='https://.../master.m3u8' \
///     swift test --filter HLSLiveIngestDecryptIntegrationTests
///
/// Proves the whole direct path end to end: master -> variant ->
/// encrypted media playlist -> key fetch -> AES-128-CBC segment
/// decrypt -> clear MPEG-TS bytes. A successful decrypt is observable
/// as the TS sync byte 0x47 at the 188-byte packet cadence; ciphertext
/// would be effectively random and fail the cadence check.
final class HLSLiveIngestDecryptIntegrationTests: XCTestCase {

    func testDecryptsRealAES128ChannelToCleanTS() throws {
        guard let raw = ProcessInfo.processInfo.environment["AETHER_LIVE_URL"],
              let url = URL(string: raw) else {
            throw XCTSkip("set AETHER_LIVE_URL to run the live AES-128 ingest test")
        }

        let reader = HLSLiveIngestReader(playlistURL: url)
        defer { reader.close() }

        // read() blocks on the FIFO; Box is a reference type so the closure captures it
        // across the thread boundary (expectation provides the happens-before edge).
        final class Box: @unchecked Sendable { var data = Data() }
        let want = 64 * 1024
        let box = Box()
        let done = expectation(description: "ingested bytes")
        Thread.detachNewThread {
            var buf = [UInt8](repeating: 0, count: 32 * 1024)
            while box.data.count < want {
                let n = buf.withUnsafeMutableBufferPointer {
                    reader.read($0.baseAddress, size: Int32($0.count))
                }
                if n <= 0 { break }
                box.data.append(contentsOf: buf[0..<Int(n)])
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 40)
        let got = box.data

        XCTAssertNil(reader.terminalError, "ingest went terminal: \(String(describing: reader.terminalError))")
        XCTAssertGreaterThan(got.count, 188 * 4, "too few bytes to judge TS structure")

        // 0x47 sync at 188-byte cadence only holds for decrypted TS; ciphertext would score ~1/256.
        XCTAssertEqual(got.first, 0x47, "stream does not start with the MPEG-TS sync byte (decrypt failed?)")
        var packets = 0
        var hits = 0
        var offset = 0
        while offset + 188 <= got.count {
            packets += 1
            if got[offset] == 0x47 { hits += 1 }
            offset += 188
        }
        XCTAssertGreaterThan(packets, 8)
        XCTAssertGreaterThan(Double(hits) / Double(packets), 0.95,
                             "TS sync cadence \(hits)/\(packets) too low; segments likely still encrypted")
    }
}
