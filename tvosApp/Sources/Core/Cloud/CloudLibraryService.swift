import Foundation

/// Reads the configured debrid provider + key and exposes the matching cloud
/// library backend. Only Premiumize and TorBox expose a browsable cloud (as on
/// Android); Real-Debrid / others return no provider.
struct CloudLibraryService {
    private let store: UserDefaults

    init(store: UserDefaults) {
        self.store = store
    }

    private var apiKey: String {
        DebridCredentials.token(
            for: DebridProviderKind(settingsValue: store.string(forKey: SettingsKey.debridProvider)),
            store: store
        )
    }

    var provider: CloudLibraryProvider? {
        switch DebridProviderKind(settingsValue: store.string(forKey: SettingsKey.debridProvider)) {
        case .premiumize: return PremiumizeCloudLibrary()
        case .torbox: return TorboxCloudLibrary()
        case .none, .realDebrid, .allDebrid, .debridLink: return nil
        }
    }

    /// Whether a cloud library can be browsed right now (supported provider + key).
    var isAvailable: Bool { provider != nil && !apiKey.isEmpty }

    var providerName: String? { provider?.displayName }

    func loadItems() async throws -> [CloudItem] {
        guard let provider else { return [] }
        guard !apiKey.isEmpty else { throw CloudLibraryError.request }
        return try await provider.listItems(apiKey: apiKey)
    }

    func resolve(item: CloudItem, file: CloudFile) async -> CloudPlaybackResult {
        guard let provider else { return .failed(nil) }
        guard !apiKey.isEmpty else { return .missingCredentials }
        return await provider.resolvePlayback(apiKey: apiKey, item: item, file: file)
    }
}
