import XCTest
@testable import NuvioTV

final class DebridStreamTemplateTests: XCTestCase {
    private var store: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "test.debrid.template.\(UUID().uuidString)"
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

    private let full: [String: DebridTemplateValue] = [
        "stream.resolution": .text("2160p"),
        "stream.quality": .text("WEB-DL"),
        "stream.visualTags": .list(["HDR+DV", "DV", "HDR"]),
        "stream.audioTags": .list(["Atmos", "DD+"]),
        "stream.audioChannels": .list(["5.1"]),
        "stream.size": .bytes(5_368_709_120),
        "stream.encode": .text("HEVC"),
        "stream.releaseGroup": .text("FLUX"),
        "stream.filename": .text("Show.S01E01.2160p.mkv"),
        "stream.library": .bool(false),
        "service.cached": .bool(true),
        "service.shortName": .text("TB"),
        "addon.name": .text("torrentio addon")
    ]

    private let bare: [String: DebridTemplateValue] = [
        "service.cached": .bool(true),
        "service.shortName": .text("RD")
    ]

    private func render(_ template: String, _ values: [String: DebridTemplateValue]) -> String? {
        DebridStreamTemplate(template)?.render(values)
    }

    /// A result as `DebridStreamPresentation` names it once the service confirmed it.
    private func confirmedResult(_ index: Int, name: String = "4K TB Instant") -> NuvioStream {
        NuvioStream(
            url: nil,
            name: name,
            description: "Film.2021.2160p.WEB-DL.DDP5.1.H.265-FLUX\n18.2 GB",
            addonName: "Addon",
            infoHash: String(format: "%040x", 0x2000 + index),
            filename: "Film.2021.2160p.WEB-DL.DDP5.1.H.265-FLUX.mkv",
            isCached: true
        )
    }

    // MARK: - The desktop app's templates

    func testDesktopNameTemplate() {
        let template = DebridStreamFormatting.desktopNameTemplate
        XCTAssertEqual(render(template, full), "2160p TB Instant")
        XCTAssertEqual(render(template, bare), "RD Instant")
        XCTAssertEqual(render(template, [:]), "Cloud Instant")
    }

    func testLegacyNameTemplate() {
        let template = DebridStreamFormatting.legacyNameTemplate
        XCTAssertEqual(render(template, full), "4K TB Ready")
        XCTAssertEqual(render(template, bare), "RD Ready")
    }

    func testLegacyDescriptionTemplateDropsEmptyLines() {
        let detailed = DebridStreamFormatting.render(
            nameTemplate: "",
            descriptionTemplate: DebridStreamFormatting.legacyDescriptionTemplate,
            values: full
        )
        XCTAssertNil(detailed.name)
        XCTAssertEqual(
            detailed.description,
            "WEB-DL HDR+DV | DV | HDR HEVC\nAtmos | DD+ | 5.1\n5 GB FLUX\nReady (TB)\nShow.S01E01.2160p.mkv"
        )

        let sparse = DebridStreamFormatting.render(
            nameTemplate: "",
            descriptionTemplate: DebridStreamFormatting.legacyDescriptionTemplate,
            values: bare
        )
        XCTAssertEqual(sparse.description, "Ready (RD)")
    }

    func testEveryPresetIsATemplate() {
        for preset in DebridStreamFormatting.namePresets + DebridStreamFormatting.descriptionPresets {
            XCTAssertNotNil(DebridStreamTemplate(preset.template), preset.label)
            XCTAssertTrue(DebridStreamFormatting.isUsable(preset.template), preset.label)
        }
        XCTAssertEqual(render(DebridStreamFormatting.qualityNameTemplate, full), "2160p WEB-DL TB")
        XCTAssertEqual(render(DebridStreamFormatting.encodeNameTemplate, full), "2160p WEB-DL HEVC TB")
        XCTAssertEqual(render(DebridStreamFormatting.compactDescriptionTemplate, full), "WEB-DL HEVC Atmos DD+ 5 GB FLUX")
    }

    // MARK: - The language

    func testPlainTextAndValues() {
        XCTAssertEqual(render("plain text } stays", full), "plain text } stays")
        XCTAssertEqual(render("{stream.resolution} / {stream.title}!", full), "2160p / !")
        XCTAssertEqual(render("{stream.audioTags}", full), "Atmos, DD+")
        XCTAssertEqual(render("", full), "")
    }

    func testTransforms() {
        XCTAssertEqual(render("{stream.size::bytes}", full), "5 GB")
        XCTAssertEqual(render("{stream.audioTags::join(' / ')}", full), "Atmos / DD+")
        XCTAssertEqual(render("{addon.name::title}", full), "Torrentio Addon")
        XCTAssertEqual(render("{addon.name::upper}", full), "TORRENTIO ADDON")
        XCTAssertEqual(render("{stream.encode::lower}", full), "hevc")
        XCTAssertEqual(render("{stream.filename::replace('.', ' ')}", full), "Show S01E01 2160p mkv")
        XCTAssertEqual(render("{stream.title::bytes}", full), "")
    }

    func testChoices() {
        XCTAssertEqual(render(#"{stream.quality::exists["yes"||"no"]}"#, full), "yes")
        XCTAssertEqual(render(#"{stream.quality::exists["yes"||"no"]}"#, bare), "no")
        XCTAssertEqual(render(#"{stream.quality::exists["only"]}"#, bare), "")
        XCTAssertEqual(render(#"{stream.audioTags::~atm["A"||"B"]}{stream.audioTags::=dd+["C"||"D"]}{stream.audioTags::=dd["E"||"F"]}"#, full), "ACF")
        XCTAssertEqual(render(#"{stream.size::>=5000000000["big"||"small"]} {stream.size::<100["tiny"||"not tiny"]}"#, full), "big not tiny")
        XCTAssertEqual(render(#"{service.cached::istrue["Ready"||"Not Ready"]} {stream.library::isfalse["not library"||"library"]}"#, full), "Ready not library")
        XCTAssertEqual(render(#"{stream.library["t"||"f"]}{service.cached["t"||"f"]}"#, full), "ft")
    }

    func testQuotedConditionValues() {
        XCTAssertEqual(render(#"{stream.quality::="WEB-DL"["a"||"b"]}"#, full), "a")
        XCTAssertEqual(render(#"{stream.quality::='web-dl'["a"||"b"]}"#, full), "a")
        XCTAssertEqual(render(#"{stream.quality::="BluRay"["a"||"b"]}"#, full), "b")
        XCTAssertEqual(render(#"{stream.audioTags::~"atm"["a"||"b"]}"#, full), "a")
        XCTAssertEqual(render(#"{stream.quality::=WEB-DL["a"||"b"]}"#, full), "a")
    }

    func testAndOr() {
        XCTAssertEqual(render(#"{stream.quality::exists::and::stream.title::exists["both"||"not both"]}"#, full), "not both")
        XCTAssertEqual(render(#"{stream.quality::exists::and::stream.encode::exists["both"||"not both"]}"#, full), "both")
        XCTAssertEqual(render(#"{stream.title::exists::or::stream.quality::exists["either"||"neither"]}"#, full), "either")
        XCTAssertEqual(render(#"{stream.title::exists::or::stream.year::exists["either"||"neither"]}"#, full), "neither")
    }

    func testNestedTemplatesInAChoice() {
        XCTAssertEqual(
            render(#"{stream.quality::exists["{stream.quality} ({stream.encode::lower})"||"?"]}"#, full),
            "WEB-DL (hevc)"
        )
    }

    func testCurlyQuotesFromTheKeyboardAreRead() {
        XCTAssertEqual(
            render("{stream.quality::exists[\u{201C}{stream.quality}!\u{201D}||\u{201C}\u{201D}]}", full),
            "WEB-DL!"
        )
    }

    // MARK: - Templates that cannot be read

    func testTemplatesThatCannotBeRead() {
        XCTAssertNil(DebridStreamTemplate("{stream.resolution"))
        XCTAssertNil(DebridStreamTemplate("{stream.nope}"))
        XCTAssertNil(DebridStreamTemplate("{}"))
        XCTAssertNil(DebridStreamTemplate("{stream.size::frobnicate}"))
        XCTAssertNil(DebridStreamTemplate(#"{stream.size::>abc["a"||"b"]}"#))
        XCTAssertNil(DebridStreamTemplate(#"{stream.quality::exists["a"||"b"}"#))
        XCTAssertNil(DebridStreamTemplate(#"{stream.quality::exists["{stream.nope}"||""]}"#))
        XCTAssertFalse(DebridStreamFormatting.isUsable("{stream.resolution"))
        XCTAssertTrue(DebridStreamFormatting.isUsable(""))
    }

    // MARK: - Falling back to the default

    func testATemplateThatCannotBeReadKeepsTheDefault() {
        let display = DebridStreamFormatting.render(
            nameTemplate: "{stream.resolution",
            descriptionTemplate: "{stream.nope}",
            values: full
        )
        XCTAssertNil(display.name)
        XCTAssertNil(display.description)
    }

    func testATemplateThatDrawsNothingKeepsTheDefault() {
        let display = DebridStreamFormatting.render(
            nameTemplate: "{stream.title}  ",
            descriptionTemplate: "{stream.year}\n \n",
            values: full
        )
        XCTAssertNil(display.name)
        XCTAssertNil(display.description)
    }

    func testNameIsOneLineAndDescriptionHasNoBlankLines() {
        let display = DebridStreamFormatting.render(
            nameTemplate: " {stream.resolution}\n  {service.shortName} ",
            descriptionTemplate: " {stream.quality} \n\n{stream.title}\n {stream.encode}",
            values: full
        )
        XCTAssertEqual(display.name, "2160p TB")
        XCTAssertEqual(display.description, "WEB-DL\nHEVC")
    }

    // MARK: - Sizes and times

    func testByteSizes() {
        XCTAssertEqual(DebridStreamTemplate.formatBytes(0), "0 B")
        XCTAssertEqual(DebridStreamTemplate.formatBytes(1023), "1023 B")
        XCTAssertEqual(DebridStreamTemplate.formatBytes(1024), "1 KB")
        XCTAssertEqual(DebridStreamTemplate.formatBytes(1536), "1.5 KB")
        XCTAssertEqual(DebridStreamTemplate.formatBytes(5_368_709_120), "5 GB")
        XCTAssertEqual(DebridStreamTemplate.formatBytes(13_314_398_617), "12 GB")
        XCTAssertEqual(DebridStreamTemplate.formatBytes(10_695_475_200), "10 GB")
        XCTAssertEqual(DebridStreamTemplate.formatBytes(.nan), "")
    }

    func testTimes() {
        XCTAssertEqual(DebridStreamTemplate.formatTime(3725), "1h 2m")
        XCTAssertEqual(DebridStreamTemplate.formatTime(125), "2m 5s")
        XCTAssertEqual(DebridStreamTemplate.formatTime(9), "9s")
    }

    // MARK: - Which results are rewritten

    func testDefaultSettingsRewriteNothing() {
        let formatting = DebridStreamFormatting(settings: store)
        XCTAssertTrue(formatting.isDefault)
        XCTAssertNil(formatting.display(for: confirmedResult(1)))
    }

    func testAConfirmedResultIsRewritten() {
        store.set(DebridStreamFormatting.desktopNameTemplate, forKey: SettingsKey.debridNameTemplate)
        let display = DebridStreamFormatting(settings: store).display(for: confirmedResult(2))
        XCTAssertEqual(display?.name, "2160p TB Instant")
        // No description template: the add-on's own description stays.
        XCTAssertNil(display?.description)
    }

    func testDescriptionTemplateReadsTheResult() {
        store.set(DebridStreamFormatting.compactDescriptionTemplate, forKey: SettingsKey.debridDescriptionTemplate)
        let display = DebridStreamFormatting(settings: store).display(for: confirmedResult(3))
        XCTAssertNil(display?.name)
        XCTAssertEqual(display?.description, "WEB-DL HEVC DD+ 18 GB FLUX")
    }

    func testOtherStreamsKeepTheirOwnText() {
        store.set(DebridStreamFormatting.desktopNameTemplate, forKey: SettingsKey.debridNameTemplate)
        let formatting = DebridStreamFormatting(settings: store)

        let direct = NuvioStream(url: "https://example.com/a.mkv", name: "Direct 1080p", description: nil, addonName: "Direct", isCached: true)
        XCTAssertNil(formatting.display(for: direct))

        // A torrent the service could not confirm keeps the add-on's name.
        let unconfirmed = confirmedResult(4, name: "Torrentio 4k")
        XCTAssertNil(formatting.display(for: unconfirmed))

        let notCached = NuvioStream(
            url: nil,
            name: "4K TB Instant",
            description: nil,
            addonName: "Addon",
            infoHash: String(format: "%040x", 0x2fff)
        )
        XCTAssertNil(formatting.display(for: notCached))
    }

    func testNothingIsRewrittenWhileDebridIsOff() {
        store.set(DebridStreamFormatting.desktopNameTemplate, forKey: SettingsKey.debridNameTemplate)
        store.set(false, forKey: SettingsKey.debridEnabled)
        XCTAssertNil(DebridStreamFormatting(settings: store).display(for: confirmedResult(5)))
    }

    func testAnUnreadableTemplateLeavesTheResultAlone() {
        store.set("{stream.resolution", forKey: SettingsKey.debridNameTemplate)
        XCTAssertNil(DebridStreamFormatting(settings: store).display(for: confirmedResult(6)))
    }

    func testFormattedResultCheck() {
        XCTAssertTrue(DebridStreamPresentation.isFormattedResult(confirmedResult(7), provider: .torbox))
        XCTAssertTrue(DebridStreamPresentation.isFormattedResult(confirmedResult(8, name: "TB Instant"), provider: .torbox))
        XCTAssertFalse(DebridStreamPresentation.isFormattedResult(confirmedResult(9), provider: .realDebrid))
        XCTAssertFalse(DebridStreamPresentation.isFormattedResult(confirmedResult(10, name: "Torrentio 4k"), provider: .torbox))
    }
}
