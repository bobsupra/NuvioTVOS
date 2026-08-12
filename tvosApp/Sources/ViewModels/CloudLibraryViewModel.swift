import Foundation
import SwiftUI

/// Drives the Cloud Library screen: loads the user's saved cloud items and
/// resolves a chosen file into a playable URL.
@MainActor
final class CloudLibraryViewModel: ObservableObject {
    @Published private(set) var items: [CloudItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    /// `stableKey`+file id currently being resolved, so its row can show a spinner.
    @Published private(set) var resolvingKey: String?

    private let service: CloudLibraryService

    init(store: UserDefaults) {
        self.service = CloudLibraryService(store: store)
    }

    var providerName: String { service.providerName ?? "Cloud" }

    func load() async {
        isLoading = true
        errorMessage = nil
        do {
            items = try await service.loadItems()
            if items.isEmpty { errorMessage = "No files in your \(providerName) cloud." }
        } catch is CancellationError {
            // Screen went away; ignore.
        } catch {
            errorMessage = "Couldn't load your \(providerName) library."
        }
        isLoading = false
    }

    /// Resolves a file to a URL and hands it back via `onResolved`. Sets an error
    /// message on failure. `key` scopes the in-flight spinner to one row.
    func play(item: CloudItem, file: CloudFile, onResolved: @escaping (URL, NuvioMeta) -> Void) {
        let key = "\(item.stableKey):\(file.id)"
        guard resolvingKey == nil else { return }
        resolvingKey = key
        Task {
            let result = await service.resolve(item: item, file: file)
            resolvingKey = nil
            switch result {
            case let .success(url, filename, _):
                onResolved(url, .cloudPlaceholder(id: "cloud:\(file.id)", name: filename ?? file.name))
            case .missingCredentials:
                errorMessage = "Add your \(providerName) API key in Settings."
            case .notPlayable:
                errorMessage = "That file can't be played."
            case let .failed(message):
                errorMessage = message ?? "Couldn't get a link for that file."
            }
        }
    }
}
