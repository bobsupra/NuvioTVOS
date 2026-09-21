import Foundation

/// The ISO 639-2/T code an fMP4 audio track's `mdhd` carries, resolved from the source container's tag.
///
/// It also names the master's `EXT-X-MEDIA:TYPE=AUDIO` rendition, which is the tag AVFoundation actually
/// reads on an HLS asset: an fMP4 whose mdhd says "deu" still reports `AVAssetTrack.languageCode == nil`
/// without it, and AVKit's audio menu reads "Not Specified" (AE#458). The mdhd is written because the
/// track IS that language for whoever reads it; the master is what moves the label.
///
/// ICU resolves ISO 639-1, ISO 639-2/T and BCP-47 subtags ("pt-BR" -> "por"), but NOT the twenty ISO 639-2/B
/// bibliographic codes, and Matroska writes exactly those ("ger", "fre", "cze"), so they are mapped first.
/// Everything else fails closed: a label ICU can neither resolve nor name writes no language at all,
/// which leaves the unlabelled-track behaviour untouched.
enum AudioLanguageMap {
    /// The twenty ISO 639-2 languages whose bibliographic code differs from the terminological one.
    /// None of these is a valid ISO 639-1 or 639-2/T code for a different language, so matching them
    /// first cannot shadow a real tag.
    private static let terminologicalByBibliographic: [String: String] = [
        "alb": "sqi", "arm": "hye", "baq": "eus", "bur": "mya", "chi": "zho",
        "cze": "ces", "dut": "nld", "fre": "fra", "geo": "kat", "ger": "deu",
        "gre": "ell", "ice": "isl", "mac": "mkd", "mao": "mri", "may": "msa",
        "per": "fas", "rum": "ron", "slo": "slk", "tib": "bod", "wel": "cym",
    ]

    static func iso639_2T(forSourceLanguage language: String?) -> String? {
        guard let raw = language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty
        else { return nil }
        if let terminological = terminologicalByBibliographic[raw] { return terminological }
        // "und" resolves to itself; writing it is the same as writing nothing, and movenc's default
        // already is und.
        if let alpha3 = alpha3(of: raw) { return alpha3 }
        // ICU's language table has no alpha3 entry for the ISO 639-3 members it aliases to a
        // macrolanguage ("cmn", "arb", "pes", "swh", "uzn", "kmr"), so Mandarin tagged "cmn" lost its
        // LANGUAGE while "yue" and "nan", which CLDR does not alias, resolved (htrung14, AE#458).
        // Canonicalizing resolves the alias; running it only where the direct route came back empty
        // keeps every tag that resolves today on its current answer ("no" stays "nor", not "nob").
        //
        // Gated on a well-formed BCP-47 primary subtag: canonicalization also turns "English" into
        // "en" and "Japanese" into "jpn", and free text in a language field is a track NAME, not a
        // tag. Guessing at it is how a commentary track ends up labelled as a language.
        guard hasLanguageSubtagShape(raw) else { return nil }
        let canonical = Locale.canonicalLanguageIdentifier(from: raw)
        if canonical != raw, let aliased = alpha3(of: canonical) { return aliased }
        return namedThreeLetterTag(raw)
    }

    /// A three-letter tag ICU can NAME but has no alpha3 entry for is already the ISO 639 code, so it
    /// passes through unchanged: `cnr` (Montenegrin), `prs` (Dari), `npi`, `ory`, `quz`, `crs`, `pis`
    /// and 49 more measured on macOS 26 (56 tags in all). Neither route above reaches them, because `identifier(.alpha3)`
    /// only maps the 639-1/639-2 pairs and CLDR does not alias these to anything (`canonicalLanguageIdentifier`
    /// returns them unchanged). htrung14 found the class through `cnr` on the AE#458 retest.
    ///
    /// **The display name is the validity gate that canonicalization is not.** `canonicalLanguageIdentifier`
    /// echoes its input for ANYTHING it does not know, so "cnr" -> "cnr" and "dub" -> "dub" are the same
    /// answer and pass-through on that signal alone would label a track tagged `dub` or `sfx` as a language.
    /// `localizedString(forLanguageCode:)` returns nil for those and "Montenegrin" for `cnr`.
    ///
    /// The reference locale is FIXED, not `Locale.current`: `cnr` has an English display name and no German
    /// one, so a device-language gate would resolve the same file on one Apple TV and not on the next.
    /// Two-letter tags are excluded (only `bh` reaches here, and it is not a three-letter code to write).
    private static func namedThreeLetterTag(_ raw: String) -> String? {
        let primary = String(raw.prefix { $0 != "-" && $0 != "_" })
        guard primary.count == 3, primary != "und" else { return nil }
        guard let name = languageNameReferenceLocale.localizedString(forLanguageCode: primary),
              name != primary
        else { return nil }
        return primary
    }

    /// ICU display data, not app resources, so this resolves on any device regardless of installed
    /// localizations. See `namedThreeLetterTag`.
    private static let languageNameReferenceLocale = Locale(identifier: "en_US")

    private static func alpha3(of identifier: String) -> String? {
        guard let alpha3 = Locale.Language(identifier: identifier).languageCode?.identifier(.alpha3),
              alpha3.count == 3, alpha3 != "und"
        else { return nil }
        return alpha3
    }

    /// RFC 5646 2.2.1: a language subtag is 2 or 3 ASCII letters (4 is reserved, 5 to 8 registered,
    /// neither of which any container writes). Anything else is prose, not a tag.
    private static func hasLanguageSubtagShape(_ raw: String) -> Bool {
        let primary = raw.prefix { $0 != "-" && $0 != "_" }
        return (2...3).contains(primary.count) && primary.allSatisfy { $0.isASCII && $0.isLetter }
    }
}
