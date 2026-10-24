import Foundation
import XCTest
@testable import NuvioTV

final class TopShelfArtworkPrunerTests: XCTestCase {
    func testPrunesObsoleteGeneratedArtworkButKeepsCurrentFeedAndUnrelatedFiles() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let current = "top-shelf-a1.jpg"
        let obsolete = "top-shelf-b2.jpg"
        let unrelated = ["photo.jpg", "top-shelf-not-a-hash.jpg", "top-shelf-.jpg", "top-shelf-123456789abcdef01.jpg"]
        for name in [current, obsolete] + unrelated { try Data([1]).write(to: directory.appendingPathComponent(name)) }
        try writeFeed(artwork: [current], to: directory)

        TopShelfArtworkPruner.prune(in: directory)

        XCTAssertFalse(exists(obsolete, in: directory))
        for name in [current, "feed.json"] + unrelated { XCTAssertTrue(exists(name, in: directory), name) }
    }

    func testMissingOrUnreadableFeedDoesNotDeleteArtwork() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let name = "top-shelf-a1.jpg"
        try Data([1]).write(to: directory.appendingPathComponent(name))

        TopShelfArtworkPruner.prune(in: directory)
        XCTAssertTrue(exists(name, in: directory))

        try Data("invalid json".utf8).write(to: directory.appendingPathComponent("feed.json"))
        TopShelfArtworkPruner.prune(in: directory)
        XCTAssertTrue(exists(name, in: directory))
    }

    func testCleanupUsesTheLatestPersistedFeed() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = "top-shelf-a1.jpg"
        let current = "top-shelf-b2.jpg"
        for name in [old, current] { try Data([1]).write(to: directory.appendingPathComponent(name)) }
        try writeFeed(artwork: [old], to: directory)
        try writeFeed(artwork: [current], to: directory)

        // A completion from the old job must keep what is referenced now.
        TopShelfArtworkPruner.prune(in: directory)

        XCTAssertFalse(exists(old, in: directory))
        XCTAssertTrue(exists(current, in: directory))
    }

    func testValidEmptyFeedRemovesOnlyGeneratedArtwork() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data([1]).write(to: directory.appendingPathComponent("top-shelf-ff.jpg"))
        try Data([1]).write(to: directory.appendingPathComponent("other.jpg"))
        try writeFeed(artwork: [], to: directory)

        TopShelfArtworkPruner.prune(in: directory)

        XCTAssertFalse(exists("top-shelf-ff.jpg", in: directory))
        XCTAssertTrue(exists("other.jpg", in: directory))
        XCTAssertTrue(exists("feed.json", in: directory))
    }

    func testDirectoriesAndSymbolicLinksAreNeverRemoved() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = directory.appendingPathComponent("top-shelf-aa.jpg")
        let target = directory.appendingPathComponent("unrelated.txt")
        let link = directory.appendingPathComponent("top-shelf-bb.jpg")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data([1]).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        try writeFeed(artwork: [], to: directory)

        TopShelfArtworkPruner.prune(in: directory)

        XCTAssertTrue(exists("top-shelf-aa.jpg", in: directory))
        XCTAssertTrue(exists("top-shelf-bb.jpg", in: directory))
        XCTAssertTrue(exists("unrelated.txt", in: directory))
    }

    func testKeepsArtworkReferencedByAnySection() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let watching = "top-shelf-a1.jpg"
        let library = "top-shelf-b2.jpg"
        let obsolete = "top-shelf-c3.jpg"
        for name in [watching, library, obsolete] { try Data([1]).write(to: directory.appendingPathComponent(name)) }
        try writeFeed(artwork: [watching], to: directory)
        try writeFeed(artwork: [library], to: directory, section: .library)

        TopShelfArtworkPruner.prune(in: directory)

        XCTAssertTrue(exists(watching, in: directory))
        XCTAssertTrue(exists(library, in: directory))
        XCTAssertFalse(exists(obsolete, in: directory))
    }

    func testUnreadableSectionFeedDoesNotDeleteArtwork() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let name = "top-shelf-a1.jpg"
        try Data([1]).write(to: directory.appendingPathComponent(name))
        try writeFeed(artwork: [], to: directory)
        try Data("invalid json".utf8)
            .write(to: directory.appendingPathComponent(TopShelfSection.library.feedFileName))

        TopShelfArtworkPruner.prune(in: directory)

        XCTAssertTrue(exists(name, in: directory))
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("topshelf-pruner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private func writeFeed(artwork: [String], to directory: URL,
                           section: TopShelfSection = .continueWatching) throws {
        let entries = artwork.map { name in
            TopShelfEntry(contentId: name, contentType: "movie", title: name,
                          subtitle: nil, imageURL: nil, progress: nil, artworkFileName: name)
        }
        try JSONEncoder().encode(TopShelfFeed(entries: entries))
            .write(to: directory.appendingPathComponent(section.feedFileName), options: .atomic)
    }

    private func exists(_ name: String, in directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)
    }
}
