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
        onNavigateToDetails: @escaping (String, String) -> Void,
        onPlayTitle: @escaping (String, String) -> Void,
        onLongPressCard: @escaping (NuvioMeta) -> Void
    ) {
        self.destination = destination
        self.catalogRevision = catalogRevision
        self.isActive = isActive
        self.isFullScreenOverlayPresented = isFullScreenOverlayPresented
        self.detailsDidDisappearGeneration = detailsDidDisappearGeneration
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
            if !hasPartialFailures {
                Text(destination.folder.title)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.top, 18)
                    .padding(.trailing, 48)
                    .allowsHitTesting(false)
            }
        }
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

/// Native tabItem needs a concrete UIImage. Prepare local circular artwork
/// first, then replace it with the configured logo/cover when available.
@MainActor
final class CollectionSidebarArtwork: ObservableObject {
    @Published private(set) var images: [CollectionHomeID: UIImage] = [:]
    private var loadedInputs: [CollectionHomeID: Input] = [:]
    private var loadedURLs: [CollectionHomeID: String] = [:]

    private struct Input: Equatable {
        let urls: [String]
        let emoji: String?
        let genre: Genre?

        init(folder: TVCollectionFolderItem) {
            var seen = Set<String>()
            urls = [folder.preferredTitleLogoURLString, folder.coverImageUrl].compactMap { raw in
                guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
                      let url = URL(string: value),
                      ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                      url.host != nil, seen.insert(value).inserted else { return nil }
                return value
            }
            let value = folder.coverEmoji?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            emoji = value.isEmpty ? nil : String(value.prefix(8))
            // Match source IDs and the template's original emoji, not its
            // editable/localized title. A user-chosen emoji remains authoritative.
            let movieGenres = folder.sources.first {
                $0.normalizedProvider == "tmdb"
                    && $0.tmdbSourceType?.uppercased() == "DISCOVER"
                    && $0.mediaType?.lowercased() == "movie"
            }?.filters?.withGenres
            genre = movieGenres.flatMap { key in
                Genre.allCases.first { $0.rawValue == key && $0.emoji == value }
            }
        }
    }

    /// Local images for the twelve Discover by Genre template folders. No
    /// remote icon service or changes to the saved collection JSON are needed.
    private enum Genre: String, CaseIterable {
        case action = "28|12", animation = "16", comedy = "35", crime = "80"
        case documentary = "99", drama = "18", family = "10751", horror = "27"
        case mystery = "9648|53", romance = "10749", fantasy = "878|14", history = "10752|36"

        var emoji: String {
            switch self {
            case .action: return "💥"
            case .animation: return "🎨"
            case .comedy: return "😂"
            case .crime: return "🕵️"
            case .documentary: return "🎥"
            case .drama: return "🎭"
            case .family: return "👨‍👩‍👧‍👦"
            case .horror: return "👻"
            case .mystery: return "🔎"
            case .romance: return "❤️"
            case .fantasy: return "🚀"
            case .history: return "⚔️"
            }
        }

        var symbol: String {
            switch self {
            case .action: return "bolt.fill"
            case .animation: return "paintpalette.fill"
            case .comedy: return "face.smiling.fill"
            case .crime: return "magnifyingglass"
            case .documentary: return "video.fill"
            case .drama: return "theatermasks.fill"
            case .family: return "person.3.fill"
            case .horror: return "moon.stars.fill"
            case .mystery: return "eye.fill"
            case .romance: return "heart.fill"
            case .fantasy: return "sparkles"
            case .history: return "shield.lefthalf.filled"
            }
        }

        var color: UIColor {
            let rgb: UInt32
            switch self {
            case .action: rgb = 0xBC4028
            case .animation: rgb = 0x9450BD
            case .comedy: rgb = 0xA66B13
            case .crime: rgb = 0x3C638A
            case .documentary: rgb = 0x237B70
            case .drama: rgb = 0x94436C
            case .family: rgb = 0x377D45
            case .horror: rgb = 0x5E477D
            case .mystery: rgb = 0x385B82
            case .romance: rgb = 0xB73D60
            case .fantasy: rgb = 0x4B50AB
            case .history: rgb = 0x81633E
            }
            return UIColor(red: CGFloat((rgb >> 16) & 255) / 255,
                           green: CGFloat((rgb >> 8) & 255) / 255,
                           blue: CGFloat(rgb & 255) / 255, alpha: 1)
        }
    }

    func load(_ destinations: [CollectionHomeDestination]) async {
        let wanted = Set(destinations.map(\.id))
        images = images.filter { wanted.contains($0.key) }
        loadedInputs = loadedInputs.filter { wanted.contains($0.key) }
        loadedURLs = loadedURLs.filter { wanted.contains($0.key) }
        let inputs = destinations.map { ($0.id, Input(folder: $0.folder)) }

        // Genre, emoji and generic images must not wait behind a slow logo URL.
        for (id, input) in inputs where loadedInputs[id] != input {
            guard !Task.isCancelled else { return }
            loadedInputs[id] = input
            loadedURLs[id] = nil
            images[id] = Self.render(input: input)
        }
        for (id, input) in inputs {
            guard !Task.isCancelled else { return }
            if loadedURLs[id] != nil { continue }
            for value in input.urls {
                guard let url = URL(string: value) else { continue }
                do {
                    let (data, response) = try await URLSession.shared.data(from: url)
                    guard !Task.isCancelled, loadedInputs[id] == input else { return }
                    guard let http = response as? HTTPURLResponse,
                          (200..<300).contains(http.statusCode), data.count <= 4_000_000,
                          let original = UIImage(data: data) else { continue }
                    images[id] = Self.render(input: input, artwork: original)
                    loadedURLs[id] = value
                    break
                } catch {
                    guard !Task.isCancelled else { return }
                    // Try the cover after a failed logo; retain local artwork
                    // when both fail. The tab always remains reachable.
                }
            }
        }
    }

    private static func render(input: Input, artwork: UIImage? = nil) -> UIImage {
        let bounds = CGRect(x: 0, y: 0, width: 40, height: 40)
        return UIGraphicsImageRenderer(size: bounds.size).image { context in
            let circle = UIBezierPath(ovalIn: bounds)
            // URL artwork gets a neutral backing; genre colors only apply to
            // the bundled glyphs and must not recolor a user's image.
            let background = artwork == nil
                ? (input.genre?.color ?? UIColor(white: 0.18, alpha: 1))
                : UIColor(white: 0.12, alpha: 1)
            background.setFill()
            circle.fill()
            context.cgContext.saveGState()
            circle.addClip()
            if let artwork {
                drawFitted(artwork, in: bounds.insetBy(dx: 5, dy: 5))
            } else if input.genre == nil, let emoji = input.emoji {
                let text = emoji as NSString
                let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 23)]
                let size = text.size(withAttributes: attributes)
                let scale = min(1, min(30 / max(1, size.width), 30 / max(1, size.height)))
                context.cgContext.translateBy(x: 20 - size.width * scale / 2,
                                             y: 20 - size.height * scale / 2)
                context.cgContext.scaleBy(x: scale, y: scale)
                text.draw(at: .zero, withAttributes: attributes)
            } else {
                let configuration = UIImage.SymbolConfiguration(pointSize: 23, weight: .semibold)
                if let symbol = UIImage(systemName: input.genre?.symbol ?? "folder.fill",
                                        withConfiguration: configuration) {
                    drawFitted(symbol.withTintColor(.white, renderingMode: .alwaysOriginal),
                               in: bounds.insetBy(dx: 9, dy: 9))
                }
            }
            context.cgContext.restoreGState()
            UIColor.white.withAlphaComponent(0.12).setStroke()
            UIBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5)).stroke()
        }
    }

    private static func drawFitted(_ image: UIImage, in rect: CGRect) {
        let scale = min(rect.width / max(1, image.size.width), rect.height / max(1, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        image.draw(in: CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                              width: size.width, height: size.height))
    }
}
