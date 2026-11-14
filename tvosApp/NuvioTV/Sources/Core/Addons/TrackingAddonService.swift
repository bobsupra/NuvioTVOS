import Foundation

/// Stremio "tracking" add-ons: add-ons that declare the `player` or `library`
/// resource receive the user's activity instead of providing content, so a
/// tracking service can follow along.
///
/// Protocol (stremio-addon-sdk docs/protocol.md):
/// - `/player/{type}/{videoID}/action={start|pause|stop}&currentTime={ms}&duration={ms}.json`
/// - `/library/{type}/{id}/action={libraryAdd|libraryRemove|watched|unwatched}[&videoId=a,b].json`
/// Each event is sent once to every add-on that declares the resource and
/// matches its `types` / `idPrefixes`. The response is not used.
///
/// Sharing is opt-in per add-on: nothing is sent until the user turns an
/// add-on on in Settings > Add-ons > Tracking Add-ons.
enum TrackingAddonService {
    enum PlayerAction: String {
        case start
        case pause
        case stop
    }

    enum LibraryAction: String {
        case libraryAdd
        case libraryRemove
        case watched
        case unwatched
    }

    /// Per-profile list of manifest URLs the user allowed to receive activity.
    /// Kept on this Apple TV only: consent is not synced to other devices.
    static let approvedManifestsKey = "nuvio.tv.trackingAddons.approvedManifestURLs"

    /// Stremio splits long `videoId` lists into events of up to 100 videos.
    static let maxVideoIdsPerEvent = 100

    // MARK: - Consent

    static func approvedManifestURLs(in defaults: UserDefaults = ProfileSettings.current) -> Set<String> {
        Set(defaults.stringArray(forKey: approvedManifestsKey) ?? [])
    }

    static func isApproved(_ manifestURL: URL, in defaults: UserDefaults = ProfileSettings.current) -> Bool {
        approvedManifestURLs(in: defaults).contains(manifestURL.absoluteString)
    }

    static func setApproved(_ approved: Bool, manifestURL: URL, in defaults: UserDefaults = ProfileSettings.current) {
        var urls = approvedManifestURLs(in: defaults)
        if approved {
            urls.insert(manifestURL.absoluteString)
        } else {
            urls.remove(manifestURL.absoluteString)
        }
        defaults.set(urls.sorted(), forKey: approvedManifestsKey)
    }

    // MARK: - URLs

    static func playerExtra(action: PlayerAction, currentTimeMs: Int64, durationMs: Int64) -> String {
        "action=\(action.rawValue)&currentTime=\(max(0, currentTimeMs))&duration=\(max(0, durationMs))"
    }

    static func libraryExtras(action: LibraryAction, videoIds: [String]) -> [String] {
        let base = "action=\(action.rawValue)"
        guard action == .watched || action == .unwatched, !videoIds.isEmpty else { return [base] }
        return stride(from: 0, to: videoIds.count, by: maxVideoIdsPerEvent).map { start in
            let chunk = videoIds[start..<min(start + maxVideoIdsPerEvent, videoIds.count)]
            let encoded = chunk.map(AddonTransportUrls.encodePathSegment).joined(separator: ",")
            return "\(base)&videoId=\(encoded)"
        }
    }

    static func playerURL(
        manifestURL: URL,
        type: String,
        videoId: String,
        action: PlayerAction,
        currentTimeMs: Int64,
        durationMs: Int64
    ) -> URL? {
        AddonTransportUrls.buildResourceURL(
            manifestURL: manifestURL,
            resource: "player",
            type: type,
            id: videoId,
            extraPathSegment: TrackingAddonService.playerExtra(action: action, currentTimeMs: currentTimeMs, durationMs: durationMs)
        )
    }

    static func libraryURLs(
        manifestURL: URL,
        type: String,
        id: String,
        action: LibraryAction,
        videoIds: [String] = []
    ) -> [URL] {
        TrackingAddonService.libraryExtras(action: action, videoIds: videoIds).compactMap { extra in
            AddonTransportUrls.buildResourceURL(
                manifestURL: manifestURL,
                resource: "library",
                type: type,
                id: id,
                extraPathSegment: extra
            )
        }
    }

    // MARK: - Sending

    static func sendPlayerEvent(
        _ action: PlayerAction,
        type: String,
        videoId: String,
        currentTime: TimeInterval,
        duration: TimeInterval
    ) {
        guard currentTime.isFinite, duration.isFinite, duration > 0 else { return }
        let currentMs = Int64((max(0, currentTime) * 1000).rounded())
        let durationMs = Int64((duration * 1000).rounded())
        dispatch(resource: "player", type: type, id: videoId) { manifestURL in
            TrackingAddonService.playerURL(
                manifestURL: manifestURL,
                type: type,
                videoId: videoId,
                action: action,
                currentTimeMs: currentMs,
                durationMs: durationMs
            ).map { [$0] } ?? []
        }
    }

    static func sendLibraryEvent(
        _ action: LibraryAction,
        type: String,
        id: String,
        videoIds: [String] = []
    ) {
        dispatch(resource: "library", type: type, id: id) { manifestURL in
            TrackingAddonService.libraryURLs(manifestURL: manifestURL, type: type, id: id, action: action, videoIds: videoIds)
        }
    }

    /// A user added or removed a title from their library or watchlist.
    static func sendLibraryMembership(_ isInLibrary: Bool, meta: NuvioMeta) {
        sendLibraryEvent(isInLibrary ? .libraryAdd : .libraryRemove, type: meta.type, id: meta.id)
    }

    /// A user marked a whole title watched or unwatched.
    static func sendWatched(_ isWatched: Bool, meta: NuvioMeta) {
        sendLibraryEvent(isWatched ? .watched : .unwatched, type: meta.type, id: meta.id)
    }

    /// Sends to every approved, installed and enabled add-on whose manifest
    /// declares `resource` for this type and id. Fire and forget.
    private static func dispatch(
        resource: String,
        type: String,
        id: String,
        urls: @escaping @Sendable (URL) -> [URL]
    ) {
        let defaults = ProfileSettings.current
        let approved = approvedManifestURLs(in: defaults)
        guard !approved.isEmpty else { return }
        let manifestURLs = CinemetaCatalogRepository.configuredStreamAddonManifestURLs(in: defaults)
            .filter { approved.contains($0.absoluteString) }
        guard !manifestURLs.isEmpty else { return }
        Task.detached(priority: .utility) {
            for manifestURL in manifestURLs {
                guard let manifest = await TrackingAddonService.manifest(for: manifestURL),
                      manifest.supports(resource, type: type, id: id) else { continue }
                for url in urls(manifestURL) {
                    var request = URLRequest(url: url)
                    request.timeoutInterval = 10
                    _ = try? await TrackingAddonService.session.data(for: request)
                }
            }
        }
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    // MARK: - Manifest

    static func manifest(for manifestURL: URL) async -> TrackingAddonManifest? {
        guard let data = await StremioManifestDataCache.shared.data(for: manifestURL) else { return nil }
        return try? JSONDecoder().decode(TrackingAddonManifest.self, from: data)
    }
}

/// The part of a Stremio manifest that tracking needs.
struct TrackingAddonManifest: Decodable, Equatable {
    struct Resource: Decodable, Equatable {
        let name: String
        let types: [String]?
        let idPrefixes: [String]?

        enum CodingKeys: String, CodingKey { case name, types, idPrefixes }

        init(name: String, types: [String]? = nil, idPrefixes: [String]? = nil) {
            self.name = name
            self.types = types
            self.idPrefixes = idPrefixes
        }

        init(from decoder: Decoder) throws {
            if let value = try? decoder.singleValueContainer().decode(String.self) {
                self.init(name: value)
                return
            }
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                name: (try? container.decode(String.self, forKey: .name)) ?? "",
                types: try? container.decode([String].self, forKey: .types),
                idPrefixes: try? container.decode([String].self, forKey: .idPrefixes)
            )
        }
    }

    let id: String?
    let name: String?
    let types: [String]?
    let idPrefixes: [String]?
    let resources: [Resource]

    enum CodingKeys: String, CodingKey { case id, name, types, idPrefixes, resources }

    init(id: String? = nil, name: String? = nil, types: [String]? = nil, idPrefixes: [String]? = nil, resources: [Resource]) {
        self.id = id
        self.name = name
        self.types = types
        self.idPrefixes = idPrefixes
        self.resources = resources
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try? container.decode(String.self, forKey: .id)
        name = try? container.decode(String.self, forKey: .name)
        types = try? container.decode([String].self, forKey: .types)
        idPrefixes = try? container.decode([String].self, forKey: .idPrefixes)
        resources = (try? container.decode([Resource].self, forKey: .resources)) ?? []
    }

    var tracksPlayback: Bool { declares("player") }
    var tracksLibrary: Bool { declares("library") }
    var isTrackingAddon: Bool { tracksPlayback || tracksLibrary }

    private func declares(_ resource: String) -> Bool {
        resources.contains { $0.name.caseInsensitiveCompare(resource) == .orderedSame }
    }

    func supports(_ resourceName: String, type: String, id: String) -> Bool {
        resources.contains { resource in
            guard resource.name.caseInsensitiveCompare(resourceName) == .orderedSame else { return false }
            let supportedTypes = (resource.types?.isEmpty == false ? resource.types : types) ?? []
            let typeMatches = supportedTypes.isEmpty
                || supportedTypes.contains { AddonTransportUrls.isTypeEquivalent($0, type) }
            let prefixes = (resource.idPrefixes?.isEmpty == false ? resource.idPrefixes : idPrefixes) ?? []
            let idMatches = prefixes.isEmpty
                || prefixes.contains { id.lowercased().hasPrefix($0.lowercased()) }
            return typeMatches && idMatches
        }
    }
}

/// Turns the player's state changes into Stremio player events: `start` when
/// playback starts or resumes, `pause`, `stop` when the player closes or the
/// video changes, and the current state again after a seek.
@MainActor
final class TrackingAddonPlaybackReporter {
    struct Item: Equatable {
        let type: String
        let videoId: String
    }

    typealias Send = (TrackingAddonService.PlayerAction, Item, TimeInterval, TimeInterval) -> Void

    private let send: Send
    private var item: Item?
    private var lastAction: TrackingAddonService.PlayerAction?
    private var lastTime: TimeInterval = 0
    private var lastDuration: TimeInterval = 0

    init(send: @escaping Send = { action, item, currentTime, duration in
        TrackingAddonService.sendPlayerEvent(
            action,
            type: item.type,
            videoId: item.videoId,
            currentTime: currentTime,
            duration: duration
        )
    }) {
        self.send = send
    }

    /// Reports `start` or `pause`. Repeats of the current state are dropped.
    func report(_ action: TrackingAddonService.PlayerAction, item: Item, currentTime: TimeInterval, duration: TimeInterval) {
        guard duration.isFinite, duration > 0, currentTime.isFinite else { return }
        if let previous = self.item, previous != item {
            stop()
        }
        if action == .stop {
            self.item = item
            remember(currentTime, duration)
            stop()
            return
        }
        guard self.item != item || lastAction != action else {
            remember(currentTime, duration)
            return
        }
        self.item = item
        lastAction = action
        remember(currentTime, duration)
        send(action, item, currentTime, duration)
    }

    /// A seek re-sends the current state with the new position.
    func seeked(to currentTime: TimeInterval, duration: TimeInterval) {
        guard let item, let lastAction, lastAction != .stop,
              currentTime.isFinite, duration.isFinite, duration > 0 else { return }
        remember(currentTime, duration)
        send(lastAction, item, currentTime, duration)
    }

    /// Player closed, video changed or ended.
    func stop(currentTime: TimeInterval? = nil, duration: TimeInterval? = nil) {
        if let currentTime, currentTime.isFinite { lastTime = currentTime }
        if let duration, duration.isFinite, duration > 0 { lastDuration = duration }
        guard let item, let lastAction, lastAction != .stop else { return }
        self.lastAction = .stop
        send(.stop, item, lastTime, lastDuration)
    }

    private func remember(_ currentTime: TimeInterval, _ duration: TimeInterval) {
        lastTime = currentTime
        lastDuration = duration
    }
}
