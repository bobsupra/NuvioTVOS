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
    case hlg
    case atmos
    case trueHD
    case dolbyDigitalPlus
    case dtsX
    case dtsHDMA
    case dts
    case channels(String)
    case source(String)
    case bitDepth(String)

    /// The asset catalog mark, when the badge shows one.
    var logoAsset: String? {
        switch self {
        case .dolbyVision: return "badge_dolby_vision"
        case .atmos: return "badge_dolby_atmos"
        case .trueHD: return "badge_dolby_truehd"
        case .dolbyDigitalPlus: return "badge_dolby_ddplus"
        case .hdr10Plus: return "badge_hdr10plus"
        case .dtsHDMA: return "badge_dts_hd_ma"
        case .dts, .dtsX: return "badge_dts"
        default: return nil
        }
    }

    /// Text after the mark, or the whole badge when there is no mark.
    var label: String? {
        switch self {
        case .resolution(let text), .channels(let text), .source(let text), .bitDepth(let text):
            return text
        case .dolbyVision(let layer): return layer
        case .hdr10: return "HDR10"
        case .hlg: return "HLG"
        case .dtsX: return ":X"
        default: return nil
        }
    }

    /// Mark height relative to the badge's text size: wide wordmarks are kept lower.
    var logoHeightFactor: CGFloat {
        switch self {
        case .dolbyVision, .atmos: return 0.95
        case .trueHD, .dolbyDigitalPlus, .dtsHDMA: return 1.3
        case .hdr10Plus: return 1.05
        case .dts, .dtsX: return 1.1
        default: return 1
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
        case .dts: return "DTS"
        default: return label ?? ""
        }
    }

    /// Badges for `stream`, read from its name, description and file name, in
    /// the order resolution, video range, audio, channels, source, bit depth.
    static func badges(for stream: NuvioStream) -> [NuvioStreamBadge] {
        let text = [stream.name, stream.description, stream.filename]
            .compactMap { $0 }
            .joined(separator: "\n")
            .lowercased()
        return badges(in: text)
    }

    static func badges(in text: String) -> [NuvioStreamBadge] {
        func has(_ pattern: String) -> Bool {
            text.range(of: pattern, options: .regularExpression) != nil
        }
        var result: [NuvioStreamBadge] = []

        if has(#"\b(2160p|4k|uhd)\b"#) {
            result.append(.resolution("4K"))
        } else if has(#"\b1080[pi]\b"#) {
            result.append(.resolution("1080p"))
        } else if has(#"\b720p\b"#) {
            result.append(.resolution("720p"))
        }

        let dolbyVision = has(#"\b(dv|dovi|dolby[ ._-]?vision)\b"#)
        if dolbyVision {
            let layer = has(#"\bfel\b"#) ? "FEL" : (has(#"\bmel\b"#) ? "MEL" : nil)
            result.append(.dolbyVision(layer: layer))
        }
        if has(#"hdr10(\+|plus|p\b)"#) {
            result.append(.hdr10Plus)
        } else if has(#"\bhdr(10)?\b"#) {
            result.append(.hdr10)
        } else if has(#"\bhlg\b"#) {
            result.append(.hlg)
        }

        if has(#"\batmos\b"#) { result.append(.atmos) }
        if has(#"\btrue[ ._-]?hd\b"#) {
            result.append(.trueHD)
        } else if has(#"\bdts[ ._:-]?x\b"#) {
            result.append(.dtsX)
        } else if has(#"\bdts[ ._-]?hd([ ._-]?ma)?\b|\bdts[ ._-]?ma\b"#) {
            result.append(.dtsHDMA)
        } else if has(#"\b(ddp|dd\+|e[ ._-]?ac[ ._-]?3|dolby[ ._-]?digital[ ._-]?plus)"#) {
            result.append(.dolbyDigitalPlus)
        } else if has(#"\bdts\b"#) {
            result.append(.dts)
        }

        // No word boundary in front: codecs run into the layout ("DDP5.1").
        if has(#"(?<![0-9])7[ ._]1(?![0-9])"#) {
            result.append(.channels("7.1"))
        } else if has(#"(?<![0-9])5[ ._]1(?![0-9])"#) {
            result.append(.channels("5.1"))
        } else if has(#"(?<![0-9])2[ ._]0(?![0-9])"#) {
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
        }

        if has(#"\b(10[ ._-]?bit|hi10p?)\b"#) {
            result.append(.bitDepth("10-bit"))
        } else if has(#"\b12[ ._-]?bit\b"#) {
            result.append(.bitDepth("12-bit"))
        }
        return result
    }
}

/// One app-drawn badge: the mark and/or label in white on a translucent pill.
struct NuvioStreamBadgeView: View {
    let badge: NuvioStreamBadge
    var scale: CGFloat = 1

    private var textSize: CGFloat { (17 * scale).rounded() }

    var body: some View {
        HStack(spacing: 4 * scale) {
            if let asset = badge.logoAsset {
                Image(asset)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(height: (textSize * badge.logoHeightFactor).rounded())
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
        .frame(height: (36 * scale).rounded())
        .background(Capsule().fill(Color.white.opacity(0.12)))
        .overlay(Capsule().stroke(Color.white.opacity(0.20), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(badge.accessibilityName)
    }
}
