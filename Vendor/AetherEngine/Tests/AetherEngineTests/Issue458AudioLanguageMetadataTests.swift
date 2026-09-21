import Testing
import Foundation
@testable import AetherEngine

/// AE#458: the fMP4 audio track's `mdhd` language, resolved from whatever the source container tagged.
struct Issue458AudioLanguageMetadataTests {

    @Test("ISO 639-1 and 639-2/T source tags resolve to 639-2/T")
    func resolvesTerminologicalAndAlpha2() {
        #expect(AudioLanguageMap.iso639_2T(forSourceLanguage: "en") == "eng")
        #expect(AudioLanguageMap.iso639_2T(forSourceLanguage: "eng") == "eng")
        #expect(AudioLanguageMap.iso639_2T(forSourceLanguage: "de") == "deu")
        #expect(AudioLanguageMap.iso639_2T(forSourceLanguage: "deu") == "deu")
        #expect(AudioLanguageMap.iso639_2T(forSourceLanguage: "ja") == "jpn")
    }

    /// The reason a table is needed at all: ICU resolves neither of these, and Matroska writes them.
    @Test("ISO 639-2/B bibliographic codes resolve to their terminological form")
    func resolvesBibliographicCodes() {
        let pairs = [
            ("alb", "sqi"), ("arm", "hye"), ("baq", "eus"), ("bur", "mya"), ("chi", "zho"),
            ("cze", "ces"), ("dut", "nld"), ("fre", "fra"), ("geo", "kat"), ("ger", "deu"),
            ("gre", "ell"), ("ice", "isl"), ("mac", "mkd"), ("mao", "mri"), ("may", "msa"),
            ("per", "fas"), ("rum", "ron"), ("slo", "slk"), ("tib", "bod"), ("wel", "cym"),
        ]
        for (bibliographic, terminological) in pairs {
            #expect(AudioLanguageMap.iso639_2T(forSourceLanguage: bibliographic) == terminological,
                    "\(bibliographic) should resolve to \(terminological)")
        }
    }

    /// The gap a fixed table has: everything outside its rows is silently unlabelled.
    @Test("languages outside the common European set resolve too")
    func resolvesLongTailLanguages() {
        #expect(AudioLanguageMap.iso639_2T(forSourceLanguage: "fa") == "fas")
        #expect(AudioLanguageMap.iso639_2T(forSourceLanguage: "ta") == "tam")
        #expect(AudioLanguageMap.iso639_2T(forSourceLanguage: "bn") == "ben")
        #expect(AudioLanguageMap.iso639_2T(forSourceLanguage: "tl") == "tgl")
        #expect(AudioLanguageMap.iso639_2T(forSourceLanguage: "yue") == "yue")
    }

    /// htrung14, AE#458 follow-up: `Locale.Language(identifier: "cmn").languageCode?.identifier(.alpha3)`
    /// is nil, so Mandarin tagged with its ISO 639-3 code hit the fail-closed branch and lost LANGUAGE.
    /// ICU has no alpha3 entry for the 639-3 members it aliases to a macrolanguage; canonicalizing the
    /// tag first resolves them. `yue` and `nan` are NOT aliased and must keep their own codes.
    @Test("ISO 639-3 members ICU aliases to a macrolanguage resolve to that macrolanguage")
    func resolvesMacrolanguageMembers() {
        #expect(AudioLanguageMap.iso639_2T(forSourceLanguage: "cmn") == "zho")
        #expect(AudioLanguageMap.iso639_2T(forSourceLanguage: "arb") == "ara")
        #expect(AudioLanguageMap.iso639_2T(forSourceLanguage: "pes") == "fas")
        #expect(AudioLanguageMap.iso639_2T(forSourceLanguage: "swh") == "swa")
        #expect(AudioLanguageMap.iso639_2T(forSourceLanguage: "uzn") == "uzb")
        #expect(AudioLanguageMap.iso639_2T(forSourceLanguage: "kmr") == "kur")
    }

    /// The fallback runs only where the direct route came back empty, so no tag that resolves today
    /// changes its answer. Canonicalization would move both of these ("no" -> "nb", "tl" -> "fil").
    @Test("a tag ICU resolves directly keeps that answer, canonicalization does not override it")
    func directResolutionWinsOverCanonicalization() {
        #expect(AudioLanguageMap.iso639_2T(forSourceLanguage: "no") == "nor")
        #expect(AudioLanguageMap.iso639_2T(forSourceLanguage: "tl") == "tgl")
        #expect(AudioLanguageMap.iso639_2T(forSourceLanguage: "yue") == "yue")
        #expect(AudioLanguageMap.iso639_2T(forSourceLanguage: "nan") == "nan")
    }

    /// htrung14, AE#458 retest: `cnr` (Montenegrin) survived fail-closed, because ICU has a display name
    /// for it and no alpha3 entry, and CLDR does not alias it either, so neither route above reaches it.
    /// 57 three-letter tags are in that state on macOS 26; these are the ones a real library carries.
    /// The tag IS the ISO 639 code, so it passes through unchanged rather than resolving to anything.
    @Test("three-letter tags ICU names but cannot map pass through as themselves")
    func resolvesNamedThreeLetterTags() {
        #expect(AudioLanguageMap.iso639_2T(forSourceLanguage: "cnr") == "cnr")
        #expect(AudioLanguageMap.iso639_2T(forSourceLanguage: "prs") == "prs")
        #expect(AudioLanguageMap.iso639_2T(forSourceLanguage: "npi") == "npi")
        #expect(AudioLanguageMap.iso639_2T(forSourceLanguage: "ory") == "ory")
        #expect(AudioLanguageMap.iso639_2T(forSourceLanguage: "quz") == "quz")
        #expect(AudioLanguageMap.iso639_2T(forSourceLanguage: "crs") == "crs")
        #expect(AudioLanguageMap.iso639_2T(forSourceLanguage: "CNR-ME") == "cnr")
    }

    /// The pass-through gate is the DISPLAY NAME, not canonicalization, and this is why:
    /// `Locale.canonicalLanguageIdentifier(from:)` echoes anything it does not know, so it answers "cnr"
    /// for "cnr" and "dub" for "dub" alike. `localizedString(forLanguageCode:)` separates them.
    ///
    /// A three-letter label can be an ISO 639-3 code ICU simply has no data for yet, and a newer ICU can
    /// promote it: macOS 27's ICU names AND maps `com` (Comanche), so it resolves through `alpha3` like any other
    /// language and left this list. The name premise is asserted per label, so the next such move fails on
    /// the premise line instead of reading like an engine regression.
    @Test("three-letter labels ICU cannot name stay unresolved even though canonicalization echoes them")
    func namelessThreeLetterLabelsStayClosed() {
        for label in ["dub", "sub", "org", "sfx", "ost", "xyz", "zzz"] {
            #expect(Locale.canonicalLanguageIdentifier(from: label) == label)
            #expect(Locale(identifier: "en_US").localizedString(forLanguageCode: label) == nil)
            #expect(AudioLanguageMap.iso639_2T(forSourceLanguage: label) == nil)
        }
    }

    /// "und" has a display name ("Unknown language") and must still write nothing: it is the muxer's
    /// default, so writing it is the same as writing nothing.
    @Test("und stays unresolved although ICU names it")
    func undefinedStaysClosed() {
        #expect(Locale(identifier: "en_US").localizedString(forLanguageCode: "und") != nil)
        #expect(AudioLanguageMap.iso639_2T(forSourceLanguage: "und") == nil)
    }

    /// The name lookup runs against a FIXED reference locale. Reading `Locale.current` instead would
    /// resolve the same file on an English Apple TV and not on a German one: ICU has "Montenegrin" for
    /// `cnr` in en and no display name for it in de (measured macOS 26, 2026-09-03). This assertion
    /// therefore fails on a de_DE machine if that gate ever moves to the device language.
    @Test("resolution does not depend on the device UI language")
    func referenceLocaleIsFixed() {
        #expect(AudioLanguageMap.iso639_2T(forSourceLanguage: "cnr") == "cnr")
    }

    /// Canonicalization resolves "English" to "en" and "Japanese" to "jpn", so the fallback is gated on
    /// a well-formed BCP-47 primary subtag (2 or 3 letters). Free text in a language field is a NAME,
    /// not a tag, and guessing at it is how a commentary track ends up labelled as its own language.
    @Test("free text stays unresolved even where canonicalization would name a language")
    func freeTextIsNotCanonicalized() {
        #expect(AudioLanguageMap.iso639_2T(forSourceLanguage: "English") == nil)
        #expect(AudioLanguageMap.iso639_2T(forSourceLanguage: "Japanese") == nil)
        #expect(AudioLanguageMap.iso639_2T(forSourceLanguage: "Original") == nil)
        #expect(AudioLanguageMap.iso639_2T(forSourceLanguage: "Commentary") == nil)
    }

    @Test("region and script subtags collapse to the base language")
    func resolvesBCP47Subtags() {
        #expect(AudioLanguageMap.iso639_2T(forSourceLanguage: "pt-BR") == "por")
        #expect(AudioLanguageMap.iso639_2T(forSourceLanguage: "pt_BR") == "por")
        #expect(AudioLanguageMap.iso639_2T(forSourceLanguage: "zh-Hans") == "zho")
        #expect(AudioLanguageMap.iso639_2T(forSourceLanguage: "es-419") == "spa")
    }

    @Test("case and surrounding whitespace do not decide the outcome")
    func normalizesInput() {
        #expect(AudioLanguageMap.iso639_2T(forSourceLanguage: "GER") == "deu")
        #expect(AudioLanguageMap.iso639_2T(forSourceLanguage: "  en  ") == "eng")
    }

    /// Fails closed: an unresolvable label writes no language, which is the pre-AE#458 behaviour.
    @Test("unknown, undefined and free-text labels resolve to nothing")
    func failsClosed() {
        #expect(AudioLanguageMap.iso639_2T(forSourceLanguage: nil) == nil)
        #expect(AudioLanguageMap.iso639_2T(forSourceLanguage: "") == nil)
        #expect(AudioLanguageMap.iso639_2T(forSourceLanguage: "   ") == nil)
        #expect(AudioLanguageMap.iso639_2T(forSourceLanguage: "und") == nil)
        #expect(AudioLanguageMap.iso639_2T(forSourceLanguage: "xyz") == nil)
        #expect(AudioLanguageMap.iso639_2T(forSourceLanguage: "English") == nil)
        #expect(AudioLanguageMap.iso639_2T(forSourceLanguage: "Director Commentary") == nil)
        #expect(AudioLanguageMap.iso639_2T(forSourceLanguage: "3") == nil)
    }

    /// movenc packs the three letters into mdhd 5 bits at a time, so anything outside a-z is dropped
    /// on the floor there instead of here.
    @Test("every resolved value is three lowercase ASCII letters")
    func outputIsMuxerSafe() {
        for tag in ["en", "ger", "pt-BR", "yue", "zh-Hans", "fa", "tl", "nb", "cnr", "prs", "cmn"] {
            guard let resolved = AudioLanguageMap.iso639_2T(forSourceLanguage: tag) else {
                Issue.record("\(tag) unexpectedly unresolved")
                continue
            }
            #expect(resolved.count == 3)
            #expect(resolved.allSatisfy { $0.isASCII && $0.isLowercase && $0.isLetter })
        }
    }
}

/// AE#458: the master's EXT-X-MEDIA:TYPE=AUDIO tag. Measured on macOS 26, this is the ONLY place
/// AVFoundation reads an audio language from on an HLS asset: with the tag absent, an fMP4 whose mdhd
/// says "deu" still reports `AVAssetTrack.languageCode == nil` and builds no audible selection group.
private final class AudioRenditionMockProvider: HLSSegmentProvider, @unchecked Sendable {
    let audio: (language: String, name: String)?
    init(audio: (language: String, name: String)?) { self.audio = audio }
    func initSegment() -> Data? { Data([0x00]) }
    func mediaSegment(at index: Int) -> Data? { Data([0x00]) }
    var segmentCount: Int { 1 }
    func segmentDuration(at index: Int) -> Double { 4.0 }
    var playlistType: HLSPlaylistType { .vod }
    var masterCodecs: String? { "hvc1.1.6.L120.90,mp4a.40.2" }
    var masterVideoRange: HLSVideoRange? { .sdr }
    var masterAudioRendition: (language: String, name: String)? { audio }
}

struct Issue458AudioRenditionPlaylistTests {

    @Test("a labelled audio track is declared as a URI-less muxed rendition and joined to the variant")
    func declaresMuxedAudioRendition() {
        let master = HLSLocalServer.buildMasterPlaylistText(
            provider: AudioRenditionMockProvider(audio: (language: "deu", name: "German"))
        )
        #expect(master.contains(
            "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"German\",LANGUAGE=\"deu\",DEFAULT=YES,AUTOSELECT=YES"
        ))
        #expect(master.contains("AUDIO=\"aud\""))
        // The audio is inside the variant, so the rendition must NOT carry a URI (RFC 8216 4.3.4.2.1);
        // one would send AVPlayer after a second playlist that does not exist.
        let mediaTag = master.split(separator: "\n").first { $0.hasPrefix("#EXT-X-MEDIA:TYPE=AUDIO") }
        #expect(mediaTag?.contains("URI=") == false)
    }

    @Test("an unlabelled audio track leaves the master exactly as it was")
    func untaggedSourceEmitsNoGroup() {
        let master = HLSLocalServer.buildMasterPlaylistText(
            provider: AudioRenditionMockProvider(audio: nil)
        )
        #expect(!master.contains("TYPE=AUDIO"))
        #expect(!master.contains("AUDIO=\"aud\""))
    }

    /// A group referenced by a variant has to exist, or AVPlayer fails the master outright.
    @Test("the variant's AUDIO attribute and the group it names appear together or not at all")
    func groupReferenceIsConsistent() {
        for audio in [("fas", "Persian"), ("yue", "Cantonese")] {
            let master = HLSLocalServer.buildMasterPlaylistText(
                provider: AudioRenditionMockProvider(audio: (language: audio.0, name: audio.1))
            )
            #expect(master.contains("LANGUAGE=\"\(audio.0)\""))
            #expect(master.contains("GROUP-ID=\"aud\"") == master.contains("AUDIO=\"aud\""))
        }
    }
}
