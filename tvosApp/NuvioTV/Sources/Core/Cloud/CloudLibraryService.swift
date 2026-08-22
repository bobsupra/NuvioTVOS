import Foundation

struct ConnectedCloudProvider: Identifiable, Hashable {
    let id: String
    let displayName: String
    let apiKey: String

    static func == (lhs: ConnectedCloudProvider, rhs: ConnectedCloudProvider) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// Reads the configured debrid provider + key and exposes the matching cloud
/// library backend. Only Premiumize and TorBox expose a browsable cloud (as on
/// Android); Real-Debrid / others return no provider.
struct CloudLibraryService {
    private let store: UserDefaults

    init(store: UserDefaults) {
        self.store = store
    }

    private func providerInstance(for providerId: String) -> CloudLibraryProvider? {
        switch providerId.lowercased() {
        case "torbox": return TorboxCloudLibrary()
        case "premiumize": return PremiumizeCloudLibrary()
        default: return nil
        }
    }

    var connectedProviders: [ConnectedCloudProvider] {
        var list: [ConnectedCloudProvider] = []
        let torboxKey = DebridCredentials.token(for: DebridProviderKind.torbox, store: store)
        if !torboxKey.isEmpty {
            list.append(ConnectedCloudProvider(id: "torbox", displayName: "TorBox", apiKey: torboxKey))
        }
        let premKey = DebridCredentials.token(for: DebridProviderKind.premiumize, store: store)
        if !premKey.isEmpty {
            list.append(ConnectedCloudProvider(id: "premiumize", displayName: "Premiumize", apiKey: premKey))
        }
        if list.isEmpty {
            let legacyKey = (store.string(forKey: SettingsKey.debridApiKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let selectedKind = DebridProviderKind(settingsValue: store.string(forKey: SettingsKey.debridProvider))
            if !legacyKey.isEmpty {
                if selectedKind == .torbox {
                    list.append(ConnectedCloudProvider(id: "torbox", displayName: "TorBox", apiKey: legacyKey))
                } else if selectedKind == .premiumize {
                    list.append(ConnectedCloudProvider(id: "premiumize", displayName: "Premiumize", apiKey: legacyKey))
                }
            }
        }
        return list
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
    var isAvailable: Bool { !connectedProviders.isEmpty }

    var providerName: String? {
        if let first = connectedProviders.first {
            return connectedProviders.count == 1 ? first.displayName : "Cloud"
        }
        return provider?.displayName
    }

    func loadItems(providerId: String? = nil) async throws -> [CloudItem] {
        let providers = connectedProviders
        guard !providers.isEmpty else { throw CloudLibraryError.request }

        if let providerId, let specific = providers.first(where: { $0.id == providerId }) {
            guard let prov = providerInstance(for: specific.id) else { return [] }
            return try await prov.listItems(apiKey: specific.apiKey)
        }

        if providers.count == 1, let single = providers.first {
            guard let prov = providerInstance(for: single.id) else { return [] }
            return try await prov.listItems(apiKey: single.apiKey)
        }

        return try await withThrowingTaskGroup(of: [CloudItem].self) { group in
            for p in providers {
                guard let prov = providerInstance(for: p.id) else { continue }
                let key = p.apiKey
                group.addTask {
                    do {
                        return try await prov.listItems(apiKey: key)
                    } catch {
                        return []
                    }
                }
            }
            var all: [CloudItem] = []
            for try await items in group {
                all.append(contentsOf: items)
            }
            return all
        }
    }

    func resolve(item: CloudItem, file: CloudFile) async -> CloudPlaybackResult {
        let providers = connectedProviders
        guard let p = providers.first(where: { $0.id == item.providerId }) ?? providers.first else {
            return .missingCredentials
        }
        guard let prov = providerInstance(for: p.id) else { return .failed(nil) }
        guard !p.apiKey.isEmpty else { return .missingCredentials }
        return await prov.resolvePlayback(apiKey: p.apiKey, item: item, file: file)
    }
}
