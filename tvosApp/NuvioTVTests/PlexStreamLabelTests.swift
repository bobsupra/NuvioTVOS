import XCTest
@testable import NuvioTV

final class PlexStreamLabelTests: XCTestCase {
    private func file(_ details: PlexFileDetails?, container: String = "mkv", size: Int64? = nil, label: String? = nil) -> PlexFile {
        PlexFile(partKey: "/library/parts/9/1/file.\(container)", container: container, sizeBytes: size, label: label, details: details)
    }

    func testFileWithTheServersTrackNames() {
        let details = PlexFileDetails(videoResolution: "4k", videoCodec: "hevc", audioCodec: "eac3", audioChannels: 6, bitrateKbps: 54_100)
        let tracks = PlexClient.PartTracks(
            videoProfile: "Main 10",
            dynamicRange: "Dolby Vision",
            audio: ["English (EAC3 5.1)", "Português (AAC Stereo)"],
            subtitles: ["English", "English SDH"]
        )
        let label = PlexStreamLabel.label(for: file(details), tracks: tracks, serverName: "Server")
        XCTAssertEqual(label.name, "Plex · 4K Dolby Vision")
        XCTAssertEqual(label.description, """
        Video: 4K (HEVC Main 10)
        Audio: English (EAC3 5.1), Português (AAC Stereo)
        Subtitles: English, English SDH
        54.1 Mbps · MKV · Server
        """)
    }

    func testWithoutTrackNamesTheListingsFormatIsUsed() {
        let details = PlexFileDetails(videoResolution: "1080", videoCodec: "h264", audioCodec: "aac", audioChannels: 2)
        let label = PlexStreamLabel.label(for: file(details, container: "mp4"), tracks: nil, serverName: "Server")
        XCTAssertEqual(label.name, "Plex · 1080p")
        XCTAssertEqual(label.description, "Video: 1080p (H.264)\nAudio: AAC Stereo\nMP4 · Server")
    }

    func testLongTrackListsAreCounted() {
        let tracks = PlexClient.PartTracks(
            audio: ["A", "B", "C", "D", "E"],
            subtitles: ["1", "2", "3", "4", "5", "6"]
        )
        let label = PlexStreamLabel.label(for: file(PlexFileDetails(videoResolution: "sd")), tracks: tracks, serverName: "Server")
        XCTAssertEqual(label.name, "Plex · SD")
        XCTAssertEqual(label.description, "Video: SD\nAudio: A, B, C, +2\nSubtitles: 1, 2, 3, 4, +2\nMKV · Server")
    }

    func testFileSyncedBeforeDetailsWereKeptStillReads() {
        let label = PlexStreamLabel.label(for: file(nil, label: "4K · 18.2 Mbps"), tracks: nil, serverName: "Server")
        XCTAssertEqual(label.name, "Plex")
        XCTAssertEqual(label.description, "MKV · 4K · 18.2 Mbps · Server")
    }

    func testSplitFileNamesItsPart() {
        let details = PlexFileDetails(videoResolution: "720", part: "Part 2 of 2")
        let label = PlexStreamLabel.label(for: file(details), tracks: nil, serverName: "Server")
        XCTAssertEqual(label.description, "Video: 720p\nMKV · Part 2 of 2 · Server")
    }

    func testDecodesTracksPerFile() throws {
        let json = """
        {"MediaContainer":{"Metadata":[{"Media":[{"Part":[{"key":"/library/parts/293/1/file.mkv","Stream":[
          {"streamType":1,"codec":"hevc","displayTitle":"4K","profile":"main 10","colorTrc":"smpte2084","DOVIPresent":true},
          {"streamType":2,"displayTitle":"English (EAC3 5.1)","languageCode":"eng"},
          {"streamType":3,"displayTitle":"English","languageCode":"eng"},
          {"streamType":3,"displayTitle":"English","languageCode":"eng"},
          {"streamType":3,"displayTitle":"Português","languageCode":"por","key":"/library/streams/77"}
        ]}]}]}]}}
        """
        let tracks = try PlexClient.decodeTracks(Data(json.utf8))
        XCTAssertEqual(tracks.parts["/library/parts/293/1/file.mkv"], PlexClient.PartTracks(
            videoProfile: "Main 10",
            dynamicRange: "Dolby Vision",
            audio: ["English (EAC3 5.1)"],
            subtitles: ["English", "Português"]
        ))
        XCTAssertEqual(tracks.externalSubtitles, [
            PlexClient.ExternalSubtitle(key: "/library/streams/77", languageCode: "por", title: "Português")
        ])
    }

    func testHDR10AndSDR() throws {
        func range(_ trc: String) throws -> String? {
            let json = #"{"MediaContainer":{"Metadata":[{"Media":[{"Part":[{"key":"k","Stream":[{"streamType":1,"colorTrc":"\#(trc)"}]}]}]}]}}"#
            return try PlexClient.decodeTracks(Data(json.utf8)).parts["k"]?.dynamicRange
        }
        XCTAssertEqual(try range("smpte2084"), "HDR10")
        XCTAssertEqual(try range("arib-std-b67"), "HLG")
        XCTAssertNil(try range("bt709"))
    }
}
