import XCTest
@testable import NuvioTV

final class IPTVGuideGzipTests: XCTestCase {
    private let fixture = "H4sIAAAAAAACA7MpKbOzKSjKTy9KzM1NVUjOSMzLS82xVUpUUiguSSwqsVUyMjAyMzQ0NDA0AAEFbRAJkswvQJIzRJKzsynJLMlJtfNLLS+20YewbfThdgDZQDsBhdiIy3gAAAA="

    func testDecompressesAndChecksLimit() throws {
        let compressed = try XCTUnwrap(Data(base64Encoded: fixture))
        let data = try IPTVGuideGzip.decompress(compressed, maximumBytes: 1024)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("<title>News</title>"))
        XCTAssertThrowsError(try IPTVGuideGzip.decompress(compressed, maximumBytes: 16))
    }

    func testRejectsCorruptedChecksumAndTruncatedData() throws {
        var compressed = try XCTUnwrap(Data(base64Encoded: fixture))
        compressed[compressed.count - 8] ^= 0xff
        XCTAssertThrowsError(try IPTVGuideGzip.decompress(compressed, maximumBytes: 1024))
        XCTAssertThrowsError(try IPTVGuideGzip.decompress(Data(compressed.prefix(12)), maximumBytes: 1024))
    }
}
