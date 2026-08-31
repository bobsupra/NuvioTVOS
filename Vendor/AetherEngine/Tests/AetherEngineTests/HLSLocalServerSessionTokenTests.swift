import Testing
import Foundation
@testable import AetherEngine

/// The listener binds 0.0.0.0 so an AirPlay receiver can reach it over the LAN (#86). That also
/// exposes it to every other host on that network, and the endpoint names are fixed, so the
/// ephemeral port was the only thing standing between a port scan and the stream. These pin the
/// per-session path token that replaced that assumption.
struct HLSLocalServerSessionTokenTests {

    // MARK: - Path check

    @Test("The token is stripped and the remainder routes")
    func tokenIsStripped() {
        #expect(HLSLocalServer.pathAfterToken("abc123", in: "/abc123/media.m3u8") == "/media.m3u8")
        #expect(HLSLocalServer.pathAfterToken("abc123", in: "/abc123/seg7.mp4") == "/seg7.mp4")
    }

    @Test("A request without the token is refused")
    func unprefixedIsRefused() {
        #expect(HLSLocalServer.pathAfterToken("abc123", in: "/media.m3u8") == nil)
        #expect(HLSLocalServer.pathAfterToken("abc123", in: "/") == nil)
        #expect(HLSLocalServer.pathAfterToken("abc123", in: "") == nil)
    }

    @Test("A wrong token is refused")
    func wrongTokenIsRefused() {
        #expect(HLSLocalServer.pathAfterToken("abc123", in: "/def456/media.m3u8") == nil)
    }

    @Test("A token that only prefixes the first segment is refused, not truncated")
    func partialSegmentMatchIsRefused() {
        // "/abc123extra/..." starts with "/abc123" as a STRING but is a different path segment.
        // Comparing on the string alone would let it through with a mangled remainder.
        #expect(HLSLocalServer.pathAfterToken("abc123", in: "/abc123extra/media.m3u8") == nil)
    }

    @Test("The bare token with nothing after it is refused")
    func bareTokenIsRefused() {
        #expect(HLSLocalServer.pathAfterToken("abc123", in: "/abc123") == nil)
    }

    // MARK: - Token shape

    @Test("Each server draws its own 128-bit token")
    func tokensAreDistinctAndFullWidth() {
        let a = HLSLocalServer(provider: StubProvider())
        let b = HLSLocalServer(provider: StubProvider())
        #expect(a.pathToken.count == 32)
        #expect(a.pathToken.allSatisfy { $0.isHexDigit })
        #expect(a.pathToken != b.pathToken)
    }

    // MARK: - Over a real socket

    @Test("The served URL carries the token and an unprefixed request 404s")
    func unprefixedRequestIsRefusedOverTheSocket() throws {
        let server = HLSLocalServer(provider: StubProvider())
        try server.start()
        defer { server.stop() }

        let served = try #require(server.mediaPlaylistURL)
        #expect(served.path == "/\(server.pathToken)/media.m3u8")

        #expect(Self.status(port: server.port, path: "/\(server.pathToken)/media.m3u8") == 200)
        // The shape a LAN scanner would try: right port, right endpoint name, no token.
        #expect(Self.status(port: server.port, path: "/media.m3u8") == 404)
        #expect(Self.status(port: server.port, path: "/init.mp4") == 404)
        #expect(Self.status(port: server.port, path: "/seg0.mp4") == 404)
    }

    // MARK: - Helpers

    /// Status line of a plain GET, or 0 when the request could not be completed.
    private static func status(port: UInt16, path: String) -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return 0 }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return 0 }
        let request = "GET \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n"
        let sent = Array(request.utf8).withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
        guard sent > 0 else { return 0 }
        var buffer = [UInt8](repeating: 0, count: 256)
        let received = recv(fd, &buffer, buffer.count, 0)
        guard received > 0,
              let line = String(bytes: buffer[0..<received], encoding: .utf8)?
                  .components(separatedBy: "\r\n").first else { return 0 }
        let parts = line.split(separator: " ")
        return parts.count >= 2 ? (Int(parts[1]) ?? 0) : 0
    }
}

/// Smallest provider that lets the server build and serve a media playlist.
private final class StubProvider: HLSSegmentProvider, @unchecked Sendable {
    func initSegment() -> Data? { Data([0x00]) }
    func mediaSegment(at index: Int) -> Data? { Data([0x00]) }
    var segmentCount: Int { 1 }
    func segmentDuration(at index: Int) -> Double { 4.0 }
    var playlistType: HLSPlaylistType { .vod }
}
