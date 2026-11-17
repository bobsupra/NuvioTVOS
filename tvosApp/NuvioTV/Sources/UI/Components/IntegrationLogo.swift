import SwiftUI

/// Brand marks for built-in integrations, shown next to their name in
/// Settings > Integrations and on stream cards from the built-in sources.
/// SMB is a protocol with no logo, so it uses a system symbol.
enum IntegrationLogo: String, CaseIterable {
    case plex
    case jellyfin
    case smb
    case simkl
    case mdblist
    case wetrakr
    case trakt

    /// Asset catalog name, or `nil` when the mark is a system symbol.
    var assetName: String? {
        switch self {
        case .plex: return "integration_plex"
        case .jellyfin: return "integration_jellyfin"
        case .simkl: return "integration_simkl"
        case .mdblist: return "integration_mdblist"
        case .wetrakr: return "integration_wetrakr"
        case .trakt: return "integration_trakt"
        case .smb: return nil
        }
    }

    var symbolName: String { "externaldrive.connected.to.line.below.fill" }

    /// Value for `NuvioStream.addonLogoURL`. Stream cards resolve it to the
    /// bundled mark instead of loading a remote add-on logo.
    var streamLogoReference: String { "\(Self.referenceScheme)\(rawValue)" }

    static let referenceScheme = "nuvio-integration://"

    /// Returns the integration a `streamLogoReference` points to, if any.
    init?(streamLogoReference: String?) {
        guard let reference = streamLogoReference,
              reference.hasPrefix(Self.referenceScheme) else { return nil }
        self.init(rawValue: String(reference.dropFirst(Self.referenceScheme.count)))
    }
}

struct IntegrationLogoView: View {
    let logo: IntegrationLogo
    let size: CGFloat

    var body: some View {
        Group {
            if let assetName = logo.assetName {
                Image(assetName)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: logo.symbolName)
                    .font(.system(size: (size * 0.5).rounded(), weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                    .frame(width: size, height: size)
                    .background(Color.white.opacity(0.12))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// The status line at the top of each integration's settings: brand mark,
/// connection state, and what the connection gives this profile.
struct IntegrationStatusRow: View {
    let logo: IntegrationLogo
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            IntegrationLogoView(logo: logo, size: 62)

            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.white)

                Text(subtitle)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.white.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 16)
        }
    }
}

/// Status titles shared by the server integrations (SMB, Jellyfin).
enum IntegrationServerStatus {
    static func title(connectedNames: [String]) -> String {
        switch connectedNames.count {
        case 0:
            return L10n.string("integration_status_not_connected", fallback: "Not Connected")
        case 1:
            return L10n.format("integration_status_connected_to", fallback: "Connected to %@", connectedNames[0])
        default:
            return L10n.format("integration_status_connected_to_count", fallback: "Connected to %d servers", connectedNames.count)
        }
    }
}
