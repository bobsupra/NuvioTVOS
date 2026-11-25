import SwiftUI

/// Stream badges drawn by the app instead of an imported badge pack, all on
/// the same translucent pill as the file size badge. The official Dolby,
/// DTS, HDR10+ and Blu-ray Disc marks and the logo of the service a WEB
/// release came from are drawn in white, as are the 4K Ultra HD and HEVC
/// marks made for the app. The rest are plain labels.
/// Settings > Layout > Stream List > Nuvio Badges.
enum NuvioStreamBadge: Hashable {
    case resolution(String)
    /// Dolby Vision, with "FEL" or "MEL" when the release names its layer.
    case dolbyVision(layer: String?)
    case hdr10Plus
    case hdr10
    /// "HDR" with no format named.
    case hdr
    case hlg
    case atmos
    case trueHD
    case dolbyDigitalPlus
    case dtsX
    case dtsHDMA
    /// DTS-HD High Resolution Audio, or "DTS-HD" with no variant named.
    case dtsHD(variant: String?)
    case dts
    /// Formats with no mark: Dolby Digital, AAC, FLAC, Opus, PCM.
    case audio(String)
    case channels(String)
    case source(String)
    /// The Blu-ray Disc mark.
    case bluRay
    /// 4K, as a 4K Ultra HD mark drawn for the app.
    case ultraHD
    case codec(String)
    /// HEVC, as an HEVC / H.265 mark drawn for the app.
    case hevc
    /// The streaming service a WEB release was taken from, by its logo.
    case service(StreamingService)
    case bitDepth(String)
    /// IMAX, 3D.
    case edition(String)

    /// The asset catalog mark, when the badge shows one.
    var logoAsset: String? {
        switch self {
        case .dolbyVision: return "badge_dolby_vision"
        case .atmos: return "badge_dolby_atmos"
        case .trueHD: return "badge_dolby_truehd"
        case .dolbyDigitalPlus: return "badge_dolby_ddplus"
        case .hdr10Plus: return "badge_hdr10plus"
        case .dtsX: return "badge_dts_x"
        case .dtsHDMA: return "badge_dts_hd_ma"
        case .dts, .dtsHD: return "badge_dts"
        case .bluRay: return "badge_bluray"
        case .ultraHD: return "badge_ultra_hd"
        case .hevc: return "badge_hevc"
        case .service(let service): return service.logoAsset
        default: return nil
        }
    }

    /// Text after the mark, or the whole badge when there is no mark.
    var label: String? {
        switch self {
        case .resolution(let text), .audio(let text), .channels(let text), .source(let text),
             .codec(let text), .bitDepth(let text), .edition(let text):
            return text
        case .dolbyVision(let layer): return layer
        case .hdr10: return "HDR10"
        case .hdr: return "HDR"
        case .hlg: return "HLG"
        case .dtsHD(let variant): return ["HD", variant].compactMap { $0 }.joined(separator: " ")
        default: return nil
        }
    }

    /// Mark height as a share of the pill's height. One-line wordmarks stay
    /// near the text's height; stacked and boxed marks get more room so their
    /// letters come out about as large as the plain labels.
    var logoHeightShare: CGFloat {
        switch self {
        case .dolbyVision, .atmos: return 0.5
        // TrueHD's double-D spans both lines, so it reads larger than its height.
        case .trueHD: return 0.62
        case .dolbyDigitalPlus, .dtsHDMA: return 0.8
        case .hdr10Plus: return 0.72
        case .dtsX: return 0.66
        case .dts, .dtsHD: return 0.6
        case .bluRay: return 0.72
        // Drawn so the boxed letters are 64 of 152 units tall: at 0.8 they
        // match the cap height of the plain labels.
        case .ultraHD, .hevc: return 0.8
        case .service(let service): return service.logoHeightShare
        default: return 0
        }
    }

    var accessibilityName: String {
        switch self {
        case .dolbyVision(let layer): return ["Dolby Vision", layer].compactMap { $0 }.joined(separator: " ")
        case .atmos: return "Dolby Atmos"
        case .trueHD: return "Dolby TrueHD"
        case .dolbyDigitalPlus: return "Dolby Digital Plus"
        case .hdr10Plus: return "HDR10+"
        case .dtsX: return "DTS:X"
        case .dtsHDMA: return "DTS-HD Master Audio"
        case .dtsHD(let variant): return ["DTS-HD", variant].compactMap { $0 }.joined(separator: " ")
        case .dts: return "DTS"
        case .bluRay: return "Blu-ray"
        case .ultraHD: return "4K Ultra HD"
        case .hevc: return "HEVC"
        case .service(let service): return service.name
        case .audio(let text): return text == "DD" ? "Dolby Digital" : text
        default: return label ?? ""
        }
    }

    /// Badges for `stream`, read from its name, description and file name, in
    /// the order resolution, video range, audio, channels, source, codec, bit
    /// depth, edition.
    static func badges(for stream: NuvioStream) -> [NuvioStreamBadge] {
        let text = [stream.name, stream.description, stream.filename]
            .compactMap { $0 }
            .joined(separator: "\n")
        return badges(in: text)
    }

    static func badges(in original: String) -> [NuvioStreamBadge] {
        let text = original.lowercased()
        func has(_ pattern: String) -> Bool {
            text.range(of: pattern, options: .regularExpression) != nil
        }
        var result: [NuvioStreamBadge] = []

        if has(#"\b(2160p|4k|uhd)\b"#) {
            result.append(.ultraHD)
        } else if has(#"\b1440p\b"#) {
            result.append(.resolution("1440p"))
        } else if has(#"\b1080[pi]\b"#) {
            result.append(.resolution("1080p"))
        } else if has(#"\b720p\b"#) {
            result.append(.resolution("720p"))
        } else if has(#"\b576[pi]\b"#) {
            result.append(.resolution("576p"))
        } else if has(#"\b480[pi]\b"#) {
            result.append(.resolution("480p"))
        }

        if has(#"\b(dv|dovi|dolby[ ._-]?vision)\b"#) {
            // Upper case only, on the original text: "Mel" is also a name.
            func names(_ layer: String) -> Bool {
                original.range(of: "\\b\(layer)\\b", options: .regularExpression) != nil
            }
            result.append(.dolbyVision(layer: names("FEL") ? "FEL" : (names("MEL") ? "MEL" : nil)))
        }
        if has(#"hdr10(\+|plus|p\b)"#) {
            result.append(.hdr10Plus)
        } else if has(#"\bhdr10\b"#) {
            result.append(.hdr10)
        } else if has(#"\bhdr\b"#) {
            result.append(.hdr)
        } else if has(#"\bhlg\b"#) {
            result.append(.hlg)
        }

        if has(#"\batmos\b"#) { result.append(.atmos) }
        if has(#"\btrue[ ._-]?hd\b"#) {
            result.append(.trueHD)
        } else if has(#"\bdts[ ._:-]?x\b"#) {
            result.append(.dtsX)
        } else if has(#"\bdts[ ._-]?(hd[ ._-]?)?hra\b"#) {
            result.append(.dtsHD(variant: "HRA"))
        } else if has(#"\bdts[ ._-]?(hd[ ._-]?)?(ma\b|master)"#) {
            result.append(.dtsHDMA)
        } else if has(#"\bdts[ ._-]?hd\b"#) {
            result.append(.dtsHD(variant: nil))
        } else if has(#"\b(ddp|dd\+|e[ ._-]?ac[ ._-]?3|dolby[ ._-]?digital[ ._-]?plus)"#) {
            result.append(.dolbyDigitalPlus)
        } else if has(#"\bdts\b"#) {
            result.append(.dts)
        } else if has(#"\b(ac[ ._-]?3|dd|dolby[ ._-]?digital)\b|\bdd(?=[257][ ._][01])"#) {
            result.append(.audio("DD"))
        } else if has(#"\bflac\b"#) {
            result.append(.audio("FLAC"))
        } else if has(#"\bl?pcm\b"#) {
            result.append(.audio("PCM"))
        } else if has(#"\b(he[ ._-]?)?aac"#) {
            result.append(.audio("AAC"))
        } else if has(#"\bopus\b"#) {
            result.append(.audio("Opus"))
        }

        // No word boundary in front: codecs run into the layout ("DDP5.1").
        // Not when a unit follows: "5.1 GB" is a file size, "7.1 Mbps" a bitrate.
        let notUnit = #"(?![0-9]|[ ]?([kmgt]i?b|[kmg]bps|[kmg]b/s)\b)"#
        if has(#"(?<![0-9])7[ ._]1"# + notUnit) {
            result.append(.channels("7.1"))
        } else if has(#"(?<![0-9])5[ ._]1"# + notUnit) {
            result.append(.channels("5.1"))
        } else if has(#"(?<![0-9])2[ ._]0"# + notUnit) {
            result.append(.channels("2.0"))
        }

        if has(#"\bremux\b"#) {
            result.append(.source("REMUX"))
        } else if has(#"\b(blu[ ._-]?ray|bdrip|brrip)\b"#) {
            result.append(.bluRay)
        } else if has(#"\bweb[ ._-]?dl\b"#) {
            result.append(.source("WEB-DL"))
            if let service = StreamingService.named(in: original) { result.append(.service(service)) }
        } else if has(#"\bweb[ ._-]?rip\b"#) {
            result.append(.source("WEBRip"))
            if let service = StreamingService.named(in: original) { result.append(.service(service)) }
        } else if has(#"\bhdtv\b"#) {
            result.append(.source("HDTV"))
        } else if has(#"\bdvd(rip)?\b"#) {
            result.append(.source("DVD"))
        }

        if has(#"\bav1\b"#) {
            result.append(.codec("AV1"))
        } else if has(#"\b(hevc|[hx][ ._]?265)\b"#) {
            result.append(.hevc)
        } else if has(#"\b(avc|[hx][ ._]?264)\b"#) {
            result.append(.codec("H.264"))
        }

        if has(#"\b(10[ ._-]?bit|hi10p?)\b"#) {
            result.append(.bitDepth("10-bit"))
        } else if has(#"\b12[ ._-]?bit\b"#) {
            result.append(.bitDepth("12-bit"))
        }

        if has(#"\bimax\b"#) { result.append(.edition("IMAX")) }
        if has(#"\b3d\b"#) { result.append(.edition("3D")) }
        // The service a WEB release came from leads the row.
        if let index = result.firstIndex(where: { if case .service = $0 { return true } else { return false } }) {
            result.insert(result.remove(at: index), at: 0)
        }
        return result
    }
}

/// One app-drawn badge: the mark and/or label in white on a translucent pill.
struct NuvioStreamBadgeView: View {
    let badge: NuvioStreamBadge
    var scale: CGFloat = 1

    private var textSize: CGFloat { (17 * scale).rounded() }
    private var pillHeight: CGFloat { (36 * scale).rounded() }

    var body: some View {
        HStack(spacing: 4 * scale) {
            if let asset = badge.logoAsset {
                Image(asset)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(height: (pillHeight * badge.logoHeightShare).rounded())
            }
            if let label = badge.label {
                Text(label)
                    .font(.system(size: textSize, weight: .bold))
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .foregroundStyle(Color.white.opacity(0.92))
        .padding(.horizontal, 12 * scale)
        .frame(height: pillHeight)
        .background(Capsule().fill(Color.white.opacity(0.12)))
        .overlay(Capsule().stroke(Color.white.opacity(0.20), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(badge.accessibilityName)
    }
}

/// Services whose tag a WEB release names, as in "Show.S01E01.1080p.NF.WEB-DL".
/// Read only beside a WEB source, and only as an upper-case word on its own,
/// so "Max" in a title or "IMAX" never counts.
enum StreamingService: String, CaseIterable, Hashable {
    case netflix, primeVideo, disneyPlus, appleTV, hboMax, hulu, peacock, paramountPlus

    var tags: [String] {
        switch self {
        case .netflix: return ["NF"]
        case .primeVideo: return ["AMZN"]
        case .disneyPlus: return ["DSNP"]
        case .appleTV: return ["ATVP"]
        case .hboMax: return ["HMAX", "MAX"]
        case .hulu: return ["HULU"]
        case .peacock: return ["PCOK"]
        case .paramountPlus: return ["PMTP"]
        }
    }

    var name: String {
        switch self {
        case .netflix: return "Netflix"
        case .primeVideo: return "Prime Video"
        case .disneyPlus: return "Disney+"
        case .appleTV: return "Apple TV"
        case .hboMax: return "HBO Max"
        case .hulu: return "Hulu"
        case .peacock: return "Peacock"
        case .paramountPlus: return "Paramount+"
        }
    }

    var logoAsset: String {
        switch self {
        case .netflix: return "badge_service_netflix"
        case .primeVideo: return "badge_service_prime"
        case .disneyPlus: return "badge_service_disney"
        case .appleTV: return "badge_service_appletv"
        case .hboMax: return "badge_service_hbomax"
        case .hulu: return "badge_service_hulu"
        case .peacock: return "badge_service_peacock"
        case .paramountPlus: return "badge_service_paramount"
        }
    }

    /// Sized so each logo's main lettering is about as tall as the plain labels.
    var logoHeightShare: CGFloat {
        switch self {
        case .netflix: return 0.36
        case .primeVideo: return 0.74
        case .disneyPlus: return 0.72
        case .appleTV: return 0.5
        case .hboMax: return 0.62
        case .hulu: return 0.4
        case .peacock: return 0.42
        case .paramountPlus: return 0.5
        }
    }

    static func named(in original: String) -> StreamingService? {
        allCases.first { service in
            service.tags.contains { tag in
                original.range(of: "(?<![A-Za-z0-9])\(tag)(?![A-Za-z0-9])", options: .regularExpression) != nil
            }
        }
    }
}
