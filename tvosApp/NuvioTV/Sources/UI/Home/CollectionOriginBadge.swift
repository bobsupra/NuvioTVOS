import SwiftUI
import UIKit

/// Decorative and non-focusable. Only the main Home supplies this annotation.
struct CollectionOriginBadge: View {
    let origin: CollectionOriginPresentation
    @State private var image: UIImage?
    @State private var loadedOrigin: CollectionOriginPresentation?

    /// A service whose mark is a logo of its own shape (MyAnimeList's "MAL" box): drawn as it is,
    /// without the round backing.
    static let plainLogoHeight: CGFloat = 32

    static func plainLogo(_ origin: CollectionOriginPresentation) -> String? {
        guard origin.imageURLs.count == 1, let only = origin.imageURLs.first, only.hasPrefix("asset:") else { return nil }
        return String(only.dropFirst("asset:".count))
    }

    var body: some View {
        if let assetName = Self.plainLogo(origin) {
            Image(assetName)
                .resizable()
                .scaledToFit()
                .frame(height: Self.plainLogoHeight)
                .allowsHitTesting(false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(origin.title))
        } else {
            roundBadge
        }
    }

    private var roundBadge: some View {
        ZStack {
            Circle().fill(Color.black.opacity(0.86))
            if loadedOrigin == origin, let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else if let emoji = origin.emoji {
                Text(emoji).font(.system(size: 23))
            } else {
                Text(String(origin.title.prefix(1)).uppercased())
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(Circle())
        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(origin.title))
        .task(id: origin) {
            let requested = origin
            let urls = requested.serviceIcon?.imageURLs ?? requested.imageURLs
            image = nil
            loadedOrigin = nil
            for value in urls {
                // "asset:name": one of the app's own images (MyAnimeList's mark).
                if value.hasPrefix("asset:"), let local = UIImage(named: String(value.dropFirst("asset:".count))) {
                    image = CollectionIconRenderer.render(local, style: requested.serviceIcon, sourceURL: value)
                    loadedOrigin = requested
                    return
                }
                guard !Task.isCancelled, let url = URL(string: value) else { return }
                if let loaded = await PosterArtworkCache.shared.image(for: url, maxPixelSize: 160) {
                    guard !Task.isCancelled, requested == origin else { return }
                    image = CollectionIconRenderer.render(loaded, style: requested.serviceIcon, sourceURL: value)
                    loadedOrigin = requested
                    return
                }
            }
        }
    }
}
