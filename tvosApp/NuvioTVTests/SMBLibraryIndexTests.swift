import XCTest
@testable import NuvioTV

@MainActor
final class SMBLibraryIndexTests: XCTestCase {
    override func tearDown() {
        SMBLibraryIndex.shared.removeAll(forServerID: "server-1")
        SMBLibraryIndex.shared.removeAll(forServerID: "server-a")
        SMBLibraryIndex.shared.removeAll(forServerID: "server-b")
        super.tearDown()
    }

    func testReplaceAndRetrieveTitlesForServer() {
        let file = SMBIndexedFile(
            serverID: "server-1", share: "Media", path: "Movies/Foo.mkv", filename: "Foo.mkv", size: 123
        )
        let title = SMBIndexedTitle(contentId: "tt1234567", type: "movie", year: 2020, files: [file])
        SMBLibraryIndex.shared.replace(titles: [title], forServerID: "server-1")

        XCTAssertEqual(SMBLibraryIndex.shared.titles().map(\.contentId), ["tt1234567"])
        XCTAssertEqual(SMBLibraryIndex.shared.files(forContentId: "tt1234567", season: nil, episode: nil).count, 1)
        XCTAssertTrue(SMBLibraryIndex.shared.files(forContentId: "tt1234567", season: 1, episode: 1).isEmpty)
    }

    func testEpisodeLookupFiltersBySeasonAndEpisode() {
        var ep1 = SMBIndexedFile(serverID: "server-1", share: "Media", path: "Show/S01E01.mkv", filename: "S01E01.mkv", size: 10)
        ep1.season = 1
        ep1.episode = 1
        var ep2 = SMBIndexedFile(serverID: "server-1", share: "Media", path: "Show/S01E02.mkv", filename: "S01E02.mkv", size: 10)
        ep2.season = 1
        ep2.episode = 2
        let title = SMBIndexedTitle(contentId: "tt9999999", type: "series", year: nil, files: [ep1, ep2])
        SMBLibraryIndex.shared.replace(titles: [title], forServerID: "server-1")

        XCTAssertEqual(
            SMBLibraryIndex.shared.files(forContentId: "tt9999999", season: 1, episode: 2).first?.filename,
            "S01E02.mkv"
        )
        XCTAssertTrue(SMBLibraryIndex.shared.files(forContentId: "tt9999999", season: 2, episode: 1).isEmpty)
    }

    /// Removing one server's titles must not touch another's — a deleted NAS
    /// shouldn't silently take a second NAS's library with it.
    func testRemoveAllForServerClearsItsTitlesOnly() {
        let fileA = SMBIndexedFile(serverID: "server-a", share: "Media", path: "A.mkv", filename: "A.mkv", size: 10)
        let fileB = SMBIndexedFile(serverID: "server-b", share: "Media", path: "B.mkv", filename: "B.mkv", size: 10)
        SMBLibraryIndex.shared.replace(
            titles: [SMBIndexedTitle(contentId: "tt1", type: "movie", year: nil, files: [fileA])],
            forServerID: "server-a"
        )
        SMBLibraryIndex.shared.replace(
            titles: [SMBIndexedTitle(contentId: "tt2", type: "movie", year: nil, files: [fileB])],
            forServerID: "server-b"
        )

        SMBLibraryIndex.shared.removeAll(forServerID: "server-a")

        let ids = Set(SMBLibraryIndex.shared.titles().map(\.contentId))
        XCTAssertFalse(ids.contains("tt1"))
        XCTAssertTrue(ids.contains("tt2"))
    }

    func testIndexedTitleCodableRoundTrip() throws {
        var file = SMBIndexedFile(serverID: "s1", share: "Media", path: "Movies/Foo.mkv", filename: "Foo.mkv", size: 999)
        file.season = 1
        file.episode = 2
        let title = SMBIndexedTitle(contentId: "tt42", type: "series", year: 2021, files: [file])

        let data = try JSONEncoder().encode(title)
        let decoded = try JSONDecoder().decode(SMBIndexedTitle.self, from: data)

        XCTAssertEqual(decoded, title)
    }

    func testStreamPathBuildsSMBURL() {
        let file = SMBIndexedFile(serverID: "s1", share: "Media", path: "Movies/Foo.mkv", filename: "Foo.mkv", size: 1)
        XCTAssertEqual(file.streamPath(hostAndPort: "192.168.1.10:445"), "smb://192.168.1.10:445/Media/Movies/Foo.mkv")
    }
}
