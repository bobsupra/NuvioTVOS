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
    @StateObject var viewModel = PlayerViewModel()
    @Environment(\.scenePhase) var scenePhase

    let url: URL
    let meta: NuvioMeta
    let subtitle: String
    let httpHeaders: [String: String]
    let externalSubtitles: [NuvioSubtitle]
    let resumeFrom: Double?
    var playbackOrigin: PlaybackOrigin = .main
    var addonName: String? = nil
    var provider: String? = nil
    var filename: String? = nil
    var videoSize: Int64? = nil
    /// Episode context for the in-player Next Episode card. Empty for movies/trailers.
    var episodes: [NuvioVideo] = []
    var currentEpisode: NuvioVideo? = nil
    var autoPlayNextEnabled: Bool = true
    var autoPlayNextCountdownSeconds: Int = 10
    /// Resolves a next episode into a ready-to-play stream (add-on fetch + smart
    /// selection), supplied by the app layer. Nil disables auto-advance.
    var resolveNextStream: ((NuvioVideo) async -> PreparedNextStream?)? = nil
    /// Re-resolves a fresh stream for the *current* title/episode, used to
    /// recover from an expired link, load timeout, or playback error.
    /// `excludedURLs` are sources already tried this session. Nil disables failover.
    var reloadCurrentStream: ((_ excludedURLs: [String]) async -> PreparedNextStream?)? = nil
    /// Lists alternate streams for the Sources side panel.
    var fetchPlaybackSources: ((_ contentId: String, _ type: String) async -> [NuvioStream])? = nil
    /// Resolves a user-selected source for mid-playback switching.
    var resolvePlaybackStream: ((
        _ stream: NuvioStream,
        _ contentId: String,
        _ subtitleLine: String
    ) async -> PreparedNextStream?)? = nil
    var onFinished: (() -> Void)? = nil
    var onPlaybackStarted: (() -> Void)? = nil
    var onPlayRecommendation: ((_ meta: NuvioMeta, _ playManually: Bool) -> Void)? = nil
    var onOpenRecommendationDetails: ((_ meta: NuvioMeta) -> Void)? = nil
    var onBack: () -> Void

    @State var didHandleFinished = false
    @State var didReportPlaybackStarted = false
    @FocusState var remoteInputFocused: Bool
    @FocusState var startupRetryFocused: Bool
    @FocusState var nextEpisodeFocused: Bool
    @FocusState var cancelAutoPlayFocused: Bool
    @FocusState var skipSegmentFocused: Bool
    @FocusState var postPlayFocus: PostPlayFocusItem?

    var body: some View {
        layersWithRemoteCommands
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
                isReloadingStream: viewModel.isReloadingStream
            )
        )
    }

    func focusRemoteInput() {
        guard !viewModel.postPlayState.isVisible, viewModel.playbackStartupError == nil else { return }
        DispatchQueue.main.async {
            guard viewModel.playbackStartupError == nil else { return }
            remoteInputFocused = true
        }
    }

    func focusNextEpisode() {
        DispatchQueue.main.async {
            nextEpisodeFocused = true
        }
    }

    func focusSkipSegment() {
        DispatchQueue.main.async {
            skipSegmentFocused = true
        }
    }
}
