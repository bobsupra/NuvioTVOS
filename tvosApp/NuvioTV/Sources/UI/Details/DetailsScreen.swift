//
//  DetailsScreen.swift
//  NuvioTV
//
//  Created by Claude Code
//  Content details screen with adaptive layouts for iOS/iPad/tvOS
//

import Foundation
import SwiftUI
import UIKit

struct DetailsScreen: View {
    let id: String
    let type: String
    /// (streamURL, meta, episodeSubtitleLine, streamSubtitles, currentEpisode, orderedEpisodes).
    /// The last two carry series context for the player's next-episode auto-play;
    /// both are empty/nil for movies and trailers.
    let onPlayClick: (String, NuvioMeta, String, [NuvioSubtitle], NuvioVideo?, [NuvioVideo]) -> Void
    let onBack: () -> Void
    /// Open another title (More Like This / production catalog).
    var onOpenTitle: ((String, String) -> Void)? = nil
    /// Open a production company / network catalog.
    var onOpenProduction: ((MetaCompany) -> Void)? = nil
    let initiallyPresentStreamPicker: Bool
    let initialStreamPickerEpisode: NuvioVideo?
    let onInitialStreamPickerPresented: (() -> Void)?

    @StateObject private var viewModel: DetailsViewModel
    @State private var isStreamPickerPresented = false
    @State private var isSmartPlaybackPending = false
    /// Episode line shown under the title in the player ("" for movies).
    @State private var pendingEpisodeSubtitle = ""
    /// The episode a stream is being picked for (nil for movies); drives the
    /// season/episode header in the stream picker.
    @State private var pendingEpisode: NuvioVideo?
    @State private var didHandleInitialStreamPicker = false
    @State private var expandedComment: TraktCommentReview?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage(SettingsKey.smartStreamSelection) private var smartStreamSelection = false
    @AppStorage(SettingsKey.smartStreamQuality) private var smartStreamQuality = "Highest"
    @AppStorage(SettingsKey.smartSubtitleMatching) private var smartSubtitleMatching = true
    @AppStorage(SettingsKey.subtitleLanguages) private var subtitleLanguages = ""
    @AppStorage(SettingsKey.subtitleLanguage) private var subtitleLanguage = "System"
    @AppStorage(SettingsKey.subtitleLanguageSecondary) private var subtitleLanguageSecondary = "None"
    @AppStorage(SettingsKey.subtitleLanguageTertiary) private var subtitleLanguageTertiary = "None"
    @AppStorage(SettingsKey.tmdbEnabled) private var tmdbEnabled = false
    @AppStorage(SettingsKey.tmdbApiKey) private var tmdbApiKey = ""
    @AppStorage(SettingsKey.debridProvider) private var debridProvider = "None"
    @AppStorage(SettingsKey.debridApiKey) private var debridApiKey = ""
    /// True while a torrent stream is being resolved through the debrid provider,
    /// so the picker can keep its spinner up instead of appearing to hang.
    @State private var isResolvingDebrid = false

    init(
        id: String,
        type: String,
        repository: CatalogRepository,
        initiallyPresentStreamPicker: Bool = false,
        initialStreamPickerEpisode: NuvioVideo? = nil,
        onInitialStreamPickerPresented: (() -> Void)? = nil,
        onPlayClick: @escaping (String, NuvioMeta, String, [NuvioSubtitle], NuvioVideo?, [NuvioVideo]) -> Void,
        onBack: @escaping () -> Void,
        onOpenTitle: ((String, String) -> Void)? = nil,
        onOpenProduction: ((MetaCompany) -> Void)? = nil
    ) {
        self.id = id
        self.type = type
        self.onPlayClick = onPlayClick
        self.onBack = onBack
        self.onOpenTitle = onOpenTitle
        self.onOpenProduction = onOpenProduction
        self.initiallyPresentStreamPicker = initiallyPresentStreamPicker
        self.initialStreamPickerEpisode = initialStreamPickerEpisode
        self.onInitialStreamPickerPresented = onInitialStreamPickerPresented
        _viewModel = StateObject(wrappedValue: DetailsViewModel(repository: repository))
    }

    var body: some View {
        ZStack {
            if viewModel.uiState.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = viewModel.uiState.error {
                ErrorView(
                    error: error,
                    onRetry: { viewModel.loadDetails(id: id, type: type) },
                    onBack: onBack
                )
            } else if viewModel.uiState.meta != nil {
                #if os(tvOS)
                TvDetailsContent(
                    uiState: viewModel.uiState,
                    onPlayClick: {
                        // Movie (or a series with no episode list): make sure streams
                        // are loaded for the title id, then either auto-select or open the picker.
                        pendingEpisodeSubtitle = ""
                        pendingEpisode = nil
                        startStreamFlow(streamId: id, type: viewModel.uiState.meta?.type ?? type, reload: viewModel.uiState.streams.isEmpty)
                    },
                    onPlayManually: {
                        // Hold-to-play-manually: always open the picker even when Auto Select is on.
                        pendingEpisodeSubtitle = ""
                        pendingEpisode = nil
                        startStreamFlow(
                            streamId: id,
                            type: viewModel.uiState.meta?.type ?? type,
                            reload: viewModel.uiState.streams.isEmpty,
                            forceManualPicker: true
                        )
                    },
                    onEpisodeSelected: { video in
                        pendingEpisodeSubtitle = "S\(video.season) · E\(video.episode) · \(video.title)"
                        pendingEpisode = video
                        startStreamFlow(streamId: video.id, type: "series", reload: true)
                    },
                    onEpisodePlayManually: { video in
                        pendingEpisodeSubtitle = "S\(video.season) · E\(video.episode) · \(video.title)"
                        pendingEpisode = video
                        startStreamFlow(streamId: video.id, type: "series", reload: true, forceManualPicker: true)
                    },
                    onWatchlistClick: { viewModel.toggleWatchlist() },
                    onWatchedClick: { viewModel.toggleWatched() },
                    onShareClick: { shareContent(viewModel.uiState.meta!) },
                    onTrailerClick: { openTrailer(for: viewModel.uiState.meta!) },
                    onOpenTitle: { contentId, contentType in
                        onOpenTitle?(contentId, contentType)
                    },
                    onOpenProduction: { company in
                        onOpenProduction?(company)
                    },
                    onCommentSelect: { comment in
                        expandedComment = comment
                    },
                    onBack: onBack
                )
                // While the stream picker is open it sits on top as a full-screen
                // overlay; disable the details content so the focus engine can't
                // route focus to the (hidden) buttons behind it.
                .disabled(isStreamPickerPresented || expandedComment != nil)
                #else
                MobileDetailsContent(
                    uiState: viewModel.uiState,
                    onPlayClick: {
                        if let url = viewModel.uiState.streams.first?.url,
                           let meta = viewModel.uiState.meta {
                            onPlayClick(url, meta, "", [], nil, [])
                        }
                    },
                    onWatchlistClick: { viewModel.toggleWatchlist() },
                    onWatchedClick: { viewModel.toggleWatched() },
                    onShareClick: { shareContent(viewModel.uiState.meta!) },
                    onBack: onBack
                )
                #endif
            }

            #if os(tvOS)
            if isStreamPickerPresented, let meta = viewModel.uiState.meta {
                // Mount the picker once any group exists (loading chips), any
                // streams arrived, or discovery finished — so add-ons appear
                // immediately as loading instead of waiting for the first hit.
                let hasGroups = !viewModel.uiState.streamGroups.isEmpty
                let hasStreams = !viewModel.uiState.streams.isEmpty
                let finished = !viewModel.uiState.isLoadingStreams
                if hasGroups || hasStreams || finished {
                    TvStreamPickerOverlay(
                        meta: meta,
                        episode: pendingEpisode,
                        streams: viewModel.uiState.streams,
                        groups: viewModel.uiState.streamGroups,
                        streamsRevision: viewModel.uiState.streamsRevision,
                        isLoading: viewModel.uiState.isLoadingStreams,
                        emptyReason: viewModel.uiState.streamsEmptyReason,
                        includeDebrid: DebridResolver(store: ProfileSettings.current).isEnabled,
                        isResolvingDebrid: isResolvingDebrid,
                        onSelect: { stream in
                            playStream(stream, meta: meta)
                        },
                        onDismiss: {
                            isStreamPickerPresented = false
                        }
                    )
                    .transition(.opacity)
                    .zIndex(10)
                } else {
                    TvStreamLoadingOverlay(
                        meta: meta,
                        episode: pendingEpisode,
                        onDismiss: { isStreamPickerPresented = false }
                    )
                    .transition(.opacity)
                    .zIndex(10)
                }
            }

            if let expandedComment {
                CommentDetailOverlay(
                    comment: expandedComment,
                    onDismiss: { self.expandedComment = nil }
                )
                .transition(.opacity)
                .zIndex(20)
            }
            #endif
        }
        .animation(.easeInOut(duration: 0.18), value: isStreamPickerPresented)
        #if os(tvOS)
        // Menu-press safety net. While the stream picker is up, focus can be
        // in limbo for a few frames (details content is disabled, the picker
        // hasn't committed focus yet); a Menu press then skips the picker's
        // own onExitCommand and bubbles to the app shell, which backs out to
        // Home or suspends the app. Catching it here closes just the picker,
        // and otherwise behaves like the regular back action.
        .onExitCommand {
            if expandedComment != nil {
                expandedComment = nil
            } else if isStreamPickerPresented {
                isStreamPickerPresented = false
            } else {
                onBack()
            }
        }
        #endif
        .onChange(of: viewModel.uiState.isLoadingStreams) { isLoading in
            if !isLoading {
                finishSmartPlaybackIfPossible()
            }
        }
        .onChange(of: viewModel.uiState.isLoading) { isLoading in
            if !isLoading {
                presentInitialStreamPickerIfNeeded()
            }
        }
        .onAppear {
            viewModel.loadDetails(id: id, type: type)
            presentInitialStreamPickerIfNeeded()
        }
    }

    private func presentInitialStreamPickerIfNeeded() {
        guard initiallyPresentStreamPicker,
              !didHandleInitialStreamPicker,
              !viewModel.uiState.isLoading,
              let meta = viewModel.uiState.meta else { return }

        didHandleInitialStreamPicker = true
        onInitialStreamPickerPresented?()
        isSmartPlaybackPending = false
        pendingEpisode = initialStreamPickerEpisode
        if let episode = initialStreamPickerEpisode {
            pendingEpisodeSubtitle = "S\(episode.season) · E\(episode.episode) · \(episode.title)"
            viewModel.prepareStreams(forId: episode.id, type: "series")
        } else {
            pendingEpisodeSubtitle = ""
            viewModel.prepareStreams(forId: id, type: meta.type)
        }
        isStreamPickerPresented = true
    }

    private func startStreamFlow(streamId: String, type: String, reload: Bool, forceManualPicker: Bool = false) {
        guard let meta = viewModel.uiState.meta else { return }

        if forceManualPicker || !smartStreamSelection {
            isSmartPlaybackPending = false
            if reload {
                viewModel.prepareStreams(forId: streamId, type: type)
            }
            isStreamPickerPresented = true
            return
        }

        isSmartPlaybackPending = true
        isStreamPickerPresented = true

        if reload {
            viewModel.prepareStreams(forId: streamId, type: type)
        } else {
            finishSmartPlaybackIfPossible(meta: meta)
        }
    }

    private func finishSmartPlaybackIfPossible(meta explicitMeta: NuvioMeta? = nil) {
        guard isSmartPlaybackPending, !viewModel.uiState.isLoadingStreams else { return }
        let meta = explicitMeta ?? viewModel.uiState.meta
        guard let meta else { return }

        let cachedOnly = (ProfileSettings.current.object(forKey: SettingsKey.cachedOnlyStreams) as? Bool) ?? false
        if let stream = SmartPlaybackSelector.bestStream(
            from: viewModel.uiState.streams,
            qualityPreference: smartStreamQuality,
            subtitleLanguages: subtitleLanguagePreferences,
            shouldMatchSubtitles: smartSubtitleMatching,
            includeDebrid: DebridResolver(store: ProfileSettings.current).isEnabled,
            preferredTags: LastStreamQualityStore.load(metaId: meta.id),
            cachedOnly: cachedOnly
        ) {
            isSmartPlaybackPending = false
            // Direct streams dismiss the picker immediately; debrid streams keep
            // it up with a spinner until the link resolves (handled in playStream).
            playStream(stream, meta: meta)
        } else {
            isSmartPlaybackPending = false
            isStreamPickerPresented = true
        }
    }

    /// Plays a chosen stream. Direct URLs go straight to the player; torrent-only
    /// streams are resolved through the configured debrid provider first, keeping
    /// the picker's spinner up until a link comes back (or the attempt fails).
    private func playStream(_ stream: NuvioStream, meta: NuvioMeta) {
        LastStreamQualityStore.save(metaId: meta.id, stream: stream)
        if let url = stream.url, !url.isEmpty {
            isStreamPickerPresented = false
            onPlayClick(url, meta, pendingEpisodeSubtitle, stream.subtitles, pendingEpisode, orderedEpisodes(for: meta))
            return
        }

        guard stream.isDebridResolvable, !isResolvingDebrid else { return }
        let season = pendingEpisode?.season
        let episode = pendingEpisode?.episode
        isResolvingDebrid = true
        Task {
            let result = await DebridResolver(store: ProfileSettings.current)
                .resolvedURL(for: stream, season: season, episode: episode)
            await MainActor.run {
                isResolvingDebrid = false
                if case let .success(url, _, _)? = result {
                    isStreamPickerPresented = false
                    onPlayClick(url.absoluteString, meta, pendingEpisodeSubtitle, stream.subtitles, pendingEpisode, orderedEpisodes(for: meta))
                }
            }
        }
    }

    private var subtitleLanguagePreferences: [String] {
        SubtitleLanguagePreferences.ordered(
            encoded: subtitleLanguages,
            primary: subtitleLanguage,
            secondary: subtitleLanguageSecondary,
            tertiary: subtitleLanguageTertiary
        )
    }

    /// The series' episodes in playback order (specials last), handed to the
    /// player so it can offer the next one. Empty for movies.
    private func orderedEpisodes(for meta: NuvioMeta) -> [NuvioVideo] {
        guard meta.isSeries else { return [] }
        return (meta.videos ?? []).sorted {
            (Self.episodeSeasonSortKey($0.season), $0.episode) < (Self.episodeSeasonSortKey($1.season), $1.episode)
        }
    }

    private static func episodeSeasonSortKey(_ season: Int) -> Int {
        season <= 0 ? Int.max : season
    }

    private func shareContent(_ meta: NuvioMeta) {
        var shareText = "Check out \(meta.name)"
        if let year = meta.year {
            shareText += " (\(year))"
        }
        shareText += "\n\n"
        if let description = meta.description {
            shareText += description
        }
        if let imdbId = meta.imdbId {
            shareText += "\n\nhttps://www.imdb.com/title/\(imdbId)"
        }

        #if !os(tvOS)
        let activityVC = UIActivityViewController(
            activityItems: [shareText],
            applicationActivities: nil
        )

        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = windowScene.windows.first?.rootViewController {
            rootVC.present(activityVC, animated: true)
        }
        #endif
    }

    private func openTrailer(for meta: NuvioMeta) {
        Task {
            guard let ytId = await preferredTrailerYouTubeId(for: meta) else { return }
            let youtubeUrl = "https://www.youtube.com/watch?v=\(ytId)"

            await MainActor.run {
                onPlayClick(youtubeUrl, meta, PlaybackMarkers.trailerSubtitle, [], nil, [])
            }
        }
    }

    private func preferredTrailerYouTubeId(for meta: NuvioMeta) async -> String? {
        if let ytId = meta.trailerYtIds?
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty }) {
            return ytId
        }

        guard tmdbEnabled,
              !tmdbApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let tmdbId = meta.tmdbId else {
            return nil
        }

        return await fetchTmdbTrailerId(tmdbId: tmdbId, type: meta.type)
    }

    private func fetchTmdbTrailerId(tmdbId: Int, type: String) async -> String? {
        let mediaPath = type.caseInsensitiveCompare("series") == .orderedSame ? "tv" : "movie"
        var components = URLComponents(string: "https://api.themoviedb.org/3/\(mediaPath)/\(tmdbId)/videos")
        components?.queryItems = [
            URLQueryItem(name: "api_key", value: tmdbApiKey),
            URLQueryItem(name: "language", value: "en-US")
        ]
        guard let url = components?.url else { return nil }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
                return nil
            }
            let decoded = try JSONDecoder().decode(TmdbVideosResponse.self, from: data)
            return decoded.results
                .filter { $0.site?.caseInsensitiveCompare("YouTube") == .orderedSame }
                .sorted { lhs, rhs in
                    if lhs.rank != rhs.rank { return lhs.rank > rhs.rank }
                    return (lhs.publishedAt ?? "") > (rhs.publishedAt ?? "")
                }
                .first?
                .key
        } catch {
            return nil
        }
    }
}

private struct TmdbVideosResponse: Decodable {
    let results: [TmdbVideoResult]
}

private struct TmdbVideoResult: Decodable {
    let key: String?
    let site: String?
    let type: String?
    let official: Bool?
    let publishedAt: String?

    enum CodingKeys: String, CodingKey {
        case key, site, type, official
        case publishedAt = "published_at"
    }

    var rank: Int {
        var value = 0
        if type?.caseInsensitiveCompare("Trailer") == .orderedSame { value += 100 }
        if official == true { value += 50 }
        if type?.caseInsensitiveCompare("Teaser") == .orderedSame { value += 25 }
        return value
    }
}

actor YouTubeTrailerResolver {
    private struct Client {
        let key: String
        let id: String
        let version: String
        let userAgent: String
        let context: [String: Any]
        let priority: Int
    }

    private struct WatchConfig {
        let apiKey: String
        let visitorData: String?
        let fetchedAt: Date
    }

    private struct StreamCandidate {
        let clientKey: String
        let url: String
        let height: Int
        let score: Double
        let hasN: Bool
        let ext: String
        let priority: Int
    }

    private struct HlsCandidate {
        let manifestUrl: String
        let selectedVariantUrl: String
        let width: Int
        let height: Int
        let bandwidth: Int
        let priority: Int
    }

    private struct TrailerBackendResponse: Decodable {
        let url: String?
    }

    private static let defaultUserAgent =
        "Mozilla/5.0 (AppleTV; CPU OS 17_0 like Mac OS X) AppleWebKit/605.1.15 " +
        "(KHTML, like Gecko) Version/17.0 Safari/605.1.15"
    private static let fallbackApiKey = "AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8"
    private static let configTTL: TimeInterval = 3 * 60 * 60
    private static let resolverBaseKey = "nuvio.tv.settings.playback.trailerResolverBaseURL"
    static let minimumHeight = 1080

    private static let clients: [Client] = [
        Client(
            key: "android_vr",
            id: "28",
            version: "1.56.21",
            userAgent: "com.google.android.apps.youtube.vr.oculus/1.56.21 (Linux; U; Android 12; en_US; Quest 3; Build/SQ3A.220605.009.A1) gzip",
            context: [
                "clientName": "ANDROID_VR",
                "clientVersion": "1.56.21",
                "deviceMake": "Oculus",
                "deviceModel": "Quest 3",
                "osName": "Android",
                "osVersion": "12",
                "platform": "MOBILE",
                "androidSdkVersion": 32,
                "hl": "en",
                "gl": "US"
            ],
            priority: 0
        ),
        Client(
            key: "android",
            id: "3",
            version: "20.10.35",
            userAgent: "com.google.android.youtube/20.10.35 (Linux; U; Android 14; en_US) gzip",
            context: [
                "clientName": "ANDROID",
                "clientVersion": "20.10.35",
                "osName": "Android",
                "osVersion": "14",
                "platform": "MOBILE",
                "androidSdkVersion": 34,
                "hl": "en",
                "gl": "US"
            ],
            priority: 1
        ),
        Client(
            key: "ios",
            id: "5",
            version: "20.10.1",
            userAgent: "com.google.ios.youtube/20.10.1 (iPhone16,2; U; CPU iOS 17_4 like Mac OS X)",
            context: [
                "clientName": "IOS",
                "clientVersion": "20.10.1",
                "deviceModel": "iPhone16,2",
                "osName": "iPhone",
                "osVersion": "17.4.0.21E219",
                "platform": "MOBILE",
                "hl": "en",
                "gl": "US"
            ],
            priority: 2
        )
    ]

    private var cachedConfig: WatchConfig?
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.httpAdditionalHeaders = [
            "Accept-Language": "en-US,en;q=0.9"
        ]
        return URLSession(configuration: configuration)
    }()

    func resolve(youtubeVideoId: String, title: String?, year: String?) async -> TrailerPlaybackSource? {
        guard Self.isYouTubeVideoId(youtubeVideoId) else { return nil }

        if let url = await resolveWithInnertube(videoId: youtubeVideoId, forceRefreshConfig: false) {
            return url
        }

        cachedConfig = nil
        if let url = await resolveWithInnertube(videoId: youtubeVideoId, forceRefreshConfig: true) {
            return url
        }

        let youtubeUrl = "https://www.youtube.com/watch?v=\(youtubeVideoId)"
        return await resolveWithBackend(youtubeUrl: youtubeUrl, title: title, year: year)
    }

    private func resolveWithInnertube(videoId: String, forceRefreshConfig: Bool) async -> TrailerPlaybackSource? {
        guard let config = try? await watchConfig(forceRefresh: forceRefreshConfig) else { return nil }
        var hlsCandidates: [HlsCandidate] = []
        var progressive: [StreamCandidate] = []
        var adaptiveVideo: [StreamCandidate] = []
        var adaptiveAudio: [StreamCandidate] = []

        for client in Self.clients {
            if Task.isCancelled { return nil }
            guard let playerResponse = try? await fetchPlayerResponse(
                apiKey: config.apiKey,
                videoId: videoId,
                client: client,
                visitorData: config.visitorData
            ) else {
                continue
            }

            if let status = stringValue(mapValue(playerResponse, key: "playabilityStatus"), key: "status"),
               status != "OK" {
                continue
            }

            guard let streamingData = mapValue(playerResponse, key: "streamingData") else { continue }

            if let manifestUrl = stringValue(streamingData, key: "hlsManifestUrl"),
               let candidate = try? await hlsCandidate(manifestUrl: manifestUrl, priority: client.priority) {
                hlsCandidates.append(candidate)
            }

            for format in listMapValue(streamingData, key: "formats") {
                guard let url = stringValue(format, key: "url") else { continue }
                let mimeType = stringValue(format, key: "mimeType") ?? ""
                guard mimeType.contains("video/") else { continue }

                let height = Int(numberValue(format, key: "height") ?? Double(parseQualityLabel(stringValue(format, key: "qualityLabel")) ?? 0))
                let fps = Int(numberValue(format, key: "fps") ?? 0)
                let bitrate = numberValue(format, key: "bitrate") ?? numberValue(format, key: "averageBitrate") ?? 0

                progressive.append(
                    StreamCandidate(
                        clientKey: client.key,
                        url: url,
                        height: height,
                        score: videoScore(height: height, fps: fps, bitrate: bitrate),
                        hasN: hasNParam(url),
                        ext: mimeType.contains("webm") ? "webm" : "mp4",
                        priority: client.priority
                    )
                )
            }

            for format in listMapValue(streamingData, key: "adaptiveFormats") {
                guard let url = stringValue(format, key: "url") else { continue }
                let mimeType = stringValue(format, key: "mimeType") ?? ""
                let hasVideo = mimeType.contains("video/")
                let hasAudio = mimeType.contains("audio/") || mimeType.hasPrefix("audio/")

                if hasVideo {
                    let height = Int(numberValue(format, key: "height") ?? Double(parseQualityLabel(stringValue(format, key: "qualityLabel")) ?? 0))
                    let fps = Int(numberValue(format, key: "fps") ?? 0)
                    let bitrate = numberValue(format, key: "bitrate") ?? numberValue(format, key: "averageBitrate") ?? 0

                    adaptiveVideo.append(
                        StreamCandidate(
                            clientKey: client.key,
                            url: url,
                            height: height,
                            score: videoScore(height: height, fps: fps, bitrate: bitrate),
                            hasN: hasNParam(url),
                            ext: mimeType.contains("webm") ? "webm" : "mp4",
                            priority: client.priority
                        )
                    )
                } else if hasAudio {
                    let bitrate = numberValue(format, key: "bitrate") ?? numberValue(format, key: "averageBitrate") ?? 0
                    let sampleRate = numberValue(format, key: "audioSampleRate") ?? 0

                    adaptiveAudio.append(
                        StreamCandidate(
                            clientKey: client.key,
                            url: url,
                            height: 0,
                            score: audioScore(bitrate: bitrate, sampleRate: sampleRate),
                            hasN: hasNParam(url),
                            ext: mimeType.contains("webm") ? "webm" : "m4a",
                            priority: client.priority
                        )
                    )
                }
            }
        }

        if let video = adaptiveVideo
            .filter({ $0.height >= Self.minimumHeight })
            .sorted(by: sortStreamCandidates)
            .first {
            let audio = adaptiveAudio
                .filter { $0.clientKey == video.clientKey }
                .sorted(by: sortStreamCandidates)
                .first ?? adaptiveAudio.sorted(by: sortStreamCandidates).first
            return TrailerPlaybackSource(videoUrl: video.url, audioUrl: audio?.url)
        }

        if let hls = hlsCandidates
            .filter({ $0.height >= Self.minimumHeight })
            .sorted(by: sortHlsCandidates)
            .first {
            return TrailerPlaybackSource(videoUrl: hls.selectedVariantUrl, audioUrl: nil)
        }

        let progressiveUrl = progressive
            .filter { $0.height >= Self.minimumHeight }
            .sorted(by: sortStreamCandidates)
            .first?.url
        guard let progressiveUrl else { return nil }
        return TrailerPlaybackSource(videoUrl: progressiveUrl, audioUrl: nil)
    }

    private func watchConfig(forceRefresh: Bool) async throws -> WatchConfig {
        if !forceRefresh,
           let cachedConfig,
           Date().timeIntervalSince(cachedConfig.fetchedAt) < Self.configTTL {
            return cachedConfig
        }

        guard let url = URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ&hl=en") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        addDefaultHeaders(to: &request)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw URLError(.badServerResponse)
        }

        let html = String(data: data, encoding: .utf8) ?? ""
        let config = WatchConfig(
            apiKey: firstCapture(in: html, pattern: #""INNERTUBE_API_KEY":"([^"]+)""#) ?? Self.fallbackApiKey,
            visitorData: firstCapture(in: html, pattern: #""VISITOR_DATA":"([^"]+)""#),
            fetchedAt: Date()
        )
        cachedConfig = config
        return config
    }

    private func fetchPlayerResponse(
        apiKey: String,
        videoId: String,
        client: Client,
        visitorData: String?
    ) async throws -> [String: Any] {
        let encodedKey = apiKey.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? apiKey
        guard let url = URL(string: "https://www.youtube.com/youtubei/v1/player?key=\(encodedKey)") else {
            throw URLError(.badURL)
        }

        let payload: [String: Any] = [
            "videoId": videoId,
            "contentCheckOk": true,
            "racyCheckOk": true,
            "context": ["client": client.context],
            "playbackContext": [
                "contentPlaybackContext": ["html5Preference": "HTML5_PREF_WANTS"]
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        addDefaultHeaders(to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue(client.id, forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(client.version, forHTTPHeaderField: "X-YouTube-Client-Version")
        request.setValue(client.userAgent, forHTTPHeaderField: "User-Agent")
        if let visitorData, !visitorData.isEmpty {
            request.setValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw URLError(.badServerResponse)
        }

        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func hlsCandidate(manifestUrl: String, priority: Int) async throws -> HlsCandidate {
        guard let url = URL(string: manifestUrl) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        addDefaultHeaders(to: &request)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw URLError(.badServerResponse)
        }

        let text = String(data: data, encoding: .utf8) ?? ""
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var best = HlsCandidate(
            manifestUrl: manifestUrl,
            selectedVariantUrl: manifestUrl,
            width: 0,
            height: 0,
            bandwidth: 0,
            priority: priority
        )
        for index in lines.indices {
            let line = lines[index]
            guard line.hasPrefix("#EXT-X-STREAM-INF:"),
                  index + 1 < lines.count,
                  !lines[index + 1].hasPrefix("#") else {
                continue
            }

            let attrs = parseHlsAttributeList(line)
            let (width, height) = parseResolution(attrs["RESOLUTION"] ?? "")
            let bandwidth = Int(attrs["BANDWIDTH"] ?? "") ?? 0
            let variantUrl = absolutizeUrl(baseUrl: manifestUrl, maybeRelative: lines[index + 1])

            if height > best.height ||
                (height == best.height && bandwidth > best.bandwidth) ||
                (height == best.height && bandwidth == best.bandwidth && width > best.width) {
                best = HlsCandidate(
                    manifestUrl: manifestUrl,
                    selectedVariantUrl: variantUrl,
                    width: width,
                    height: height,
                    bandwidth: bandwidth,
                    priority: priority
                )
            }
        }

        return best
    }

    private func resolveWithBackend(youtubeUrl: String, title: String?, year: String?) async -> TrailerPlaybackSource? {
        guard let baseUrl = configuredBackendBaseURL() else { return nil }
        let endpoint = baseUrl.lastPathComponent == "trailer" ? baseUrl : baseUrl.appendingPathComponent("trailer")
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else { return nil }

        components.queryItems = [
            URLQueryItem(name: "youtube_url", value: youtubeUrl),
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "year", value: year)
        ].filter { $0.value != nil }

        guard let url = components.url else { return nil }

        do {
            var request = URLRequest(url: url)
            addDefaultHeaders(to: &request)
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
                return nil
            }
            let decoded = try JSONDecoder().decode(TrailerBackendResponse.self, from: data)
            guard let resolved = decoded.url,
                  resolved.hasPrefix("http://") || resolved.hasPrefix("https://") else {
                return nil
            }
            return TrailerPlaybackSource(videoUrl: resolved, audioUrl: nil)
        } catch {
            return nil
        }
    }

    private func configuredBackendBaseURL() -> URL? {
        let candidates = [
            UserDefaults.standard.string(forKey: Self.resolverBaseKey),
            Bundle.main.object(forInfoDictionaryKey: "NuvioTrailerAPIBaseURL") as? String
        ]

        return candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
            .flatMap(URL.init(string:))
    }

    private func addDefaultHeaders(to request: inout URLRequest) {
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue(Self.defaultUserAgent, forHTTPHeaderField: "User-Agent")
    }

    private func sortHlsCandidates(_ lhs: HlsCandidate, _ rhs: HlsCandidate) -> Bool {
        if lhs.height != rhs.height { return lhs.height > rhs.height }
        if lhs.bandwidth != rhs.bandwidth { return lhs.bandwidth > rhs.bandwidth }
        return lhs.priority < rhs.priority
    }

    private func sortStreamCandidates(_ lhs: StreamCandidate, _ rhs: StreamCandidate) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        if lhs.hasN != rhs.hasN { return !lhs.hasN }
        if containerPreference(lhs.ext) != containerPreference(rhs.ext) {
            return containerPreference(lhs.ext) < containerPreference(rhs.ext)
        }
        return lhs.priority < rhs.priority
    }

    private func videoScore(height: Int, fps: Int, bitrate: Double) -> Double {
        Double(height) * 1_000_000_000 + Double(fps) * 1_000_000 + bitrate
    }

    private func audioScore(bitrate: Double, sampleRate: Double) -> Double {
        bitrate * 1_000_000 + sampleRate
    }

    private func containerPreference(_ ext: String) -> Int {
        switch ext.lowercased() {
        case "mp4", "m4a": return 0
        case "webm": return 1
        default: return 2
        }
    }

    private func parseQualityLabel(_ label: String?) -> Int? {
        guard let label else { return nil }
        return firstCapture(in: label, pattern: #"\b(\d{2,4})p\b"#).flatMap(Int.init)
    }

    private func hasNParam(_ url: String) -> Bool {
        URLComponents(string: url)?.queryItems?.contains { $0.name == "n" && !($0.value ?? "").isEmpty } ?? false
    }

    private func parseHlsAttributeList(_ line: String) -> [String: String] {
        guard let colon = line.firstIndex(of: ":") else { return [:] }
        let raw = line[line.index(after: colon)...]
        var output: [String: String] = [:]
        var key = ""
        var value = ""
        var inKey = true
        var inQuote = false

        for char in raw {
            if inKey {
                if char == "=" {
                    inKey = false
                } else {
                    key.append(char)
                }
                continue
            }

            if char == "\"" {
                inQuote.toggle()
                continue
            }

            if char == "," && !inQuote {
                let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedKey.isEmpty {
                    output[trimmedKey] = value.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                key = ""
                value = ""
                inKey = true
                continue
            }

            value.append(char)
        }

        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKey.isEmpty {
            output[trimmedKey] = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return output
    }

    private func parseResolution(_ raw: String) -> (Int, Int) {
        let parts = raw.split(separator: "x", maxSplits: 1)
        guard parts.count == 2 else { return (0, 0) }
        return (Int(parts[0]) ?? 0, Int(parts[1]) ?? 0)
    }

    private func absolutizeUrl(baseUrl: String, maybeRelative: String) -> String {
        guard let base = URL(string: baseUrl),
              let resolved = URL(string: maybeRelative, relativeTo: base)?.absoluteURL else {
            return maybeRelative
        }
        return resolved.absoluteString
    }

    private func mapValue(_ dictionary: [String: Any]?, key: String) -> [String: Any]? {
        dictionary?[key] as? [String: Any]
    }

    private func listMapValue(_ dictionary: [String: Any], key: String) -> [[String: Any]] {
        (dictionary[key] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
    }

    private func stringValue(_ dictionary: [String: Any]?, key: String) -> String? {
        guard let value = dictionary?[key] else { return nil }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private func numberValue(_ dictionary: [String: Any], key: String) -> Double? {
        if let number = dictionary[key] as? NSNumber { return number.doubleValue }
        if let string = dictionary[key] as? String { return Double(string) }
        return nil
    }

    private func firstCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[captureRange])
    }

    private static func isYouTubeVideoId(_ value: String) -> Bool {
        value.count == 11 && value.allSatisfy { char in
            char.isLetter || char.isNumber || char == "_" || char == "-"
        }
    }
}

enum SmartPlaybackSelector {
    static func bestStream(
        from streams: [NuvioStream],
        qualityPreference: String,
        subtitleLanguages: [String],
        shouldMatchSubtitles: Bool,
        includeDebrid: Bool = false,
        preferredTags: StreamQualityTags? = nil,
        cachedOnly: Bool = false
    ) -> NuvioStream? {
        rankedStreams(
            from: streams,
            qualityPreference: qualityPreference,
            subtitleLanguages: subtitleLanguages,
            shouldMatchSubtitles: shouldMatchSubtitles,
            includeDebrid: includeDebrid,
            preferredTags: preferredTags,
            cachedOnly: cachedOnly
        ).first
    }

    /// Ordered playable candidates: best match first (for resume failover).
    static func rankedStreams(
        from streams: [NuvioStream],
        qualityPreference: String,
        subtitleLanguages: [String],
        shouldMatchSubtitles: Bool,
        includeDebrid: Bool = false,
        preferredTags: StreamQualityTags? = nil,
        cachedOnly: Bool = false
    ) -> [NuvioStream] {
        let playable = streams.enumerated().compactMap { index, stream -> (index: Int, stream: NuvioStream)? in
            if let url = stream.url?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty {
                return (index, stream)
            }
            // Torrent-only streams are candidates only when a debrid provider is
            // configured to resolve them into a direct URL.
            if includeDebrid, stream.isDebridResolvable { return (index, stream) }
            return nil
        }
        let compatible = playable.filter { isPlatformPlaybackCompatible($0.stream) }
        var candidates = compatible.filter { !isPromotionalStream($0.stream) }
        if candidates.isEmpty { candidates = compatible }
        if cachedOnly {
            let cached = candidates.filter { $0.stream.isLikelyCached }
            if !cached.isEmpty { candidates = cached }
        }

        let ranked = candidates.map { index, stream -> (index: Int, stream: NuvioStream, score: Int) in
            let tags = StreamQualityTags.parse(stream: stream)
            let resolution = tags.resolution > 0 ? tags.resolution : inferredResolution(for: stream)
            let subtitleScore = shouldMatchSubtitles ? subtitleScore(in: stream, languages: subtitleLanguages) : 0
            let qualityScore = score(resolution: resolution, preference: qualityPreference)
            let featureScore = featureBoost(tags: tags, preference: qualityPreference)
            let resumeScore = preferredTags.map { tags.matchScore(against: $0) } ?? 0
            let cachedBoost = tags.isCached ? 5_000 : 0
            return (index, stream, subtitleScore + qualityScore + featureScore + resumeScore + cachedBoost)
        }

        return ranked.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.index < rhs.index
        }.map(\.stream)
    }

    static func playableStreams(
        from streams: [NuvioStream],
        includeDebrid: Bool = false,
        cachedOnly: Bool = false
    ) -> [NuvioStream] {
        let playable = streams.filter { stream in
            if let url = stream.url?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty {
                return true
            }
            return includeDebrid && stream.isDebridResolvable
        }
        let compatible = playable.filter(isPlatformPlaybackCompatible)
        let nonPromotional = compatible.filter { !isPromotionalStream($0) }
        var result = nonPromotional.isEmpty ? compatible : nonPromotional
        if cachedOnly {
            let cached = result.filter(\.isLikelyCached)
            if !cached.isEmpty { result = cached }
        }
        return result
    }

    /// Prefer DV / HDR / Atmos when aiming for highest quality.
    private static func featureBoost(tags: StreamQualityTags, preference: String) -> Int {
        guard preference == "Highest" || preference == "4K" else { return 0 }
        var boost = 0
        if tags.isDolbyVision { boost += 12_000 }
        else if tags.isHDR { boost += 8_000 }
        if tags.isAtmos { boost += 6_000 }
        return boost
    }

    static func matchingSubtitles(in stream: NuvioStream, languages: [String]) -> [NuvioSubtitle] {
        var seen: Set<String> = []
        return languages.flatMap { language in
            stream.subtitles.filter { subtitle in
                SubtitleLanguagePreferences.matches(subtitle.language, target: language) ||
                SubtitleLanguagePreferences.matches(subtitle.label, target: language)
            }
        }
        .filter { subtitle in
            seen.insert(subtitle.url).inserted
        }
    }

    private static func inferredResolution(for stream: NuvioStream) -> Int {
        let text = searchableText(for: stream)
        if text.contains("2160p") || text.contains("2160") || text.contains("4k") || text.contains("uhd") {
            return 2160
        }
        if text.contains("1080p") || text.contains("1080") || text.contains("fhd") {
            return 1080
        }
        if text.contains("720p") || text.contains("720") || text.contains(" hd ") {
            return 720
        }
        if text.contains("480p") || text.contains("480") || text.contains(" sd ") {
            return 480
        }
        return 0
    }

    private static func score(resolution: Int, preference: String) -> Int {
        switch preference {
        case "4K":
            return resolution >= 2160 ? 50_000 + resolution : resolution
        case "1080p":
            if resolution == 1080 { return 50_000 }
            if resolution > 1080 { return 20_000 - (resolution - 1080) }
            return resolution
        case "720p":
            if resolution == 720 { return 50_000 }
            if resolution > 720 { return 20_000 - (resolution - 720) }
            return resolution
        case "Smallest":
            return resolution == 0 ? 10_000 : 10_000 - resolution
        default:
            return resolution
        }
    }

    private static func subtitleScore(in stream: NuvioStream, languages: [String]) -> Int {
        for (index, language) in languages.enumerated() {
            let priorityScore = max(1, 3 - index) * 30_000
            if !matchingSubtitles(in: stream, languages: [language]).isEmpty {
                return priorityScore + 10_000
            }
            if SubtitleLanguagePreferences.matches(searchableText(for: stream), target: language) {
                return priorityScore
            }
        }
        return 0
    }

    private static func isPromotionalStream(_ stream: NuvioStream) -> Bool {
        let text = ([stream.name, stream.description, stream.addonName, stream.url])
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        return ["trailer", "teaser", "preview", "promo", "sample", "featurette", "youtube.com", "youtu.be"].contains { text.contains($0) }
    }

    private static func searchableText(for stream: NuvioStream) -> String {
        ([stream.name, stream.description, stream.addonName, stream.filename] +
         stream.subtitles.flatMap { [$0.language, $0.label, $0.url] })
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
    }

    /// Codec-relevant fields only (name / description / filename). Subtitle
    /// labels, languages, and URLs are intentionally excluded so AV1 detection
    /// does not scan large subtitle payloads during list derivation.
    static func isAV1LabeledStream(_ stream: NuvioStream) -> Bool {
        for field in [stream.name, stream.description, stream.filename] {
            guard let field, !field.isEmpty else { continue }
            if fieldContainsAV1CodecToken(field) { return true }
        }
        return false
    }

    /// Tokenizes a single field and looks for standalone `av1` / `av01` codec tags.
    private static func fieldContainsAV1CodecToken(_ field: String) -> Bool {
        // Lowercase only this field (not subtitles / joined blob).
        let lower = field.lowercased()
        var tokenStart: String.Index?
        var index = lower.startIndex
        while index <= lower.endIndex {
            let atEnd = index == lower.endIndex
            let isTokenChar = !atEnd && (lower[index].isLetter || lower[index].isNumber)
            if isTokenChar {
                if tokenStart == nil { tokenStart = index }
            } else if let start = tokenStart {
                let token = lower[start..<index]
                if token == "av1" || token == "av01" { return true }
                tokenStart = nil
            }
            if atEnd { break }
            index = lower.index(after: index)
        }
        return false
    }

    private static func isPlatformPlaybackCompatible(_ stream: NuvioStream) -> Bool {
        #if targetEnvironment(simulator)
        // AV1 falls back to software decoding in the tvOS simulator. Its
        // decoded frames then use MoltenVK/libplacebo's PBO upload path, which
        // MTLSimDriver can terminate as XPC API misuse. Prefer another stream;
        // physical Apple TV keeps AV1 available through its real Metal driver.
        return !isAV1LabeledStream(stream)
        #else
        return true
        #endif
    }

}

/// How the stream picker orders results. `.default` keeps the add-ons' own
/// order (usually already best-first); the others re-rank across all sources.
enum StreamSortOption: String, CaseIterable, Identifiable {
    case `default` = "Default"
    case quality = "Quality"
    case size = "Size"
    case name = "Name"

    var id: String { rawValue }
}

/// Pure stream-list derivation for the tvOS stream picker. Kept free of view
/// state so focus movement cannot re-filter/sort, and unit tests can assert
/// caching/identity behavior without mounting SwiftUI.
enum StreamPickerListBuilder {
    /// Streams for the current add-on filter, preserving group order when "All".
    static func sourceStreams(
        streams: [NuvioStream],
        groups: [AddonStreamGroup],
        selectedAddonId: String?
    ) -> [NuvioStream] {
        if let selectedAddonId {
            if let group = groups.first(where: { $0.addonId == selectedAddonId }) {
                return group.streams
            }
            let displayName = groups.first(where: { $0.addonId == selectedAddonId })?.displayName
            return streams.filter { $0.addonName == displayName }
        }
        if !groups.isEmpty {
            return groups.flatMap(\.streams)
        }
        return streams
    }

    static func playableStreams(
        streams: [NuvioStream],
        groups: [AddonStreamGroup],
        selectedAddonId: String?,
        includeDebrid: Bool,
        cachedOnly: Bool = false
    ) -> [NuvioStream] {
        let source = sourceStreams(streams: streams, groups: groups, selectedAddonId: selectedAddonId)
        return SmartPlaybackSelector.playableStreams(
            from: source,
            includeDebrid: includeDebrid,
            cachedOnly: cachedOnly
        )
    }

    /// Filter + sort result shown in the picker list.
    static func displayedStreams(
        streams: [NuvioStream],
        groups: [AddonStreamGroup],
        selectedAddonId: String?,
        sortOption: StreamSortOption,
        includeDebrid: Bool,
        cachedOnly: Bool = false
    ) -> [NuvioStream] {
        let playable = playableStreams(
            streams: streams,
            groups: groups,
            selectedAddonId: selectedAddonId,
            includeDebrid: includeDebrid,
            cachedOnly: cachedOnly
        )
        return sorted(playable, by: sortOption)
    }

    /// Constant-size cache key. Repository revision captures every publication,
    /// including metadata/subtitle changes with unchanged stream ids and counts.
    static func cacheKey(
        revision: UInt64,
        selectedAddonId: String?,
        sortOption: StreamSortOption,
        includeDebrid: Bool,
        cachedOnly: Bool = false
    ) -> StreamPickerListCacheKey {
        StreamPickerListCacheKey(
            revision: revision,
            selectedAddonId: selectedAddonId,
            sortOption: sortOption,
            includeDebrid: includeDebrid,
            cachedOnly: cachedOnly
        )
    }

    /// Re-orders streams for the chosen sort. `.default` is a no-op so the
    /// add-ons' own (usually best-first) order is preserved. `.enumerated` keeps
    /// the sort stable, so streams that tie fall back to their original order.
    static func sorted(_ streams: [NuvioStream], by option: StreamSortOption) -> [NuvioStream] {
        switch option {
        case .default:
            return streams
        case .quality:
            return streams.enumerated().sorted {
                resolution(for: $0.element) != resolution(for: $1.element)
                    ? resolution(for: $0.element) > resolution(for: $1.element)
                    : $0.offset < $1.offset
            }.map(\.element)
        case .size:
            return streams.enumerated().sorted {
                sizeBytes(for: $0.element) != sizeBytes(for: $1.element)
                    ? sizeBytes(for: $0.element) > sizeBytes(for: $1.element)
                    : $0.offset < $1.offset
            }.map(\.element)
        case .name:
            return streams.sorted {
                ($0.name ?? "").localizedCaseInsensitiveCompare($1.name ?? "") == .orderedAscending
            }
        }
    }

    /// Best-effort resolution parsed from a stream's text (2160/1080/720/480),
    /// 0 when unknown so untagged streams sink to the bottom of a Quality sort.
    static func resolution(for stream: NuvioStream) -> Int {
        let text = "\(stream.name ?? "") \(stream.description ?? "")".lowercased()
        if text.contains("2160") || text.contains("4k") || text.contains("uhd") { return 2160 }
        if text.contains("1440") || text.contains("2k") { return 1440 }
        if text.contains("1080") || text.contains("fhd") { return 1080 }
        if text.contains("720") { return 720 }
        if text.contains("480") { return 480 }
        return 0
    }

    /// Best-effort file size in bytes parsed from a stream's text (e.g. "12.3 GB",
    /// "📦 700 MB"). 0 when no size is present.
    static func sizeBytes(for stream: NuvioStream) -> Int64 {
        let text = "\(stream.name ?? "") \(stream.description ?? "")"
        let pattern = #"(\d+(?:[.,]\d+)?)\s*(TB|GB|MB|KB)"#
        guard let match = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else {
            return 0
        }
        let token = String(text[match])
        let number = token.replacingOccurrences(of: ",", with: ".")
            .components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted)
            .first { Double($0) != nil }
            .flatMap(Double.init) ?? 0
        let unit = token.uppercased()
        let multiplier: Double
        if unit.contains("TB") { multiplier = 1_099_511_627_776 }
        else if unit.contains("GB") { multiplier = 1_073_741_824 }
        else if unit.contains("MB") { multiplier = 1_048_576 }
        else { multiplier = 1024 }
        return Int64(number * multiplier)
    }
}

/// Small Equatable key used by the picker cache. It deliberately contains no
/// stream URLs, descriptions, or subtitle payloads, so focus changes are O(1).
struct StreamPickerListCacheKey: Equatable {
    let revision: UInt64
    let selectedAddonId: String?
    let sortOption: StreamSortOption
    let includeDebrid: Bool
    var cachedOnly: Bool = false
}

struct TvDetailsContent: View {
    let uiState: DetailsUiState
    let onPlayClick: () -> Void
    var onPlayManually: (() -> Void)? = nil
    let onEpisodeSelected: (NuvioVideo) -> Void
    var onEpisodePlayManually: ((NuvioVideo) -> Void)? = nil
    let onWatchlistClick: () -> Void
    let onWatchedClick: () -> Void
    let onShareClick: () -> Void
    let onTrailerClick: () -> Void
    var onOpenTitle: ((String, String) -> Void)? = nil
    var onOpenProduction: ((MetaCompany) -> Void)? = nil
    var onCommentSelect: ((TraktCommentReview) -> Void)? = nil
    let onBack: () -> Void

    @FocusState private var actionFocus: DetailsActionFocus?
    @AppStorage(SettingsKey.smartStreamSelection) private var smartStreamSelection = false

    var body: some View {
        if let meta = uiState.meta {
            let episodes = sortedEpisodes(meta)
            let playTarget = playTarget(for: meta, episodes: episodes)

            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    TvDetailsBackdrop(meta: meta)

                    ScrollViewReader { scrollProxy in
                        ScrollView(.vertical, showsIndicators: false) {
                            VStack(alignment: .leading, spacing: 34) {
                                TvDetailsLogo(meta: meta)
                                    .padding(.bottom, 10)

                                TvDetailsActionRow(
                                    isInWatchlist: uiState.isInWatchlist,
                                    isWatched: uiState.isWatched,
                                    playTitle: playTarget.label,
                                    playHint: smartStreamSelection
                                        ? "Plays the best link. Hold Select to choose a source manually."
                                        : "Starts playback or opens stream sources",
                                    onPlayClick: {
                                        guard playTarget.isPlayable else { return }
                                        // Series: play the resume/next-up episode; movies
                                        // fall through to the stream picker.
                                        if let episode = playTarget.episode {
                                            onEpisodeSelected(episode)
                                        } else {
                                            onPlayClick()
                                        }
                                    },
                                    onPlayLongPress: smartStreamSelection ? {
                                        guard playTarget.isPlayable else { return }
                                        if let episode = playTarget.episode {
                                            if let onEpisodePlayManually {
                                                onEpisodePlayManually(episode)
                                            } else {
                                                onEpisodeSelected(episode)
                                            }
                                        } else if let onPlayManually {
                                            onPlayManually()
                                        } else {
                                            onPlayClick()
                                        }
                                    } : nil,
                                    onWatchlistClick: onWatchlistClick,
                                    onWatchedClick: onWatchedClick,
                                    onTrailerClick: onTrailerClick,
                                    focus: $actionFocus
                                )
                                .padding(.bottom, 6)

                                TvDetailsSummary(meta: meta)

                                if !episodes.isEmpty {
                                    TvDetailsEpisodes(
                                        metaId: meta.id,
                                        episodes: episodes,
                                        seriesRating: meta.rating,
                                        continueItem: ContinueWatchingStore.item(for: meta.id),
                                        onFocus: {
                                            withAnimation(.easeOut(duration: 0.24)) {
                                                scrollProxy.scrollTo(TvDetailsScrollID.episodesSection, anchor: .top)
                                            }
                                        },
                                        onSelect: onEpisodeSelected
                                    )
                                    .padding(.top, 24)
                                    .id(TvDetailsScrollID.episodesSection)
                                }

                                TvDetailsCastAndTrailer(
                                    meta: meta,
                                    onTrailerClick: onTrailerClick,
                                    onFocus: {
                                        withAnimation(.easeOut(duration: 0.24)) {
                                            scrollProxy.scrollTo(TvDetailsScrollID.castSection, anchor: .top)
                                        }
                                    }
                                )
                                .padding(.top, 34)
                                .id(TvDetailsScrollID.castSection)

                                if !uiState.moreLikeThis.isEmpty {
                                    TvDetailsRelatedRow(
                                        title: "More Like This",
                                        items: uiState.moreLikeThis,
                                        onSelect: { item in
                                            onOpenTitle?(item.id, item.type)
                                        },
                                        onFocus: {
                                            withAnimation(.easeOut(duration: 0.24)) {
                                                scrollProxy.scrollTo(TvDetailsScrollID.moreLikeThisSection, anchor: .top)
                                            }
                                        }
                                    )
                                    .padding(.top, 40)
                                    .id(TvDetailsScrollID.moreLikeThisSection)
                                }

                                if !uiState.companies.isEmpty {
                                    TvDetailsProductionRow(
                                        companies: uiState.companies,
                                        onSelect: { company in
                                            onOpenProduction?(company)
                                        },
                                        onFocus: {
                                            withAnimation(.easeOut(duration: 0.24)) {
                                                scrollProxy.scrollTo(TvDetailsScrollID.productionSection, anchor: .top)
                                            }
                                        }
                                    )
                                    .padding(.top, 40)
                                    .id(TvDetailsScrollID.productionSection)
                                }

                                if !uiState.comments.isEmpty {
                                    TvDetailsCommentsRow(
                                        comments: uiState.comments,
                                        onSelect: { comment in
                                            onCommentSelect?(comment)
                                        },
                                        onFocus: {
                                            withAnimation(.easeOut(duration: 0.24)) {
                                                scrollProxy.scrollTo(TvDetailsScrollID.commentsSection, anchor: .top)
                                            }
                                        }
                                    )
                                    .padding(.top, 40)
                                    .id(TvDetailsScrollID.commentsSection)
                                }
                            }
                            .padding(.leading, 96)
                            .padding(.top, 78)
                            .padding(.bottom, 96)
                            .frame(width: detailsWidth(proxy, hasEpisodes: !episodes.isEmpty), alignment: .leading)
                            .frame(minHeight: proxy.size.height, alignment: .topLeading)
                        }
                        .scrollClipDisabledIfAvailable()
                    }
                }
            }
            .background(Color.black.ignoresSafeArea())
            .onExitCommand(perform: onBack)
            // tvOS doesn't re-run default-focus when this content swaps in after
            // the async load finishes, so focus lands nowhere / off the Play
            // button. Move it onto Play explicitly once the content appears
            // (async so it runs after the focus engine's own first pass).
            .onAppear {
                DispatchQueue.main.async { actionFocus = .play }
            }
        } else {
            EmptyView()
        }
    }

    // Give series more horizontal room so the episode cards aren't cramped.
    private func detailsWidth(_ proxy: GeometryProxy, hasEpisodes: Bool) -> CGFloat {
        hasEpisodes ? min(proxy.size.width - 96, 2200) : min(proxy.size.width * 0.64, 1180)
    }

    private func sortedEpisodes(_ meta: NuvioMeta) -> [NuvioVideo] {
        (meta.videos ?? []).sorted {
            (seasonSortKey($0.season), $0.episode) < (seasonSortKey($1.season), $1.episode)
        }
    }

    private func firstPlayableEpisode(_ episodes: [NuvioVideo]) -> NuvioVideo? {
        // Prefer a real season over season 0 specials.
        episodes.first(where: { $0.season > 0 }) ?? episodes.first
    }

    /// Primary-button target: resume the in-progress episode, advance to the
    /// next one after a finished episode, or start from the first playable one.
    /// Movies have no episode; the label alone flips between Play and Resume.
    private func playTarget(for meta: NuvioMeta, episodes: [NuvioVideo]) -> (episode: NuvioVideo?, label: String, isPlayable: Bool) {
        let continueItem = ContinueWatchingStore.item(for: meta.id)

        guard !episodes.isEmpty else {
            return (nil, continueItem == nil ? "Play" : "Resume", true)
        }

        if let continueItem,
           let numbers = continueItem.episodeNumbers,
           let target = episodes.first(where: { $0.season == numbers.season && $0.episode == numbers.episode }) {
            if continueItem.isUpNextEntry, !continueItem.hasAired {
                let label = continueItem.airDateText.map { "Airs \($0)" } ?? "Upcoming"
                return (target, label, false)
            }
            let verb = continueItem.isUpNextEntry ? "Next" : "Resume"
            return (target, "\(verb) S\(target.season) E\(target.episode)", true)
        }

        // No progress entry (e.g. the episode just finished): continue with the
        // first episode that hasn't been watched yet.
        let watched = WatchedStore.watchedEpisodeKeys(metaId: meta.id)
        if !watched.isEmpty,
           let next = episodes.first(where: { $0.season > 0 && !watched.contains("\($0.season):\($0.episode)") }) {
            return (next, "Next S\(next.season) E\(next.episode)", true)
        }

        let first = firstPlayableEpisode(episodes)
        return (first, first.map { "Play S\($0.season) E\($0.episode)" } ?? "Play", true)
    }

    private func seasonSortKey(_ season: Int) -> Int {
        season <= 0 ? Int.max : season
    }
}

private enum TvDetailsScrollID {
    static let castSection = "tv-details-cast-section"
    static let episodesSection = "tv-details-episodes-section"
    static let moreLikeThisSection = "tv-details-more-like-this"
    static let productionSection = "tv-details-production"
    static let commentsSection = "tv-details-comments"
}

private struct TvDetailsBackdrop: View {
    let meta: NuvioMeta

    var body: some View {
        ZStack {
            if let imageUrl = meta.backgroundUrl ?? meta.posterUrl,
               let url = URL(string: imageUrl) {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image
                            .resizable()
                            .scaledToFill()
                    } else {
                        Color.black
                    }
                }
                .ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
            }

            Color.black.opacity(0.20)

            LinearGradient(
                colors: [
                    Color.black.opacity(0.98),
                    Color.black.opacity(0.74),
                    Color.black.opacity(0.24),
                    Color.black.opacity(0.66)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )

            LinearGradient(
                colors: [
                    Color.black.opacity(0.34),
                    Color.black.opacity(0.08),
                    Color.black.opacity(0.86)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }
}

private struct TvDetailsLogo: View {
    let meta: NuvioMeta

    var body: some View {
        Group {
            if let logoUrl = meta.logoUrl,
               let url = URL(string: logoUrl) {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image
                            .resizable()
                            .scaledToFit()
                    } else {
                        titleFallback
                    }
                }
            } else {
                titleFallback
            }
        }
        .frame(width: 520, height: 150, alignment: .leading)
    }

    private var titleFallback: some View {
        Text(meta.name)
            .font(.system(size: 58, weight: .heavy))
            .foregroundColor(.white)
            .lineLimit(2)
            .minimumScaleFactor(0.74)
            .shadow(color: .black.opacity(0.65), radius: 14, y: 6)
            .frame(maxWidth: 520, alignment: .leading)
    }
}

/// Identifies the action-row buttons so focus can be driven programmatically
/// (tvOS doesn't auto-focus the primary button when the details content swaps in
/// after the async load — see `TvDetailsContent`).
private enum DetailsActionFocus: Hashable {
    case play, watchlist, watched, trailer
}

private struct TvDetailsActionRow: View {
    let isInWatchlist: Bool
    let isWatched: Bool
    var playTitle: String = "Play"
    var playHint: String = "Starts playback or opens stream sources"
    let onPlayClick: () -> Void
    var onPlayLongPress: (() -> Void)? = nil
    let onWatchlistClick: () -> Void
    let onWatchedClick: () -> Void
    let onTrailerClick: () -> Void
    var focus: FocusState<DetailsActionFocus?>.Binding

    var body: some View {
        HStack(spacing: 26) {
            TvDetailsActionButton(
                title: playTitle,
                systemName: "play.fill",
                accessibilityLabel: playTitle,
                accessibilityHint: playHint,
                isPrimary: true,
                focus: focus,
                tag: .play,
                action: onPlayClick,
                longPressAction: onPlayLongPress
            )

            TvDetailsActionButton(
                title: nil,
                systemName: isInWatchlist ? "checkmark" : "plus",
                accessibilityLabel: isInWatchlist ? "In library" : "Add to library",
                accessibilityHint: isInWatchlist
                    ? "Removes this title from your library"
                    : "Adds this title to your library",
                isPrimary: false,
                focus: focus,
                tag: .watchlist,
                action: onWatchlistClick
            )

            TvDetailsActionButton(
                title: nil,
                systemName: isWatched ? "eye.fill" : "eye.slash.fill",
                accessibilityLabel: isWatched ? "Watched" : "Not watched",
                accessibilityHint: isWatched
                    ? "Marks this title as unwatched"
                    : "Marks this title as watched",
                isPrimary: false,
                focus: focus,
                tag: .watched,
                action: onWatchedClick
            )

            TvDetailsActionButton(
                title: nil,
                systemName: "play.rectangle.fill",
                accessibilityLabel: "Trailer",
                accessibilityHint: "Plays the trailer when available",
                isPrimary: false,
                focus: focus,
                tag: .trailer,
                action: onTrailerClick
            )
        }
    }
}

private struct TvDetailsActionButton: View {
    let title: String?
    let systemName: String
    let accessibilityLabel: String
    var accessibilityHint: String? = nil
    let isPrimary: Bool
    var focus: FocusState<DetailsActionFocus?>.Binding
    let tag: DetailsActionFocus
    let action: () -> Void
    var longPressAction: (() -> Void)? = nil

    private var isFocused: Bool { focus.wrappedValue == tag }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: systemName)
                    .font(.system(size: isPrimary ? 30 : 36, weight: .bold))
                    .accessibilityHidden(true)

                if let title {
                    Text(title)
                        .font(.system(size: 32, weight: .medium))
                        .lineLimit(1)
                        .accessibilityHidden(true)
                }
            }
            .foregroundColor(foregroundColor)
            .padding(.horizontal, isPrimary ? 44 : 0)
            .frame(minWidth: isPrimary ? 228 : 98, maxWidth: isPrimary ? nil : 98, minHeight: 98)
            .frame(height: 98)
            .modifier(TvDetailsGlassBackground(filled: isPrimary || isFocused, shape: Capsule()))
            .shadow(color: .black.opacity(isFocused ? 0.35 : 0.18), radius: isFocused ? 18 : 7, y: 8)
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused(focus, equals: tag)
        .focusEffectDisabledIfAvailable()
        .scaleEffect(isFocused ? 1.08 : 1)
        .animation(.easeOut(duration: 0.14), value: isFocused)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.55).onEnded { _ in
                longPressAction?()
            }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .modifier(OptionalAccessibilityHint(hint: accessibilityHint))
    }

    private var foregroundColor: Color {
        if isPrimary || isFocused {
            return .black
        }
        return .white
    }
}

private struct OptionalAccessibilityHint: ViewModifier {
    let hint: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let hint, !hint.isEmpty {
            content.accessibilityHint(hint)
        } else {
            content
        }
    }
}

private struct TvDetailsSummary: View {
    let meta: NuvioMeta

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let creatorLine {
                Text(creatorLine)
                    .font(.system(size: 28, weight: .regular))
                    .foregroundColor(.white.opacity(0.62))
            }

            if let description = meta.description, !description.isEmpty {
                Text(description.wrappedEveryNWords(9))
                    .font(.system(size: 30, weight: .regular))
                    .foregroundColor(.white)
                    .lineSpacing(8)
                    .lineLimit(4)
                    .frame(maxWidth: 950, alignment: .leading)
            }

            if !primaryMetaItems.isEmpty {
                Text(primaryMetaItems.joined(separator: "  •  "))
                    .font(.system(size: 27, weight: .medium))
                    .foregroundColor(.white.opacity(0.58))
                    .lineLimit(2)
            }

            if statusLabel != nil || !secondaryMetaItems.isEmpty {
                HStack(spacing: 16) {
                    if let statusLabel {
                        Text(statusLabel)
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundColor(.white.opacity(0.88))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 7)
                            .overlay(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .stroke(Color.white.opacity(0.45), lineWidth: 2)
                            )
                    }

                    if !secondaryMetaItems.isEmpty {
                        Text((statusLabel != nil ? "•  " : "") + secondaryMetaItems.joined(separator: "  •  "))
                            .font(.system(size: 24, weight: .medium))
                            .foregroundColor(.white.opacity(0.88))
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    private var creatorLine: String? {
        if let director = meta.director?.first, !director.isEmpty {
            return "Director: \(director)"
        }
        if let writer = meta.writer?.first, !writer.isEmpty {
            return "Writer: \(writer)"
        }
        return nil
    }

    /// Series status badge ("ENDED" / "ONGOING"); nil for movies.
    private var statusLabel: String? { meta.statusBadgeLabel }

    private var primaryMetaItems: [String] {
        var items = Array((meta.genres ?? []).prefix(3))
        // Series show the year range ("2026–"); movies show the full release date.
        if meta.isSeries {
            if let info = meta.releaseInfo, !info.isEmpty {
                items.append(info)
            } else if let year = meta.year {
                items.append(String(year))
            }
        } else if let date = releaseDisplay {
            items.append(date)
        } else if let year = meta.year {
            items.append(String(year))
        }
        return items
    }

    private var secondaryMetaItems: [String] {
        var items: [String] = []
        if let runtime = NuvioRuntimeDisplay.formatted(meta.runtime) {
            items.append(runtime)
        }
        if let country = meta.country, !country.isEmpty {
            items.append(country)
        }
        return items
    }

    private var releaseDisplay: String? {
        NuvioDateDisplay.formattedDate(meta.released ?? meta.releaseInfo)
    }
}

private struct TvDetailsCastAndTrailer: View {
    let meta: NuvioMeta
    let onTrailerClick: () -> Void
    let onFocus: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(spacing: 18) {
                TvDetailsSectionButton(title: "Creator and Cast", isSelected: false, onFocus: onFocus) {}

                Text("|")
                    .font(.system(size: 36, weight: .medium))
                    .foregroundColor(.white.opacity(0.38))

                TvDetailsSectionButton(title: "Trailer", isSelected: false, onFocus: onFocus, action: onTrailerClick)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 58) {
                    ForEach(displayPeople, id: \.self) { name in
                        TvDetailsPersonCard(name: name, onFocus: onFocus)
                    }
                }
                .padding(.trailing, 80)
            }
            .scrollClipDisabledIfAvailable()
        }
    }

    private var displayPeople: [String] {
        let cast = meta.cast ?? []
        if !cast.isEmpty {
            return Array(cast.prefix(8))
        }

        let creators = (meta.director ?? []) + (meta.writer ?? [])
        if !creators.isEmpty {
            return Array(creators.prefix(8))
        }

        return ["Cast"]
    }
}

private struct TvDetailsSectionButton: View {
    let title: String
    let isSelected: Bool
    let onFocus: () -> Void
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 36, weight: .semibold))
                .foregroundColor(.white.opacity(isFocused || isSelected ? 1 : 0.48))
                .padding(.horizontal, isSelected ? 0 : 4)
                .frame(height: 64)
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($isFocused)
        .focusEffectDisabledIfAvailable()
        .scaleEffect(isFocused ? 1.035 : 1)
        .animation(.easeOut(duration: 0.14), value: isFocused)
        .onChange(of: isFocused) { focused in
            if focused {
                onFocus()
            }
        }
    }
}

// MARK: - More Like This / Production / Comments

private struct TvDetailsRelatedRow: View {
    let title: String
    let items: [RelatedTitle]
    let onSelect: (RelatedTitle) -> Void
    let onFocus: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(title)
                .font(.system(size: 34, weight: .semibold))
                .foregroundColor(.white.opacity(0.9))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 28) {
                    ForEach(items) { item in
                        TvDetailsRelatedCard(item: item, onSelect: { onSelect(item) }, onFocus: onFocus)
                    }
                }
                .padding(.trailing, 80)
                .padding(.vertical, 8)
            }
            .scrollClipDisabledIfAvailable()
        }
    }
}

private struct TvDetailsRelatedCard: View {
    let item: RelatedTitle
    let onSelect: () -> Void
    let onFocus: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                    if let poster = item.posterURL, let url = URL(string: poster) {
                        AsyncImage(url: url) { phase in
                            if case .success(let image) = phase {
                                image.resizable().scaledToFill()
                            }
                        }
                        .frame(width: 180, height: 270)
                        .clipped()
                    } else {
                        Image(systemName: "film")
                            .font(.system(size: 36, weight: .medium))
                            .foregroundColor(.white.opacity(0.35))
                    }
                }
                .frame(width: 180, height: 270)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(
                            isFocused ? AppFocusOutline.color : Color.white.opacity(0.12),
                            lineWidth: isFocused ? AppFocusOutline.width : 1
                        )
                )

                Text(item.name)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .frame(width: 180, alignment: .leading)
            }
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($isFocused)
        .focusEffectDisabledIfAvailable()
        .scaleEffect(isFocused ? 1.05 : 1)
        .animation(.easeOut(duration: 0.14), value: isFocused)
        .onChange(of: isFocused) { focused in
            if focused { onFocus() }
        }
    }
}

private struct TvDetailsProductionRow: View {
    let companies: [MetaCompany]
    let onSelect: (MetaCompany) -> Void
    let onFocus: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Production")
                .font(.system(size: 34, weight: .semibold))
                .foregroundColor(.white.opacity(0.9))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 22) {
                    ForEach(companies) { company in
                        TvDetailsCompanyCard(company: company, onSelect: { onSelect(company) }, onFocus: onFocus)
                    }
                }
                .padding(.trailing, 80)
                .padding(.vertical, 8)
            }
            .scrollClipDisabledIfAvailable()
        }
    }
}

private struct TvDetailsCompanyCard: View {
    let company: MetaCompany
    let onSelect: () -> Void
    let onFocus: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white)
                    if let logo = company.logoURL, let url = URL(string: logo) {
                        AsyncImage(url: url) { phase in
                            if case .success(let image) = phase {
                                image
                                    .resizable()
                                    .scaledToFit()
                                    .padding(16)
                            } else {
                                Text(company.name)
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundColor(.black)
                                    .multilineTextAlignment(.center)
                                    .padding(12)
                            }
                        }
                    } else {
                        Text(company.name)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(.black)
                            .multilineTextAlignment(.center)
                            .padding(12)
                    }
                }
                .frame(width: 200, height: 100)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(
                            isFocused ? AppFocusOutline.color : Color.clear,
                            lineWidth: isFocused ? AppFocusOutline.width : 0
                        )
                )

                Text(company.name)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(.white.opacity(0.75))
                    .lineLimit(2)
                    .frame(width: 200)
                    .multilineTextAlignment(.center)
            }
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($isFocused)
        .focusEffectDisabledIfAvailable()
        .scaleEffect(isFocused ? 1.05 : 1)
        .animation(.easeOut(duration: 0.14), value: isFocused)
        .onChange(of: isFocused) { focused in
            if focused { onFocus() }
        }
        .disabled(company.tmdbId == nil)
        .opacity(company.tmdbId == nil ? 0.55 : 1)
    }
}

private struct TvDetailsCommentsRow: View {
    let comments: [TraktCommentReview]
    let onSelect: (TraktCommentReview) -> Void
    let onFocus: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Top Comments")
                .font(.system(size: 34, weight: .semibold))
                .foregroundColor(.white.opacity(0.9))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 22) {
                    ForEach(comments) { comment in
                        TvDetailsCommentCard(
                            comment: comment,
                            onSelect: { onSelect(comment) },
                            onFocus: onFocus
                        )
                    }
                }
                .padding(.trailing, 80)
                .padding(.vertical, 8)
            }
            .scrollClipDisabledIfAvailable()
        }
    }
}

private struct TvDetailsCommentCard: View {
    let comment: TraktCommentReview
    let onSelect: () -> Void
    let onFocus: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Text(comment.author)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if comment.likes > 0 {
                        Label("\(comment.likes)", systemImage: "heart.fill")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(.white.opacity(0.55))
                    }
                }

                Text(comment.spoiler ? "Spoiler — select to read" : comment.comment)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundColor(.white.opacity(comment.spoiler ? 0.45 : 0.82))
                    .lineLimit(5)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let date = comment.displayDate {
                    Text(date)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.white.opacity(0.4))
                }
            }
            .padding(24)
            .frame(width: 420, height: 240, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.white.opacity(isFocused ? 0.14 : 0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(
                        isFocused ? AppFocusOutline.color : Color.white.opacity(0.1),
                        lineWidth: isFocused ? AppFocusOutline.width : 1
                    )
            )
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($isFocused)
        .focusEffectDisabledIfAvailable()
        .scaleEffect(isFocused ? 1.03 : 1)
        .animation(.easeOut(duration: 0.14), value: isFocused)
        .onChange(of: isFocused) { focused in
            if focused { onFocus() }
        }
    }
}

private struct CommentDetailOverlay: View {
    let comment: TraktCommentReview
    let onDismiss: () -> Void

    @FocusState private var closeFocused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.72).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(comment.author)
                            .font(.system(size: 36, weight: .bold))
                            .foregroundColor(.white)
                        if let date = comment.displayDate {
                            Text(date)
                                .font(.system(size: 24, weight: .medium))
                                .foregroundColor(.white.opacity(0.5))
                        }
                    }
                    Spacer()
                    Button("Close", action: onDismiss)
                        .focused($closeFocused)
                }

                ScrollView {
                    Text(comment.comment)
                        .font(.system(size: 28, weight: .regular))
                        .foregroundColor(.white.opacity(0.92))
                        .lineSpacing(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if comment.likes > 0 {
                    Label("\(comment.likes) likes", systemImage: "heart.fill")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundColor(.white.opacity(0.55))
                }
            }
            .padding(48)
            .frame(maxWidth: 1100, maxHeight: 620)
            .background(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(Color.black.opacity(0.9))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(Color.white.opacity(0.14), lineWidth: 1)
            )
        }
        .onAppear { closeFocused = true }
        .onExitCommand(perform: onDismiss)
    }
}

private struct TvDetailsPersonCard: View {
    let name: String
    let onFocus: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: {}) {
            VStack(spacing: 18) {
                Circle()
                    .frame(width: 188, height: 188)
                    .modifier(TvDetailsGlassBackground(filled: isFocused, shape: Circle()))
                    .overlay(
                        Circle()
                            .strokeBorder(Color.white.opacity(isFocused ? 0.0 : 0.22), lineWidth: 1)
                    )
                    .overlay {
                        Text(initials)
                            .font(.system(size: 44, weight: .medium))
                            .foregroundColor(isFocused ? .black : .white)
                    }

                Text(name)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundColor(isFocused ? .white : .white.opacity(0.74))
                    .lineLimit(1)
                    .frame(width: 210)
            }
            .frame(width: 220)
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($isFocused)
        .focusEffectDisabledIfAvailable()
        .scaleEffect(isFocused ? 1.08 : 1)
        .animation(.easeOut(duration: 0.14), value: isFocused)
        .onChange(of: isFocused) { focused in
            if focused {
                onFocus()
            }
        }
    }

    private var initials: String {
        let words = name
            .split(separator: " ")
            .prefix(2)
            .compactMap { $0.first }
        let value = String(words).uppercased()
        return value.isEmpty ? "?" : value
    }
}

// MARK: - Series episodes

private struct TvDetailsEpisodes: View {
    let metaId: String
    let episodes: [NuvioVideo]
    let seriesRating: Double?
    let continueItem: ContinueWatchingItem?
    let onFocus: () -> Void
    let onSelect: (NuvioVideo) -> Void

    @State private var selectedSeason: Int
    @State private var episodeScrollIndex = 0
    @State private var watchedEpisodeKeys: Set<String>
    @AppStorage(SettingsKey.smoothFocus) private var smoothFocus = true

    init(
        metaId: String,
        episodes: [NuvioVideo],
        seriesRating: Double?,
        continueItem: ContinueWatchingItem?,
        onFocus: @escaping () -> Void,
        onSelect: @escaping (NuvioVideo) -> Void
    ) {
        self.metaId = metaId
        self.episodes = episodes
        self.seriesRating = seriesRating
        self.continueItem = continueItem
        self.onFocus = onFocus
        self.onSelect = onSelect
        _selectedSeason = State(initialValue: Self.defaultSeason(episodes))
        _watchedEpisodeKeys = State(initialValue: WatchedStore.watchedEpisodeKeys(metaId: metaId))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            seasonSelector
            episodeCardStrip
        }
        .onReceive(NotificationCenter.default.publisher(for: WatchedStore.changedNotification)) { _ in
            watchedEpisodeKeys = WatchedStore.watchedEpisodeKeys(metaId: metaId)
        }
    }

    private var episodeCardStrip: some View {
        GeometryReader { geo in
            let edgeInset = max(0, geo.frame(in: .global).minX)
            let stripWidth = geo.size.width + edgeInset * 2

            HStack(alignment: .bottom, spacing: TvEpisodeCardLayout.spacing) {
                ForEach(seasonEpisodes) { video in
                    TvEpisodeCard(
                        video: video,
                        fallbackRating: seriesRating,
                        continueProgress: continueProgress(for: video),
                        isWatched: watchedEpisodeKeys.contains("\(video.season):\(video.episode)"),
                        onFocus: {
                            if let index = seasonEpisodes.firstIndex(where: { $0.id == video.id }) {
                                episodeScrollIndex = index
                            }
                            onFocus()
                        },
                        action: { onSelect(video) }
                    )
                }
            }
            .padding(.vertical, TvEpisodeCardLayout.verticalPadding)
            .offset(x: edgeInset - CGFloat(episodeScrollIndex) * TvEpisodeCardLayout.step)
            .frame(width: stripWidth, height: TvEpisodeCardLayout.stripHeight, alignment: .leading)
            .clipped()
            .offset(x: -edgeInset)
            // Critically damped — same no-bounce Home strip feel.
            .animation(smoothFocus ? .spring(response: 0.3, dampingFraction: 1.0) : nil, value: episodeScrollIndex)
        }
        .frame(height: TvEpisodeCardLayout.stripHeight)
    }

    @ViewBuilder
    private var seasonSelector: some View {
        if seasons.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 22) {
                    ForEach(seasons, id: \.self) { season in
                        TvSeasonPill(
                            title: seasonTitle(season),
                            isSelected: season == selectedSeason,
                            onFocus: onFocus,
                            action: {
                                selectedSeason = season
                                episodeScrollIndex = 0
                            }
                        )
                    }
                }
                .padding(.trailing, 96)
                .padding(.vertical, 8)
            }
            .scrollClipDisabledIfAvailable()
        } else {
            Text(seasonTitle(selectedSeason))
                .font(.system(size: 32, weight: .semibold))
                .foregroundColor(.black)
                .padding(.horizontal, 34)
                .frame(height: 70)
                .background(Color.white, in: Capsule())
        }
    }

    private var seasons: [Int] {
        Array(Set(episodes.map(\.season))).sorted {
            (seasonSortKey($0), $0) < (seasonSortKey($1), $1)
        }
    }

    private var seasonEpisodes: [NuvioVideo] {
        episodes
            .filter { $0.season == selectedSeason }
            .sorted { $0.episode < $1.episode }
    }

    private static func defaultSeason(_ episodes: [NuvioVideo]) -> Int {
        let seasons = Array(Set(episodes.map(\.season))).sorted {
            (seasonSortKey($0), $0) < (seasonSortKey($1), $1)
        }
        return seasons.first(where: { $0 > 0 }) ?? seasons.first ?? 1
    }

    private func seasonTitle(_ season: Int) -> String {
        season <= 0 ? "Specials" : "Season \(season)"
    }

    private static func seasonSortKey(_ season: Int) -> Int {
        season <= 0 ? Int.max : season
    }

    private func seasonSortKey(_ season: Int) -> Int {
        Self.seasonSortKey(season)
    }

    private func continueProgress(for video: NuvioVideo) -> Double? {
        guard let continueItem,
              !continueItem.isUpNextEntry,
              let numbers = continueItem.episodeNumbers,
              numbers.season == video.season,
              numbers.episode == video.episode else {
            return nil
        }
        return continueItem.progress
    }
}

private enum TvEpisodeCardLayout {
    static let width: CGFloat = 660
    static let height: CGFloat = 430
    static let spacing: CGFloat = 40
    static let verticalPadding: CGFloat = 28
    static let stripHeight: CGFloat = height + verticalPadding * 2
    static let step: CGFloat = width + spacing
}

private struct TvSeasonPill: View {
    let title: String
    let isSelected: Bool
    let onFocus: () -> Void
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 30, weight: .semibold))
                .foregroundColor(isSelected || isFocused ? .black : .white.opacity(0.66))
                .padding(.horizontal, 30)
                .frame(height: 70)
                .modifier(TvDetailsGlassBackground(filled: isSelected || isFocused, shape: Capsule()))
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($isFocused)
        .focusEffectDisabledIfAvailable()
        .scaleEffect(isFocused ? 1.06 : 1)
        .animation(.easeOut(duration: 0.14), value: isFocused)
        .animation(.easeOut(duration: 0.14), value: isSelected)
        .onChange(of: isFocused) { focused in
            if focused { onFocus() }
        }
    }
}

private struct TvEpisodeCard: View {
    let video: NuvioVideo
    let fallbackRating: Double?
    let continueProgress: Double?
    let isWatched: Bool
    let onFocus: () -> Void
    let action: () -> Void

    @FocusState private var isFocused: Bool

    private let cardWidth: CGFloat = TvEpisodeCardLayout.width
    private let thumbHeight: CGFloat = 300
    private let cardHeight: CGFloat = TvEpisodeCardLayout.height

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                episodeArtwork

                LinearGradient(
                    gradient: Gradient(stops: [
                        .init(color: .black.opacity(0.0), location: 0.12),
                        .init(color: .black.opacity(0.28), location: 0.46),
                        .init(color: .black.opacity(0.78), location: 0.78),
                        .init(color: .black.opacity(0.94), location: 1.0)
                    ]),
                    startPoint: .top,
                    endPoint: .bottom
                )

                VStack(alignment: .leading, spacing: 14) {
                    Text("EPISODE \(video.episode)")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.52), in: Capsule())

                    Text(video.title)
                        .font(.system(size: 30, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)

                    if let overview = video.overview, !overview.isEmpty {
                        Text(overview)
                            .font(.system(size: 22, weight: .regular))
                            .foregroundColor(.white.opacity(0.78))
                            .lineSpacing(4)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    HStack(spacing: 8) {
                        if let ratingText {
                            Text("IMDb")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundColor(.white.opacity(0.78))
                            Text(ratingText)
                                .font(.system(size: 20, weight: .bold))
                                .foregroundColor(Color(red: 0.96, green: 0.77, blue: 0.22))
                        }

                        Spacer(minLength: 12)

                        if let dateText {
                            Text(dateText)
                                .font(.system(size: 20, weight: .medium))
                                .foregroundColor(.white.opacity(0.62))
                        }
                    }
                }
                .padding(EdgeInsets(top: 24, leading: 24, bottom: continueProgress == nil ? 24 : 44, trailing: 24))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)

                continueProgressOverlay

                if isWatched {
                    watchedBadge
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
            }
            .frame(width: cardWidth, height: cardHeight)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(isFocused ? Color(white: 0.17) : Color.tvCard)
            )
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(isFocused ? AppFocusOutline.color : .clear, lineWidth: isFocused ? AppFocusOutline.width : 0)
            )
            .shadow(color: .black.opacity(isFocused ? 0.4 : 0.16), radius: isFocused ? 26 : 10, y: 12)
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($isFocused)
        .focusEffectDisabledIfAvailable()
        .scaleEffect(isFocused ? 1.05 : 1)
        .animation(.easeOut(duration: 0.14), value: isFocused)
        .onChange(of: isFocused) { focused in
            if focused { onFocus() }
        }
    }

    /// Same green check as the poster-grid watched badge, scaled for the card.
    private var watchedBadge: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 18, weight: .bold))
            .foregroundColor(.white)
            .frame(width: 38, height: 38)
            .background(
                Circle()
                    .fill(Color(red: 0.10, green: 0.68, blue: 0.34))
            )
            .overlay(
                Circle()
                    .stroke(Color.white.opacity(0.45), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
            .padding(16)
    }

    private var episodeArtwork: some View {
        Group {
            if let thumb = video.thumbnail, let url = URL(string: thumb) {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        placeholderThumb
                    }
                }
            } else {
                placeholderThumb
            }
        }
        .frame(width: cardWidth, height: cardHeight)
        .clipped()
    }

    @ViewBuilder
    private var continueProgressOverlay: some View {
        if let continueProgress {
            let progress = CGFloat(min(max(continueProgress, 0), 1))
            GeometryReader { geo in
                let width = max(0, geo.size.width - 48)

                VStack {
                    Spacer()
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.36))
                            .frame(width: width, height: 8)

                        Capsule()
                            .fill(Color.white)
                            .frame(width: max(8, width * progress), height: 8)
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 20)
                }
            }
        }
    }

    private var thumbnail: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let thumb = video.thumbnail, let url = URL(string: thumb) {
                    AsyncImage(url: url) { phase in
                        if case .success(let image) = phase {
                            image.resizable().scaledToFill()
                        } else {
                            placeholderThumb
                        }
                    }
                } else {
                    placeholderThumb
                }
            }
            .frame(width: cardWidth, height: thumbHeight)
            .clipped()

            LinearGradient(
                colors: [.black.opacity(0.0), .black.opacity(0.55)],
                startPoint: .center,
                endPoint: .bottom
            )

            Text("EPISODE \(video.episode)")
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.55), in: Capsule())
                .padding(18)
        }
        .frame(width: cardWidth, height: thumbHeight)
    }

    private var placeholderThumb: some View {
        ZStack {
            Color.white.opacity(0.06)
            Image(systemName: "film")
                .font(.system(size: 52, weight: .regular))
                .foregroundColor(.white.opacity(0.28))
        }
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(video.title)
                .font(.system(size: 30, weight: .bold))
                .foregroundColor(.white)
                .lineLimit(1)

            if let overview = video.overview, !overview.isEmpty {
                Text(overview)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundColor(.white.opacity(0.6))
                    .lineSpacing(4)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                if let ratingText {
                    Text("IMDb")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.white.opacity(0.78))
                    Text(ratingText)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(Color(red: 0.96, green: 0.77, blue: 0.22))
                }

                Spacer(minLength: 12)

                if let dateText {
                    Text(dateText)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))
                }
            }
        }
        .padding(22)
        .frame(width: cardWidth, height: 232, alignment: .topLeading)
    }

    private var ratingText: String? {
        if let r = video.rating?.trimmingCharacters(in: .whitespaces), !r.isEmpty {
            return r
        }
        if let fb = fallbackRating {
            return String(format: "%.1f", fb)
        }
        return nil
    }

    private var dateText: String? {
        NuvioDateDisplay.formattedDate(video.released)
    }
}

struct TvDetailsGlassBackground<S: InsettableShape>: ViewModifier {
    let filled: Bool
    let shape: S

    @ViewBuilder
    func body(content: Content) -> some View {
        if filled {
            if #available(tvOS 26.0, *) {
                content
                    .background(Color.white.opacity(0.96), in: shape)
                    .glassEffect(.regular, in: shape)
            } else {
                content.background(Color.white, in: shape)
            }
        } else if #available(tvOS 26.0, *) {
            content
                .background(Color.white.opacity(0.10), in: shape)
                .glassEffect(.regular, in: shape)
        } else {
            content.background(.ultraThinMaterial, in: shape)
        }
    }
}

/// Translucent "liquid glass" fill used by the stream picker panel and cards.
/// Uses real Liquid Glass on tvOS 26+, falling back to a frosted material with
/// a matching tint on older systems so the look stays consistent.
private struct TvStreamGlass<S: InsettableShape>: ViewModifier {
    let shape: S
    let tint: Color

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(tvOS 26.0, *) {
            content
                .background(tint, in: shape)
                .glassEffect(.regular, in: shape)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .background(tint, in: shape)
        }
    }
}

#if os(tvOS)
/// Shown in place of the picker while streams are still loading. Keeping the
/// picker unmounted until streams exist means the picker's first appearance is
/// a fresh focus transition, which is the only reliable way to auto-focus the
/// first stream on tvOS. A focusable spinner keeps the Menu/back button working.
private struct TvStreamLoadingOverlay: View {
    let meta: NuvioMeta
    let episode: NuvioVideo?
    let onDismiss: () -> Void

    @FocusState private var spinnerFocused: Bool

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                TvDetailsBackdrop(meta: meta)

                HStack(alignment: .center, spacing: 74) {
                    VStack(alignment: .leading, spacing: 34) {
                        TvDetailsLogo(meta: meta)

                        if let episode {
                            Text("Season \(episode.season) · Episode \(episode.episode)")
                                .font(.system(size: 36, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(width: 560, alignment: .center)
                        }
                    }
                    .frame(width: min(proxy.size.width * 0.34, 620), alignment: .leading)
                    .padding(.top, proxy.size.height * 0.20)

                    VStack(spacing: 26) {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(1.8)

                        Text("Finding streams")
                            .font(.system(size: 32, weight: .semibold))
                            .foregroundColor(.white.opacity(0.8))
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .focusable()
                    .focused($spinnerFocused)
                }
                .padding(.horizontal, 96)
            }
            .onAppear { spinnerFocused = true }
            .onExitCommand(perform: onDismiss)
        }
        .background(Color.black.ignoresSafeArea())
    }
}

private struct TvStreamPickerOverlay: View {
    let meta: NuvioMeta
    let episode: NuvioVideo?
    let streams: [NuvioStream]
    let groups: [AddonStreamGroup]
    let streamsRevision: UInt64
    let isLoading: Bool
    let emptyReason: StreamsEmptyStateReason?
    /// Whether torrent-only streams should be listed (a debrid provider is set).
    let includeDebrid: Bool
    /// A torrent stream is being turned into a playable link right now.
    let isResolvingDebrid: Bool
    let onSelect: (NuvioStream) -> Void
    let onDismiss: () -> Void

    /// Filter by stable add-on id (not display name).
    @State private var selectedAddonId: String?
    @State private var sortOption: StreamSortOption = .default
    @State private var showSortOptions = false
    @AppStorage(SettingsKey.cachedOnlyStreams) private var cachedOnly = false
    /// Cached filter+sort result. Rebuilt only when derivation inputs change —
    /// never when focus moves between cards.
    @State private var displayedStreams: [NuvioStream] = []
    @State private var displayedStreamsCacheKey: StreamPickerListCacheKey?
    // A single focus state for the whole picker (filter chips + stream cards),
    // keyed by string. Filter chips use the "filter::" prefix; stream cards use
    // their natural id. One shared state makes programmatic focus moves reliable
    // and lets us seed focus on appear so the picker is never in limbo.
    @FocusState private var focusedItem: String?

    private let filterAllKey = "filter::all"
    private let sortKey = "filter::sort"
    private let cachedKey = "filter::cached"
    private func filterKey(_ addonId: String) -> String { "filter::\(addonId)" }

    /// Inputs that may change the visible stream list (not focus).
    private var listCacheKey: StreamPickerListCacheKey {
        StreamPickerListBuilder.cacheKey(
            revision: streamsRevision,
            selectedAddonId: selectedAddonId,
            sortOption: sortOption,
            includeDebrid: includeDebrid,
            cachedOnly: cachedOnly
        )
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                TvDetailsBackdrop(meta: meta)

                HStack(alignment: .center, spacing: 74) {
                    leftSummary
                        .frame(width: min(proxy.size.width * 0.34, 620), alignment: .leading)
                        .padding(.top, proxy.size.height * 0.20)

                    VStack(alignment: .leading, spacing: 36) {
                        filterRow

                        streamPanel
                            .frame(
                                width: min(proxy.size.width * 0.56, 1080),
                                height: min(proxy.size.height * 0.72, 760)
                            )
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .padding(.horizontal, 96)
            }
            // The picker is only mounted once streams are available, so this
            // first appearance is a fresh focus transition and the seed wins.
            .onAppear {
                refreshDisplayedStreamsIfNeeded()
                seedInitialFocus()
            }
            // Progressive add-on results, filter chips, sort, and debrid toggle
            // all flow through this cache key. Focus is excluded.
            .onChange(of: listCacheKey) { _ in
                refreshDisplayedStreamsIfNeeded()
            }
            // The focus engine can still reject the seed after grabFocus reads
            // back its own write and stops retrying — e.g. the loading spinner
            // keeps real focus while it fades out, then its removal makes the
            // engine re-resolve and write nil into this binding, visibly
            // un-highlighting the first card. If focus ever evaporates while
            // the picker is up, grab it again — but only if it's *still* gone
            // after a beat. A fast scroll blips `focusedItem` to nil between
            // cards before landing on the next one; re-seeding on that blip
            // snaps focus back to the first stream (the reported bug), so we
            // debounce and bail when focus has already landed somewhere.
            .onChange(of: focusedItem) { newValue in
                guard newValue == nil else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    if focusedItem == nil {
                        seedInitialFocus()
                    }
                }
            }
            .onExitCommand(perform: onDismiss)
        }
        .background(Color.black.ignoresSafeArea())
    }

    /// Cached list when inputs are unchanged; live derivation only while the
    /// cache is stale (filter/sort/progressive results). Focus never invalidates
    /// the key, so focus movement hits the cache path.
    private var activeDisplayedStreams: [NuvioStream] {
        let key = listCacheKey
        if key == displayedStreamsCacheKey {
            return displayedStreams
        }
        return StreamPickerListBuilder.displayedStreams(
            streams: streams,
            groups: groups,
            selectedAddonId: selectedAddonId,
            sortOption: sortOption,
            includeDebrid: includeDebrid,
            cachedOnly: cachedOnly
        )
    }

    /// Rebuilds the cached list only when derivation inputs actually change.
    private func refreshDisplayedStreamsIfNeeded() {
        let key = listCacheKey
        guard key != displayedStreamsCacheKey else { return }
        displayedStreamsCacheKey = key
        displayedStreams = StreamPickerListBuilder.displayedStreams(
            streams: streams,
            groups: groups,
            selectedAddonId: selectedAddonId,
            sortOption: sortOption,
            includeDebrid: includeDebrid,
            cachedOnly: cachedOnly
        )
    }

    private var leftSummary: some View {
        VStack(alignment: .leading, spacing: 34) {
            TvDetailsLogo(meta: meta)

            if let episode {
                VStack(spacing: 14) {
                    Text("Season \(episode.season) · Episode \(episode.episode)")
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundColor(.white)

                    Text(episode.title)
                        .font(.system(size: 30, weight: .regular))
                        .foregroundColor(.white.opacity(0.7))
                        .lineSpacing(6)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                }
                .frame(width: 560, alignment: .center)
            } else if !summaryItems.isEmpty {
                Text(summaryItems.joined(separator: "  •  "))
                    .font(.system(size: 34, weight: .medium))
                    .foregroundColor(.white.opacity(0.68))
                    .lineSpacing(8)
                    .multilineTextAlignment(.center)
                    .frame(width: 560, alignment: .center)
            }
        }
    }

    private var filterRow: some View {
        HStack(spacing: 18) {
            // Only add-on filters scroll. Vertical/edge padding gives the 1.06x
            // focused scale room to draw without the ScrollView clipping it.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 18) {
                    TvStreamFilterButton(
                        title: "All",
                        isSelected: selectedAddonId == nil,
                        focusBinding: $focusedItem,
                        focusValue: filterAllKey,
                        action: { selectedAddonId = nil }
                    )

                    // Preserve configured add-on order from discovery groups.
                    ForEach(filterGroups) { group in
                        TvStreamFilterButton(
                            title: group.isLoading ? "\(group.displayName)…" : group.displayName,
                            isSelected: selectedAddonId == group.addonId,
                            focusBinding: $focusedItem,
                            focusValue: filterKey(group.addonId),
                            action: { selectedAddonId = group.addonId }
                        )
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if includeDebrid {
                TvStreamFilterButton(
                    title: cachedOnly ? "Cached only" : "All cache",
                    isSelected: cachedOnly,
                    focusBinding: $focusedItem,
                    focusValue: cachedKey,
                    action: { cachedOnly.toggle() }
                )
                .fixedSize(horizontal: true, vertical: false)
            }

            // Sort remains pinned to the trailing edge instead of moving with
            // the add-on scroller.
            TvStreamFilterButton(
                title: "Sort: \(sortOption.rawValue)",
                isSelected: sortOption != .default,
                focusBinding: $focusedItem,
                focusValue: sortKey,
                action: { showSortOptions = true }
            )
            .fixedSize(horizontal: true, vertical: false)
            .confirmationDialog("Sort streams by", isPresented: $showSortOptions, titleVisibility: .visible) {
                ForEach(StreamSortOption.allCases) { option in
                    Button(option.rawValue) { sortOption = option }
                }
            }
        }
        .padding(.vertical, 4)
        .focusSection()
    }

    private var streamPanel: some View {
        // Resolve once per panel body — focus changes hit the cache path only.
        let streamsToShow = activeDisplayedStreams
        return ZStack {
            if isLoading && streamsToShow.isEmpty && selectedGroupError == nil {
                VStack(spacing: 24) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(1.6)

                    Text("Finding streams")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundColor(.white.opacity(0.74))
                }
            } else if streamsToShow.isEmpty {
                VStack(spacing: 18) {
                    if selectedGroupIsLoading {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(1.4)
                        Text("Checking \(selectedGroupName)…")
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundColor(.white.opacity(0.74))
                    } else {
                        Image(systemName: "play.slash")
                            .font(.system(size: 54, weight: .semibold))
                            .foregroundColor(.white.opacity(0.64))

                        Text(emptyPanelTitle)
                            .font(.system(size: 32, weight: .semibold))
                            .foregroundColor(.white.opacity(0.78))
                            .multilineTextAlignment(.center)

                        if let detail = emptyPanelDetail {
                            Text(detail)
                                .font(.system(size: 26, weight: .regular))
                                .foregroundColor(.white.opacity(0.55))
                                .multilineTextAlignment(.center)
                        }
                    }
                }
                .padding(.horizontal, 40)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 28) {
                        ForEach(streamsToShow) { stream in
                            // Focus appearance is owned by the card via local
                            // @FocusState + ExternalFocusBinding so only the
                            // old/new cards pay for outline/scale updates.
                            TvStreamCard(
                                stream: stream,
                                externalFocus: $focusedItem,
                                action: { onSelect(stream) }
                            )
                        }

                        if isLoading {
                            HStack(spacing: 18) {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                Text("Checking more add-ons…")
                                    .font(.system(size: 26, weight: .medium))
                                    .foregroundColor(.white.opacity(0.62))
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 8)
                            .padding(.bottom, 12)
                        }
                    }
                    .padding(40)
                }
                .focusSection()
            }

            // Torrent streams take a moment to cache/unrestrict on the debrid
            // provider; cover the panel so it doesn't look frozen.
            if isResolvingDebrid {
                VStack(spacing: 24) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(1.6)

                    Text("Preparing stream")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundColor(.white.opacity(0.74))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.55))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Keep outer panel Liquid Glass; cards use a cheap solid/material fill.
        .modifier(TvStreamGlass(shape: RoundedRectangle(cornerRadius: 32, style: .continuous), tint: Color.black.opacity(0.22)))
        // Clip the scrolling content to the panel so partial cards stay inside
        // the box (no overflow below it) until the user scrolls.
        .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
    }

    /// Groups shown as filter chips (configured order; includes loading/error).
    private var filterGroups: [AddonStreamGroup] {
        if !groups.isEmpty { return groups }
        // Fallback when only a flat stream list is available (mock path).
        let names = Array(Set(streams.compactMap(\.addonName))).sorted()
        return names.map { name in
            AddonStreamGroup(
                addonId: name,
                displayName: name,
                streams: streams.filter { $0.addonName == name },
                isLoading: false
            )
        }
    }

    private var selectedGroup: AddonStreamGroup? {
        selectedAddonId.flatMap { id in groups.first(where: { $0.addonId == id }) }
    }

    private var selectedGroupIsLoading: Bool {
        selectedGroup?.isLoading == true
    }

    private var selectedGroupName: String {
        selectedGroup?.displayName ?? "add-on"
    }

    private var selectedGroupError: String? {
        selectedGroup?.error
    }

    private var emptyPanelTitle: String {
        if let selectedGroup {
            if selectedGroup.error != nil {
                return "\(selectedGroup.displayName) failed"
            }
            return "No streams from \(selectedGroup.displayName)"
        }
        switch emptyReason {
        case .noAddonsConfigured:
            return "No stream add-ons configured"
        case .noCompatibleAddons:
            return "No compatible add-ons"
        case .noStreamsFound, .none:
            return isLoading ? "Finding streams" : "No playable streams found"
        }
    }

    private var emptyPanelDetail: String? {
        if let error = selectedGroupError {
            return error
        }
        switch emptyReason {
        case .noAddonsConfigured:
            return "Enable a stream add-on in Settings."
        case .noCompatibleAddons:
            return "Installed add-ons do not support this title."
        case .noStreamsFound:
            return isLoading ? nil : "Try another add-on or check back later."
        case .none:
            return nil
        }
    }

    private var summaryItems: [String] {
        var items = Array((meta.genres ?? []).prefix(3))
        if let year = meta.year {
            items.append(String(year))
        }
        return items
    }

    /// Seeds focus when the picker appears. The picker is only mounted once
    /// streams are available, so this first appearance is a fresh focus
    /// transition where tvOS hasn't committed focus yet — setting `focusedItem`
    /// here wins, landing on the first stream (or the "All" chip if none).
    private func seedInitialFocus() {
        DispatchQueue.main.async {
            refreshDisplayedStreamsIfNeeded()
            if let firstID = activeDisplayedStreams.first?.id {
                grabFocus(firstID, attempt: 0)
            } else {
                grabFocus(filterAllKey, attempt: 0)
            }
        }
    }

    /// Asserts focus on `id` and retries for a short window, because the target
    /// view may not be hit-testable on the very first runloop tick after it
    /// renders. `id` is captured by value (never reads a stale `streams`), and
    /// it stops the moment focus lands.
    private func grabFocus(_ id: String, attempt: Int) {
        if focusedItem == id { return }
        focusedItem = id
        guard attempt < 12 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.07) {
            grabFocus(id, attempt: attempt + 1)
        }
    }
}

private struct TvStreamFilterButton: View {
    let title: String
    let isSelected: Bool
    let focusBinding: FocusState<String?>.Binding
    let focusValue: String
    let action: () -> Void

    private var isFocused: Bool { focusBinding.wrappedValue == focusValue }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 26, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundColor(isSelected || isFocused ? .black : .white.opacity(0.62))
                .padding(.horizontal, 26)
                .frame(height: 58)
                .modifier(TvDetailsGlassBackground(filled: isSelected || isFocused, shape: Capsule()))
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused(focusBinding, equals: focusValue)
        .focusEffectDisabledIfAvailable()
        .scaleEffect(isFocused ? 1.06 : 1)
        .animation(.easeOut(duration: 0.14), value: isFocused)
        .animation(.easeOut(duration: 0.14), value: isSelected)
    }
}

private struct TvStreamCard: View {
    let stream: NuvioStream
    let externalFocus: FocusState<String?>.Binding
    let action: () -> Void

    /// Local focus drives appearance only for this card, so focus moves do not
    /// push `isFocused` through the parent ForEach for every sibling.
    @FocusState private var isFocused: Bool

    /// Precomputed once per card identity — not re-derived on every body tick.
    private let primaryName: String
    private let secondaryName: String?

    init(
        stream: NuvioStream,
        externalFocus: FocusState<String?>.Binding,
        action: @escaping () -> Void
    ) {
        self.stream = stream
        self.externalFocus = externalFocus
        self.action = action
        let lines = Self.nameLines(for: stream)
        self.primaryName = lines.first ?? "Stream"
        let rest = lines.dropFirst().joined(separator: " ")
        self.secondaryName = rest.isEmpty ? nil : rest
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 34) {
                VStack(alignment: .leading, spacing: 14) {
                    Text(primaryName)
                        .font(.system(size: 34, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    if let secondaryName {
                        Text(secondaryName)
                            .font(.system(size: 38, weight: .medium))
                            .foregroundColor(.white)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let description = stream.description, !description.isEmpty {
                        Text(description)
                            .font(.system(size: 26, weight: .regular))
                            .foregroundColor(.white.opacity(0.62))
                            .lineSpacing(5)
                            .lineLimit(6)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    let badges = StreamBadgeKind.badges(for: stream)
                    if !badges.isEmpty {
                        HStack(spacing: 10) {
                            ForEach(badges) { badge in
                                Text(badge.rawValue)
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(
                                        Capsule().fill(Color.white.opacity(0.14 + badge.tint.bg * 0.08))
                                    )
                            }
                        }
                        .padding(.top, 4)
                    }
                }

                Spacer(minLength: 28)

                VStack(spacing: 18) {
                    addonLogo

                    if let addonName = stream.addonName {
                        Text(addonName)
                            .font(.system(size: 22, weight: .medium))
                            .foregroundColor(.white.opacity(0.42))
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .frame(width: 220)
                    }
                }
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 34)
            .frame(minHeight: 250)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Lightweight fill instead of per-card Liquid Glass (panel keeps glass).
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.white.opacity(isFocused ? 0.14 : 0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(
                        isFocused ? AppFocusOutline.color : Color.white.opacity(0.10),
                        lineWidth: isFocused ? AppFocusOutline.width : 1
                    )
            )
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($isFocused)
        .modifier(ExternalFocusBinding(binding: externalFocus, id: stream.id))
        .focusEffectDisabledIfAvailable()
        .scaleEffect(isFocused ? 1.025 : 1)
        .animation(.easeOut(duration: 0.14), value: isFocused)
    }

    private static func nameLines(for stream: NuvioStream) -> [String] {
        let raw = stream.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = raw?
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
        return lines.isEmpty ? ["Stream"] : lines
    }

    /// The source add-on's real logo, falling back to a neutral stream glyph
    /// (never a warning-looking one) while it loads or when the manifest has none.
    @ViewBuilder
    private var addonLogo: some View {
        let fallback = Image(systemName: "play.tv.fill")
            .font(.system(size: 62, weight: .semibold))
            .foregroundColor(.white.opacity(0.9))

        if let logo = stream.addonLogoURL, let url = URL(string: logo) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFit()
                case .failure:
                    fallback
                default:
                    ProgressView().tint(.white)
                }
            }
            .frame(width: 96, height: 96)
        } else {
            fallback.frame(width: 96, height: 96)
        }
    }
}
#endif

struct MobileDetailsContent: View {
    let uiState: DetailsUiState
    let onPlayClick: () -> Void
    let onWatchlistClick: () -> Void
    let onWatchedClick: () -> Void
    let onShareClick: () -> Void
    let onBack: () -> Void

    var body: some View {
        guard let meta = uiState.meta else { return AnyView(EmptyView()) }

        return AnyView(
            ZStack(alignment: .top) {
                ScrollView {
                    VStack(spacing: 0) {
                        // Background image with gradient
                        ZStack(alignment: .bottom) {
                            if let backgroundUrl = meta.backgroundUrl ?? meta.posterUrl {
                                AsyncImage(url: URL(string: backgroundUrl)) { image in
                                    image
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                } placeholder: {
                                    Color.black
                                }
                                .frame(height: 400)
                                .clipped()
                            }

                            // Gradient overlay
                            LinearGradient(
                                colors: [
                                    Color.clear,
                                    Color.black.opacity(0.6),
                                    Color.black
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            .frame(height: 400)
                        }

                        // Content
                        VStack(alignment: .leading, spacing: 24) {
                            // Metadata info
                            MetadataInfo(meta: meta)

                            // Action buttons
                            ActionButtons(
                                onPlayClick: onPlayClick,
                                onWatchlistClick: onWatchlistClick,
                                onWatchedClick: onWatchedClick,
                                onShareClick: onShareClick,
                                isInWatchlist: uiState.isInWatchlist,
                                isWatched: uiState.isWatched
                            )

                            // Cast and Crew
                            CastCrewSection(
                                cast: meta.cast,
                                director: meta.director,
                                writer: meta.writer
                            )
                        }
                        .padding(24)
                        .background(Color.black)
                    }
                }
                .ignoresSafeArea(edges: .top)

                // Back button overlay
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.title2)
                        .foregroundColor(.white)
                        .frame(width: 44, height: 44)
                        .background(
                            Circle()
                                .fill(Color.black.opacity(0.5))
                        )
                }
                .buttonStyle(.plain)
                .padding(16)
            }
        )
    }
}

struct ErrorView: View {
    let error: String
    let onRetry: () -> Void
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Error")
                .font(.title)
                .foregroundColor(.red)

            Text(error)
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 16) {
                Button("Retry", action: onRetry)
                    .buttonStyle(.borderedProminent)

                Button("Go Back", action: onBack)
                    .buttonStyle(.bordered)
            }
        }
        .padding(32)
    }
}
