import XCTest
@testable import NuvioTV

final class DebridResultRulesTests: XCTestCase {
    private var store: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "test.debrid.rules.\(UUID().uuidString)"
        store = UserDefaults(suiteName: suiteName)!
        store.set(true, forKey: SettingsKey.debridEnabled)
        store.set(DebridProviderKind.torbox.rawValue, forKey: SettingsKey.debridProvider)
        store.set("test-token", forKey: SettingsKey.torboxAccessToken)
    }

    override func tearDown() {
        store.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - Helpers

    /// A torrent the debrid service resolves. Each index gives its own hash.
    private func debrid(_ index: Int, _ release: String) -> NuvioStream {
        NuvioStream(
            url: nil,
            name: "Addon",
            description: release,
            addonName: "Addon",
            infoHash: String(format: "%040x", 0x1000 + index),
            filename: release + ".mkv"
        )
    }

    private func direct(_ index: Int, _ release: String) -> NuvioStream {
        NuvioStream(
            url: "https://example.com/\(index).mkv",
            name: "Direct",
            description: release,
            addonName: "Direct"
        )
    }

    private func setRules(_ edit: (inout DebridResultRules) -> Void) {
        var rules = DebridResultRules()
        edit(&rules)
        store.set(rules.json, forKey: SettingsKey.debridResultRules)
    }

    private func applied(_ streams: [NuvioStream]) -> [String] {
        DebridResultLimits(settings: store).applied(to: streams).compactMap(\.description)
    }

    private func facts(_ release: String, name: String? = nil) -> DebridStreamFacts {
        DebridStreamFacts.parse(
            name: name,
            description: release,
            filename: nil,
            resolution: StreamQualityTags.resolution(in: release),
            quality: StreamQualityTags.quality(in: release)
        )
    }

    private let uhd = "Film.2021.2160p.WEB-DL.DDP5.1.Atmos.DV.HDR10+.H.265-FLUX"
    private let fhd = "Film.2021.1080p.BluRay.x264.DTS.5.1-NTb"
    private let hd = "Film.2021.720p.WEBRip.x264.AAC.2.0-YTS"

    // MARK: - Defaults

    func testNoRulesLeavesTheListAsItCame() {
        let streams = [debrid(1, hd), direct(2, fhd), debrid(3, uhd)]
        XCTAssertFalse(DebridResultLimits(settings: store).isActive)
        XCTAssertEqual(DebridResultLimits(settings: store).applied(to: streams), streams)
    }

    func testEmptyRulesStoreNothing() {
        var rules = DebridResultRules()
        rules.toggle(.required, .resolutions, "P1080")
        rules.toggle(.required, .resolutions, "P1080")
        XCTAssertTrue(rules.isEmpty)
        XCTAssertEqual(rules.json, "")
    }

    func testRulesDoNothingWhileDebridIsOff() {
        store.set(false, forKey: SettingsKey.debridEnabled)
        setRules { $0.set(.required, .resolutions, ["P2160"]) }
        let streams = [debrid(1, hd), debrid(2, uhd)]
        XCTAssertEqual(DebridResultLimits(settings: store).applied(to: streams), streams)
    }

    // MARK: - Required and excluded

    func testRequiredResolutionsHideOtherDebridResults() {
        setRules { $0.set(.required, .resolutions, ["P2160", "P1080"]) }
        XCTAssertEqual(applied([debrid(1, hd), debrid(2, fhd), debrid(3, uhd)]), [fhd, uhd])
    }

    func testExcludedValuesHideMatchingDebridResults() {
        setRules {
            $0.set(.excluded, .audioTags, ["AAC"])
            $0.set(.excluded, .qualities, ["BLURAY"])
        }
        XCTAssertEqual(applied([debrid(1, hd), debrid(2, fhd), debrid(3, uhd)]), [uhd])
    }

    func testRequiredTagNeedsOnlyOneOfTheSelectedValues() {
        setRules { $0.set(.required, .visualTags, ["DV", "IMAX"]) }
        XCTAssertEqual(applied([debrid(1, fhd), debrid(2, uhd)]), [uhd])
    }

    func testRequiredEncodeAndChannels() {
        setRules {
            $0.set(.required, .encodes, ["AVC"])
            $0.set(.required, .audioChannels, ["CH_5_1"])
        }
        XCTAssertEqual(applied([debrid(1, hd), debrid(2, fhd), debrid(3, uhd)]), [fhd])
    }

    func testOtherSourcesAreNeverHiddenOrMoved() {
        setRules {
            $0.set(.required, .resolutions, ["P2160"])
            $0.set(.preferred, .qualities, ["WEB_DL"])
        }
        let streams = [direct(1, hd), debrid(2, fhd), direct(3, fhd), debrid(4, uhd)]
        // The 2160p result takes the first debrid place. The direct sources stay where they were.
        XCTAssertEqual(applied(streams), [hd, uhd, fhd])
        XCTAssertEqual(DebridResultLimits(settings: store).applied(to: streams).map(\.addonName), ["Direct", "Addon", "Direct"])
    }

    func testRulesThatHideEverySourceShowTheFullList() {
        setRules { $0.set(.required, .resolutions, ["P480"]) }
        let streams = [debrid(1, hd), debrid(2, fhd), debrid(3, uhd)]
        XCTAssertEqual(DebridResultLimits(settings: store).applied(to: streams), streams)
    }

    func testFullListFallbackKeepsTheOriginalOrder() {
        setRules {
            $0.set(.required, .resolutions, ["P480"])
            $0.set(.preferred, .resolutions, ["P2160"])
        }
        let streams = [debrid(1, hd), debrid(2, fhd), debrid(3, uhd)]
        XCTAssertEqual(DebridResultLimits(settings: store).applied(to: streams), streams)
    }

    func testReleaseGroupRulesIgnoreLetterCase() {
        setRules { $0.setReleaseGroups(["flux", "ntb"], required: true) }
        XCTAssertEqual(applied([debrid(1, hd), debrid(2, fhd), debrid(3, uhd)]), [fhd, uhd])

        setRules { $0.setReleaseGroups(["Flux"], required: false) }
        XCTAssertEqual(applied([debrid(1, hd), debrid(2, fhd), debrid(3, uhd)]), [hd, fhd])
    }

    // MARK: - Preferred

    func testPreferredValuesComeFirstAndTiesKeepTheirOrder() {
        setRules { $0.set(.preferred, .resolutions, ["P1080"]) }
        let streams = [debrid(1, hd), debrid(2, uhd), debrid(3, fhd), debrid(4, fhd + ".PROPER")]
        XCTAssertEqual(applied(streams), [fhd, fhd + ".PROPER", hd, uhd])
    }

    func testPreferredValuesRankInTheFacetOrder() {
        // 2160p ranks ahead of 1080p whichever was selected first.
        setRules {
            $0.toggle(.preferred, .resolutions, "P1080")
            $0.toggle(.preferred, .resolutions, "P2160")
        }
        XCTAssertEqual(applied([debrid(1, hd), debrid(2, fhd), debrid(3, uhd)]), [uhd, fhd, hd])
    }

    func testEarlierFacetsDecideBeforeLaterOnes() {
        setRules {
            $0.set(.preferred, .encodes, ["AVC"])
            $0.set(.preferred, .resolutions, ["P720"])
        }
        // Resolution is compared first, then encode.
        XCTAssertEqual(applied([debrid(1, uhd), debrid(2, fhd), debrid(3, hd)]), [hd, fhd, uhd])
    }

    // MARK: - With the limits

    func testRulesApplyBeforeTheLimits() {
        setRules { $0.set(.required, .resolutions, ["P1080", "P2160"]) }
        store.set(1, forKey: SettingsKey.debridMaxResults)
        XCTAssertEqual(applied([debrid(1, hd), debrid(2, fhd), debrid(3, uhd)]), [fhd])
    }

    func testPreferredOrderDecidesWhatTheLimitKeeps() {
        setRules { $0.set(.preferred, .resolutions, ["P2160"]) }
        store.set(1, forKey: SettingsKey.debridMaxResults)
        XCTAssertEqual(applied([debrid(1, hd), debrid(2, fhd), debrid(3, uhd)]), [uhd])
    }

    // MARK: - Languages

    func testLanguagesAreReadFromWordsCodesAndFlags() {
        XCTAssertEqual(facts("Film 1969 1080p BluRay ITA ENG").languages, ["EN", "IT"])
        XCTAssertEqual(facts("Film.2021.1080p.WEB-DL\n🇫🇷 / 🇩🇪").languages, ["FR", "DE"])
        XCTAssertEqual(facts("Film 2021 1080p Multi").languages, ["MULTI"])
    }

    func testTitleWordsAndAudioTagsAreNotLanguages() {
        XCTAssertEqual(facts("The.French.Dispatch.2021.1080p.WEB-DL.x264").languages, [])
        XCTAssertEqual(facts("The Italian Job 1969 1080p BluRay DTS-ES").languages, [])
    }

    func testExcludedLanguagesHideOnlyWhenEveryLanguageIsExcluded() {
        var rules = DebridResultRules()
        rules.set(.excluded, .languages, ["IT"])
        XCTAssertFalse(rules.matches(facts("Film 2021 1080p ITA")))
        XCTAssertTrue(rules.matches(facts("Film 2021 1080p ITA ENG")))
        XCTAssertTrue(rules.matches(facts("Film 2021 1080p")))
    }

    func testAResultWithNoLanguageCountsAsUnknown() {
        var rules = DebridResultRules()
        rules.set(.required, .languages, ["EN"])
        XCTAssertFalse(rules.matches(facts("Film 2021 1080p")))
        rules.set(.required, .languages, ["EN", DebridRuleFacet.unknown])
        XCTAssertTrue(rules.matches(facts("Film 2021 1080p")))
    }

    // MARK: - Facts

    func testFactsOfAReleaseName() {
        let parsed = facts(uhd)
        XCTAssertEqual(parsed.resolution, "P2160")
        XCTAssertEqual(parsed.quality, "WEB_DL")
        XCTAssertEqual(parsed.visualTags, ["HDR_DV", "HDR10_PLUS", "HDR10", "DV", "HDR"])
        XCTAssertEqual(parsed.audioTags, ["ATMOS", "DD_PLUS"])
        XCTAssertEqual(parsed.audioChannels, ["CH_5_1"])
        XCTAssertEqual(parsed.encode, "HEVC")
    }

    func testFactsWithNothingToRead() {
        let parsed = DebridStreamFacts.parse(name: nil, description: nil, filename: nil, resolution: 0, quality: .unknown)
        XCTAssertEqual(parsed.resolution, DebridRuleFacet.unknown)
        XCTAssertEqual(parsed.quality, DebridRuleFacet.unknown)
        XCTAssertEqual(parsed.visualTags, [DebridRuleFacet.unknown])
        XCTAssertEqual(parsed.audioTags, [DebridRuleFacet.unknown])
        XCTAssertEqual(parsed.audioChannels, [DebridRuleFacet.unknown])
        XCTAssertEqual(parsed.encode, DebridRuleFacet.unknown)
        XCTAssertEqual(parsed.languages, [])
        XCTAssertEqual(parsed.releaseGroup, "")
    }

    func testTagsNeedWordBoundaries() {
        // "HDRip" is not HDR, "dts" inside a word is not DTS, and "15.1" is not 5.1.
        let parsed = facts("Film.2021.HDRip.XviD.Soundts.15.10")
        XCTAssertEqual(parsed.visualTags, [DebridRuleFacet.unknown])
        XCTAssertEqual(parsed.audioTags, [DebridRuleFacet.unknown])
        XCTAssertEqual(parsed.audioChannels, [DebridRuleFacet.unknown])
        XCTAssertEqual(parsed.encode, "XVID")
    }

    func testChannelsAfterTheAudioFormat() {
        XCTAssertEqual(facts("Film.2021.1080p.AAC.2.0").audioChannels, ["CH_2_0"])
        XCTAssertEqual(facts("Film.2021.1080p.DDP5.1").audioChannels, ["CH_5_1"])
        XCTAssertEqual(facts("Film.2021.1080p.TrueHD 7.1").audioChannels, ["CH_7_1"])
    }

    func testResolutionIDs() {
        XCTAssertEqual(DebridRuleFacet.resolutionID(2160), "P2160")
        XCTAssertEqual(DebridRuleFacet.resolutionID(1080), "P1080")
        XCTAssertEqual(DebridRuleFacet.resolutionID(540), "P480")
        XCTAssertEqual(DebridRuleFacet.resolutionID(0), DebridRuleFacet.unknown)
    }

    func testRulesThatHideEveryDebridResultKeepTheDirectSource() {
        setRules { $0.set(.required, .resolutions, ["P480"]) }
        let streams = [debrid(1, hd), direct(2, fhd), debrid(3, uhd)]
        // The direct source is still there to play, so the rules stand.
        XCTAssertEqual(applied(streams), [fhd])
        XCTAssertEqual(DebridResultLimits(settings: store).applied(to: streams).map(\.addonName), ["Direct"])
    }

    // MARK: - Release groups

    func testReleaseGroupAfterTheCodec() {
        XCTAssertEqual(facts("Movie.2019.1080p.BluRay.x264-SPARKS.mkv").releaseGroup, "SPARKS")
        XCTAssertEqual(facts("Show.S01E02.720p.WEB-DL.DDP5.1.H.264-GRP").releaseGroup, "GRP")
        XCTAssertEqual(facts("Film.2020.2160p.TrueHD.7.1.Atmos-GRP.mkv").releaseGroup, "GRP")
        XCTAssertEqual(facts("Movie.2019.1080p.x264-GRP[TGx]").releaseGroup, "GRP")
    }

    func testHyphenatedTagsAreNotReleaseGroups() {
        XCTAssertEqual(facts("Movie.2019.1080p.WEB-DL").releaseGroup, "")
        XCTAssertEqual(facts("Movie.2019.1080p.WEB-DL.mkv").releaseGroup, "")
        XCTAssertEqual(facts("Movie.2019.1080p.DTS-HD").releaseGroup, "")
        XCTAssertEqual(facts("Movie.2019.1080p.H-264").releaseGroup, "")
        XCTAssertEqual(facts("Movie.2019.1080p.DD-EX").releaseGroup, "")
        XCTAssertEqual(facts("Multi-Audio").releaseGroup, "")
    }

    func testBracketedAndKnownGroupsAreStillRead() {
        XCTAssertEqual(facts("Movie.2019.1080p.x264 [QxR]").releaseGroup.uppercased(), "QXR")
        XCTAssertEqual(facts("Movie 2019 1080p x264 YTS").releaseGroup.uppercased(), "YTS")
    }

    func testReleaseGroupRulesWorkForAnyGroup() {
        let sparks = "Movie.2019.1080p.BluRay.x264-SPARKS"
        setRules { $0.setReleaseGroups(["sparks"], required: false) }
        XCTAssertEqual(applied([debrid(1, sparks), debrid(2, uhd)]), [uhd])
        setRules { $0.setReleaseGroups(["sparks"], required: true) }
        XCTAssertEqual(applied([debrid(1, sparks), debrid(2, uhd)]), [sparks])
    }

    // MARK: - Audio spellings

    func testAudioFormatsWrittenAgainstTheChannels() {
        XCTAssertEqual(facts("Film.2020.1080p.DD5.1").audioTags, ["DD"])
        XCTAssertEqual(facts("Film.2020.1080p.DD2.0").audioTags, ["DD"])
        XCTAssertEqual(facts("Film.2020.1080p.AAC2.0").audioTags, ["AAC"])
        XCTAssertEqual(facts("Film.2020.1080p.FLAC2.0.Opus5.1").audioTags, ["OPUS", "FLAC"])
    }

    func testDTSSpellings() {
        XCTAssertEqual(facts("Film.2020.1080p.DTS-HD.MA.5.1").audioTags, ["DTS_HD_MA", "DTS_HD", "DTS"])
        XCTAssertEqual(facts("Film.2020.1080p.DTS-HD_MA").audioTags, ["DTS_HD_MA", "DTS_HD", "DTS"])
        XCTAssertEqual(facts("Film.2020.1080p.DTS-X.7.1").audioTags, ["DTS_X", "DTS"])
        XCTAssertEqual(facts("Film.2020.1080p.DTS.X").audioTags, ["DTS_X", "DTS"])
        // The codec after DTS is not DTS:X.
        XCTAssertEqual(facts("Film.2020.1080p.DTS-x264").audioTags, ["DTS"])
    }

    func testDolbyDigitalPlusIsNotAlsoPlainDolbyDigital() {
        XCTAssertEqual(facts("Film.2020.1080p.DD+5.1").audioTags, ["DD_PLUS"])
        XCTAssertEqual(facts("Film.2020.1080p.DDP5.1").audioTags, ["DD_PLUS"])
        XCTAssertEqual(facts("Film.2020.1080p.Dolby Digital Plus").audioTags, ["DD_PLUS"])
        XCTAssertEqual(facts("Film.2020.1080p.EAC3").audioTags, ["DD_PLUS"])
        XCTAssertEqual(facts("Film.2020.1080p.Dolby Digital 5.1").audioTags, ["DD"])
    }

    func testTitleWordsAreNotTags() {
        XCTAssertEqual(facts("The.Fairly.OddParents.2001.720p.WEB").audioTags, [DebridRuleFacet.unknown])
        XCTAssertEqual(facts("Ghost.in.the.Shell.2.0.2008.1080p").audioChannels, [DebridRuleFacet.unknown])
        XCTAssertEqual(facts("AI.Artificial.Intelligence.2001.1080p").visualTags, [DebridRuleFacet.unknown])
    }

    func testFrenchReleaseTags() {
        for tag in ["VFF", "VF", "VFQ", "VOSTFR", "TRUEFRENCH"] {
            XCTAssertEqual(facts("Film.2020.1080p.\(tag).x264").languages, ["FR"], tag)
        }
        XCTAssertEqual(facts("Film.2020.MULTi.VF2.1080p").languages, ["FR", "MULTI"])
    }

    // MARK: - Contradictory selections

    func testRequiringAValueStopsExcludingIt() {
        var rules = DebridResultRules()
        rules.toggle(.excluded, .resolutions, "P1080")
        rules.toggle(.required, .resolutions, "P1080")
        XCTAssertEqual(rules.selection(.required, .resolutions), ["P1080"])
        XCTAssertEqual(rules.selection(.excluded, .resolutions), [])
    }

    func testExcludingAValueStopsRequiringAndPreferringIt() {
        var rules = DebridResultRules()
        rules.toggle(.preferred, .resolutions, "P1080")
        rules.toggle(.preferred, .resolutions, "P2160")
        rules.toggle(.required, .resolutions, "P1080")
        rules.toggle(.excluded, .resolutions, "P1080")
        XCTAssertEqual(rules.selection(.excluded, .resolutions), ["P1080"])
        XCTAssertEqual(rules.selection(.required, .resolutions), [])
        XCTAssertEqual(rules.selection(.preferred, .resolutions), ["P2160"])
    }

    func testTurningAValueOffLeavesTheOtherRulesAlone() {
        var rules = DebridResultRules()
        rules.toggle(.required, .resolutions, "P1080")
        rules.toggle(.preferred, .resolutions, "P1080")
        rules.toggle(.preferred, .resolutions, "P1080")
        XCTAssertEqual(rules.selection(.required, .resolutions), ["P1080"])
        // The same value in another facet is a different value.
        rules.toggle(.excluded, .audioTags, "AAC")
        XCTAssertEqual(rules.selection(.required, .resolutions), ["P1080"])
    }

    // MARK: - Storage

    func testStoredRulesRoundTrip() {
        var rules = DebridResultRules()
        rules.set(.required, .resolutions, ["P1080", "P2160"])
        rules.set(.excluded, .audioTags, ["AAC"])
        rules.set(.preferred, .encodes, ["HEVC"])
        rules.setReleaseGroups(["FLUX", " flux ", "NTb", ""], required: true)

        let restored = DebridResultRules(json: rules.json)
        XCTAssertEqual(restored, rules)
        XCTAssertEqual(restored.selection(.required, .resolutions), ["P2160", "P1080"])
        XCTAssertEqual(restored.requiredReleaseGroups, ["FLUX", "NTb"])
        XCTAssertEqual(restored.activeRuleCount, 4)
        XCTAssertTrue(restored.hasFilters)
        XCTAssertTrue(restored.hasPreferences)
    }

    func testStoredRulesDropUnknownValuesAndBadText() {
        let rules = DebridResultRules(json: #"{"requiredResolutions":["P1080","P9000"],"excludedEncodes":["NOPE"],"other":[1]}"#)
        XCTAssertEqual(rules.selection(.required, .resolutions), ["P1080"])
        XCTAssertEqual(rules.selection(.excluded, .encodes), [])
        XCTAssertEqual(rules.activeRuleCount, 1)

        XCTAssertTrue(DebridResultRules(json: nil).isEmpty)
        XCTAssertTrue(DebridResultRules(json: "not json").isEmpty)
        XCTAssertTrue(DebridResultRules(json: "[1, 2]").isEmpty)
    }

    func testFieldNamesMatchTheDesktopApp() {
        XCTAssertEqual(DebridResultRules.field(.required, .resolutions), "requiredResolutions")
        XCTAssertEqual(DebridResultRules.field(.excluded, .visualTags), "excludedVisualTags")
        XCTAssertEqual(DebridResultRules.field(.preferred, .audioChannels), "preferredAudioChannels")
    }

    func testReleaseGroupsTypedOnOneLine() {
        XCTAssertEqual(DebridResultRules.releaseGroups(fromText: " FLUX, NTb ;YTS,, "), ["FLUX", "NTb", "YTS"])
        XCTAssertEqual(DebridResultRules.releaseGroups(fromText: ""), [])
    }

    func testEveryRuleValueHasAUniqueID() {
        for facet in DebridRuleFacet.allCases {
            let ids = facet.options.map(\.id)
            XCTAssertEqual(Set(ids).count, ids.count, "\(facet)")
            XCTAssertEqual(ids.last, DebridRuleFacet.unknown, "\(facet)")
        }
    }
}
