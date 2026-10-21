import SwiftUI
import UIKit
import Combine

// PlayerView is split across several files because `body` had grown to roughly
// 640 lines as a single expression, which the Swift type-checker could no longer
// solve within its budget ("unable to type-check this expression in reasonable
// time"). Each stage below is its own expression, so each is checked
// independently.
//
//   PlayerView+Layers.swift          the ZStack children
//   PlayerView+Overlays.swift        status / mini-player / debug overlays
//   PlayerView+Lifecycle.swift       animations, onAppear/onDisappear, onChange
//   PlayerView+RemoteCommands.swift  play-pause / move / exit commands
//
// The staged properties are chained in the original modifier order, so the
// resulting view tree is unchanged.

struct PlayerView: View {
    @StateObject var viewModel: PlayerViewModel
    @Environment(\.scenePhase) var scenePhase

    let url: URL
    let meta: NuvioMeta
    let subtitle: String
    let httpHeaders: [String: String]
    let externalSubtitles: [NuvioSubtitle]
    let resumeFrom: Double?
    var isActionPlaybackSession: Bool = false
    var playbackOrigin: PlaybackOrigin = .main
    var bingeGroup: String? = nil
    var addonName: String? = nil
    var provider: String? = nil
    var filename: String? = nil
    var videoSize: Int64? = nil
    var videoHash: String? = nil
    var cacheFileIdentity: PlaybackCacheFileIdentity? = nil
    var sourceID: String? = nil
    var trickplayURL: URL? = nil
    /// Episode context for the in-player Next Episode card. Empty for movies/trailers.
    var episodes: [NuvioVideo] = []
    var currentEpisode: NuvioVideo? = nil
    var initialStartupBenchmarkToken: UUID? = nil
    var autoPlayNextEnabled: Bool = true
    var autoPlayNextCountdownSeconds: Int = 10
    /// Resolves a next episode into a ready-to-play stream (add-on fetch + smart
    /// selection), supplied by the app layer. Nil disables auto-advance.
    var resolveNextStream: ((NuvioVideo, UUID?) async -> PreparedNextStream?)? = nil
    /// Re-resolves a fresh stream for the *current* title/episode, used to
    /// recover from an expired link, load timeout, or playback error.
    /// The first argument is the episode currently playing; `excludedURLs` are
    /// sources already tried this session. Nil disables failover.
    var reloadCurrentStream: ((_ episode: NuvioVideo?, _ excludedURLs: [String]) async -> PreparedNextStream?)? = nil
    /// Streams alternate sources into the Sources side panel as add-ons respond.
    var fetchPlaybackSources: ((_ contentId: String, _ type: String) -> AsyncStream<[NuvioStream]>)? = nil
    /// Resolves a user-selected source for mid-playback switching.
    var resolvePlaybackStream: ((
        _ stream: NuvioStream,
        _ contentId: String,
        _ subtitleLine: String,
        _ startupToken: UUID?
    ) async -> PreparedNextStream?)? = nil
    var onRequestSources: (() -> Void)? = nil
    var onFinished: (() -> Void)? = nil
    var onPlaybackStarted: (() -> Void)? = nil
    var onPlayRecommendation: ((_ meta: NuvioMeta, _ playManually: Bool) -> Void)? = nil
    var onOpenRecommendationDetails: ((_ meta: NuvioMeta) -> Void)? = nil
    var onBack: () -> Void
    let partyPlayback: WatchPartyPlayerMount?
    let partyPlaybackIdentity: UUID?
    let watchPartyOwner: WatchPartyAppOwner?
    let isCurrentPlayerSurface: @MainActor () -> Bool
    let onOpenWatchPartyLobby: () -> Void

    /// An explicit runtime can retain the same model across fullscreen / PiP surfaces.
    /// Existing callers keep lazy StateObject creation. A checked Party mount supplies its
    /// own model and lifecycle; a standalone viewModel argument supplies only the model.
    @MainActor
    init(
        url: URL,
        meta: NuvioMeta,
        subtitle: String,
        httpHeaders: [String: String],
        externalSubtitles: [NuvioSubtitle],
        resumeFrom: Double?,
        isActionPlaybackSession: Bool = false,
        playbackOrigin: PlaybackOrigin = .main,
        bingeGroup: String? = nil,
        addonName: String? = nil,
        provider: String? = nil,
        filename: String? = nil,
        videoSize: Int64? = nil,
        videoHash: String? = nil,
        cacheFileIdentity: PlaybackCacheFileIdentity? = nil,
        sourceID: String? = nil,
        trickplayURL: URL? = nil,
        episodes: [NuvioVideo] = [],
        currentEpisode: NuvioVideo? = nil,
        initialStartupBenchmarkToken: UUID? = nil,
        autoPlayNextEnabled: Bool = true,
        autoPlayNextCountdownSeconds: Int = 10,
        resolveNextStream: ((NuvioVideo, UUID?) async -> PreparedNextStream?)? = nil,
        reloadCurrentStream: ((NuvioVideo?, [String]) async -> PreparedNextStream?)? = nil,
        fetchPlaybackSources: ((String, String) -> AsyncStream<[NuvioStream]>)? = nil,
        resolvePlaybackStream: ((NuvioStream, String, String, UUID?) async -> PreparedNextStream?)? = nil,
        onRequestSources: (() -> Void)? = nil,
        onFinished: (() -> Void)? = nil,
        onPlaybackStarted: (() -> Void)? = nil,
        onPlayRecommendation: ((NuvioMeta, Bool) -> Void)? = nil,
        onOpenRecommendationDetails: ((NuvioMeta) -> Void)? = nil,
        viewModel: PlayerViewModel? = nil,
        partyPlayback: WatchPartyPlayerMount? = nil,
        partyPlaybackIdentity: UUID? = nil,
        watchPartyOwner: WatchPartyAppOwner? = nil,
        isCurrentPlayerSurface: @escaping @MainActor () -> Bool = { true },
        onOpenWatchPartyLobby: @escaping () -> Void = {},
        onBack: @escaping () -> Void
    ) {
        _viewModel = StateObject(wrappedValue: partyPlayback?.viewModel ?? viewModel ?? PlayerViewModel())
        self.partyPlayback = partyPlayback
        self.partyPlaybackIdentity = partyPlaybackIdentity
        self.watchPartyOwner = watchPartyOwner
        self.isCurrentPlayerSurface = isCurrentPlayerSurface
        self.onOpenWatchPartyLobby = onOpenWatchPartyLobby
        self.url = url
        self.meta = meta
        self.subtitle = subtitle
        self.httpHeaders = httpHeaders
        self.externalSubtitles = externalSubtitles
        self.resumeFrom = resumeFrom
        self.isActionPlaybackSession = isActionPlaybackSession
        self.playbackOrigin = playbackOrigin
        self.bingeGroup = bingeGroup
        self.addonName = addonName
        self.provider = provider
        self.filename = filename
        self.videoSize = videoSize
        self.videoHash = videoHash
        self.cacheFileIdentity = cacheFileIdentity
        self.sourceID = sourceID
        self.trickplayURL = trickplayURL
        self.episodes = episodes
        self.currentEpisode = currentEpisode
        self.initialStartupBenchmarkToken = initialStartupBenchmarkToken
        self.autoPlayNextEnabled = autoPlayNextEnabled
        self.autoPlayNextCountdownSeconds = autoPlayNextCountdownSeconds
        self.resolveNextStream = resolveNextStream
        self.reloadCurrentStream = reloadCurrentStream
        self.fetchPlaybackSources = fetchPlaybackSources
        self.resolvePlaybackStream = resolvePlaybackStream
        self.onRequestSources = onRequestSources
        self.onFinished = onFinished
        self.onPlaybackStarted = onPlaybackStarted
        self.onPlayRecommendation = onPlayRecommendation
        self.onOpenRecommendationDetails = onOpenRecommendationDetails
        self.onBack = onBack
    }

    @State var didHandleFinished = false
    @State var partySurface: WatchPartyPlayerRuntime.Surface?
    @State var didReportPlaybackStarted = false
    @State var lastBecameActiveAt: Date = Date()
    @State var requestedControlFocus: PlayerControlFocus? = nil
    @State var showingWatchPartyMenu = false
    @FocusState var remoteInputFocused: Bool
    @FocusState var nextEpisodeFocused: Bool
    @FocusState var cancelAutoPlayFocused: Bool
    @FocusState var skipSegmentFocused: Bool
    @FocusState var postPlayFocus: PostPlayFocusItem?

    var isWakingFromBackground: Bool {
        Date().timeIntervalSince(lastBecameActiveAt) < 0.6
    }

    var body: some View {
        layersWithRemoteCommands
    }

    var isStandalonePlaybackSession: Bool {
        isActionPlaybackSession || subtitle == PlaybackMarkers.trailerSubtitle
    }

    var canShowWatchPartyButton: Bool {
        WatchPartyConfiguration.isEnabled
            && watchPartyOwner?.service != nil && !isStandalonePlaybackSession
    }

    var subtitleContentId: String {
        if let currentEpisode { return currentEpisode.id }
        if meta.isSeries, let numbers = EpisodeTagResolver.episodeNumbers(in: subtitle) {
            return "\(meta.id):\(numbers.season):\(numbers.episode)"
        }
        return meta.id
    }

    func syncPlaybackWakeLock() {
        PlaybackWakeLock.setPreventsIdle(
            PlaybackIdlePolicy.preventsIdle(
                status: viewModel.status,
                isSwitchingSource: viewModel.isSwitchingSource,
                isReloadingStream: viewModel.isReloadingStream,
                isAdvancingEpisode: viewModel.isAdvancingEpisode
            )
        )
    }

    func focusRemoteInput() {
        guard !viewModel.postPlayState.isVisible, viewModel.currentErrorDiagnostic == nil else { return }
        DispatchQueue.main.async {
            guard viewModel.currentErrorDiagnostic == nil else { return }
            remoteInputFocused = true
        }
    }

    func focusNextEpisode(allowWhenControlsVisible: Bool = false) {
        DispatchQueue.main.async {
            guard viewModel.showNextEpisodeCard,
                  !viewModel.isScrubbing,
                  !viewModel.isHoldingSeek,
                  !viewModel.isSwitchingSource,
                  !viewModel.showSettingsPanel,
                  !viewModel.showScenePanel,
                  !viewModel.isSceneDetailVisible,
                  viewModel.sidePanel == nil,
                  !viewModel.postPlayState.isVisible,
                  !viewModel.showPauseOverlay,
                  viewModel.currentErrorDiagnostic == nil,
                  !isWakingFromBackground,
                  !skipSegmentFocused,
                  !cancelAutoPlayFocused,
                  allowWhenControlsVisible || !viewModel.showControls else { return }
            nextEpisodeFocused = true
        }
    }

    func focusSkipSegment() {
        DispatchQueue.main.async {
            guard viewModel.showSkipSegmentCard,
                  !viewModel.postPlayState.isVisible,
                  !viewModel.showSettingsPanel,
                  !viewModel.showScenePanel,
                  !viewModel.isSceneDetailVisible,
                  viewModel.sidePanel == nil,
                  !viewModel.isScrubbing,
                  !viewModel.isHoldingSeek,
                  viewModel.currentErrorDiagnostic == nil,
                  !isWakingFromBackground else { return }
            skipSegmentFocused = true
        }
    }
}
