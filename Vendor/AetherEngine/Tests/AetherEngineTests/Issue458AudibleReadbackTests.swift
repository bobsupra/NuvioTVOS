import Foundation
import Testing
@testable import AetherEngine

/// AE#458: the engine has always logged what it SERVED (`audioLang=` on the serving line) and never what
/// AVFoundation RESOLVED from it. The resolved value is the one AVKit prints in its audio menu, so a report
/// of "Not Specified" could only ever be answered from the first half of the exchange.
struct Issue458AudibleReadbackTests {

    private func option(_ name: String, _ tag: String?) -> AudibleSelectionReadback.Option {
        AudibleSelectionReadback.Option(displayName: name, languageTag: tag)
    }

    @Test("The agreeing case names both halves and says they agree")
    func servedAndResolvedAgree() {
        let english = option("English", "eng")
        let line = AudibleSelectionReadback.line(
            served: "eng", servingMaster: true, groupPresent: true,
            options: [english], selected: english)
        #expect(line.contains("served=eng"))
        #expect(line.contains("resolved=\"English\" (eng)"))
        #expect(line.contains("options=1"))
        #expect(!line.contains("MISMATCH"))
        #expect(!line.contains("no audible group"))
    }

    /// AVFoundation normalizes an HLS LANGUAGE tag (matroska "ger" comes back as "de", often with a region
    /// subtag), so a raw string compare would call every second German title a mismatch.
    @Test("A tag AVFoundation normalized is not a mismatch")
    func normalizedTagIsNotAMismatch() {
        for (served, resolved) in [("ger", "de"), ("deu", "de-DE"), ("fre", "fr"), ("eng", "en-US")] {
            let line = AudibleSelectionReadback.line(
                served: served, servingMaster: true, groupPresent: true,
                options: [option("Whatever", resolved)], selected: option("Whatever", resolved))
            #expect(!line.contains("MISMATCH"), "\(served) vs \(resolved) flagged")
        }
    }

    @Test("A genuinely different language is flagged, because that is a defect and not a normalization")
    func differentLanguageIsFlagged() {
        let line = AudibleSelectionReadback.line(
            served: "eng", servingMaster: true, groupPresent: true,
            options: [option("Français", "fr")], selected: option("Français", "fr"))
        #expect(line.contains("MISMATCH"))
    }

    /// The reported shape: a master went out carrying a rendition, and nothing came back to read a language
    /// from. This is the line that answers #458 without a second round trip.
    @Test("A served rendition with no group back is the #458 shape, and says so")
    func servedRenditionWithNoGroup() {
        let line = AudibleSelectionReadback.line(
            served: "eng", servingMaster: true, groupPresent: false, options: [], selected: nil)
        #expect(line.contains("served=eng"))
        #expect(line.contains("no audible group"))
        #expect(line.contains("Not Specified"))
    }

    /// An empty group is the same loss as a missing one: AVKit has nothing to label the track from.
    @Test("An empty group reads like a missing one")
    func emptyGroupReadsLikeAMissingOne() {
        let line = AudibleSelectionReadback.line(
            served: "eng", servingMaster: true, groupPresent: true, options: [], selected: nil)
        #expect(line.contains("no audible group"))
    }

    /// Not every session declares audio: a media-direct title has no master to carry a rendition, and the
    /// absent group there is the documented consequence, not a finding. The line must not cry defect.
    @Test("A media-direct session with nothing declared is reported as expected, not as a loss")
    func mediaDirectSessionIsNotADefect() {
        let line = AudibleSelectionReadback.line(
            served: nil, servingMaster: false, groupPresent: false, options: [], selected: nil)
        #expect(line.contains("media playlist"))
        #expect(!line.contains("Not Specified"))
        #expect(!line.contains("MISMATCH"))
    }

    /// A master that served no rendition is a different sentence from one that served a rendition and lost it.
    @Test("A master without a declared rendition names the master and the absence")
    func masterWithoutRendition() {
        let line = AudibleSelectionReadback.line(
            served: nil, servingMaster: true, groupPresent: false, options: [], selected: nil)
        #expect(line.contains("served=none"))
        #expect(!line.contains("Not Specified"))
    }

    /// A group with options but no selection still answers the question it was added for.
    @Test("Options without a selection are still listed")
    func optionsWithoutSelection() {
        let line = AudibleSelectionReadback.line(
            served: "eng", servingMaster: true, groupPresent: true,
            options: [option("English", "eng"), option("Commentary", nil)], selected: nil)
        #expect(line.contains("options=2"))
        #expect(line.contains("resolved=none"))
        #expect(line.contains("English"))
    }

    /// The line goes into a 300-line ring buffer, so it is one line and it is bounded.
    @Test("The line stays one bounded line whatever the title declares")
    func lineStaysOneBoundedLine() {
        let many = (1...12).map { option("Track \($0)", "eng") }
        let line = AudibleSelectionReadback.line(
            served: "eng", servingMaster: true, groupPresent: true, options: many, selected: many[0])
        #expect(!line.contains("\n"))
        #expect(line.count < 400)
        #expect(line.contains("options=12"))
        #expect(line.contains("more"))
    }

    @Test("A displayName AVFoundation left empty does not produce an empty pair of quotes")
    func emptyDisplayNameIsNamed() {
        let line = AudibleSelectionReadback.line(
            served: "eng", servingMaster: true, groupPresent: true,
            options: [option("", "eng")], selected: option("", "eng"))
        #expect(!line.contains("\"\""))
    }

    /// The readback is worth nothing if it never runs: the loopback load is the path #458 and #541 are about.
    @Test("The loopback load calls the readback")
    func loopbackLoadCallsTheReadback() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/AetherEngine/AetherEngine+Loading.swift")
        guard let text = try? String(contentsOf: source, encoding: .utf8) else { return }
        #expect(text.contains("logAudibleReadback(host: host)"))
    }
}
