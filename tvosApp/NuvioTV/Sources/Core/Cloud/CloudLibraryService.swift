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
            let legacyKey = (ProviderCredentialStore.string(forKey: SettingsKey.debridApiKey, in: store) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// Whether a cloud library can be browsed right now (supported provider + key, and cloud library setting enabled).
    var isAvailable: Bool {
        let enabled = store.object(forKey: SettingsKey.cloudLibraryEnabled) as? Bool ?? true
        return enabled && !connectedProviders.isEmpty
    }

    var providerName: String? {
        if let first = connectedProviders.first {
            return connectedProviders.count == 1 ? first.displayName : "Cloud"
        }
        return provider?.displayName
    }

    func loadItems(providerId: String? = nil) async throws -> [CloudItem] {
        try Task.checkCancellation()
        let providers = connectedProviders
        guard !providers.isEmpty else { throw CloudLibraryError.request }

        if let providerId, let specific = providers.first(where: { $0.id == providerId }) {
            guard let prov = providerInstance(for: specific.id) else { return [] }
            let items = try await prov.listItems(apiKey: specific.apiKey)
            try Task.checkCancellation()
            return items
        }

        if providers.count == 1, let single = providers.first {
            guard let prov = providerInstance(for: single.id) else { return [] }
            let items = try await prov.listItems(apiKey: single.apiKey)
            try Task.checkCancellation()
            return items
        }

        let requests: [(provider: CloudLibraryProvider, apiKey: String)] = providers.compactMap { p in
            guard let provider = providerInstance(for: p.id) else { return nil }
            return (provider, p.apiKey)
        }
        return try await Self.loadProviderItems(requests)
    }

    /// A successful empty response is different from an unavailable provider.
    /// Keep partial results, but never report total failure as an empty library.
    static func loadProviderItems(
        _ requests: [(provider: CloudLibraryProvider, apiKey: String)]
    ) async throws -> [CloudItem] {
        try Task.checkCancellation()
        return try await withThrowingTaskGroup(of: Result<[CloudItem], Error>.self) { group in
            for request in requests {
                group.addTask {
                    do {
                        try Task.checkCancellation()
                        let items = try await request.provider.listItems(apiKey: request.apiKey)
                        try Task.checkCancellation()
                        return .success(items)
                    } catch {
                        if Task.isCancelled || error is CancellationError {
                            throw CancellationError()
                        }
                        return .failure(error)
                    }
                }
            }
            var all: [CloudItem] = []
            var successes = 0
            var failure: Error?
            for try await result in group {
                try Task.checkCancellation()
                switch result {
                case let .success(items):
                    successes += 1
                    all.append(contentsOf: items)
                case let .failure(error):
                    failure = error
                }
            }
            try Task.checkCancellation()
            guard successes > 0 else { throw failure ?? CloudLibraryError.request }
            return all
        }
    }

    func resolve(item: CloudItem, file: CloudFile) async -> CloudPlaybackResult {
        let providers = connectedProviders
        // A cloud item belongs to one backend. Falling back to another linked
        // provider can send a TorBox identifier to Premiumize (or vice versa)
        // and, worse, use credentials the item never belonged to.
        guard let p = providers.first(where: { $0.id == item.providerId }) else {
            return .missingCredentials
        }
        guard let prov = providerInstance(for: p.id) else { return .failed(nil) }
        guard !p.apiKey.isEmpty else { return .missingCredentials }
        return await prov.resolvePlayback(apiKey: p.apiKey, item: item, file: file)
    }
}
