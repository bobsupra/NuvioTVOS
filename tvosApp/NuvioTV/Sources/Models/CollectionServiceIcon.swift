import Foundation

/// Presentation only. Provider identity comes from source filters, never an
/// editable collection name. Unknown/custom artwork keeps its configured URLs.
struct CollectionServiceIcon: Equatable, Hashable, Sendable {
    let imageURLs: [String]
    let backgroundRGB: UInt32
    let fillsCircle: Bool

    static let primeBlueURL = "https://thumb.wikimedia.org/wikipedia/commons/thumb/7/7c/Amazon_Prime_Video_blue_logo_1.svg/500px-Amazon_Prime_Video_blue_logo_1.svg.png"

    private struct Service {
        let provider: String
        let imagePath: String
        let color: UInt32
        var legacyPaths: [String] = []
        var preferredURL: String? = nil
    }

    private static let services: [Service] = [
        Service(provider: "8", imagePath: "pbpMk2JmcoNnQwx5JGpXngfoWtp.jpg", color: 0x000000,
                legacyPaths: ["wwemzKWzjKYJFfCeiB57q3r4Bcm.png"]),
        Service(provider: "9", imagePath: "pvske1MyAoymrs5bguRfVqYiM9a.jpg", color: 0x0095FF,
                preferredURL: primeBlueURL),
        Service(provider: "337", imagePath: "97yvRBw1GzX7fXprcF80er19ot.jpg", color: 0x006576),
        Service(provider: "1899", imagePath: "jbe4gVSfRlbPTdESXhEKpornsfu.jpg", color: 0x002BE7),
        Service(provider: "350", imagePath: "2E03IAZsX4ZaUqM7tXlctEPMGWS.jpg", color: 0x000000),
        Service(provider: "15", imagePath: "bxBlRPEPpMVDc4jMhSrTf2339DW.jpg", color: 0x1CE783),
        Service(provider: "531", imagePath: "h5DcR0J2EESLitnhR8xLG1QymTE.jpg", color: 0x0064FF),
        Service(provider: "386", imagePath: "2aGrp1xw3qhwCYvNGAJZPdjfeeX.jpg", color: 0x000000),
        Service(provider: "283", imagePath: "", color: 0xFFFFFF)
    ]

    static func configured(folder: TVCollectionFolderItem) -> Self? {
        guard folder.presentationStyle?.uppercased() != "STUDIO_FRANCHISE",
              !folder.sources.isEmpty,
              folder.coverEmoji?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false else { return nil }
        let providers = folder.sources.compactMap { source -> String? in
            guard source.normalizedProvider == "tmdb", source.tmdbSourceType?.uppercased() == "DISCOVER",
                  let filters = source.filters,
                  filters.withCompanies?.isEmpty != false, filters.withNetworks?.isEmpty != false else { return nil }
            return filters.withWatchProviders?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard providers.count == folder.sources.count, Set(providers).count == 1,
              let provider = providers.first,
              let service = services.first(where: { $0.provider == provider }) else { return nil }

        var seen = Set<String>()
        let configuredURLs = [folder.titleLogoUrl, folder.coverImageUrl].compactMap { raw -> String? in
            guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  url.host?.isEmpty == false, seen.insert(value).inserted else { return nil }
            return value
        }
        let knownURLs = !configuredURLs.isEmpty && configuredURLs.allSatisfy { raw in
            guard let url = URL(string: raw), url.query == nil, url.fragment == nil else { return false }
            if service.provider == "283" {
                return url.scheme == "https" && url.host == "upload.wikimedia.org"
                    && url.path == "/wikipedia/commons/0/08/Crunchyroll_Logo.png"
            }
            guard url.scheme == "https", url.host == "image.tmdb.org" else { return false }
            let parts = url.path.split(separator: "/").map(String.init)
            return parts.count == 4 && parts[0] == "t" && parts[1] == "p"
                && ["original", "w92", "w154", "w185", "w300", "w500", "w780"].contains(parts[2])
                && ([service.imagePath] + service.legacyPaths).contains(parts[3])
        }
        // Only known original assets can be replaced by the provider's icon.
        // The original URLs remain as fallback, and no stored artwork is edited.
        let preferred = knownURLs && !service.imagePath.isEmpty
            ? [service.preferredURL ?? "https://image.tmdb.org/t/p/w500/\(service.imagePath)"] : []
        let urls = (preferred + configuredURLs).filter { seen.insert("icon:\($0)").inserted }
        guard !urls.isEmpty else { return nil }
        return Self(imageURLs: urls, backgroundRGB: knownURLs ? service.color : 0x1F1F1F,
                    fillsCircle: knownURLs && !service.imagePath.isEmpty)
    }
}
