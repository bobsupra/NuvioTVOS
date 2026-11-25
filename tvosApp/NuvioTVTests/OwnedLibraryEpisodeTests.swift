import XCTest
@testable import NuvioTV

/// A library stream is matched to the episode by the library itself, so it
/// ranks with the add-on results that name the episode, not below them.
final class OwnedLibraryEpisodeTests: XCTestCase {
    private let target = StreamEpisodeTarget(season: 3, episode: 4)
    private let plex = NuvioStream(url: "https://plex.test/720", name: "720p WEB-DL", description: nil, addonName: "Plex")
    private let addonUHD = NuvioStream(url: "https://addon.test/uhd", name: "Show S03E04 2160p BluRay", description: nil, addonName: "Add-on")
    private let addonHD = NuvioStream(url: "https://addon.test/hd", name: "Show S03E04 1080p WEB-DL", description: nil, addonName: "Add-on")
    private let addonUnnamed = NuvioStream(url: "https://addon.test/x", name: "720p WEBRip", description: nil, addonName: "Add-on")

    private func groups(plexId: String = "local.plex") -> [AddonStreamGroup] {
        [
            AddonStreamGroup(addonId: plexId, displayName: "Plex", streams: [plex], isLoading: false),
            AddonStreamGroup(addonId: "addon", displayName: "Add-on", streams: [addonUnnamed, addonHD, addonUHD], isLoading: false)
        ]
    }

    func testDefaultOrderKeepsLibraryFirstForAnEpisode() {
        let all = StreamPickerListBuilder.displayedStreams(
            streams: [], groups: groups(), selectedAddonId: nil,
            sortOption: .default, includeDebrid: false, preserveAddonStreams: true,
            episodeTarget: target
        )
        XCTAssertEqual(all.map(\.id), [plex.id, addonHD.id, addonUHD.id, addonUnnamed.id])
    }

    func testQualitySortStillRanksLibraryByQuality() {
        let all = StreamPickerListBuilder.displayedStreams(
            streams: [], groups: groups(), selectedAddonId: nil,
            sortOption: .quality, includeDebrid: false, episodeTarget: target
        )
        XCTAssertEqual(all.map(\.id), [addonUHD.id, addonHD.id, plex.id, addonUnnamed.id])
    }

    func testAnAddOnNamedLikeALibraryIsNotTrusted() {
        let all = StreamPickerListBuilder.displayedStreams(
            streams: [], groups: groups(plexId: "some.addon"), selectedAddonId: nil,
            sortOption: .default, includeDebrid: false, preserveAddonStreams: true,
            episodeTarget: target
        )
        XCTAssertEqual(all.first?.id, addonHD.id)
    }
}
