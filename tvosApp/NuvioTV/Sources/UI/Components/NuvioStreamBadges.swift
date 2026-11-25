import SwiftUI

/// Stream badges drawn by the app instead of an imported badge pack: the
/// official Dolby, DTS and HDR10+ marks in white, and plain labels for the
/// rest, all on the same translucent pill as the file size badge.
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
    case codec(String)
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
            result.append(.resolution("4K"))
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
            result.append(.source("BluRay"))
        } else if has(#"\bweb[ ._-]?dl\b"#) {
            result.append(.source("WEB-DL"))
        } else if has(#"\bweb[ ._-]?rip\b"#) {
            result.append(.source("WEBRip"))
        } else if has(#"\bhdtv\b"#) {
            result.append(.source("HDTV"))
        } else if has(#"\bdvd(rip)?\b"#) {
            result.append(.source("DVD"))
        }

        if has(#"\bav1\b"#) {
            result.append(.codec("AV1"))
        } else if has(#"\b(hevc|[hx][ ._]?265)\b"#) {
            result.append(.codec("HEVC"))
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
