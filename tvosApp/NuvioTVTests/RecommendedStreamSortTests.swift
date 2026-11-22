import XCTest
@testable import NuvioTV

final class RecommendedStreamSortTests: XCTestCase {
    func testRecommendedSortPrioritizesResolutionThenDynamicRange() {
        let hd = NuvioStream(url: "https://example.test/hd", name: "1080p SDR", description: nil, addonName: "B")
        let ultraHD = NuvioStream(url: "https://example.test/uhd", name: "2160p SDR", description: nil, addonName: "A")
        let hdr = NuvioStream(url: "https://example.test/hdr", name: "2160p HDR", description: nil, addonName: "B")
        let sorted = StreamPickerListBuilder.sorted([hd, ultraHD, hdr], by: .recommended)
        XCTAssertEqual(sorted.map(\.id), [hdr.id, ultraHD.id, hd.id])
    }

    func testRecommendedSortKeepsInputOrderForEquivalentFacts() {
        let first = NuvioStream(url: "https://example.test/one", name: "1080p", description: nil, addonName: "A")
        let second = NuvioStream(url: "https://example.test/two", name: "1080p", description: nil, addonName: "B")
        let sorted = StreamPickerListBuilder.sorted([first, second], by: .recommended)
        XCTAssertEqual(sorted.map(\.id), [first.id, second.id])
    }

    func testAudioRankingUsesDeclaredMetadataOnly() {
        func stream(_ name: String) -> NuvioStream {
            NuvioStream(url: "https://example.test/movie", name: name, description: nil, addonName: "A")
        }
        XCTAssertGreaterThan(StreamPickerListBuilder.recommendedAudioRank(for: stream("1080p Atmos")),
                             StreamPickerListBuilder.recommendedAudioRank(for: stream("1080p DD+")))
        XCTAssertGreaterThan(StreamPickerListBuilder.recommendedAudioRank(for: stream("1080p DTS-HD MA 5.1")),
                             StreamPickerListBuilder.recommendedAudioRank(for: stream("1080p AAC")))
        XCTAssertEqual(StreamPickerListBuilder.recommendedAudioRank(for: stream("1080p")), 0)
    }

    func testBestPerResolutionKeepsLowerResolutionsAvailable() {
        let high = NuvioStream(url: "https://example.test/4k", name: "2160p", description: nil, addonName: "A")
        let standard = NuvioStream(url: "https://example.test/1080", name: "1080p", description: nil, addonName: "B")
        let low = NuvioStream(url: "https://example.test/480", name: "480p", description: nil, addonName: "B")
        let sorted = StreamPickerListBuilder.displayedStreams(
            streams: [low, standard, high], groups: [], selectedAddonId: nil,
            sortOption: .recommended, includeDebrid: false
        )
        let picks = StreamPickerListBuilder.recommendedByResolution(from: sorted)
        XCTAssertEqual(picks.map { $0.resolution }, [2160, 1080, 480])
        XCTAssertEqual(picks.map { $0.stream.id }, [high.id, standard.id, low.id])
    }

    func testEpisodeTargetRanksConfirmedBeforeUnknownAndDropsExplicitMismatchesAutomatically() {
        let target = StreamEpisodeTarget(season: 1, episode: 2)
        let wrongUHD = NuvioStream(url: "https://example.test/wrong", name: "Show S01E06 2160p", description: nil, addonName: "A")
        let unknown = NuvioStream(url: "https://example.test/unknown", name: "2160p WEB-DL", description: nil, addonName: "B")
        let confirmedHD = NuvioStream(url: "https://example.test/right", name: "Show S01E02 720p", description: nil, addonName: "C")
        let confirmedFHD = NuvioStream(url: "https://example.test/right2", name: "Show 1x02 1080p", description: nil, addonName: "D")

        let sorted = StreamPickerListBuilder.automaticStreams(
            streams: [wrongUHD, unknown, confirmedHD, confirmedFHD],
            sortOption: .recommended, includeDebrid: false, cachedOnly: false,
            preserveAddonStreams: false, episodeTarget: target
        )
        XCTAssertEqual(sorted.map(\.id), [confirmedFHD.id, confirmedHD.id, unknown.id])

        let manual = StreamPickerListBuilder.displayedStreams(
            streams: [wrongUHD, confirmedHD], groups: [], selectedAddonId: nil,
            sortOption: .recommended, includeDebrid: false,
            selectionMode: .manual, episodeTarget: target
        )
        XCTAssertEqual(manual.map(\.id), [confirmedHD.id, wrongUHD.id])

        let onlyWrong = StreamPickerListBuilder.automaticStreams(
            streams: [wrongUHD], sortOption: .recommended, includeDebrid: false,
            cachedOnly: false, preserveAddonStreams: false, episodeTarget: target
        )
        XCTAssertTrue(onlyWrong.isEmpty)
    }

    func testEpisodeTargetParsesBoundedLabelsAndRejectsAmbiguousEvidence() {
        let target = StreamEpisodeTarget(season: 1, episode: 2)
        func stream(_ name: String, description: String? = nil) -> NuvioStream {
            NuvioStream(url: "https://example.test/item", name: name, description: description, addonName: "A")
        }
        XCTAssertEqual(target.match(for: stream("Show S01E02 1080p")), .confirmed)
        XCTAssertEqual(target.match(for: stream("Show 1x02 1080p")), .confirmed)
        XCTAssertEqual(target.match(for: stream("Season 1 Episode 2")), .confirmed)
        XCTAssertEqual(target.match(for: stream("Show S01E020")), .mismatch, "Episode 20 must not match episode 2 by prefix")
        XCTAssertEqual(target.match(for: stream("Show S01E20 S01E02")), .unknown, "Adjacent labels must both be detected")
        XCTAssertEqual(target.match(for: stream("Show S01E02", description: "Show S01E03")), .unknown)
        XCTAssertEqual(target.match(for: stream("Show S01E01-E03")), .unknown)
        XCTAssertEqual(target.match(for: stream("Show 1x01-1x03")), .unknown)
        XCTAssertEqual(target.match(filename: "Show_S01E01-E03_1080p.mkv"), .unknown)
        XCTAssertEqual(target.match(filename: "Show_1x01-1x03_1080p.mkv"), .unknown)
        XCTAssertEqual(target.match(for: stream("Show Season 1 Pack S01E02")), .unknown)
        XCTAssertEqual(target.match(for: stream("2160p UHD")), .unknown, "Quality labels carry no episode evidence")
    }

    func testEpisodeTargetURLUsesRecognizablePathFilenameAndIgnoresQueries() {
        let target = StreamEpisodeTarget(season: 1, episode: 2)
        XCTAssertEqual(target.match(url: URL(string: "https://cdn.test/Show.S01E02.mkv?token=S01E06")!), .confirmed)
        XCTAssertEqual(target.match(url: URL(string: "https://cdn.test/opaque/ab1234567890abcdefabcdef?episode=S01E02")!), .unknown)
        XCTAssertEqual(target.match(url: URL(string: "https://cdn.test/Show.S01E06.mkv")!), .mismatch)
        XCTAssertEqual(target.match(url: URL(string: "https://cdn.test/watch/S01E06?token=abc")!), .unknown)
    }

    func testEpisodeTargetCanKeepAlternateNumberingUnknown() {
        let target = StreamEpisodeTarget(season: 1, episode: 2, allowsMismatch: false)
        let alternateNumbering = NuvioStream(
            url: "https://example.test/alternate", name: "Show S01E03 1080p",
            description: nil, addonName: "A"
        )
        XCTAssertEqual(target.match(for: alternateNumbering), .unknown)
        XCTAssertEqual(target.match(for: NuvioStream(
            url: nil, name: "Show S01E02", description: nil, addonName: "A"
        )), .confirmed)
        XCTAssertNotEqual(StreamEpisodeTarget(season: 1, episode: 2), target,
                          "Picker cache identity includes the mismatch policy")
    }

    func testLastPlayedPromotionPreservesOtherOrderAndRejectsDuplicateIDs() {
        let first = NuvioStream(url: "https://example.test/first", name: "1080p", description: nil, addonName: "A")
        let played = NuvioStream(url: "https://example.test/played", name: "2160p", description: nil, addonName: "B")
        let last = NuvioStream(url: "https://example.test/last", name: "720p", description: nil, addonName: "C")
        let ordered = [first, played, last]

        let promoted = StreamPickerListBuilder.promotingPlayableSource(played.id, in: ordered)
        XCTAssertEqual(promoted.map(\.id), [played.id, first.id, last.id])

        let duplicate = NuvioStream(url: "https://example.test/played", name: "Duplicate", description: nil, addonName: "D")
        let ambiguous = [first, played, duplicate, last]
        XCTAssertEqual(StreamPickerListBuilder.promotingPlayableSource(played.id, in: ambiguous), ambiguous)
        XCTAssertNil(StreamPickerListBuilder.uniquePlayableIndex(for: played.id, in: ambiguous))

        let unavailableDuplicate = NuvioStream(
            url: played.url, name: "Duplicate", description: nil, addonName: "D", notPlayable: true
        )
        XCTAssertEqual(
            StreamPickerListBuilder.promotingPlayableSource(played.id, in: [first, played, unavailableDuplicate]),
            [first, played, unavailableDuplicate]
        )
    }

    @MainActor
    func testPickerMatchesHistoryAcrossDuplicateSourceIDsWithoutCollapsingRows() {
        let first = NuvioStream(url: "https://example.test/played", name: "2160p", description: nil, addonName: "B")
        let duplicate = NuvioStream(url: first.url, name: "2160p", description: nil, addonName: "D")
        let unavailableDuplicate = NuvioStream(
            url: first.url, name: "Action", description: nil, addonName: "A", notPlayable: true
        )
        let pickerRows = [unavailableDuplicate, first, duplicate]
        let rowFocusIDs = StreamPickerListBuilder.rowFocusIDs(for: pickerRows)

        XCTAssertEqual(pickerRows.count, 3, "Different add-on rows and headers remain available")
        XCTAssertEqual(Set(rowFocusIDs).count, pickerRows.count)
        XCTAssertEqual(StreamPickerListBuilder.firstPlayableIndex(for: first.id, in: pickerRows), 1)
        XCTAssertEqual(
            StreamPickerListBuilder.uniquePlayableSourceIDs(in: pickerRows),
            [first.id],
            "History matching receives one deterministic candidate ID"
        )
        let promoted = StreamPickerListBuilder.promotingPlayableSource(at: 1, in: pickerRows)
        XCTAssertEqual(promoted, [first, unavailableDuplicate, duplicate])
        XCTAssertEqual(
            StreamPickerListBuilder.promotingRowFocusIDs(at: 1, in: rowFocusIDs).first,
            rowFocusIDs[1]
        )

        let enriched = NuvioStream(
            url: first.url, name: "2160p HDR", description: "New metadata", addonName: "B",
            addonLogoURL: "https://example.test/logo.png", isCached: true
        )
        XCTAssertEqual(
            StreamPickerListBuilder.rowFocusIDs(for: [enriched]).first,
            StreamPickerListBuilder.rowFocusIDs(for: [first]).first,
            "Progressive metadata must not change a source row's focus identity"
        )

        let sameAddonDuplicate = NuvioStream(
            url: first.url, name: "1080p", description: nil, addonName: "B"
        )
        let sourceOrder = [first, sameAddonDuplicate]
        let sourceOrderIDs = StreamPickerListBuilder.rowFocusIDs(for: sourceOrder)
        XCTAssertEqual(
            StreamPickerListBuilder.rowFocusIDs(
                for: [sameAddonDuplicate, first],
                inSourceOrder: sourceOrder
            ),
            [sourceOrderIDs[1], sourceOrderIDs[0]],
            "Sorting must preserve duplicate row identities assigned from source order"
        )

        let suiteName = "RecommendedStreamSortTests.\(UUID().uuidString)"
        let store = UserDefaults(suiteName: suiteName)!
        defer { store.removePersistentDomain(forName: suiteName) }
        LastManualSourceStore.remember(
            sourceID: first.id, profileID: "profile", metaID: "movie", type: "movie",
            season: nil, episode: nil, store: store
        )
        let match = LastManualSourceStore.lastPlayedMatch(
            in: StreamPickerListBuilder.uniquePlayableSourceIDs(in: pickerRows),
            profileID: "profile", metaID: "movie", type: "movie",
            season: nil, episode: nil, store: store
        )
        XCTAssertEqual(match?.sourceID, first.id)
    }
}
