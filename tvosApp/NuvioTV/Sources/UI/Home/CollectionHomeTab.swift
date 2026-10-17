import SwiftUI
import UIKit

/// A real TabView destination. Details/player use the existing root overlays,
/// leaving this tab selected so Back returns to the same platform and focus.
struct CollectionHomeTab: View {
    let destination: CollectionHomeDestination
    let catalogRevision: UInt
    let isActive: Bool
    let isFullScreenOverlayPresented: Bool
    let detailsDidDisappearGeneration: UInt
    let collectionArtwork: UIImage?
    let onNavigateToDetails: (String, String) -> Void
    let onPlayTitle: (String, String) -> Void
    let onLongPressCard: (NuvioMeta) -> Void

    @StateObject private var model: CollectionHomeModel

    init(
        destination: CollectionHomeDestination,
        catalogRevision: UInt,
        isActive: Bool,
        isFullScreenOverlayPresented: Bool,
        detailsDidDisappearGeneration: UInt,
        collectionArtwork: UIImage? = nil,
        onNavigateToDetails: @escaping (String, String) -> Void,
        onPlayTitle: @escaping (String, String) -> Void,
        onLongPressCard: @escaping (NuvioMeta) -> Void
    ) {
        self.destination = destination
        self.catalogRevision = catalogRevision
        self.isActive = isActive
        self.isFullScreenOverlayPresented = isFullScreenOverlayPresented
        self.detailsDidDisappearGeneration = detailsDidDisappearGeneration
        self.collectionArtwork = collectionArtwork
        self.onNavigateToDetails = onNavigateToDetails
        self.onPlayTitle = onPlayTitle
        self.onLongPressCard = onLongPressCard
        _model = StateObject(wrappedValue: CollectionHomeModel(
            destination: destination, repository: CinemetaCatalogRepository()
        ))
    }

    var body: some View {
        Group {
            if isActive {
                home
            } else {
                Color.clear
            }
        }
        .onChange(of: isActive) { _, active in
            if !active { model.releaseCatalogs() }
        }
    }

    private var hasPartialFailures: Bool {
        !model.failures.isEmpty && model.store.sections.contains(where: \.hasContent)
    }

    private var home: some View {
        TVHomeView(
            store: model.store,
            repository: CinemetaCatalogRepository(),
            isActive: isActive,
            isFullScreenOverlayPresented: isFullScreenOverlayPresented,
            detailsDidDisappearGeneration: detailsDidDisappearGeneration,
            contentIdentity: TVHomeContentIdentity(
                profileId: destination.id.profileID,
                catalogRevision: catalogRevision,
                collectionScope: destination.id.key
            ),
            collectionsRevision: 0,
            onNavigateToDetails: onNavigateToDetails,
            onPlayTitle: onPlayTitle,
            onOpenCollectionFolder: { _, _ in },
            onResumePlayback: { _ in },
            collectionHome: model,
            onLongPressCard: onLongPressCard
        )
        .safeAreaInset(edge: .top, spacing: 0) {
            if hasPartialFailures {
                failureActions
            }
        }
        .overlay(alignment: .topTrailing) {
            if !isFullScreenOverlayPresented {
                collectionIdentity
                    .padding(.top, hasPartialFailures ? 112 : 18)
                    .padding(.trailing, 48)
            }
        }
    }

    /// Outside Home's ScrollView so the current collection remains identifiable
    /// while browsing lower rows. It never uses the focused movie's metadata.
    private var collectionIdentity: some View {
        HStack(spacing: 10) {
            Group {
                if let collectionArtwork {
                    Image(uiImage: collectionArtwork)
                        .renderingMode(.original)
                        .resizable()
                        .scaledToFit()
                } else if let emoji = destination.folder.coverEmoji,
                          !emoji.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(emoji).font(.system(size: 22))
                } else {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 18, weight: .semibold))
                }
            }
            .frame(width: 32, height: 32)
            .background(.white.opacity(0.12), in: Circle())
            .clipShape(Circle())
            .accessibilityHidden(true)
            Text(destination.folder.title)
                .font(.system(size: 24, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(.white.opacity(0.85))
        .frame(maxWidth: 360, alignment: .trailing)
        .allowsHitTesting(false)
    }

    private var failureActions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                ForEach(model.failures) { failure in
                    Button {
                        model.retry(rowID: failure.id)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle")
                            Text(failure.title).lineLimit(1)
                            Text(L10n.string("catalog_load_failed", fallback: "Catalog failed"))
                                .foregroundStyle(.secondary)
                            if model.retryingRows.contains(failure.id) {
                                ProgressView()
                            } else {
                                Label(L10n.string("action_retry", fallback: "Retry"), systemImage: "arrow.clockwise")
                            }
                        }
                        .font(.system(size: 18, weight: .medium))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .background(.ultraThinMaterial, in: Capsule())
                    }
                    .buttonStyle(PosterCardButtonStyle())
                    // Keep the native focus target mounted while retrying;
                    // the model coalesces repeated presses for the same row.
                }
            }
            .padding(.horizontal, 48)
            .padding(.vertical, 12)
        }
        .focusSection()
    }
}

/// Native tabItem needs a concrete UIImage, just like the existing profile
/// tab. Download only small configured logos; never prefetch platform catalogs.
@MainActor
final class CollectionSidebarArtwork: ObservableObject {
    @Published private(set) var images: [CollectionHomeID: UIImage] = [:]
    private var loadedURLs: [CollectionHomeID: String] = [:]

    func load(_ destinations: [CollectionHomeDestination]) async {
        let wanted = Set(destinations.map(\.id))
        images = images.filter { wanted.contains($0.key) }
        loadedURLs = loadedURLs.filter { wanted.contains($0.key) }
        for destination in destinations {
            guard !Task.isCancelled else { return }
            let value = destination.folder.preferredTitleLogoURLString ?? destination.folder.coverImageUrl
            guard let value, let url = URL(string: value),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                images[destination.id] = nil
                loadedURLs[destination.id] = nil
                continue
            }
            if loadedURLs[destination.id] == value { continue }
            images[destination.id] = nil
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard !Task.isCancelled else { return }
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode), data.count <= 4_000_000,
                      let original = UIImage(data: data) else { continue }
                let renderer = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40))
                images[destination.id] = renderer.image { _ in
                    let scale = min(40 / max(1, original.size.width), 40 / max(1, original.size.height))
                    let size = CGSize(width: original.size.width * scale, height: original.size.height * scale)
                    original.draw(in: CGRect(x: (40 - size.width) / 2, y: (40 - size.height) / 2, width: size.width, height: size.height))
                }
                loadedURLs[destination.id] = value
            } catch {
                // The platform remains reachable using its SF Symbol fallback.
            }
        }
    }
}
