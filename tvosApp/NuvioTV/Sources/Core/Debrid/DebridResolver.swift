import Foundation

/// Entry point for turning a torrent-only `NuvioStream` into a playable one.
/// Reads the user's configured provider + API key from the given settings store
/// and dispatches to the matching backend. Providers not yet implemented (or
/// "None") make this a no-op so playback falls back to the next stream.
struct DebridResolver {
    private let store: UserDefaults

    init(store: UserDefaults) {
        self.store = store
    }

    /// The provider currently selected in Settings → Integrations → Debrid.
    var selectedKind: DebridProviderKind {
        DebridProviderKind(settingsValue: store.string(forKey: SettingsKey.debridProvider))
    }

    /// Whether resolution is possible at all (a provider with a backend is
    /// selected and a key is present). Lets callers skip the work entirely.
    var isEnabled: Bool {
        provider(for: selectedKind) != nil && !apiKey.isEmpty
    }

    private var apiKey: String {
        DebridCredentials.token(for: selectedKind, store: store)
    }

    /// Resolves a torrent stream to a direct URL. Returns `nil` when the stream
    /// isn't a torrent, no provider is configured, or resolution fails — the
    /// caller should then move on to the next stream.
    func resolvedURL(for stream: NuvioStream, season: Int?, episode: Int?) async -> DebridResult? {
        guard stream.isDebridResolvable, let infoHash = stream.infoHash else { return nil }
        guard let provider = provider(for: selectedKind) else { return nil }

        let request = DebridRequest(
            infoHash: infoHash,
            fileIdx: stream.fileIdx,
            sources: stream.sources,
            filename: stream.filename,
            season: season,
            episode: episode
        )
        return await provider.resolve(request, apiKey: apiKey)
    }

    /// Maps a provider kind to its implementation. Unimplemented kinds
    /// (AllDebrid, Debrid-Link) and None return `nil`.
    private func provider(for kind: DebridProviderKind) -> DebridProvider? {
        guard kind.hasResolver else { return nil }
        switch kind {
        case .realDebrid: return RealDebridResolver()
        case .premiumize: return PremiumizeResolver()
        case .torbox: return TorboxResolver()
        case .none, .allDebrid, .debridLink: return nil
        }
    }
}
