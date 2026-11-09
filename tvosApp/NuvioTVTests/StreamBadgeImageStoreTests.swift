import XCTest
import UIKit
@testable import NuvioTV

final class StreamBadgeImageStoreTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("StreamBadgeImageStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testImageLinksAreTakenOnceFromEveryPack() {
        let rules = StreamBadgeRules(imports: [
            StreamBadgeImport(sourceUrl: "https://example.com/a.json", filters: [
                StreamBadgeFilter(name: "4K", pattern: "2160", imageURL: " https://example.com/4k.png "),
                StreamBadgeFilter(name: "HDR", pattern: "hdr", imageURL: "https://example.com/hdr.png"),
                StreamBadgeFilter(name: "Text only", pattern: "x", imageURL: "")
            ]),
            StreamBadgeImport(sourceUrl: "https://example.com/b.json", filters: [
                StreamBadgeFilter(name: "4K again", pattern: "4k", imageURL: "https://example.com/4k.png")
            ])
        ])
        XCTAssertEqual(
            StreamBadgeImageStore.imageURLs(in: rules).map(\.absoluteString),
            ["https://example.com/4k.png", "https://example.com/hdr.png"]
        )
    }

    func testFileNameIsAStableHashOfTheLink() {
        let url = URL(string: "https://example.com/badges/4k.png?v=2")!
        let name = StreamBadgeImageStore.fileName(for: url)
        XCTAssertEqual(name.count, 64)
        XCTAssertEqual(name, StreamBadgeImageStore.fileName(for: url))
        XCTAssertNotEqual(name, StreamBadgeImageStore.fileName(for: URL(string: "https://example.com/badges/hdr.png")!))
    }

    func testAnImageIsKeptOnDiskAndReadBackWithoutItsSource() async throws {
        let source = folder.appendingPathComponent("source.png")
        let pixel = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        try XCTUnwrap(pixel.pngData()).write(to: source)
        let cache = folder.appendingPathComponent("cache", isDirectory: true)

        let first = StreamBadgeImageStore(directory: cache)
        let loaded = await first.image(for: source)
        XCTAssertNotNil(loaded)
        XCTAssertNotNil(first.cachedImage(for: source))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: cache.appendingPathComponent(StreamBadgeImageStore.fileName(for: source)).path
        ))

        // A new start (nothing in memory) with the source gone: the kept copy is used.
        try FileManager.default.removeItem(at: source)
        let second = StreamBadgeImageStore(directory: cache)
        XCTAssertNil(second.cachedImage(for: source))
        let reloaded = await second.image(for: source)
        XCTAssertNotNil(reloaded)
    }
}
