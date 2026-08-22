import Foundation
import SwiftUI

/// Drives the Cloud Library screen: loads the user's saved cloud items and
/// resolves a chosen file into a playable URL.
@MainActor
final class CloudLibraryViewModel: ObservableObject {
    @Published private(set) var items: [CloudItem] = []
    @Published var selectedProviderId: String? = nil
    @Published var selectedType: CloudItemType? = nil
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    /// `stableKey`+file id currently being resolved, so its row can show a spinner.
    @Published private(set) var resolvingKey: String?

    private let service: CloudLibraryService

    init(store: UserDefaults) {
        self.service = CloudLibraryService(store: store)
    }

    var isAvailable: Bool { service.isAvailable }

    var availableProviders: [ConnectedCloudProvider] { service.connectedProviders }

    var availableTypes: [CloudItemType] {
        let matchingProviderItems = items.filter { item in
            selectedProviderId == nil || item.providerId == selectedProviderId
        }
        let types = Array(Set(matchingProviderItems.map(\.type))).sorted { $0.rawValue < $1.rawValue }
        return types.isEmpty ? CloudItemType.allCases : types
    }

    var filteredItems: [CloudItem] {
        items.filter { item in
            let matchesProvider = selectedProviderId == nil || item.providerId == selectedProviderId
            let matchesType = selectedType == nil || item.type == selectedType
            return matchesProvider && matchesType
        }
    }

    var providerName: String { service.providerName ?? "Cloud" }

    func load() async {
        isLoading = true
        errorMessage = nil
        do {
            items = try await service.loadItems()
            if items.isEmpty {
                errorMessage = L10n.string("cloud_library_empty_message", fallback: "No playable cloud files match the current filters.")
            }
        } catch is CancellationError {
            // Screen went away; ignore.
        } catch {
            errorMessage = L10n.string("cloud_library_load_failed", fallback: "Couldn't load your \(providerName) library.")
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
                errorMessage = L10n.string("cloud_library_play_not_connected", fallback: "Add your \(providerName) API key in Settings.")
            case .notPlayable:
                errorMessage = L10n.string("cloud_library_no_playable_files", fallback: "That file can't be played.")
            case let .failed(message):
                errorMessage = message ?? L10n.string("cloud_library_play_failed", fallback: "Couldn't get a link for that file.")
            }
        }
    }
}
