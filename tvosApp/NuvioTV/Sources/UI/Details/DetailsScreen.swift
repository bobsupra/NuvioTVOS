//
//  DetailsScreen.swift
//  NuvioTV
//
//  Content details screen with adaptive layouts for iOS/iPad/tvOS
//

import Foundation
import SwiftUI
import UIKit
import Combine
import ImageIO
import AVFoundation
import AVKit

struct DetailsScreen: View {
    let id: String
    let type: String
    let libraryWatchedContext: LibraryWatchedContext?
    let initialPlaybackRequestID: UInt?
    let onInitialPlaybackRequestConsumed: ((UInt) -> Void)?
    /// (streamURL, httpHeaders, meta, episodeSubtitleLine, streamSubtitles, currentEpisode, orderedEpisodes, actionSession).
    /// The last two carry series context for the player's next-episode auto-play;
    /// (streamURL, httpHeaders, meta, episodeSubtitleLine, streamSubtitles, currentEpisode, orderedEpisodes, player, cacheFileIdentity, filename, videoSize, videoHash, resumeFrom).
    /// The episode fields carry series context for the player's next-episode auto-play;
    /// both are empty/nil for movies and trailers.
    let onPlayClick: (
        _ streamUrl: String,
        _ httpHeaders: [String: String],
        _ meta: NuvioMeta,
        _ subtitle: String,
        _ externalSubtitles: [NuvioSubtitle],
        _ currentEpisode: NuvioVideo?,
        _ episodes: [NuvioVideo],
        _ player: ExternalPlayer?,
        _ cacheFileIdentity: PlaybackCacheFileIdentity?,
        _ filename: String?,
        _ videoSize: Int64?,
        _ videoHash: String?,
        _ resumeFrom: Double?,
        _ startupBenchmarkToken: UUID?,
        _ sourceID: String?,
        _ isActionPlaybackSession: Bool
    ) -> Void
    let onBack: () -> Void
    /// Host a room for the current title or a specific series episode.
    var onCreateWatchParty: ((NuvioMeta, NuvioVideo?) -> Void)? = nil
    /// Open another title (More Like This / production catalog).
    var onOpenTitle: ((String, String) -> Void)? = nil
    /// Open a production company / network catalog.
    var onOpenProduction: ((MetaCompany) -> Void)? = nil
    /// Open the movies and series associated with a TMDB person.
    var onOpenPerson: ((TmdbPersonMetadata) -> Void)? = nil
    let initiallyPresentStreamPicker: Bool
    let initialStreamPickerEpisode: NuvioVideo?
    let initialStreamPickerResumePosition: Double?
    /// Episode to select in the episode list on open (from the calendar).
    let initialFocusEpisode: DetailsEpisodeFocus?
    let onInitialStreamPickerPresented: (() -> Void)?
    var onWatchPartyMovieReady: ((NuvioMeta) -> Void)? = nil
    var creatingWatchPartyRoom = false
    var onWatchPartyMediaSelected: ((NuvioMeta, NuvioVideo?) -> Void)? = nil

    @StateObject private var viewModel: DetailsViewModel
    @State private var isStreamPickerPresented = false
    @State private var pendingStreamPickerResumePosition: Double? = nil
    @State private var isSmartPlaybackPending = false
    @State private var isPreparingPlayback = false
    @State private var isPreparingInitialPlayback = false
    @State private var startupBenchmarkToken: UUID?
    @State private var pendingInitialPlaybackRequestID: UInt?
    @State private var readyInitialPlaybackRequestID: UInt?
    @State private var initialPlaybackPreparationTask: Task<Void, Never>?
    @State private var initialPlaybackPreparationError: String?
    @State private var streamPickerAvailabilityMessage: String?
    /// Episode line shown under the title in the player ("" for movies).
    @State private var pendingEpisodeSubtitle = ""
    /// The episode a stream is being picked for (nil for movies); drives the
    /// season/episode header in the stream picker.
    @State private var pendingEpisode: NuvioVideo?
    @State private var didHandleInitialStreamPicker = false
    @State private var expandedComment: TraktCommentReview?
    @State private var showingMdbListRating = false
    /// Set while an episode card's context menu is up. tvOS hands the Menu press
    /// that dismisses the menu to this screen as well, and without this the
    /// screen would treat it as Back and return to Home.
    @State private var isEpisodeMenuPresented = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage(SettingsKey.smartStreamSelection) private var smartStreamSelection = false
    @AppStorage(SettingsKey.reuseLastLink) private var reuseLastLink = false
    @AppStorage(SettingsKey.smartStreamUseTopResult) private var smartStreamUseTopResult = false
    @AppStorage(SettingsKey.preserveAddonStreamOrder) private var preserveAddonOrder = false
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
    @AppStorage(SettingsKey.backgroundStreamPreFetch) private var backgroundStreamPreFetch = true
    @State private var preResolvedStream: NuvioStream? = nil
    @State private var preResolvedURL: URL? = nil
    @State private var preResolvedFilename: String? = nil
    @State private var preResolvedVideoSize: Int64? = nil
    @State private var preResolvedStreamId: String? = nil
    @State private var preResolvedEpisode: NuvioVideo? = nil
    @State private var preResolvedEpisodeSubtitle: String = ""
    @State private var preFetchDebridTask: Task<Void, Never>? = nil
    @State private var preResolvedDuration: TimeInterval? = nil
    @State private var streamDiscoveryDuration: TimeInterval? = nil
    @State private var playbackPrewarmer: DetailsPlaybackPrewarmer
    @State private var isDetailsPlaybackContextActive = false
    @State private var didHandOffPlayback = false
    @State private var preResolutionIdentity: DetailsBackgroundResolutionIdentity?
    @State private var preResolutionGeneration: UInt64 = 0
    @State private var prewarmedSavedTarget: DetailsSavedPlaybackTarget?
    /// True while a torrent stream is being resolved through the debrid provider,
    /// so the picker can keep its spinner up instead of appearing to hang.
    @State private var isResolvingDebrid = false

    private var detailsLoadingMessage: String {
        if isSmartPlaybackPending {
            return L10n.string("player_searching_sources", fallback: "Searching sources…")
        } else if isResolvingDebrid {
            return L10n.string("player_loading_preparing", fallback: "Preparing stream…")
        } else {
            return L10n.string("player_loading_building", fallback: "Building player…")
        }
    }

    private var displayedDetailsUiState: DetailsUiState {
        var state = viewModel.uiState
        if let meta = state.meta, let libraryWatchedContext {
            state.isWatched = WatchedStore.isWatchedForLibrary(
                meta: meta,
                source: libraryWatchedContext.source,
                profileId: libraryWatchedContext.profileId
            )
        }
        return state
    }

    init(
        id: String,
        type: String,
        libraryWatchedContext: LibraryWatchedContext? = nil,
        repository: CatalogRepository,
        initialPlaybackRequestID: UInt? = nil,
        onInitialPlaybackRequestConsumed: ((UInt) -> Void)? = nil,
        initiallyPresentStreamPicker: Bool = false,
        initialStreamPickerEpisode: NuvioVideo? = nil,
        initialStreamPickerResumePosition: Double? = nil,
        initialFocusEpisode: DetailsEpisodeFocus? = nil,
        onInitialStreamPickerPresented: (() -> Void)? = nil,
        onWatchPartyMovieReady: ((NuvioMeta) -> Void)? = nil,
        creatingWatchPartyRoom: Bool = false,
        onWatchPartyMediaSelected: ((NuvioMeta, NuvioVideo?) -> Void)? = nil,
        onPlayClick: @escaping (
            _ streamUrl: String,
            _ httpHeaders: [String: String],
            _ meta: NuvioMeta,
            _ subtitle: String,
            _ externalSubtitles: [NuvioSubtitle],
            _ currentEpisode: NuvioVideo?,
            _ episodes: [NuvioVideo],
            _ player: ExternalPlayer?,
            _ cacheFileIdentity: PlaybackCacheFileIdentity?,
            _ filename: String?,
            _ videoSize: Int64?,
            _ videoHash: String?,
            _ resumeFrom: Double?,
            _ startupBenchmarkToken: UUID?,
            _ sourceID: String?,
            _ isActionPlaybackSession: Bool
        ) -> Void,
        onBack: @escaping () -> Void,
        onCreateWatchParty: ((NuvioMeta, NuvioVideo?) -> Void)? = nil,
        onOpenTitle: ((String, String) -> Void)? = nil,
        onOpenProduction: ((MetaCompany) -> Void)? = nil,
        onOpenPerson: ((TmdbPersonMetadata) -> Void)? = nil
    ) {
        self.id = id
        self.type = type
        self.libraryWatchedContext = libraryWatchedContext
        self.initialPlaybackRequestID = initialPlaybackRequestID
        self.onInitialPlaybackRequestConsumed = onInitialPlaybackRequestConsumed
        self.onPlayClick = onPlayClick
        self.onBack = onBack
        self.onCreateWatchParty = onCreateWatchParty
        self.onOpenTitle = onOpenTitle
        self.onOpenProduction = onOpenProduction
        self.onOpenPerson = onOpenPerson
        self.initiallyPresentStreamPicker = initiallyPresentStreamPicker
        self.initialStreamPickerEpisode = initialStreamPickerEpisode
        self.initialStreamPickerResumePosition = initialStreamPickerResumePosition
        self.initialFocusEpisode = initialFocusEpisode
        self.onInitialStreamPickerPresented = onInitialStreamPickerPresented
        self.onWatchPartyMovieReady = onWatchPartyMovieReady
        self.creatingWatchPartyRoom = creatingWatchPartyRoom
        self.onWatchPartyMediaSelected = onWatchPartyMediaSelected
        _pendingStreamPickerResumePosition = State(initialValue: initialStreamPickerResumePosition)
        _isPreparingInitialPlayback = State(initialValue: initialPlaybackRequestID != nil)
        _playbackPrewarmer = State(initialValue: DetailsPlaybackPrewarmer.engineBacked())
        _viewModel = StateObject(wrappedValue: DetailsViewModel(repository: repository))
        TVHomeDebugTrace.log("details.init id=\(id) type=\(type)")
    }

    @FocusState private var isLoadingInitialFocusActive: Bool

    var body: some View {
        ZStack {
            if viewModel.uiState.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                #if os(tvOS)
                Color.clear
                    .frame(width: 1, height: 1)
                    .focusable(true)
                    .focused($isLoadingInitialFocusActive)
                #endif
            } else if let error = viewModel.uiState.error {
                ErrorView(
                    error: error,
                    onRetry: retryDetailsLoad,
                    onBack: handleBack
                )
            } else if let error = initialPlaybackPreparationError {
                ErrorView(
                    error: error,
                    onRetry: retryDetailsLoad,
                    onBack: handleBack
                )
            } else if viewModel.uiState.meta != nil {
                #if os(tvOS)
                TvDetailsContent(
                    uiState: viewModel.uiState,
                    libraryWatchedContext: libraryWatchedContext,
                    initialPlayRequestID: readyInitialPlaybackRequestID,
                    initialFocusEpisode: initialFocusEpisode,
                    onInitialPlayRequestConsumed: { requestID in
                        finishInitialPlaybackRequest(requestID)
                    },
                    onPlayClick: {
                        // Movie (or a series with no episode list): make sure streams
                        // are loaded for the canonical title id, then either auto-select
                        // or open the picker.
                        if creatingWatchPartyRoom, let meta = viewModel.uiState.meta, !meta.isSeries {
                            onWatchPartyMediaSelected?(meta, nil)
                            return
                        }
                        pendingEpisodeSubtitle = ""
                        pendingEpisode = nil
                        startStreamFlow(streamId: viewModel.uiState.meta?.streamId ?? id, type: viewModel.uiState.meta?.type ?? type, reload: viewModel.uiState.streams.isEmpty)
                    },
                    onPlayManually: {
                        // Hold-to-play-manually: always open the picker even when Auto Select is on.
                        if creatingWatchPartyRoom, let meta = viewModel.uiState.meta, !meta.isSeries {
                            onWatchPartyMediaSelected?(meta, nil)
                            return
                        }
                        pendingEpisodeSubtitle = ""
                        pendingEpisode = nil
                        startStreamFlow(
                            streamId: viewModel.uiState.meta?.streamId ?? id,
                            type: viewModel.uiState.meta?.type ?? type,
                            reload: viewModel.uiState.streams.isEmpty,
                            forceManualPicker: true
                        )
                    },
                    onHostWatchParty: onCreateWatchParty == nil ? nil : { episode in
                        guard let meta = viewModel.uiState.meta else { return }
                        onCreateWatchParty?(meta, episode)
                    },
                    onEpisodeSelected: { video in
                        if creatingWatchPartyRoom, let meta = viewModel.uiState.meta {
                            onWatchPartyMediaSelected?(meta, video)
                            return
                        }
                        pendingEpisodeSubtitle = "S\(video.season) · E\(video.episode) · \(video.title)"
                        pendingEpisode = video
                        let streamId = canonicalEpisodeStreamId(for: video, meta: viewModel.uiState.meta)
                        let isPreFetched = (viewModel.prefetchedStreamId == streamId && !viewModel.uiState.streams.isEmpty)
                        startStreamFlow(streamId: streamId, type: "series", reload: !isPreFetched)
                    },
                    onEpisodePlayManually: { video in
                        if creatingWatchPartyRoom, let meta = viewModel.uiState.meta {
                            onWatchPartyMediaSelected?(meta, video)
                            return
                        }
                        pendingEpisodeSubtitle = "S\(video.season) · E\(video.episode) · \(video.title)"
                        pendingEpisode = video
                        let streamId = canonicalEpisodeStreamId(for: video, meta: viewModel.uiState.meta)
                        let isPreFetched = (viewModel.prefetchedStreamId == streamId && !viewModel.uiState.streams.isEmpty)
                        startStreamFlow(streamId: streamId, type: "series", reload: !isPreFetched, forceManualPicker: true)
                    },
                    onEpisodeMenuPresented: { isPresented in
                        isEpisodeMenuPresented = isPresented
                    },
                    onWatchlistClick: { viewModel.toggleWatchlist() },
                    onWatchedClick: { viewModel.toggleWatched(libraryContext: libraryWatchedContext) },
                    mdbListUserRating: viewModel.uiState.mdbListUserRating,
                    showMdbListRating: false,
                    onRateClick: { showingMdbListRating = true },
                    onShareClick: { shareContent(viewModel.uiState.meta!) },
                    onTrailerClick: { resumeFrom in openTrailer(for: viewModel.uiState.meta!, resumeFrom: resumeFrom) },
                    onOpenTitle: { contentId, contentType in
                        onOpenTitle?(contentId, contentType)
                    },
                    onOpenProduction: { company in
                        onOpenProduction?(company)
                    },
                    onOpenPerson: { person in
                        let clean = person.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        guard !clean.isEmpty && clean != "cast" else { return }
                        onOpenPerson?(person)
                    },
                    onCommentSelect: { comment in
                        expandedComment = comment
                    },
                    onBack: handleBack
                )
                // While the stream picker is open it sits on top as a full-screen
                // overlay; disable the details content so the focus engine can't
                // route focus to the (hidden) buttons behind it.
                .disabled(isStreamPickerPresented || expandedComment != nil || isSmartPlaybackPending || isResolvingDebrid || isPreparingPlayback || isPreparingInitialPlayback)
                #else
                MobileDetailsContent(
                    uiState: displayedDetailsUiState,
                    onPlayClick: {
                        if let url = viewModel.uiState.streams.first?.url,
                           let meta = viewModel.uiState.meta {
                            dispatchPlayback(url, [:], meta, "", [], nil, [], nil, nil, nil, nil, nil, nil, nil, nil, false)
                        }
                    },
                    onWatchlistClick: { viewModel.toggleWatchlist() },
                    onWatchedClick: { viewModel.toggleWatched(libraryContext: libraryWatchedContext) },
                    onShareClick: { shareContent(viewModel.uiState.meta!) },
                    onBack: handleBack
                )
                #endif
            }

            #if os(tvOS)
            if let expandedComment {
                CommentDetailOverlay(
                    comment: expandedComment,
                    onDismiss: { self.expandedComment = nil }
                )
                .transition(.opacity)
                .zIndex(20)
            }


            playerLoadingOverlayView
            #endif
        }
        .animation(.easeInOut(duration: 0.18), value: isStreamPickerPresented)
        .confirmationDialog(
            viewModel.uiState.meta.map { "Rate \($0.name)" } ?? "Rate on MDBList",
            isPresented: $showingMdbListRating,
            titleVisibility: .visible
        ) {
            ForEach(Array(stride(from: 10, through: 1, by: -1)), id: \.self) { rating in
                Button("\(rating)/10") {
                    submitMdbListRating(rating)
                }
            }
            Button(L10n.string("details_remove_rating", fallback: "Remove Rating"), role: .destructive) {
                submitMdbListRating(nil)
            }
        }
        #if os(tvOS)
        // Present sources in an isolated full-screen focus hierarchy. Keeping
        // this overlay inside the details screen's vertical ScrollView ancestry
        // lets tvOS apply focus-visibility corrections to the shared host,
        // occasionally translating the filters and stream panel below screen.
        .fullScreenCover(isPresented: $isStreamPickerPresented) {
            if let meta = viewModel.uiState.meta {
                TvStreamPickerOverlay(
                    meta: meta,
                    episode: pendingEpisode,
                    streams: viewModel.uiState.streams,
                    groups: viewModel.uiState.streamGroups,
                    streamsRevision: viewModel.uiState.streamsRevision,
                    isLoading: viewModel.uiState.isLoadingStreams,
                    emptyReason: viewModel.uiState.streamsEmptyReason,
                    includeDebrid: true,
                    isResolvingDebrid: isResolvingDebrid,
                    initialAvailabilityMessage: streamPickerAvailabilityMessage,
                    onSelect: { stream, player in
                        let startupToken = ensureStartupRequest(title: meta.name)
                        streamPickerAvailabilityMessage = nil
                        isStreamPickerPresented = false
                        isPreparingPlayback = true
                        playStream(stream, meta: meta, player: player, startupToken: startupToken)
                    },
                    onRefresh: {
                        refreshSources()
                    },
                    onDismiss: {
                        streamPickerAvailabilityMessage = nil
                        pendingStreamPickerResumePosition = nil
                        isStreamPickerPresented = false
                    }
                )
                .ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
            }
        }
        // Menu-press safety net. While the stream picker is up, focus can be
        // in limbo for a few frames (details content is disabled, the picker
        // hasn't committed focus yet); a Menu press then skips the picker's
        // own onExitCommand and bubbles to the app shell, which backs out to
        // Home or suspends the app. Catching it here closes just the picker,
        // and otherwise behaves like the regular back action.
        .onExitCommand {
            if isEpisodeMenuPresented {
                // The context menu consumed this press to close itself; it
                // reaches here anyway. Swallow it so Details stays put.
                isEpisodeMenuPresented = false
            } else if expandedComment != nil {
                expandedComment = nil
            } else if isPreparingInitialPlayback {
                if let requestID = pendingInitialPlaybackRequestID {
                    finishInitialPlaybackRequest(requestID)
                }
            } else if isSmartPlaybackPending || isResolvingDebrid || isPreparingPlayback {
                cancelStartupRequest()
                isSmartPlaybackPending = false
                isResolvingDebrid = false
                isPreparingPlayback = false
            } else if isStreamPickerPresented {
                pendingStreamPickerResumePosition = nil
                isStreamPickerPresented = false
            } else {
                handleBack()
            }
        }
        #endif
        .onChange(of: viewModel.uiState.isLoadingStreams) { _, isLoading in
            if !isLoading {
                finishSmartPlaybackIfPossible()
            }
            performBackgroundAutoSelectionAndPreResolution()
        }
        .onChange(of: viewModel.uiState.streamsRevision) { _, _ in
            finishSmartPlaybackIfPossible()
            performBackgroundAutoSelectionAndPreResolution()
        }
        .onChange(of: viewModel.uiState.isLoading) { _, isLoading in
            if !isLoading {
                if let meta = viewModel.uiState.meta, meta.id == id, !meta.isSeries {
                    onWatchPartyMovieReady?(meta)
                }
                presentInitialStreamPickerIfNeeded()
            }
        }
        .onChange(of: viewModel.uiState.meta?.id) { _, newID in
            guard let newID, newID == id, let meta = viewModel.uiState.meta, meta.id == newID, !meta.isSeries else { return }
            onWatchPartyMovieReady?(meta)
        }
        .onChange(of: initialPlaybackRequestID) { oldRequestID, newRequestID in
            if let newRequestID {
                beginInitialPlaybackPreparation(requestID: newRequestID)
            } else if let oldRequestID,
                      pendingInitialPlaybackRequestID == oldRequestID {
                finishInitialPlaybackRequest(oldRequestID)
            }
        }
        .onAppear {
            isDetailsPlaybackContextActive = true
            didHandOffPlayback = false
            playbackPrewarmer.activateContext()
            cancelStartupRequest()
            isSmartPlaybackPending = false
            isResolvingDebrid = false
            isPreparingPlayback = false
            #if os(tvOS)
            if viewModel.uiState.isLoading {
                DispatchQueue.main.async {
                    isLoadingInitialFocusActive = true
                }
            }
            #endif
            TVHomeDebugTrace.log("details.appear id=\(id) type=\(type)")
            if let initialPlaybackRequestID {
                beginInitialPlaybackPreparation(requestID: initialPlaybackRequestID)
            } else if viewModel.uiState.meta == nil || viewModel.uiState.meta?.id != id {
                viewModel.loadDetails(id: id, type: type)
            } else {
                if let meta = viewModel.uiState.meta {
                    if !meta.isSeries {
                        onWatchPartyMovieReady?(meta)
                    }
                    if viewModel.prefetchedStreamId == nil, pendingEpisode == nil {
                        viewModel.triggerStreamPreFetch(for: meta)
                    }
                }
                viewModel.refreshWatchlistAndWatchedStatus()
            }
            presentInitialStreamPickerIfNeeded()
            performBackgroundAutoSelectionAndPreResolution()
        }
        .onDisappear {
            TVHomeDebugTrace.log("details.disappear id=\(id) type=\(type)")
            isDetailsPlaybackContextActive = false
            cancelStartupRequest()
            cleanupPreFetchedResources()
            if let requestID = pendingInitialPlaybackRequestID {
                finishInitialPlaybackRequest(requestID)
            } else {
                initialPlaybackPreparationTask?.cancel()
                initialPlaybackPreparationTask = nil
            }
            viewModel.cancelAllTasks()
            isPreparingPlayback = false
        }
    }

    /// Stop Details work before asking the parent to remove this screen.
    /// Waiting for onDisappear is too late: enrichment can still publish
    /// updates while the opacity transition is trying to tear Details down.
    private func handleBack() {
        isDetailsPlaybackContextActive = false
        cancelStartupRequest()
        cleanupPreFetchedResources()
        TVHomeDebugTrace.log("details.back.cancelTasks id=\(id)")
        if let requestID = pendingInitialPlaybackRequestID {
            finishInitialPlaybackRequest(requestID)
        }
        viewModel.cancelAllTasks()
        isSmartPlaybackPending = false
        isResolvingDebrid = false
        isPreparingPlayback = false
        onBack()
    }

    private func retryDetailsLoad() {
        initialPlaybackPreparationError = nil
        let detailsTask = viewModel.loadDetails(id: id, type: type)
        if let requestID = pendingInitialPlaybackRequestID {
            waitForInitialPlaybackMetadata(detailsTask, requestID: requestID)
        }
    }

    private func beginInitialPlaybackPreparation(requestID: UInt) {
        guard pendingInitialPlaybackRequestID != requestID ||
                (!isPreparingInitialPlayback && readyInitialPlaybackRequestID != requestID) else {
            return
        }
        let detailsTask = viewModel.loadDetails(id: id, type: type)
        pendingInitialPlaybackRequestID = requestID
        readyInitialPlaybackRequestID = nil
        initialPlaybackPreparationError = nil
        waitForInitialPlaybackMetadata(detailsTask, requestID: requestID)
    }

    private func waitForInitialPlaybackMetadata(_ detailsTask: Task<Void, Never>, requestID: UInt) {
        initialPlaybackPreparationTask?.cancel()
        isPreparingInitialPlayback = true
        initialPlaybackPreparationTask = Task { @MainActor in
            await detailsTask.value
            guard !Task.isCancelled,
                  pendingInitialPlaybackRequestID == requestID else { return }
            initialPlaybackPreparationTask = nil
            isPreparingInitialPlayback = false
            if let error = viewModel.metadataLoadError {
                initialPlaybackPreparationError = error
                return
            }
            guard viewModel.didLoadMetadataSuccessfully else { return }
            guard viewModel.uiState.error == nil,
                  !viewModel.uiState.isLoading,
                  viewModel.uiState.meta?.id == id else { return }
            readyInitialPlaybackRequestID = requestID
        }
    }

    private func finishInitialPlaybackRequest(_ requestID: UInt) {
        guard pendingInitialPlaybackRequestID == requestID else { return }
        initialPlaybackPreparationTask?.cancel()
        initialPlaybackPreparationTask = nil
        pendingInitialPlaybackRequestID = nil
        readyInitialPlaybackRequestID = nil
        isPreparingInitialPlayback = false
        initialPlaybackPreparationError = nil
        onInitialPlaybackRequestConsumed?(requestID)
    }

    private func submitMdbListRating(_ rating: Int?) {
        guard let meta = viewModel.uiState.meta else { return }
        Task { @MainActor in
            let succeeded = await MdbListRatingsService.setRating(meta, rating: rating)
            guard succeeded, viewModel.uiState.meta?.id == meta.id else { return }
            viewModel.setMdbListUserRating(rating)
        }
    }

    private func presentInitialStreamPickerIfNeeded() {
        guard initiallyPresentStreamPicker,
              !didHandleInitialStreamPicker,
              !viewModel.uiState.isLoading,
              let meta = viewModel.uiState.meta else { return }

        didHandleInitialStreamPicker = true
        pendingStreamPickerResumePosition = initialStreamPickerResumePosition
        onInitialStreamPickerPresented?()
        isSmartPlaybackPending = false
        // Prefer the entry from the guide this screen just loaded. A Continue
        // Watching card carries no episode guide, so it can only name the season
        // and episode — and the player queues the next episode by matching ids,
        // which a stand-in entry would not satisfy.
        let requestedEpisode = initialStreamPickerEpisode.map { requested in
            (meta.videos ?? []).first {
                $0.season == requested.season && $0.episode == requested.episode
            } ?? requested
        }
        pendingEpisode = requestedEpisode
        if let episode = requestedEpisode {
            pendingEpisodeSubtitle = "S\(episode.season) · E\(episode.episode) · \(episode.title)"
            let streamId = canonicalEpisodeStreamId(for: episode, meta: meta)
            viewModel.prepareStreams(forId: streamId, type: "series")
        } else {
            pendingEpisodeSubtitle = ""
            viewModel.prepareStreams(forId: meta.streamId, type: meta.type)
        }
        isStreamPickerPresented = true
    }

    private func canonicalEpisodeStreamId(for video: NuvioVideo, meta: NuvioMeta?) -> String {
        meta?.canonicalEpisodeStreamId(for: video) ?? video.id
    }

    private func refreshSources() {
        guard let meta = viewModel.uiState.meta else { return }
        streamPickerAvailabilityMessage = nil
        if let episode = pendingEpisode {
            let streamId = canonicalEpisodeStreamId(for: episode, meta: meta)
            viewModel.prepareStreams(forId: streamId, type: "series", forceRefresh: true)
        } else {
            viewModel.prepareStreams(forId: meta.streamId, type: meta.type, forceRefresh: true)
        }
    }

    private func ensureStartupRequest(title: String) -> UUID {
        if let token = startupBenchmarkToken,
           PlaybackStartupTiming.isActive(token: token) {
            return token
        }
        let token = PlaybackStartupTiming.start(title: title)
        startupBenchmarkToken = token
        return token
    }

    private func cancelStartupRequest(token explicitToken: UUID? = nil) {
        guard let token = explicitToken ?? startupBenchmarkToken else { return }
        PlaybackStartupTiming.cancel(token: token)
        if startupBenchmarkToken == token {
            startupBenchmarkToken = nil
        }
    }

    private func savedPlaybackTarget(
        for meta: NuvioMeta,
        episode: NuvioVideo?,
        profileID: String?,
        manualPicker: Bool
    ) -> DetailsSavedPlaybackTarget? {
        DetailsSavedPlaybackTargetResolver.resolve(
            metaID: meta.id,
            episode: episode,
            profileID: profileID,
            reuseEnabled: reuseLastLink,
            manualPicker: manualPicker,
            lookup: { metaID, season, episodeNumber, profileID in
                LastPlaybackStreamStore.load(
                    metaId: metaID,
                    season: season,
                    episode: episodeNumber,
                    meta: meta,
                    profileId: profileID
                )
            }
        )
    }

    private func dispatchPlayback(
        _ streamUrl: String,
        _ httpHeaders: [String: String],
        _ meta: NuvioMeta,
        _ subtitle: String,
        _ externalSubtitles: [NuvioSubtitle],
        _ currentEpisode: NuvioVideo?,
        _ episodes: [NuvioVideo],
        _ player: ExternalPlayer?,
        _ cacheFileIdentity: PlaybackCacheFileIdentity?,
        _ filename: String?,
        _ videoSize: Int64?,
        _ videoHash: String?,
        _ resumeFrom: Double?,
        _ startupBenchmarkToken: UUID?,
        _ sourceID: String?,
        _ isActionPlaybackSession: Bool
    ) {
        isDetailsPlaybackContextActive = false
        didHandOffPlayback = true
        _ = playbackPrewarmer.handOff(
            urlString: streamUrl,
            headers: httpHeaders,
            retainOnlyIf: effectivePlayer(for: player) == .builtIn
        )
        resetPreResolutionCandidate()
        onPlayClick(
            streamUrl,
            httpHeaders,
            meta,
            subtitle,
            externalSubtitles,
            currentEpisode,
            episodes,
            player,
            cacheFileIdentity,
            filename,
            videoSize,
            videoHash,
            resumeFrom,
            startupBenchmarkToken,
            sourceID,
            isActionPlaybackSession
        )
    }

    private func startStreamFlow(streamId: String, type: String, reload: Bool, forceManualPicker: Bool = false) {
        guard let meta = viewModel.uiState.meta else { return }
        streamPickerAvailabilityMessage = nil

        let activeProfileId = ProfileSettings.activeProfileID

        if let storedTarget = savedPlaybackTarget(
            for: meta,
            episode: pendingEpisode,
            profileID: activeProfileId,
            manualPicker: forceManualPicker
        ) {
            let startupToken = ensureStartupRequest(title: meta.name)
            isStreamPickerPresented = false
            isPreparingPlayback = true
            isSmartPlaybackPending = false

            dispatchPlayback(
                storedTarget.url.absoluteString,
                storedTarget.httpHeaders,
                meta,
                pendingEpisodeSubtitle.isEmpty ? (pendingEpisode.map { "S\($0.season) · E\($0.episode) · \($0.title)" } ?? "") : pendingEpisodeSubtitle,
                [],
                pendingEpisode,
                orderedEpisodes(for: meta),
                nil,
                nil,
                nil,
                nil,
                nil,
                nil,
                startupToken,
                nil,
                false
            )
            return
        }

        if forceManualPicker || !smartStreamSelection {
            if forceManualPicker {
                resetPreResolutionCandidate()
            }
            cancelStartupRequest()
            isSmartPlaybackPending = false
            isResolvingDebrid = false
            isPreparingPlayback = false
            if reload {
                viewModel.prepareStreams(forId: streamId, type: type)
            }
            if !viewModel.uiState.streams.isEmpty {
                let saved = streamDiscoveryDuration ?? (viewModel.prefetchStartTime.map { Date().timeIntervalSince($0) } ?? 0)
                print("[PreFetch] ⏱ Stream picker opened instantly with \(viewModel.uiState.streams.count) pre-fetched sources! Saved \(String(format: "%.3fs", saved)) of add-on search wait time.")
            }
            isStreamPickerPresented = true
            return
        }

        // Instant launch if pre-resolved in background!
        if !forceManualPicker,
           let preStream = preResolvedStream,
           let preURL = preResolvedURL,
           preResolvedStreamId == streamId {
            let discoverySaved = streamDiscoveryDuration ?? 0
            let debridSaved = preResolvedDuration ?? 0
            let totalSaved = discoverySaved + debridSaved

            #if DEBUG
            print("\n============================================================")
            print("[PreFetch] 🚀 INSTANT PLAYBACK TRIGGERED (ZERO-WAIT LAUNCH):")
            print("  • Title:              \(meta.name)")
            let cleanStreamName = (preStream.name ?? preStream.description ?? "").replacingOccurrences(of: "\n", with: " ")
            print("  • Source:             \(preStream.addonName ?? "Unknown") · \(cleanStreamName)")
            print("  • Stream Discovery:   Saved \(String(format: "%.3fs", discoverySaved)) (bypassed)")
            print("  • Debrid Resolution:  Saved \(String(format: "%.3fs", debridSaved)) (bypassed)")
            print("  ⏱ TOTAL TIME SAVED:   \(String(format: "%.3fs", totalSaved))")
            print("============================================================\n")
            #endif

            let startupToken = ensureStartupRequest(title: meta.name)
            PlaybackStartupTiming.markSourcePicked(stream: preStream, token: startupToken)
            if debridSaved > 0 {
                PlaybackStartupTiming.markDebridResolved(token: startupToken)
            }

            isStreamPickerPresented = false
            isPreparingPlayback = true
            isSmartPlaybackPending = false

            let activeProfileId = ProfileSettings.activeProfileID
            if !preStream.isNotPlayable {
                LastStreamQualityStore.save(metaId: meta.id, stream: preStream, profileId: activeProfileId)
                BingeGroupStore.save(seriesId: meta.id, stream: preStream, profileId: activeProfileId)
            }

            dispatchPlayback(
                preURL.absoluteString,
                preStream.httpHeaders ?? [:],
                meta,
                pendingEpisodeSubtitle.isEmpty ? preResolvedEpisodeSubtitle : pendingEpisodeSubtitle,
                preStream.subtitles,
                pendingEpisode ?? preResolvedEpisode,
                orderedEpisodes(for: meta),
                nil,
                PlaybackCacheFileIdentity(infoHash: preStream.effectiveInfoHash, fileIndex: preStream.effectiveFileIdx),
                preResolvedFilename ?? preStream.filename,
                preResolvedVideoSize ?? preStream.videoSize,
                preStream.videoHash,
                nil,
                startupToken,
                preStream.id,
                preStream.isNotPlayable
            )
            return
        }

        startupBenchmarkToken = PlaybackStartupTiming.start(title: meta.name)
        isSmartPlaybackPending = true
        isResolvingDebrid = false
        isPreparingPlayback = false
        isStreamPickerPresented = false

        if reload {
            viewModel.prepareStreams(forId: streamId, type: type, forceRefresh: true)
        }
        finishSmartPlaybackIfPossible(meta: meta)
    }

    private func finishSmartPlaybackIfPossible(meta explicitMeta: NuvioMeta? = nil) {
        guard isSmartPlaybackPending else { return }
        let meta = explicitMeta ?? viewModel.uiState.meta
        guard let meta else { return }

        let debrid = DebridResolver(store: ProfileSettings.current)
        let cachedOnlyPreference = (ProfileSettings.current.object(forKey: SettingsKey.cachedOnlyStreams) as? Bool) ?? false
        let cachedOnly = SmartPlaybackSelector.effectiveCachedOnly(
            cachedOnlyPreference,
            contentType: meta.type
        )

        let activeProfileId = ProfileSettings.activeProfileID
        let preferredTags = LastStreamQualityStore.load(metaId: meta.id, profileId: activeProfileId)
        let preserveAddonOrder = (ProfileSettings.current.object(forKey: SettingsKey.preserveAddonStreamOrder) as? Bool) ?? false
        let unavailableReason: String? = {
            let streams = viewModel.uiState.streams
            guard !streams.isEmpty, streams.allSatisfy({ $0.unavailabilityReason != nil }) else { return nil }
            return streams.compactMap(\.unavailabilityReason).first
        }()

        let candidateStream: NuvioStream?
        if smartStreamUseTopResult || preserveAddonOrder {
            let sortRaw = ProfileSettings.current.string(forKey: SettingsKey.streamSortOption)
            let sortOption = sortRaw.flatMap(StreamSortOption.init(rawValueOrSync:)) ?? .quality
            let displayed = StreamPickerListBuilder.displayedStreams(
                streams: viewModel.uiState.streams,
                groups: viewModel.uiState.streamGroups,
                selectedAddonId: nil,
                sortOption: sortOption,
                includeDebrid: debrid.isEnabled || TorrentSettings.isEnabled(),
                cachedOnly: cachedOnly,
                preserveAddonStreams: preserveAddonOrder
            )
            let available = displayed.filter { $0.unavailabilityReason == nil && !$0.isNotPlayable }
            let pool: [NuvioStream]
            if preserveAddonOrder {
                pool = available
            } else {
                // Filter out 0-res / ticket streams if valid streams exist
                let valid = available.filter {
                    !SmartPlaybackSelector.isLowQualityOrTicketStream($0) && StreamPickerListBuilder.resolution(for: $0) >= 720
                }
                pool = valid.isEmpty ? available : valid
            }
            let preferBingeGroup = (ProfileSettings.current.object(forKey: SettingsKey.streamAutoPlayPreferBingeGroup) as? Bool) ?? true
            let reuseBingeGroup = (ProfileSettings.current.object(forKey: SettingsKey.streamAutoPlayReuseBingeGroup) as? Bool) ?? true
            if (preferBingeGroup || reuseBingeGroup), let preferredTags, preferredTags.bingeGroup != nil || preferredTags.releaseFingerprint != nil {
                let matching = pool.first { stream in
                    let tags = StreamQualityTags.parse(stream: stream)
                    if let pbg = preferredTags.bingeGroup, let sbg = tags.bingeGroup,
                       pbg.compare(sbg, options: .caseInsensitive) == .orderedSame {
                        return true
                    }
                    if let pfp = preferredTags.releaseFingerprint, let sfp = tags.releaseFingerprint,
                       pfp.compare(sfp, options: .caseInsensitive) == .orderedSame {
                        return true
                    }
                    return false
                }
                candidateStream = matching ?? pool.first
            } else {
                candidateStream = pool.first
            }
        } else {
            candidateStream = SmartPlaybackSelector.bestStream(
                from: viewModel.uiState.streams,
                qualityPreference: smartStreamQuality,
                subtitleLanguages: subtitleLanguagePreferences,
                shouldMatchSubtitles: smartSubtitleMatching,
                includeDebrid: debrid.isEnabled || TorrentSettings.isEnabled(),
                preferredTags: preferredTags,
                cachedOnly: cachedOnly
            )
        }

        if let stream = candidateStream {
            let isIdealMatch: Bool = {
                if stream.isNotPlayable { return false }
                if !viewModel.uiState.isLoadingStreams { return true }
                if preserveAddonOrder {
                    if debrid.isEnabled, cachedOnly {
                        return stream.isLikelyCached
                    }
                    return true
                }
                if SmartPlaybackSelector.isLowQualityOrTicketStream(stream) { return false }
                let tags = StreamQualityTags.parse(stream: stream)
                let res = tags.resolution > 0 ? tags.resolution : SmartPlaybackSelector.inferredResolution(for: stream)
                let targetRes = (smartStreamQuality == "720p") ? 720 : 1080

                // If a preferred binge group or release fingerprint is expected for this title,
                // do NOT declare a non-matching stream an "ideal match" while streams are still loading.
                if let preferredTags, preferredTags.bingeGroup != nil || preferredTags.releaseFingerprint != nil {
                    let matchesBingeGroup = (preferredTags.bingeGroup != nil && tags.bingeGroup?.compare(preferredTags.bingeGroup!, options: .caseInsensitive) == .orderedSame)
                    let matchesFingerprint = (preferredTags.releaseFingerprint != nil && tags.releaseFingerprint?.compare(preferredTags.releaseFingerprint!, options: .caseInsensitive) == .orderedSame)
                    guard matchesBingeGroup || matchesFingerprint else {
                        return false
                    }
                }

                if debrid.isEnabled,
                   SmartPlaybackSelector.effectiveCachedOnly(true, contentType: meta.type) {
                    return (stream.isLikelyCached || tags.isCached) && res >= targetRes
                }
                return res >= targetRes
            }()

            if isIdealMatch {
                isSmartPlaybackPending = false
                isPreparingPlayback = true
                guard let startupToken = startupBenchmarkToken,
                      PlaybackStartupTiming.isActive(token: startupToken) else { return }
                playStream(stream, meta: meta, startupToken: startupToken)
            }
        } else if !viewModel.uiState.isLoadingStreams
                    && (viewModel.uiState.streamsEmptyReason != nil || !viewModel.uiState.streamGroups.isEmpty || unavailableReason != nil) {
            cancelStartupRequest()
            isSmartPlaybackPending = false
            isPreparingPlayback = false
            if let unavailableReason {
                streamPickerAvailabilityMessage = L10n.format(
                    "details_no_sources_available_yet",
                    fallback: "No sources available yet. %@",
                    unavailableReason
                )
            }
            isStreamPickerPresented = true
        }
    }

    private func cleanupPreFetchedResources() {
        playbackPrewarmer.endContext()
        if preFetchDebridTask != nil || preResolvedURL != nil {
            print("[PreFetch] 🛑 Details view dismissed — cancelled pending background pre-resolution tasks and cleaned up pre-loaded resources.")
        }
        resetPreResolutionCandidate()
        streamDiscoveryDuration = nil
    }

    private func resetPreResolutionCandidate() {
        preResolutionGeneration &+= 1
        preFetchDebridTask?.cancel()
        preFetchDebridTask = nil
        preResolutionIdentity = nil
        preResolvedStream = nil
        preResolvedURL = nil
        preResolvedFilename = nil
        preResolvedVideoSize = nil
        preResolvedStreamId = nil
        preResolvedEpisode = nil
        preResolvedEpisodeSubtitle = ""
        preResolvedDuration = nil
        prewarmedSavedTarget = nil
        playbackPrewarmer.discardCurrent()
    }

    @ViewBuilder
    private var playerLoadingOverlayView: some View {
        if let meta = viewModel.uiState.meta,
           (isSmartPlaybackPending || isResolvingDebrid || isPreparingPlayback || isPreparingInitialPlayback) && !isStreamPickerPresented {
            PlayerLoadingOverlay(
                backdropUrl: meta.backgroundUrl ?? meta.posterUrl,
                logoUrl: meta.logoUrl,
                title: meta.name,
                message: detailsLoadingMessage,
                onDismiss: {
                    cancelStartupRequest()
                    isSmartPlaybackPending = false
                    isResolvingDebrid = false
                    isPreparingPlayback = false
                    if let requestID = pendingInitialPlaybackRequestID {
                        finishInitialPlaybackRequest(requestID)
                    }
                }
            )
            .transition(.opacity)
            .zIndex(25)
        }
    }

    private func performBackgroundAutoSelectionAndPreResolution() {
        guard isDetailsPlaybackContextActive, !didHandOffPlayback else { return }
        let prefetchEnabled = (ProfileSettings.current.object(forKey: SettingsKey.backgroundStreamPreFetch) as? Bool) ?? true
        guard prefetchEnabled else {
            resetPreResolutionCandidate()
            return
        }
        guard let meta = viewModel.uiState.meta else {
            resetPreResolutionCandidate()
            return
        }
        let savedEpisode = pendingEpisode ?? viewModel.prefetchedEpisode
        if let savedTarget = savedPlaybackTarget(
            for: meta,
            episode: savedEpisode,
            profileID: ProfileSettings.activeProfileID,
            manualPicker: isStreamPickerPresented
        ) {
            let savedStreamID = savedEpisode.map { canonicalEpisodeStreamId(for: $0, meta: meta) } ?? meta.streamId
            if viewModel.requestedStreamId == nil || viewModel.requestedStreamId == savedStreamID {
                if prewarmedSavedTarget != savedTarget {
                    resetPreResolutionCandidate()
                    prewarmedSavedTarget = savedTarget
                    print("[PreFetch] 🔗 Preparing saved playback target for \(savedEpisode == nil ? "movie" : "episode").")
                }
                maybeWarmSavedPlaybackTarget(savedTarget, meta: meta, episode: savedEpisode)
                return
            }
        }
        if prewarmedSavedTarget != nil {
            resetPreResolutionCandidate()
        }
        let streams = viewModel.uiState.streams
        guard !streams.isEmpty else {
            resetPreResolutionCandidate()
            return
        }

        guard let currentStreamId = viewModel.prefetchedStreamId,
              viewModel.requestedStreamId == currentStreamId else {
            resetPreResolutionCandidate()
            return
        }
        let currentEpisode = viewModel.prefetchedEpisode

        if streamDiscoveryDuration == nil, let start = viewModel.prefetchStartTime {
            streamDiscoveryDuration = Date().timeIntervalSince(start)
        }

        let debrid = DebridResolver(store: ProfileSettings.current)
        let cachedOnlyPreference = (ProfileSettings.current.object(forKey: SettingsKey.cachedOnlyStreams) as? Bool) ?? false
        let cachedOnly = SmartPlaybackSelector.effectiveCachedOnly(
            cachedOnlyPreference,
            contentType: meta.type
        )

        let activeProfileId = ProfileSettings.activeProfileID
        let preferredTags = LastStreamQualityStore.load(metaId: meta.id, profileId: activeProfileId)
        let preserveAddonOrder = (ProfileSettings.current.object(forKey: SettingsKey.preserveAddonStreamOrder) as? Bool) ?? false

        let candidateStream: NuvioStream?
        if smartStreamUseTopResult || preserveAddonOrder {
            let sortRaw = ProfileSettings.current.string(forKey: SettingsKey.streamSortOption)
            let sortOption = sortRaw.flatMap(StreamSortOption.init(rawValueOrSync:)) ?? .quality
            let displayed = StreamPickerListBuilder.displayedStreams(
                streams: streams,
                groups: viewModel.uiState.streamGroups,
                selectedAddonId: nil,
                sortOption: sortOption,
                includeDebrid: debrid.isEnabled || TorrentSettings.isEnabled(),
                cachedOnly: cachedOnly,
                preserveAddonStreams: preserveAddonOrder
            )
            let available = displayed.filter { $0.unavailabilityReason == nil && !$0.isNotPlayable }
            let pool: [NuvioStream]
            if preserveAddonOrder {
                pool = available
            } else {
                let valid = available.filter {
                    !SmartPlaybackSelector.isLowQualityOrTicketStream($0) && StreamPickerListBuilder.resolution(for: $0) >= 720
                }
                pool = valid.isEmpty ? available : valid
            }
            let preferBingeGroup = (ProfileSettings.current.object(forKey: SettingsKey.streamAutoPlayPreferBingeGroup) as? Bool) ?? true
            let reuseBingeGroup = (ProfileSettings.current.object(forKey: SettingsKey.streamAutoPlayReuseBingeGroup) as? Bool) ?? true
            if (preferBingeGroup || reuseBingeGroup), let preferredTags, preferredTags.bingeGroup != nil || preferredTags.releaseFingerprint != nil {
                let matching = pool.first { stream in
                    let tags = StreamQualityTags.parse(stream: stream)
                    if let pbg = preferredTags.bingeGroup, let sbg = tags.bingeGroup,
                       pbg.compare(sbg, options: .caseInsensitive) == .orderedSame {
                        return true
                    }
                    if let pfp = preferredTags.releaseFingerprint, let sfp = tags.releaseFingerprint,
                       pfp.compare(sfp, options: .caseInsensitive) == .orderedSame {
                        return true
                    }
                    return false
                }
                candidateStream = matching ?? pool.first
            } else {
                candidateStream = pool.first
            }
        } else {
            candidateStream = SmartPlaybackSelector.bestStream(
                from: streams,
                qualityPreference: smartStreamQuality,
                subtitleLanguages: subtitleLanguagePreferences,
                shouldMatchSubtitles: smartSubtitleMatching,
                includeDebrid: debrid.isEnabled || TorrentSettings.isEnabled(),
                preferredTags: preferredTags,
                cachedOnly: cachedOnly
            )
        }

        guard let candidate = candidateStream else {
            resetPreResolutionCandidate()
            return
        }

        let isIdealMatch: Bool = {
            if candidate.isNotPlayable { return false }
            if !viewModel.uiState.isLoadingStreams { return true }
            if preserveAddonOrder {
                if debrid.isEnabled, cachedOnly {
                    return candidate.isLikelyCached
                }
                return true
            }
            if SmartPlaybackSelector.isLowQualityOrTicketStream(candidate) { return false }
            let tags = StreamQualityTags.parse(stream: candidate)
            let res = tags.resolution > 0 ? tags.resolution : SmartPlaybackSelector.inferredResolution(for: candidate)
            let targetRes = (smartStreamQuality == "720p") ? 720 : 1080

            if let preferredTags, preferredTags.bingeGroup != nil || preferredTags.releaseFingerprint != nil {
                let matchesBingeGroup = (preferredTags.bingeGroup != nil && tags.bingeGroup?.compare(preferredTags.bingeGroup!, options: .caseInsensitive) == .orderedSame)
                let matchesFingerprint = (preferredTags.releaseFingerprint != nil && tags.releaseFingerprint?.compare(preferredTags.releaseFingerprint!, options: .caseInsensitive) == .orderedSame)
                guard matchesBingeGroup || matchesFingerprint else {
                    return false
                }
            }

            if debrid.isEnabled,
               SmartPlaybackSelector.effectiveCachedOnly(true, contentType: meta.type) {
                return (candidate.isLikelyCached || tags.isCached) && res >= targetRes
            }
            return res >= targetRes
        }()

        guard isIdealMatch else {
            resetPreResolutionCandidate()
            return
        }

        let identity = DetailsBackgroundResolutionIdentity(
            streamID: currentStreamId,
            episodeID: currentEpisode?.id,
            candidate: candidate
        )
        if preResolutionIdentity != identity {
            resetPreResolutionCandidate()
        }
        // Keep the latest stream payload even when its transport identity did
        // not change (for example, when subtitle results arrive later).
        preResolutionIdentity = identity

        if let resolvedURL = preResolvedURL,
           let resolvedStream = preResolvedStream,
           let resolvedStreamId = preResolvedStreamId {
            let resolvedIdentity = DetailsBackgroundResolutionIdentity(
                streamID: resolvedStreamId,
                episodeID: preResolvedEpisode?.id,
                candidate: resolvedStream
            )
            if resolvedIdentity == identity {
                if resolvedStream != candidate {
                    print("[PreFetch] ♻️ Retained prepared source after stream metadata update (subtitles=\(candidate.subtitles.count)).")
                }
                preResolvedStream = candidate
                preResolvedEpisode = currentEpisode
                preResolvedEpisodeSubtitle = currentEpisode.map { "S\($0.season) · E\($0.episode) · \($0.title)" } ?? ""
                maybeWarmPreResolvedURL(resolvedURL, candidate: candidate, meta: meta, episode: currentEpisode)
                return
            }
        }
        // A stream revision for the same candidate must not restart an active
        // debrid resolution.
        if preFetchDebridTask != nil { return }

        let discDuration = streamDiscoveryDuration ?? (viewModel.prefetchStartTime.map { Date().timeIntervalSince($0) } ?? 0)
        streamDiscoveryDuration = discDuration
        let cleanName = (candidate.name ?? candidate.description ?? "Direct Source").replacingOccurrences(of: "\n", with: " ")
        print("[PreFetch] 🔍 Auto-selected candidate source in \(String(format: "%.3fs", discDuration)): \(candidate.addonName ?? "Unknown") · \(cleanName)")

        if let direct = candidate.directURL, !direct.isEmpty, let url = URL(string: direct) {
            preResolvedURL = url
            preResolvedStream = candidate
            preResolvedStreamId = currentStreamId
            preResolvedEpisode = currentEpisode
            preResolvedEpisodeSubtitle = currentEpisode.map { "S\($0.season) · E\($0.episode) · \($0.title)" } ?? ""
            preResolvedFilename = candidate.filename
            preResolvedVideoSize = candidate.videoSize
            preResolvedDuration = 0.0
            maybeWarmPreResolvedURL(url, candidate: candidate, meta: meta, episode: currentEpisode)
            print("[PreFetch] ⚡️ Direct source URL ready; playback prepares on Play.")
            return
        }

        guard candidate.isDebridResolvable && smartStreamSelection else { return }

        let resolutionGeneration = preResolutionGeneration
        preFetchDebridTask = Task { @MainActor in
            let t0_debrid = Date()
            let season = currentEpisode?.season
            let episode = currentEpisode?.episode
            let resolver = DebridResolver(store: ProfileSettings.current)
            var resolvedURL: URL? = nil
            var debridFilename: String? = nil
            var debridVideoSize: Int64? = nil
            if resolver.isEnabled {
                let result = await resolver.resolvedURL(for: candidate, season: season, episode: episode)
                if case let .success(url, filename, videoSize)? = result {
                    resolvedURL = url
                    debridFilename = filename
                    debridVideoSize = videoSize
                }
            }
            guard !Task.isCancelled,
                  self.isDetailsPlaybackContextActive,
                  !self.didHandOffPlayback,
                  self.preResolutionGeneration == resolutionGeneration,
                  let latestIdentity = self.preResolutionIdentity,
                  latestIdentity == identity else { return }
            self.preFetchDebridTask = nil
            guard let url = resolvedURL else { return }
            let resolvedCandidate = latestIdentity.candidate
            let debridElapsed = Date().timeIntervalSince(t0_debrid)
            self.preResolvedURL = url
            self.preResolvedFilename = debridFilename
            self.preResolvedVideoSize = debridVideoSize
            self.preResolvedStream = resolvedCandidate
            self.preResolvedStreamId = latestIdentity.streamID
            self.preResolvedEpisode = currentEpisode
            self.preResolvedEpisodeSubtitle = currentEpisode.map { "S\($0.season) · E\($0.episode) · \($0.title)" } ?? ""
            self.preResolvedDuration = debridElapsed
            self.maybeWarmPreResolvedURL(url, candidate: resolvedCandidate, meta: meta, episode: currentEpisode)
            print("[PreFetch] ⚡️ Pre-resolved Debrid link in background in \(String(format: "%.3fs", debridElapsed))!")
            print("[PreFetch] ✅ Stream URL ready; startup prewarm requested when supported.")
        }
    }

    private func maybeWarmPreResolvedURL(
        _ url: URL,
        candidate: NuvioStream,
        meta: NuvioMeta,
        episode: NuvioVideo?
    ) {
        guard isDetailsPlaybackContextActive, !didHandOffPlayback else { return }
        let isSeries = meta.isSeries || NuvioMeta.isSeriesType(meta.type)
        let type = meta.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isPlayableMovieOrEpisode = isSeries ? episode != nil : (type == "movie" || type == "film")
        let isLiveOrSports = isLiveOrSportsContent(meta: meta, url: url)
        let headers = candidate.httpHeaders ?? [:]
        let backend = PlaybackBackendPolicy.resolveFromCurrentSettings(
            url: url,
            streamName: candidate.name,
            streamDescription: candidate.description,
            filename: candidate.filename,
            isLiveStream: isLiveOrSports,
            isSports: meta.isSports,
            httpHeaders: headers
        ).backend
        let hybridDiskCacheEnabled = (ProfileSettings.current.object(forKey: SettingsKey.hybridDiskCacheEnabled) as? Bool) ?? false
        let eligible = DetailsPlaybackPrewarmPolicy.shouldPrewarm(
            url: url,
            backend: backend,
            backgroundStreamPreFetchEnabled: (ProfileSettings.current.object(forKey: SettingsKey.backgroundStreamPreFetch) as? Bool) ?? true,
            smartStreamSelectionEnabled: smartStreamSelection,
            usesExternalPlayer: effectivePlayer(for: nil) != .builtIn,
            isPlayableMovieOrEpisode: isPlayableMovieOrEpisode,
            isLiveOrSports: isLiveOrSports || meta.isSports
        )
        if eligible {
            playbackPrewarmer.warm(
                url: url,
                headers: headers,
                hybridProfileID: hybridDiskCacheEnabled ? (ProfileSettings.activeProfileID ?? "") : nil
            )
        } else {
            playbackPrewarmer.discardCurrent()
        }
    }

    private func isLiveOrSportsContent(meta: NuvioMeta, url: URL) -> Bool {
        if meta.isSports || CinemetaCatalogRepository.isLiveContentType(meta.type) { return true }

        let id = meta.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if id.hasPrefix("iptv:") || id.hasPrefix("live:") || id.hasPrefix("channel:") || id.hasPrefix("stream:")
            || id.hasPrefix("pp-live:") || id.contains("cdnlive") || id.contains("daddylive")
            || id.contains("streamed.pk") || id.contains("nuvio_sport") {
            return true
        }

        var name = meta.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while let first = name.first, !first.isLetter && !first.isNumber && first != "[" && first != "(" {
            name.removeFirst()
            name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if name.hasPrefix("now:") || name.hasPrefix("live:") || name.hasPrefix("[live]") || name.hasPrefix("(live)") {
            return true
        }

        let path = url.path.lowercased()
        return path.contains("/live/") || path.contains("/iptv/") || path.contains("live.m3u8") || path.contains("cdnlive")
    }

    private func effectivePlayer(for selectedPlayer: ExternalPlayer?) -> ExternalPlayer {
        selectedPlayer ?? ExternalPlayer.from(
            ProfileSettings.current.string(forKey: SettingsKey.externalPlayer)
        )
    }

    private func maybeWarmSavedPlaybackTarget(
        _ target: DetailsSavedPlaybackTarget,
        meta: NuvioMeta,
        episode: NuvioVideo?
    ) {
        guard isDetailsPlaybackContextActive, !didHandOffPlayback else { return }
        let isSeries = meta.isSeries || NuvioMeta.isSeriesType(meta.type)
        let type = meta.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isPlayableMovieOrEpisode = isSeries ? episode != nil : (type == "movie" || type == "film")
        let isLiveOrSports = isLiveOrSportsContent(meta: meta, url: target.url)
        let backend = PlaybackBackendPolicy.resolveFromCurrentSettings(
            url: target.url,
            isLiveStream: isLiveOrSports,
            isSports: meta.isSports,
            httpHeaders: target.httpHeaders
        ).backend
        let hybridDiskCacheEnabled = (ProfileSettings.current.object(forKey: SettingsKey.hybridDiskCacheEnabled) as? Bool) ?? false
        let eligible = DetailsPlaybackPrewarmPolicy.shouldPrewarm(
            url: target.url,
            backend: backend,
            backgroundStreamPreFetchEnabled: (ProfileSettings.current.object(forKey: SettingsKey.backgroundStreamPreFetch) as? Bool) ?? true,
            smartStreamSelectionEnabled: smartStreamSelection,
            usesExternalPlayer: effectivePlayer(for: nil) != .builtIn,
            isPlayableMovieOrEpisode: isPlayableMovieOrEpisode,
            isLiveOrSports: isLiveOrSports || meta.isSports,
            isSavedPlaybackTarget: true
        )
        if eligible {
            playbackPrewarmer.warm(
                url: target.url,
                headers: target.httpHeaders,
                hybridProfileID: hybridDiskCacheEnabled ? (ProfileSettings.activeProfileID ?? "") : nil
            )
        } else {
            playbackPrewarmer.discardCurrent()
        }
    }

    /// Up to two more Usenet streams (other NZBs) listed after `stream`.
    private func usenetAlternates(after stream: NuvioStream) -> [NuvioStream] {
        let all = viewModel.uiState.streams
        let chosenNZB = stream.directURL.flatMap(URL.init(string:)).flatMap(UsenetStreamSpec.init(url:))?.nzbURL
        let start = all.firstIndex { $0.id == stream.id }.map { $0 + 1 } ?? 0
        var seen = Set(chosenNZB.map { [$0] } ?? [])
        var result: [NuvioStream] = []
        for candidate in all[start...] where result.count < 2 {
            guard candidate.unavailabilityReason == nil,
                  let raw = candidate.directURL, let url = URL(string: raw),
                  let spec = UsenetStreamSpec(url: url),
                  seen.insert(spec.nzbURL).inserted else { continue }
            result.append(candidate)
        }
        return result
    }

    private func preResolvedMatchesPlaybackSelection(_ stream: NuvioStream, meta: NuvioMeta) -> Bool {
        guard let resolvedStream = preResolvedStream,
              let resolvedStreamID = preResolvedStreamId else { return false }
        let selectedEpisode = pendingEpisode ?? viewModel.prefetchedEpisode
        let selectedStreamID = selectedEpisode.map { canonicalEpisodeStreamId(for: $0, meta: meta) } ?? meta.streamId
        guard resolvedStreamID == selectedStreamID,
              preResolvedEpisode?.id == selectedEpisode?.id else { return false }

        let resolvedIdentity = DetailsBackgroundResolutionIdentity(
            streamID: resolvedStreamID,
            episodeID: preResolvedEpisode?.id,
            candidate: resolvedStream
        )
        let selectedIdentity = DetailsBackgroundResolutionIdentity(
            streamID: selectedStreamID,
            episodeID: selectedEpisode?.id,
            candidate: stream
        )
        return resolvedIdentity == selectedIdentity
    }

    /// Plays a chosen stream. Direct URLs go straight to the player; torrent-only
    /// streams are resolved through the configured debrid provider first, keeping
    /// the picker's spinner up until a link comes back (or the attempt fails).
    private func playStream(
        _ stream: NuvioStream,
        meta: NuvioMeta,
        player: ExternalPlayer? = nil,
        startupToken: UUID
    ) {
        guard PlaybackStartupTiming.isActive(token: startupToken) else {
            cancelStartupRequest(token: startupToken)
            return
        }
        if let unavailableReason = stream.unavailabilityReason {
            cancelStartupRequest(token: startupToken)
            isResolvingDebrid = false
            isPreparingPlayback = false
            isSmartPlaybackPending = false
            streamPickerAvailabilityMessage = unavailableReason
            isStreamPickerPresented = true
            return
        }

        let activeProfileId = ProfileSettings.activeProfileID
        if !stream.isNotPlayable {
            LastStreamQualityStore.save(metaId: meta.id, stream: stream, profileId: activeProfileId)
            BingeGroupStore.save(seriesId: meta.id, stream: stream, profileId: activeProfileId)
        }
        PlaybackStartupTiming.markSourcePicked(stream: stream, token: startupToken)
        // Usenet: start the on-device engine here so a failure (no server,
        // incomplete release) lands back in the source picker with a reason.
        if let raw = stream.directURL, let usenetURL = URL(string: raw), UsenetStreamSpec(url: usenetURL) != nil {
            isResolvingDebrid = true
            isPreparingPlayback = true
            isSmartPlaybackPending = false
            // A broken release falls through to the next Usenet streams of the
            // same title, so one bad upload doesn't end in an error.
            let candidates = [stream] + usenetAlternates(after: stream)
            Task { @MainActor in
                var lastError: Error = UsenetError.noPlayableFile
                for candidate in candidates {
                    guard let raw = candidate.directURL, let url = URL(string: raw),
                          let spec = UsenetStreamSpec(url: url) else { continue }
                    do {
                        let localURL = try await UsenetEngineManager.shared.startStream(spec)
                        guard PlaybackStartupTiming.isActive(token: startupToken) else {
                            await UsenetEngineManager.shared.stopActiveStream(for: localURL)
                            return
                        }
                        isResolvingDebrid = false
                        isStreamPickerPresented = false
                        if !candidate.isNotPlayable { armExternalPlayerTimeoutIfNeeded(player: player) }
                        if self.startupBenchmarkToken == startupToken {
                            self.startupBenchmarkToken = nil
                        }
                        let resumePos = pendingStreamPickerResumePosition
                        pendingStreamPickerResumePosition = nil
                        dispatchPlayback(
                            localURL.absoluteString,
                            candidate.httpHeaders ?? [:],
                            meta,
                            pendingEpisodeSubtitle,
                            candidate.subtitles,
                            pendingEpisode,
                            orderedEpisodes(for: meta),
                            player,
                            nil,
                            candidate.filename,
                            candidate.videoSize,
                            candidate.videoHash,
                            resumePos,
                            startupToken,
                            candidate.id,
                            candidate.isNotPlayable
                        )
                        return
                    } catch {
                        lastError = error
                        guard UsenetEngineManager.isReleaseProblem(error),
                              PlaybackStartupTiming.isActive(token: startupToken) else { break }
                        usenetLog.notice("usenet: trying the next source after: \(error.localizedDescription, privacy: .public)")
                    }
                }
                isResolvingDebrid = false
                cancelStartupRequest(token: startupToken)
                isPreparingPlayback = false
                isSmartPlaybackPending = false
                if !(lastError is CancellationError) {
                    streamPickerAvailabilityMessage = lastError.localizedDescription
                    isStreamPickerPresented = true
                }
            }
            return
        }
        if let url = stream.directURL, !url.isEmpty {
            isStreamPickerPresented = false
            isPreparingPlayback = true
            isSmartPlaybackPending = false
            if !stream.isNotPlayable { armExternalPlayerTimeoutIfNeeded(player: player) }
            if self.startupBenchmarkToken == startupToken {
                self.startupBenchmarkToken = nil
            }
            let resumePos = pendingStreamPickerResumePosition
            pendingStreamPickerResumePosition = nil
            dispatchPlayback(
                url,
                stream.httpHeaders ?? [:],
                meta,
                pendingEpisodeSubtitle,
                stream.subtitles,
                pendingEpisode,
                orderedEpisodes(for: meta),
                player,
                PlaybackCacheFileIdentity(infoHash: stream.effectiveInfoHash, fileIndex: stream.effectiveFileIdx),
                stream.filename,
                stream.videoSize,
                stream.videoHash,
                resumePos,
                startupToken,
                stream.id,
                stream.isNotPlayable
            )
            return
        }

        if let preURL = preResolvedURL, preResolvedMatchesPlaybackSelection(stream, meta: meta) {
            preResolvedStream = stream
            preResolvedEpisode = pendingEpisode ?? viewModel.prefetchedEpisode
            preResolvedEpisodeSubtitle = preResolvedEpisode.map {
                "S\($0.season) · E\($0.episode) · \($0.title)"
            } ?? ""
            let debridSaved = preResolvedDuration ?? 0
            if debridSaved > 0 {
                PlaybackStartupTiming.markDebridResolved(token: startupToken)
            }
            isStreamPickerPresented = false
            isPreparingPlayback = true
            isSmartPlaybackPending = false
            if !stream.isNotPlayable { armExternalPlayerTimeoutIfNeeded(player: player) }
            if self.startupBenchmarkToken == startupToken {
                self.startupBenchmarkToken = nil
            }
            let resumePos = pendingStreamPickerResumePosition
            pendingStreamPickerResumePosition = nil
            dispatchPlayback(
                preURL.absoluteString,
                stream.httpHeaders ?? [:],
                meta,
                pendingEpisodeSubtitle.isEmpty ? preResolvedEpisodeSubtitle : pendingEpisodeSubtitle,
                stream.subtitles,
                pendingEpisode ?? preResolvedEpisode,
                orderedEpisodes(for: meta),
                player,
                PlaybackCacheFileIdentity(infoHash: stream.effectiveInfoHash, fileIndex: stream.effectiveFileIdx),
                preResolvedFilename ?? stream.filename,
                preResolvedVideoSize ?? stream.videoSize,
                stream.videoHash,
                resumePos,
                startupToken,
                stream.id,
                stream.isNotPlayable
            )
            return
        }

        guard stream.isDebridResolvable, !isResolvingDebrid else {
            isPreparingPlayback = false
            isSmartPlaybackPending = false
            return
        }
        let season = pendingEpisode?.season
        let episode = pendingEpisode?.episode
        isResolvingDebrid = true
        isPreparingPlayback = true
        Task {
            let debridResolver = DebridResolver(store: ProfileSettings.current)
            var resolvedURL: URL? = nil
            var debridFilename: String? = nil
            var debridVideoSize: Int64? = nil
            var rateLimited = false
            if debridResolver.isEnabled {
                let result = await debridResolver
                    .resolvedURL(for: stream, season: season, episode: episode)
                if case let .success(url, filename, videoSize)? = result {
                    resolvedURL = url
                    debridFilename = filename
                    debridVideoSize = videoSize
                } else if case .rateLimited? = result {
                    rateLimited = true
                }
            }

            if resolvedURL == nil, TorrentSettings.isEnabled(), let infoHash = stream.effectiveInfoHash, !infoHash.isEmpty {
                do {
                    resolvedURL = try await TorrentEngineManager.shared.startStream(
                        infoHash: infoHash,
                        fileIdx: stream.effectiveFileIdx,
                        trackers: stream.sources,
                        filename: stream.filename
                    )
                } catch {
                    print("[DetailsScreen] Torrent stream start failed: \(error)")
                }
            }

            await MainActor.run {
                guard PlaybackStartupTiming.isActive(token: startupToken) else { return }
                isResolvingDebrid = false
                if let url = resolvedURL {
                    PlaybackStartupTiming.markDebridResolved(token: startupToken)
                    isStreamPickerPresented = false
                    isPreparingPlayback = true
                    isSmartPlaybackPending = false
                    if !stream.isNotPlayable { armExternalPlayerTimeoutIfNeeded(player: player) }
                    if self.startupBenchmarkToken == startupToken {
                        self.startupBenchmarkToken = nil
                    }
                    let resumePos = pendingStreamPickerResumePosition
                    pendingStreamPickerResumePosition = nil
                    dispatchPlayback(
                        url.absoluteString,
                        stream.httpHeaders ?? [:],
                        meta,
                        pendingEpisodeSubtitle,
                        stream.subtitles,
                        pendingEpisode,
                        orderedEpisodes(for: meta),
                        player,
                        nil,
                        debridFilename ?? stream.filename,
                        debridVideoSize ?? stream.videoSize,
                        stream.videoHash,
                        resumePos,
                        startupToken,
                        stream.id,
                        stream.isNotPlayable
                    )
                } else {
                    cancelStartupRequest(token: startupToken)
                    isPreparingPlayback = false
                    isSmartPlaybackPending = false
                    isStreamPickerPresented = true
                    if rateLimited {
                        print("[DetailsScreen] Debrid provider rate limit reached (HTTP 429).")
                    }
                }
            }
        }
    }

    private func armExternalPlayerTimeoutIfNeeded(player: ExternalPlayer?) {
        let store = ProfileSettings.current
        let defaultPlayer = ExternalPlayer.from(store.string(forKey: SettingsKey.externalPlayer))
        let effectivePlayer = player ?? defaultPlayer
        if effectivePlayer != .builtIn {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                isPreparingPlayback = false
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

    private func openTrailer(for meta: NuvioMeta, resumeFrom: Double? = nil) {
        Task {
            if let source = await YouTubeTrailerResolver.shared.resolve(for: meta) {
                await MainActor.run {
                    dispatchPlayback(source.videoUrl, source.requestHeaders, meta, PlaybackMarkers.trailerSubtitle, [], nil, [], nil, nil, nil, nil, nil, resumeFrom, nil, nil, false)
                }
            } else if let ytId = await preferredTrailerYouTubeId(for: meta) {
                let youtubeUrl = "https://www.youtube.com/watch?v=\(ytId)"
                await MainActor.run {
                    dispatchPlayback(youtubeUrl, [:], meta, PlaybackMarkers.trailerSubtitle, [], nil, [], nil, nil, nil, nil, nil, resumeFrom, nil, nil, false)
                }
            }
        }
    }

    private func preferredTrailerYouTubeId(for meta: NuvioMeta) async -> String? {
        await YouTubeTrailerResolver.preferredTrailerYouTubeId(for: meta)
    }
}

actor YouTubeTrailerResolver {
    static let shared = YouTubeTrailerResolver()
    private var trailerIdCache: [String: String] = [:]
    private var trailerIdFailureDates: [String: Date] = [:]
    private var trailerioCache: [String: TrailerPlaybackSource] = [:]

    private let preferredLanguageProvider: () -> String
    private let configurationIdentityProvider: () -> String
    private let trailerYouTubeIdProvider: ((NuvioMeta) async -> String?)?
    private let refreshedTrailerIdsProvider: ((NuvioMeta) async -> [String]?)?
    private let trailerioProvider: ((String, Bool) async -> TrailerPlaybackSource?)?
    private let youtubeSourceProvider: ((String, String?, String?, Bool) async -> TrailerPlaybackSource?)?

    init(
        preferredLanguageProvider: @escaping () -> String = { TmdbDetailsService.preferredLanguage },
        configurationIdentityProvider: @escaping () -> String = { TmdbDetailsService.trailerResolutionConfigurationIdentity },
        trailerYouTubeIdProvider: ((NuvioMeta) async -> String?)? = nil,
        refreshedTrailerIdsProvider: ((NuvioMeta) async -> [String]?)? = nil,
        trailerioProvider: ((String, Bool) async -> TrailerPlaybackSource?)? = nil,
        youtubeSourceProvider: ((String, String?, String?, Bool) async -> TrailerPlaybackSource?)? = nil
    ) {
        self.preferredLanguageProvider = preferredLanguageProvider
        self.configurationIdentityProvider = configurationIdentityProvider
        self.trailerYouTubeIdProvider = trailerYouTubeIdProvider
        self.refreshedTrailerIdsProvider = refreshedTrailerIdsProvider
        self.trailerioProvider = trailerioProvider
        self.youtubeSourceProvider = youtubeSourceProvider
    }

    private struct TrailerioResponse: Decodable {
        struct Meta: Decodable {
            struct Link: Decodable {
                let trailers: String?
                let provider: String?
            }
            let id: String?
            let links: [Link]?
        }
        let meta: Meta?
    }

    private func scoreTrailerioLink(_ provider: String, url: String) -> Int {
        let p = provider.lowercased()
        var score = 0
        if p.contains("apple tv") {
            score += 1000
        } else if p.contains("rotten tomatoes") || p.contains("fandango") {
            score += 800
        } else if p.contains("plex") {
            score += 700
        } else if p.contains("mubi") {
            score += 500
        } else if p.contains("imdb") {
            score += 300
        }

        if p.contains("4k") || p.contains("2160p") {
            score += 400
        } else if p.contains("1080p") {
            score += 300
        } else if p.contains("720p") {
            score += 200
        }

        if p.contains("atmos") || p.contains("5.1") {
            score += 50
        }

        let u = url.lowercased()
        if u.contains(".m3u8") || u.contains(".mp4") {
            score += 100
        }

        return score
    }

    func resolveTrailerio(imdbId: String, isSeries: Bool) async -> TrailerPlaybackSource? {
        let cleanImdb = NuvioMeta.canonicalImdbID(from: imdbId) ?? imdbId
        guard cleanImdb.hasPrefix("tt") else { return nil }

        if let cached = trailerioCache[cleanImdb] {
            return cached
        }

        let mediaType = isSeries ? "series" : "movie"
        guard let url = URL(string: "https://trailerio.cc/meta/\(mediaType)/\(cleanImdb).json") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.setValue("NuvioTV/1.0", forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let decoded = try? JSONDecoder().decode(TrailerioResponse.self, from: data),
              let links = decoded.meta?.links, !links.isEmpty else {
            return nil
        }

        let validLinks = links.compactMap { link -> (url: String, provider: String)? in
            guard let rawUrl = link.trailers?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawUrl.isEmpty,
                  rawUrl.hasPrefix("http://") || rawUrl.hasPrefix("https://") else {
                return nil
            }
            return (url: rawUrl, provider: link.provider ?? "1080p")
        }

        guard !validLinks.isEmpty else { return nil }

        let sorted = validLinks.sorted { scoreTrailerioLink($0.provider, url: $0.url) > scoreTrailerioLink($1.provider, url: $1.url) }
        guard let best = sorted.first else { return nil }

        let source = TrailerPlaybackSource(
            videoUrl: best.url,
            audioUrl: nil,
            requestHeaders: [:],
            qualityLabel: best.provider,
            diagnostics: "TRAILER: \(best.provider) [Trailerio 1080p]"
        )
        trailerioCache[cleanImdb] = source
        return source
    }

    func resolve(for meta: NuvioMeta) async -> TrailerPlaybackSource? {
        await TmdbDetailsService.withRequestContext {
            await self.resolveForCurrentContext(meta, preview: false)
        }
    }

    func resolvePreview(for meta: NuvioMeta) async -> TrailerPlaybackSource? {
        await TmdbDetailsService.withRequestContext {
            await self.resolveForCurrentContext(meta, preview: true)
        }
    }

    static func preferredTrailerYouTubeId(for meta: NuvioMeta) async -> String? {
        await shared.preferredTrailerYouTubeId(for: meta)
    }

    func preferredTrailerYouTubeId(for meta: NuvioMeta) async -> String? {
        await TmdbDetailsService.withRequestContext {
            await self.preferredTrailerYouTubeIdInCurrentContext(for: meta)
        }
    }

    private func preferredTrailerYouTubeIdInCurrentContext(for meta: NuvioMeta) async -> String? {
        let mediaType = meta.isSeries ? "tv" : "movie"
        let language = TmdbMetadataLanguage.normalized(preferredLanguageProvider())
        let cacheKey = [
            meta.id,
            String(meta.tmdbId ?? 0),
            mediaType,
            language,
            configurationIdentityProvider()
        ].joined(separator: "|")
        if let cached = trailerIdCache[cacheKey] {
            if !cached.isEmpty { return cached }
            if let failedAt = trailerIdFailureDates[cacheKey],
               Date().timeIntervalSince(failedAt) < 300 {
                return nil
            }
            trailerIdCache.removeValue(forKey: cacheKey)
            trailerIdFailureDates.removeValue(forKey: cacheKey)
        }

        var resolvedId: String? = nil

        // TMDB applies the selected metadata language and its own English
        // fallback, so prefer it to untagged catalog trailer IDs.
        let tmdbTrailerId: String?
        if let trailerYouTubeIdProvider {
            tmdbTrailerId = await trailerYouTubeIdProvider(meta)
        } else {
            tmdbTrailerId = await TmdbDetailsService.fetchTrailerYouTubeId(for: meta)
        }
        if let ytId = tmdbTrailerId,
           Self.isYouTubeVideoId(ytId.trimmingCharacters(in: .whitespacesAndNewlines)) {
            resolvedId = ytId.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let ytId = meta.trailerYtIds?
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { Self.isYouTubeVideoId($0) }) {
            resolvedId = ytId
        } else {
            let refreshedTrailerIds: [String]?
            if let refreshedTrailerIdsProvider {
                refreshedTrailerIds = await refreshedTrailerIdsProvider(meta)
            } else if let refreshed = try? await CinemetaCatalogRepository().getMetadata(
                id: meta.id,
                type: meta.type
            ) {
                refreshedTrailerIds = refreshed.trailerYtIds
            } else {
                refreshedTrailerIds = nil
            }
            resolvedId = refreshedTrailerIds?
                .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
                .first(where: { Self.isYouTubeVideoId($0) })
        }

        guard !Task.isCancelled else { return nil }
        // An older failed lookup must not replace a concurrent success.
        if resolvedId == nil, let cached = trailerIdCache[cacheKey], !cached.isEmpty {
            return cached
        }
        trailerIdCache[cacheKey] = resolvedId ?? ""
        if resolvedId == nil {
            trailerIdFailureDates[cacheKey] = Date()
        } else {
            trailerIdFailureDates.removeValue(forKey: cacheKey)
        }
        return resolvedId
    }

    private func resolveForCurrentContext(
        _ meta: NuvioMeta,
        preview: Bool
    ) async -> TrailerPlaybackSource? {
        let isEnglish = TmdbMetadataLanguage.normalized(preferredLanguageProvider())
            .split(separator: "-").first?.lowercased() == "en"

        if isEnglish, let source = await resolveTrailerio(for: meta) {
            return source
        }

        if let ytId = await preferredTrailerYouTubeIdInCurrentContext(for: meta) {
            let source: TrailerPlaybackSource?
            if let youtubeSourceProvider {
                source = await youtubeSourceProvider(
                    ytId,
                    meta.name,
                    meta.year.map(String.init),
                    preview
                )
            } else if preview {
                source = await resolvePreview(
                    youtubeVideoId: ytId,
                    title: meta.name,
                    year: meta.year.map(String.init)
                )
            } else {
                source = await resolve(
                    youtubeVideoId: ytId,
                    title: meta.name,
                    year: meta.year.map(String.init)
                )
            }
            if let source { return source }
        }

        // The YouTube ID may be present while its stream is unavailable. Keep
        // Trailerio as a fallback for both language paths in that case.
        return isEnglish ? nil : await resolveTrailerio(for: meta)
    }

    private func resolveTrailerio(for meta: NuvioMeta) async -> TrailerPlaybackSource? {
        guard let imdbId = meta.imdbId ?? NuvioMeta.canonicalImdbID(from: meta.id) else {
            return nil
        }
        if let trailerioProvider {
            return await trailerioProvider(imdbId, meta.isSeries)
        }
        return await resolveTrailerio(imdbId: imdbId, isSeries: meta.isSeries)
    }
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
        let clientKey: String
        let height: Int
        let bandwidth: Int
        let priority: Int
    }

    private struct TrailerBackendResponse: Decodable {
        let url: String?
        let videoUrl: String?
        let streamUrl: String?
        let hls: String?
        let hlsUrl: String?
        let quality: String?
        let resolution: String?

        var effectiveUrl: String? {
            url ?? videoUrl ?? streamUrl ?? hls ?? hlsUrl
        }
    }

    private static let defaultUserAgent =
        "Mozilla/5.0 (AppleTV; CPU OS 17_0 like Mac OS X) AppleWebKit/605.1.15 " +
        "(KHTML, like Gecko) Version/17.0 Safari/605.1.15"
    private static let fallbackApiKey = "AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8"
    private static let configTTL: TimeInterval = 3 * 60 * 60
    private static let resolverBaseKey = "nuvio.tv.settings.playback.trailerResolverBaseURL"
    private static let embeddedPlayerOrigin = "https://nuvioapp.space/"
    private static let probeTimeout: TimeInterval = 3
    private static let attemptBudget: TimeInterval = 12

    private static let clients: [Client] = [
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
            priority: 2
        )
    ]

    private var cachedConfig: WatchConfig?
    private var previewCache: [String: (source: TrailerPlaybackSource, date: Date)] = [:]
    private var probeResults: [String: Bool] = [:]
    private enum AttemptContext {
        @TaskLocal static var startedAt: Date?
    }
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.httpAdditionalHeaders = [
            "Accept-Language": "en-US,en;q=0.9"
        ]
        return URLSession(configuration: configuration)
    }()

    private let probeSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 3
        return URLSession(configuration: configuration)
    }()

    func resolve(youtubeVideoId: String, title: String?, year: String?) async -> TrailerPlaybackSource? {
        guard Self.isYouTubeVideoId(youtubeVideoId) else { return nil }

        let youtubeUrl = "https://www.youtube.com/watch?v=\(youtubeVideoId)"
        if let source = await resolveWithBackend(
            videoId: youtubeVideoId,
            youtubeUrl: youtubeUrl,
            title: title,
            year: year
        ) {
            return source
        }

        // Full player supports 1080p adaptive video + audio pairs as well as HLS
        if let source = await resolveWithInnertube(
            videoId: youtubeVideoId,
            forceRefreshConfig: false,
            preferIntegratedStream: false
        ) {
            return source
        }

        guard !Task.isCancelled else { return nil }
        cachedConfig = nil

        // Retry with refreshed config
        if let source = await resolveWithInnertube(
            videoId: youtubeVideoId,
            forceRefreshConfig: true,
            preferIntegratedStream: false
        ) {
            return source
        }

        return nil
    }

    /// Returns an integrated preview stream and the headers required by its
    /// originating YouTube client.
    func resolvePreview(youtubeVideoId: String, title: String?, year: String?) async -> TrailerPlaybackSource? {
        guard Self.isYouTubeVideoId(youtubeVideoId) else { return nil }

        if let cached = previewCache[youtubeVideoId], Date().timeIntervalSince(cached.date) < 1800 {
            return cached.source
        }

        let youtubeUrl = "https://www.youtube.com/watch?v=\(youtubeVideoId)"
        if let source = await resolveWithBackend(
            videoId: youtubeVideoId,
            youtubeUrl: youtubeUrl,
            title: title,
            year: year
        ) {
            previewCache[youtubeVideoId] = (source, Date())
            return source
        }

        if let source = await resolveWithInnertube(
            videoId: youtubeVideoId,
            forceRefreshConfig: false,
            preferIntegratedStream: true
        ) {
            previewCache[youtubeVideoId] = (source, Date())
            return source
        }

        guard !Task.isCancelled else { return nil }
        cachedConfig = nil
        if let source = await resolveWithInnertube(
            videoId: youtubeVideoId,
            forceRefreshConfig: true,
            preferIntegratedStream: true
        ) {
            previewCache[youtubeVideoId] = (source, Date())
            return source
        }

        return nil
    }

    private func resolveWithInnertube(
        videoId: String,
        forceRefreshConfig: Bool,
        preferIntegratedStream: Bool = false
    ) async -> TrailerPlaybackSource? {
        await AttemptContext.$startedAt.withValue(Date()) {
            await resolveInnertubeAttempt(
                videoId: videoId,
                forceRefreshConfig: forceRefreshConfig,
                preferIntegratedStream: preferIntegratedStream
            )
        }
    }

    private func resolveInnertubeAttempt(
        videoId: String,
        forceRefreshConfig: Bool,
        preferIntegratedStream: Bool
    ) async -> TrailerPlaybackSource? {
        guard !Task.isCancelled else { return nil }
        probeResults.removeAll(keepingCapacity: true)
        guard let config = try? await watchConfig(forceRefresh: forceRefreshConfig),
              canContinueAttempt else { return nil }
        var hlsCandidates: [HlsCandidate] = []
        var progressive: [StreamCandidate] = []
        var adaptiveVideo: [StreamCandidate] = []
        var adaptiveAudio: [StreamCandidate] = []

        for client in Self.clients {
            guard canContinueAttempt else { return nil }
            guard let playerResponse = try? await fetchPlayerResponse(
                apiKey: config.apiKey,
                videoId: videoId,
                client: client,
                visitorData: config.visitorData
            ) else {
                guard canContinueAttempt else { return nil }
                continue
            }
            guard canContinueAttempt else { return nil }

            if let status = stringValue(mapValue(playerResponse, key: "playabilityStatus"), key: "status"),
               status != "OK" {
                continue
            }

            guard let streamingData = mapValue(playerResponse, key: "streamingData") else { continue }

            if let manifestUrl = stringValue(streamingData, key: "hlsManifestUrl") {
                do {
                    let candidate = try await hlsCandidate(
                        manifestUrl: manifestUrl,
                        client: client,
                        includeReferer: false
                    )
                    hlsCandidates.append(candidate)
                } catch {
                }
            }
            guard canContinueAttempt else { return nil }

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

        let sortedHLS = hlsCandidates.sorted(by: sortHlsCandidates)
        let sortedAdaptiveVideo = adaptiveVideo.sorted(by: sortStreamCandidates)
        let sortedAdaptiveAudio = adaptiveAudio.sorted(by: sortStreamCandidates)
        let sortedProgressive = progressive.filter { $0.height > 0 }.sorted(by: sortStreamCandidates)

        var summaryParts: [String] = []
        let hlsDesc = sortedHLS.map { "\($0.clientKey):\($0.height)p" }.joined(separator: ", ")
        if !hlsDesc.isEmpty { summaryParts.append("HLS[\(hlsDesc)]") }
        let progDesc = sortedProgressive.map { "\($0.clientKey):\($0.height)p" }.joined(separator: ", ")
        if !progDesc.isEmpty { summaryParts.append("Prog[\(progDesc)]") }
        let adaptDesc = sortedAdaptiveVideo.prefix(6).map { "\($0.clientKey):\($0.height)p" }.joined(separator: ", ")
        if !adaptDesc.isEmpty { summaryParts.append("Adaptive[\(adaptDesc)]") }
        let availableSummary = summaryParts.joined(separator: " | ")

        let unthrottledAdaptiveVideo = sortedAdaptiveVideo
        let unthrottledAdaptiveAudio = sortedAdaptiveAudio

        // 1. Prioritize HD HLS master manifest (1080p / 720p).
        // HLS contains video+audio natively, decoded by AetherEngine / AVPlayer in full 1080p HD with zero 403 errors.
        if let bestHls = sortedHLS.first, bestHls.height >= 720 {
            let label = "\(bestHls.height)p (HLS)"
            let diag = "TRAILER: \(label) [\(bestHls.clientKey)] | Available: \(availableSummary)"
            return TrailerPlaybackSource(
                videoUrl: bestHls.manifestUrl,
                audioUrl: nil,
                requestHeaders: requestHeaders(
                    for: bestHls.clientKey,
                    includeReferer: false
                ),
                qualityLabel: label,
                diagnostics: diag
            )
        }

        // 2. Check for HD progressive streams (1080p / 720p muxed MP4)
        if let bestProg = await firstReachable(
            sortedProgressive.filter { $0.height >= 720 },
            includeReferer: false
        ) {
            let label = "\(bestProg.height)p (MP4)"
            let diag = "TRAILER: \(label) [\(bestProg.clientKey)] | Available: \(availableSummary)"
            return TrailerPlaybackSource(
                videoUrl: bestProg.url,
                audioUrl: nil,
                requestHeaders: requestHeaders(
                    for: bestProg.clientKey,
                    includeReferer: false
                ),
                qualityLabel: label,
                diagnostics: diag
            )
        }

        // 3. For full player: Check for 1080p+ unthrottled adaptive pair
        if !preferIntegratedStream,
           let pair = await firstReachableAdaptivePair(
               videos: unthrottledAdaptiveVideo.filter { $0.height >= 1080 },
               audios: unthrottledAdaptiveAudio,
               includeReferer: false
           ) {
            let label = "\(pair.video.height)p (Adaptive)"
            let diag = "TRAILER: \(label) [\(pair.video.clientKey)] | Available: \(availableSummary)"
            return TrailerPlaybackSource(
                videoUrl: pair.video.url,
                audioUrl: pair.audio.url,
                requestHeaders: requestHeaders(
                    for: pair.video.clientKey,
                    includeReferer: false
                ),
                qualityLabel: label,
                diagnostics: diag
            )
        }

        // 4. For full player: Check for 720p unthrottled adaptive pair
        if !preferIntegratedStream,
           let pair = await firstReachableAdaptivePair(
               videos: unthrottledAdaptiveVideo.filter { $0.height >= 720 },
               audios: unthrottledAdaptiveAudio,
               includeReferer: false
           ) {
            let label = "\(pair.video.height)p (Adaptive)"
            let diag = "TRAILER: \(label) [\(pair.video.clientKey)] | Available: \(availableSummary)"
            return TrailerPlaybackSource(
                videoUrl: pair.video.url,
                audioUrl: pair.audio.url,
                requestHeaders: requestHeaders(
                    for: pair.video.clientKey,
                    includeReferer: false
                ),
                qualityLabel: label,
                diagnostics: diag
            )
        }

        // 5. Fall back to any HLS stream (often contains 1080p/720p variants)
        if let bestHls = sortedHLS.first {
            let label = "\(bestHls.height > 0 ? "\(bestHls.height)p" : "Adaptive") (HLS)"
            let diag = "TRAILER: \(label) [\(bestHls.clientKey)] | Available: \(availableSummary)"
            return TrailerPlaybackSource(
                videoUrl: bestHls.manifestUrl,
                audioUrl: nil,
                requestHeaders: requestHeaders(
                    for: bestHls.clientKey,
                    includeReferer: false
                ),
                qualityLabel: label,
                diagnostics: diag
            )
        }

        // 6. Fall back to standard progressive (e.g. 360p)
        if let progressiveMatch = await firstReachable(
            sortedProgressive,
            includeReferer: false
        ) {
            let label = "\(progressiveMatch.height)p (MP4)"
            let diag = "TRAILER: \(label) [\(progressiveMatch.clientKey)] fallback | Available: \(availableSummary)"
            return TrailerPlaybackSource(
                videoUrl: progressiveMatch.url,
                audioUrl: nil,
                requestHeaders: requestHeaders(
                    for: progressiveMatch.clientKey,
                    includeReferer: false
                ),
                qualityLabel: label,
                diagnostics: diag
            )
        }

        // 7. For preview: fall back to best adaptive video if no integrated stream exists.
        // On Apple TV, card previews are muted by default and play the video track directly.
        if preferIntegratedStream,
           let bestAdaptive = await firstReachable(
               sortedAdaptiveVideo,
               includeReferer: false
           ) {
            let label = "\(bestAdaptive.height)p (Adaptive Video)"
            let diag = "TRAILER: \(label) [\(bestAdaptive.clientKey)] preview | Available: \(availableSummary)"
            return TrailerPlaybackSource(
                videoUrl: bestAdaptive.url,
                audioUrl: nil,
                requestHeaders: requestHeaders(
                    for: bestAdaptive.clientKey,
                    includeReferer: false
                ),
                qualityLabel: label,
                diagnostics: diag
            )
        }

        // 8. For full player: Fall back to any adaptive pair
        if !preferIntegratedStream,
           let pair = await firstReachableAdaptivePair(
               videos: unthrottledAdaptiveVideo,
               audios: unthrottledAdaptiveAudio,
               includeReferer: false
           ) {
            let label = "\(pair.video.height)p (Adaptive)"
            let diag = "TRAILER: \(label) [\(pair.video.clientKey)] fallback | Available: \(availableSummary)"
            return TrailerPlaybackSource(
                videoUrl: pair.video.url,
                audioUrl: pair.audio.url,
                requestHeaders: requestHeaders(
                    for: pair.video.clientKey,
                    includeReferer: false
                ),
                qualityLabel: label,
                diagnostics: diag
            )
        }

        return nil
    }

    private func watchConfig(forceRefresh: Bool) async throws -> WatchConfig {
        if !forceRefresh,
           let cachedConfig,
           Date().timeIntervalSince(cachedConfig.fetchedAt) < Self.configTTL {
            return cachedConfig
        }

        // Return the reliable fallback Innertube API key directly.
        // Web scraping youtube.com/watch triggers 302 captcha/bot challenges that fail or stall on tvOS.
        let config = WatchConfig(
            apiKey: Self.fallbackApiKey,
            visitorData: nil,
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

        let context = client.context
        var requestContext: [String: Any] = ["client": context]
        if client.key == "web_embedded_player" || client.key == "tv_embedded" {
            requestContext["thirdParty"] = [
                "embedUrl": "https://www.youtube.com/embed/\(videoId)"
            ]
        }

        let payload: [String: Any] = [
            "videoId": videoId,
            "contentCheckOk": true,
            "racyCheckOk": true,
            "context": requestContext,
            "playbackContext": [
                "contentPlaybackContext": ["html5Preference": "HTML5_PREF_WANTS"]
            ]
        ]

        var request = URLRequest(url: url)
        guard let timeout = requestTimeout(cap: 8) else { throw CancellationError() }
        request.timeoutInterval = timeout
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        addDefaultHeaders(to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        if client.key == "web_embedded_player" || client.key == "tv_embedded" {
            request.setValue("https://www.youtube.com/embed/\(videoId)", forHTTPHeaderField: "Referer")
        }
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

    private func hlsCandidate(
        manifestUrl: String,
        client: Client,
        includeReferer: Bool
    ) async throws -> HlsCandidate {
        guard let url = URL(string: manifestUrl) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        guard let timeout = requestTimeout(cap: 6) else { throw CancellationError() }
        request.timeoutInterval = timeout
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
            clientKey: client.key,
            height: 0,
            bandwidth: 0,
            priority: client.priority
        )
        for index in lines.indices {
            let line = lines[index]
            guard line.hasPrefix("#EXT-X-STREAM-INF:"),
                  index + 1 < lines.count,
                  !lines[index + 1].hasPrefix("#") else {
                continue
            }

            let attrs = parseHlsAttributeList(line)
            let (_, height) = parseResolution(attrs["RESOLUTION"] ?? "")
            let bandwidth = Int(attrs["BANDWIDTH"] ?? "") ?? 0

            if height > best.height ||
                (height == best.height && bandwidth > best.bandwidth) {
                best = HlsCandidate(
                    manifestUrl: manifestUrl,
                    clientKey: client.key,
                    height: height,
                    bandwidth: bandwidth,
                    priority: client.priority
                )
            }
        }

        if best.height == 0 && text.contains("#EXTM3U") {
            best = HlsCandidate(
                manifestUrl: manifestUrl,
                clientKey: client.key,
                height: 1080,
                bandwidth: 5_000_000,
                priority: client.priority
            )
        }

        return best
    }

    private func resolveWithBackend(
        videoId: String,
        youtubeUrl: String,
        title: String?,
        year: String?
    ) async -> TrailerPlaybackSource? {
        guard let baseUrl = configuredBackendBaseURL() else { return nil }
        let endpoint = baseUrl.lastPathComponent == "trailer" ? baseUrl : baseUrl.appendingPathComponent("trailer")
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else { return nil }

        components.queryItems = [
            URLQueryItem(name: "videoId", value: videoId),
            URLQueryItem(name: "youtube_url", value: youtubeUrl),
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "year", value: year)
        ].filter { $0.value != nil }

        guard let url = components.url else { return nil }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 6
            addDefaultHeaders(to: &request)
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
                return nil
            }
            let decoded = try JSONDecoder().decode(TrailerBackendResponse.self, from: data)
            guard let resolved = decoded.effectiveUrl,
                  resolved.hasPrefix("http://") || resolved.hasPrefix("https://") else {
                return nil
            }
            let label = decoded.quality ?? decoded.resolution ?? "1080p (Proxy)"
            let diag = "TRAILER: \(label) [backend proxy]"
            return TrailerPlaybackSource(
                videoUrl: resolved,
                audioUrl: nil,
                qualityLabel: label,
                diagnostics: diag
            )
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

    private func requestHeaders(for clientKey: String, includeReferer: Bool) -> [String: String] {
        guard let client = Self.clients.first(where: { $0.key == clientKey }) else {
            return ["User-Agent": Self.defaultUserAgent]
        }
        var headers = ["User-Agent": client.userAgent]
        if includeReferer {
            headers["Referer"] = client.key == "web_embedded_player"
                ? Self.embeddedPlayerOrigin
                : "https://www.youtube.com/"
        }
        return headers
    }

    private func addStreamHeaders(
        to request: inout URLRequest,
        client: Client,
        includeReferer: Bool
    ) {
        request.setValue(client.userAgent, forHTTPHeaderField: "User-Agent")
        if includeReferer {
            request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
            request.setValue(
                client.key == "web_embedded_player"
                    ? Self.embeddedPlayerOrigin
                    : "https://www.youtube.com/",
                forHTTPHeaderField: "Referer"
            )
        }
    }

    private func firstReachable(
        _ candidates: [StreamCandidate],
        includeReferer: Bool
    ) async -> StreamCandidate? {
        // Keep probing sequential and bounded: each candidate is an actual
        // network request, and a signed URL can fail independently of its API
        // response.
        for candidate in candidates.prefix(8) {
            guard canContinueAttempt else { return nil }
            if await isReachable(
                candidate.url,
                clientKey: candidate.clientKey,
                includeReferer: includeReferer
            ) {
                return candidate
            }
        }
        return nil
    }

    private func firstReachableAdaptivePair(
        videos: [StreamCandidate],
        audios: [StreamCandidate],
        includeReferer: Bool
    ) async -> (video: StreamCandidate, audio: StreamCandidate)? {
        var pairs: [(video: StreamCandidate, audio: StreamCandidate)] = []
        for video in videos.prefix(8) {
            guard canContinueAttempt else { return nil }
            let sameClient = audios.filter { $0.clientKey == video.clientKey }
            for audio in sameClient.prefix(3) {
                pairs.append((video: video, audio: audio))
            }
        }

        for pair in pairs.prefix(12) {
            guard canContinueAttempt else { return nil }
            guard await isReachable(
                pair.video.url,
                clientKey: pair.video.clientKey,
                includeReferer: includeReferer
            ) else {
                continue
            }
            guard await isReachable(
                pair.audio.url,
                clientKey: pair.audio.clientKey,
                includeReferer: includeReferer
            ) else {
                continue
            }
            return pair
        }
        return nil
    }

    private func isReachable(
        _ streamUrl: String,
        clientKey: String,
        includeReferer: Bool
    ) async -> Bool {
        guard canContinueAttempt else { return false }
        if let cached = probeResults[streamUrl] {
            return cached
        }
        guard let url = URL(string: streamUrl),
              let client = Self.clients.first(where: { $0.key == clientKey }) else {
            probeResults[streamUrl] = false
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        guard let timeout = requestTimeout(cap: Self.probeTimeout) else { return false }
        request.timeoutInterval = timeout
        request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
        addStreamHeaders(to: &request, client: client, includeReferer: includeReferer)
        do {
            let (bytes, response) = try await probeSession.bytes(for: request)
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 206,
                  let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
                  contentRange.hasPrefix("bytes 0-") else {
                probeResults[streamUrl] = false
                return false
            }
            // Touch only the first bounded response chunk. `bytes(for:)`
            // avoids buffering a server that ignores the requested range.
            var iterator = bytes.makeAsyncIterator()
            guard (try await iterator.next()) != nil, canContinueAttempt else {
                probeResults[streamUrl] = false
                return false
            }
            let reachable = true
            probeResults[streamUrl] = reachable
            return reachable
        } catch {
            probeResults[streamUrl] = false
            return false
        }
    }

    private var attemptBudgetExceeded: Bool {
        guard let attemptStartedAt = AttemptContext.startedAt else { return false }
        return Date().timeIntervalSince(attemptStartedAt) >= Self.attemptBudget
    }

    private var canContinueAttempt: Bool {
        !Task.isCancelled && !attemptBudgetExceeded
    }

    private func requestTimeout(cap: TimeInterval) -> TimeInterval? {
        guard canContinueAttempt else { return nil }
        guard let attemptStartedAt = AttemptContext.startedAt else { return cap }
        let remaining = Self.attemptBudget - Date().timeIntervalSince(attemptStartedAt)
        guard remaining > 0 else { return nil }
        return min(cap, remaining)
    }

    private func sortHlsCandidates(_ lhs: HlsCandidate, _ rhs: HlsCandidate) -> Bool {
        if lhs.height != rhs.height { return lhs.height > rhs.height }
        if lhs.bandwidth != rhs.bandwidth { return lhs.bandwidth > rhs.bandwidth }
        return lhs.priority < rhs.priority
    }

    private func sortStreamCandidates(_ lhs: StreamCandidate, _ rhs: StreamCandidate) -> Bool {
        let lhsTier = lhs.height >= 1080 ? (lhs.height >= 2160 ? 2160 : (lhs.height >= 1440 ? 1440 : 1080)) : lhs.height
        let rhsTier = rhs.height >= 1080 ? (rhs.height >= 2160 ? 2160 : (rhs.height >= 1440 ? 1440 : 1080)) : rhs.height
        if lhsTier != rhsTier { return lhsTier > rhsTier }
        if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
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

    static func isYouTubeVideoId(_ value: String) -> Bool {
        value.count == 11 && value.allSatisfy { char in
            char.isLetter || char.isNumber || char == "_" || char == "-"
        }
    }
}

enum SmartPlaybackSelector {
    /// Cached-only is a VOD preference. Live and sports catalogs often have
    /// no cache markers. Keep the legacy `tv` alias local to this policy instead
    /// of changing shared type classification used by series handling.
    static func effectiveCachedOnly(_ preference: Bool, contentType: String) -> Bool {
        let normalizedType = contentType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return preference
            && normalizedType != "tv"
            && !CinemetaCatalogRepository.isLiveContentType(normalizedType)
    }

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
            guard stream.unavailabilityReason == nil else { return nil }
            guard !stream.isNotPlayable else { return nil }
            if let url = stream.directURL?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty {
                return (index, stream)
            }
            // Torrent-only streams are candidates when either Debrid or the
            // embedded P2P engine can turn them into a playable URL.
            if includeDebrid, stream.isDebridResolvable { return (index, stream) }
            return nil
        }
        let compatible = playable.filter { isPlatformPlaybackCompatible($0.stream) }
        var candidates = compatible.filter { !isPromotionalStream($0.stream) }
        if candidates.isEmpty { candidates = compatible }
        if cachedOnly {
            candidates = candidates.filter { $0.stream.isLikelyCached }
        }

        // Strictly exclude ticket / N/A / 0-resolution streams whenever valid >= 720p streams exist.
        let validCandidates = candidates.filter { item in
            let tags = StreamQualityTags.parse(stream: item.stream)
            let res = tags.resolution > 0 ? tags.resolution : inferredResolution(for: item.stream)
            return !isLowQualityOrTicketStream(item.stream) && res >= 720
        }
        let candidatePool = validCandidates.isEmpty ? candidates : validCandidates

        let preferHardware = ProfileSettings.current.object(forKey: SettingsKey.preferHardwareDecodedStreams) as? Bool ?? true

        let ranked = candidatePool.map { index, stream -> (index: Int, stream: NuvioStream, score: Int) in
            let tags = StreamQualityTags.parse(stream: stream)
            let resolution = tags.resolution > 0 ? tags.resolution : inferredResolution(for: stream)
            let subtitleScore = shouldMatchSubtitles ? subtitleScore(in: stream, languages: subtitleLanguages) : 0
            let qualityScore = score(resolution: resolution, preference: qualityPreference)
            let featureScore = featureBoost(tags: tags, preference: qualityPreference)
            let resumeScore = preferredTags.map { tags.matchScore(against: $0) } ?? 0
            let cachedBoost = (stream.isLikelyCached || tags.isCached) ? 15_000 : 0
            let lowQualityPenalty: Int = {
                if isLowQualityOrTicketStream(stream) || resolution == 0 {
                    return -300_000
                }
                if resolution < 720 {
                    return -100_000
                }
                return 0
            }()
            let hardwareBoost: Int
            if preferHardware, resolution >= 2160, !AppleTVCapability.current.supportsAV1HardwareDecode {
                if tags.isHardwareAccelerated() {
                    hardwareBoost = 25_000
                } else if tags.isAV1 {
                    hardwareBoost = -25_000
                } else {
                    hardwareBoost = 0
                }
            } else {
                hardwareBoost = 0
            }
            return (index, stream, subtitleScore + qualityScore + featureScore + resumeScore + cachedBoost + lowQualityPenalty + hardwareBoost)
        }

        return ranked.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.index < rhs.index
        }.map(\.stream)
    }

    static func playableStreams(
        from streams: [NuvioStream],
        includeDebrid: Bool = false,
        cachedOnly: Bool = false,
        preserveAddonStreams: Bool = false,
        includeUnavailable: Bool = false
    ) -> [NuvioStream] {
        let playable = streams.filter { stream in
            if stream.unavailabilityReason != nil { return includeUnavailable }
            if stream.isNotPlayable { return true }
            if let url = stream.directURL?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty {
                return true
            }
            return includeDebrid && stream.isDebridResolvable
        }
        let compatible = playable.filter { $0.unavailabilityReason != nil || $0.isNotPlayable || isPlatformPlaybackCompatible($0) }
        let available = compatible.filter { $0.unavailabilityReason == nil }
        let nonPromotional = available.filter { $0.isNotPlayable || !isPromotionalStream($0) }
        let selectedAvailable = nonPromotional.isEmpty ? available : nonPromotional
        let selectedAvailableIDs = Set(selectedAvailable.map(\.id))
        // Keep notice cards in place without letting them count as promotional
        // fallback evidence or changing the selected available candidates.
        var result = compatible.filter {
            $0.unavailabilityReason != nil || selectedAvailableIDs.contains($0.id)
        }
        if cachedOnly {
            result = result.filter { $0.unavailabilityReason != nil || $0.isNotPlayable || $0.isLikelyCached }
        }
        if preserveAddonStreams {
            return result
        }
        let valid = result.filter { stream in
            guard stream.unavailabilityReason == nil else { return false }
            if stream.isNotPlayable { return true }
            let tags = StreamQualityTags.parse(stream: stream)
            let res = tags.resolution > 0 ? tags.resolution : inferredResolution(for: stream)
            return !isLowQualityOrTicketStream(stream) && res >= 720
        }
        guard !valid.isEmpty else { return result }
        let validIDs = Set(valid.map(\.id))
        return result.filter { $0.unavailabilityReason != nil || validIDs.contains($0.id) }
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

    static func isLowQualityOrTicketStream(_ stream: NuvioStream) -> Bool {
        if stream.isNotPlayable {
            return false
        }
        let res = StreamPickerListBuilder.resolution(for: stream)
        // Verified HD/UHD streams (>= 720p) are NEVER low quality or ticket streams,
        // even if add-ons like AIOStreams annotate them with the 🎫 (ticket/debrid) emoji.
        if res >= 720 {
            return false
        }
        let text = metadataSearchText(for: stream)
        if text.contains("🎫") || text.contains("[ticket]") || text.contains("ticket") || text.contains("download ticket") {
            return true
        }
        let nameLower = (stream.name ?? "").lowercased()
        if nameLower.contains("n/a") || text.contains("n/a") {
            return true
        }
        return res == 0
    }

    static func inferredResolution(for stream: NuvioStream) -> Int {
        let text = metadataSearchText(for: stream)
        return StreamQualityTags.resolution(in: text)
    }

    private static func metadataSearchText(for stream: NuvioStream) -> String {
        [stream.name, stream.description, stream.filename]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
    }

    static func score(resolution: Int, preference: String) -> Int {
        if resolution == 0 { return -200_000 }
        switch preference {
        case "4K":
            if resolution >= 2160 { return 250_000 + resolution }
            if resolution == 1440 { return 180_000 }
            if resolution == 1080 { return 150_000 }
            if resolution == 720 { return 60_000 }
            return 10_000
        case "1080p":
            if resolution == 1080 { return 250_000 }
            if resolution >= 2160 { return 180_000 }
            if resolution == 1440 { return 160_000 }
            if resolution == 720 { return 60_000 }
            return 10_000
        case "720p":
            if resolution == 720 { return 250_000 }
            if resolution == 1080 { return 150_000 }
            if resolution >= 2160 { return 80_000 }
            return 10_000
        case "Smallest":
            return resolution == 0 ? -100_000 : 200_000 - resolution
        default: // "Highest"
            return resolution >= 2160 ? 300_000 + resolution : resolution * 100
        }
    }

    private static func subtitleScore(in stream: NuvioStream, languages: [String]) -> Int {
        for (index, language) in languages.enumerated() {
            let priorityScore = max(1, 3 - index) * 3_000
            if !matchingSubtitles(in: stream, languages: [language]).isEmpty {
                return priorityScore + 4_000
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
        if isAV1LabeledStream(stream) { return false }
        #endif
        // Apple TV HD cannot hardware-decode 4K/HDR/Dolby Vision sources.
        return AppleTVCapability.current.isPlayable(
            tags: StreamQualityTags.parse(stream: stream)
        )
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

    init?(rawValueOrSync: String) {
        let upper = rawValueOrSync.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        switch upper {
        case "DEFAULT":
            self = .default
        case "QUALITY", "QUALITY_DESC":
            self = .quality
        case "SIZE", "SIZE_DESC", "SIZE_ASC":
            self = .size
        case "NAME":
            self = .name
        default:
            if let direct = StreamSortOption(rawValue: rawValueOrSync) {
                self = direct
            } else {
                return nil
            }
        }
    }
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

    /// Default page batch size for lazy-loading stream lists.
    static let defaultPageSize = 20

    /// Pure pagination slice helper.
    static func paginatedSlice(
        streams: [NuvioStream],
        limit: Int
    ) -> [NuvioStream] {
        guard limit > 0 else { return [] }
        return Array(streams.prefix(limit))
    }

    /// Check whether more streams remain beyond the currently requested limit.
    static func hasMorePages(
        totalCount: Int,
        currentLimit: Int
    ) -> Bool {
        totalCount > currentLimit
    }

    static func playableStreams(
        streams: [NuvioStream],
        groups: [AddonStreamGroup],
        selectedAddonId: String?,
        includeDebrid: Bool,
        cachedOnly: Bool = false,
        preserveAddonStreams: Bool = false
    ) -> [NuvioStream] {
        let source = sourceStreams(streams: streams, groups: groups, selectedAddonId: selectedAddonId)
        return SmartPlaybackSelector.playableStreams(
            from: source,
            includeDebrid: includeDebrid,
            cachedOnly: cachedOnly,
            preserveAddonStreams: preserveAddonStreams,
            includeUnavailable: true
        )
    }

    /// Filter + sort result shown in the picker list.
    static func displayedStreams(
        streams: [NuvioStream],
        groups: [AddonStreamGroup],
        selectedAddonId: String?,
        sortOption: StreamSortOption,
        includeDebrid: Bool,
        cachedOnly: Bool = false,
        preserveAddonStreams: Bool = false
    ) -> [NuvioStream] {
        let playable = playableStreams(
            streams: streams,
            groups: groups,
            selectedAddonId: selectedAddonId,
            includeDebrid: includeDebrid,
            cachedOnly: cachedOnly,
            preserveAddonStreams: preserveAddonStreams
        )
        return sorted(playable, by: sortOption, preserveAddonStreams: preserveAddonStreams)
    }

    /// Constant-size cache key. Repository revision captures every publication,
    /// including metadata/subtitle changes with unchanged stream ids and counts.
    static func cacheKey(
        revision: UInt64,
        selectedAddonId: String?,
        sortOption: StreamSortOption,
        includeDebrid: Bool,
        cachedOnly: Bool = false,
        preserveAddonStreams: Bool = false
    ) -> StreamPickerListCacheKey {
        StreamPickerListCacheKey(
            revision: revision,
            selectedAddonId: selectedAddonId,
            sortOption: sortOption,
            includeDebrid: includeDebrid,
            cachedOnly: cachedOnly,
            preserveAddonStreams: preserveAddonStreams
        )
    }

    /// Re-orders streams for the chosen sort matching Android TV's `DirectDebridStreamFilter.compareFacts`.
    /// `.default` preserves the add-on's own order for valid streams while sinking unknown/0-res items
    /// unless `preserveAddonStreams` is true, which strictly preserves the add-on's exact output order.
    /// `.quality` (Android's QUALITY_DESC) orders:
    ///   1. Resolution DESC (2160 > 1440 > 1080 > 720 > 576 > 480 > 360 > 0)
    ///   2. Release Quality DESC (Remux > BluRay > Web-DL > WebRip > HDRip > HD-Rip > DVDRip > HDTV > Cam/TS/TC/SCR > UNKNOWN)
    ///   3. Size bytes DESC
    ///   4. Apple TV hardware acceleration (AV1 check for 4K)
    ///   5. Stable original offset
    static func sorted(
        _ streams: [NuvioStream],
        by option: StreamSortOption,
        preserveAddonStreams: Bool = false
    ) -> [NuvioStream] {
        if preserveAddonStreams && option == .default {
            return streams
        }
        // Action / informational items remain anchored at their returned positions,
        // while playable video streams are sorted around them.
        let actionItemIndices = streams.enumerated().filter { $0.element.isNotPlayable }
        if !actionItemIndices.isEmpty {
            let playableOnly = streams.filter { !$0.isNotPlayable }
            let sortedPlayable = sortPlayableStreams(playableOnly, by: option, preserveAddonStreams: preserveAddonStreams)
            var result = sortedPlayable
            for item in actionItemIndices {
                let insertIndex = min(item.offset, result.count)
                result.insert(item.element, at: insertIndex)
            }
            return result
        }
        return sortPlayableStreams(streams, by: option, preserveAddonStreams: preserveAddonStreams)
    }

    private static func sortPlayableStreams(
        _ streams: [NuvioStream],
        by option: StreamSortOption,
        preserveAddonStreams: Bool = false
    ) -> [NuvioStream] {
        // Parse sort facts once per stream, not on every O(n log n) comparison.
        // Keep mode-specific work out of modes that do not use it.
        let needsResolution = !preserveAddonStreams || option == .quality || option == .default
        let needsHardwareCheck = option == .quality && !AppleTVCapability.current.supportsAV1HardwareDecode
        let entries = streams.enumerated().map { entry in
            let stream = entry.element
            let resolutionValue = needsResolution ? resolution(for: stream) : 0
            let isBad = (!preserveAddonStreams || option == .default)
                && (SmartPlaybackSelector.isLowQualityOrTicketStream(stream) || resolutionValue == 0)
            return (
                offset: entry.offset,
                element: stream,
                resolution: resolutionValue,
                isBad: isBad,
                quality: option == .quality ? streamQuality(for: stream) : DebridStreamQuality.unknown,
                size: option == .quality || option == .size ? sizeBytes(for: stream) : 0,
                hardwareAccelerated: needsHardwareCheck && resolutionValue >= 2160
                    ? StreamQualityTags.parse(stream: stream).isHardwareAccelerated() : false
            )
        }

        switch option {
        case .default:
            return entries.sorted {
                let bad0 = $0.isBad
                let bad1 = $1.isBad
                if bad0 != bad1 {
                    return !bad0 && bad1
                }
                return $0.offset < $1.offset
            }.map(\.element)
        case .quality:
            return entries.sorted {
                let res0 = $0.resolution
                let res1 = $1.resolution
                if !preserveAddonStreams {
                    let bad0 = $0.isBad
                    let bad1 = $1.isBad
                    if bad0 != bad1 {
                        return !bad0 && bad1
                    }
                }
                // Tier 1: Resolution DESC (Android DebridStreamSortKey.RESOLUTION)
                if res0 != res1 {
                    return res0 > res1
                }
                // Tier 2: Release Quality DESC (Android DebridStreamSortKey.QUALITY)
                let q0 = $0.quality
                let q1 = $1.quality
                if q0 != q1 {
                    return q0 > q1
                }
                // Tier 3: Size bytes DESC (Android DebridStreamSortKey.SIZE)
                let s0 = $0.size
                let s1 = $1.size
                if s0 != s1 {
                    return s0 > s1
                }
                // Tier 4: Hardware decode capability check (Apple TV AV1 decode at 4K)
                if res0 >= 2160, needsHardwareCheck {
                    let hw0 = $0.hardwareAccelerated
                    let hw1 = $1.hardwareAccelerated
                    if hw0 != hw1 {
                        return hw0 && !hw1
                    }
                }
                // Tier 5: Preserved original offset
                return $0.offset < $1.offset
            }.map(\.element)
        case .size:
            return entries.sorted {
                if !preserveAddonStreams {
                    let bad0 = $0.isBad
                    let bad1 = $1.isBad
                    if bad0 != bad1 {
                        return !bad0 && bad1
                    }
                }
                let s0 = $0.size
                let s1 = $1.size
                if s0 != s1 {
                    return s0 > s1
                }
                return $0.offset < $1.offset
            }.map(\.element)
        case .name:
            return entries.sorted {
                if !preserveAddonStreams {
                    let bad0 = $0.isBad
                    let bad1 = $1.isBad
                    if bad0 != bad1 {
                        return !bad0 && bad1
                    }
                }
                let c = ($0.element.name ?? "").localizedCaseInsensitiveCompare($1.element.name ?? "")
                if c != .orderedSame {
                    return c == .orderedAscending
                }
                return $0.offset < $1.offset
            }.map(\.element)
        }
    }

    /// Best-effort resolution parsed from a stream's release metadata (2160/1440/1080/720/576/480/360),
    /// 0 when unknown so untagged streams sink to the bottom of a Quality sort.
    static func resolution(for stream: NuvioStream) -> Int {
        let tags = StreamQualityTags.parse(stream: stream)
        if tags.resolution > 0 { return tags.resolution }
        return SmartPlaybackSelector.inferredResolution(for: stream)
    }

    /// Release quality tier matching Android TV's `DebridStreamQuality`.
    static func streamQuality(for stream: NuvioStream) -> DebridStreamQuality {
        let text = "\(stream.name ?? "") \(stream.description ?? "") \(stream.filename ?? "")"
        return StreamQualityTags.quality(in: text)
    }

    /// Best-effort file size in bytes matching Android TV's `StreamTextSizeParser`:
    /// structured videoSize field first, then free-text parsing as last resort.
    static func sizeBytes(for stream: NuvioStream) -> Int64 {
        if let videoSize = stream.videoSize, videoSize > 0 {
            return videoSize
        }
        let text = "\(stream.description ?? "") \(stream.name ?? "")"
        let pattern = #"(\d+(?:[.,]\d+)?)\s*(TB|GB|MB|KB)\b"#
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
    var preserveAddonStreams: Bool = false
}

private enum TvDetailsFocusSection: Hashable {
    case actions
    case episodes
    case cast
    case related
    case network
    case production
    case comments
}

struct TvDetailsContent: View {
    let uiState: DetailsUiState
    var libraryWatchedContext: LibraryWatchedContext? = nil
    var initialPlayRequestID: UInt? = nil
    var initialFocusEpisode: DetailsEpisodeFocus? = nil
    var onInitialPlayRequestConsumed: ((UInt) -> Void)? = nil
    let onPlayClick: () -> Void
    var onPlayManually: (() -> Void)? = nil
    var onHostWatchParty: ((NuvioVideo?) -> Void)? = nil
    let onEpisodeSelected: (NuvioVideo) -> Void
    var onEpisodePlayManually: ((NuvioVideo) -> Void)? = nil
    var onEpisodeMenuPresented: ((Bool) -> Void)? = nil
    let onWatchlistClick: () -> Void
    let onWatchedClick: () -> Void
    var mdbListUserRating: Int? = nil
    var showMdbListRating: Bool = false
    var onRateClick: (() -> Void)? = nil
    let onShareClick: () -> Void
    let onTrailerClick: (Double?) -> Void
    var onOpenTitle: ((String, String) -> Void)? = nil
    var onOpenProduction: ((MetaCompany) -> Void)? = nil
    var onOpenPerson: ((TmdbPersonMetadata) -> Void)? = nil
    var onCommentSelect: ((TraktCommentReview) -> Void)? = nil
    let onBack: () -> Void

    @FocusState private var actionFocus: DetailsActionFocus?
    @FocusState private var castHeaderFocus: DetailsCastHeaderFocus?
    /// Which episode control holds focus, as `TvEpisodeFocus` keys. Owned here
    /// rather than per card so focus can be put back on a specific episode.
    @FocusState private var episodeFocus: String?
    /// The section that currently owns focus. Other sections expose only their
    /// remembered entry anchor, matching Settings' pre-spatial focus lock.
    @State private var focusedDetailsSection: TvDetailsFocusSection = .actions
    @State private var isChoosingWatchPartyEpisode = false
    @State private var consumedInitialPlayRequestID: UInt?
    @State private var detailsFocusMoveGeneration = 0
    @State private var pendingPlayFocusGeneration: Int?
    /// Episode control to re-focus once the stream picker closes, captured when
    /// this content gets disabled. Same approach Home uses for the card you
    /// left when entering Details — see `restoreEpisodeFocus`.
    @State private var restoreEpisodeKey: String?
    @State private var restoreGeneration = 0
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(SettingsKey.smartStreamSelection) private var smartStreamSelection = false
    @AppStorage(SettingsKey.reuseLastLink) private var reuseLastLink = false
    @AppStorage(SettingsKey.trailersEnabled) private var trailersEnabled = true
    @AppStorage(SettingsKey.backgroundTrailersEnabled) private var backgroundTrailersEnabled = true
    @AppStorage(SettingsKey.trailerPreviewSound) private var trailerPreviewSound = false
    @AppStorage(SettingsKey.trailerDelay) private var trailerDelay = 7
    @AppStorage(SettingsKey.detailsActionsBelowInfo) private var detailsActionsBelowInfo = false
    @State private var configuredDetailsSections: [TVDetailsSection] = TVDetailsSectionOrder.currentOrder()
    @State private var disabledDetailsSections: Set<TVDetailsSection> = TVDetailsSectionOrder.disabledSections()

    private var activeDetailsSections: [TVDetailsSection] {
        configuredDetailsSections.filter { !disabledDetailsSections.contains($0) }
    }
    @State private var trailerPlayer = AVPlayer()
    @State private var isTrailerPlaying = false
    @State private var isTrailerRenderReady = false
    @State private var isFullscreenTrailerPresented = false
    @State private var didStopTrailerManually = false
    @State private var trailerTask: Task<Void, Never>? = nil
    /// Bumped whenever a watched mark or a progress write lands. Resume progress
    /// is read straight from the stores below rather than from `uiState`, so
    /// without this the episode strip keeps drawing the bar it rendered with —
    /// marking an episode watched cleared the stores but nothing re-read them.
    @State private var progressRevision = 0
    @State private var scrollOffset: CGFloat = 0
    @State private var hasAppearedBefore = false
    /// Opened from the calendar before the title listed that episode (a
    /// cached copy shows first): focus it once the full title arrives.
    @State private var calendarFocusPending = false
    @State private var reentryProgressRefreshPending = false
    @StateObject private var episodeCache = TvDetailsEpisodeCache()

    private func isBackgroundTrailerAllowed(hasHandoff: Bool = false) -> Bool {
        guard trailersEnabled && backgroundTrailersEnabled && !didStopTrailerManually && isEnabled else { return false }
        return true
    }

    private func scheduleBackgroundTrailer(for meta: NuvioMeta) {
        trailerTask?.cancel()
        let handoff = TrailerPlaybackHandoff.shared.takeHandoff(for: meta.id)
        let hasHandoff = handoff != nil
        guard isBackgroundTrailerAllowed(hasHandoff: hasHandoff) else {
            stopBackgroundTrailer(manual: false)
            return
        }

        trailerTask = Task { @MainActor in
            if !hasHandoff {
                let delaySeconds = max(0, trailerDelay)
                if delaySeconds > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delaySeconds) * 1_000_000_000)
                }
            }
            guard !Task.isCancelled, isBackgroundTrailerAllowed(hasHandoff: hasHandoff) else { return }

            let playbackSource: TrailerPlaybackSource?
            if let source = handoff?.playbackSource {
                playbackSource = source
            } else {
                playbackSource = await YouTubeTrailerResolver.shared.resolvePreview(for: meta)
            }

            guard let playbackSource,
                  let url = URL(string: playbackSource.videoUrl),
                  !Task.isCancelled, isBackgroundTrailerAllowed(hasHandoff: hasHandoff) else {
                return
            }

            let asset: AVURLAsset
            if let userAgent = playbackSource.requestHeaders["User-Agent"], !userAgent.isEmpty {
                asset = AVURLAsset(
                    url: url,
                    options: [AVURLAssetHTTPUserAgentKey: userAgent]
                )
            } else {
                asset = AVURLAsset(url: url)
            }

            let item = AVPlayerItem(asset: asset)
            item.preferredForwardBufferDuration = 2.0
            item.preferredPeakBitRate = 0
            item.preferredMaximumResolution = .zero
            trailerPlayer.replaceCurrentItem(with: item)

            if let handoffTime = handoff?.time, handoffTime > 0.1 {
                await trailerPlayer.seek(
                    to: CMTime(seconds: handoffTime, preferredTimescale: 600),
                    toleranceBefore: .zero,
                    toleranceAfter: .zero
                )
            }
            applySoundPreference(trailerPreviewSound)
            isTrailerPlaying = true
            trailerPlayer.play()
        }
    }

    private func presentFullscreenTrailer() {
        if isTrailerPlaying && trailerPlayer.currentItem != nil {
            applySoundPreference(true)
            trailerPlayer.play()
            withAnimation(.easeInOut(duration: 0.22)) {
                isFullscreenTrailerPresented = true
            }
        } else if let meta = uiState.meta {
            withAnimation(.easeInOut(duration: 0.22)) {
                isFullscreenTrailerPresented = true
            }
            startFullscreenTrailer(for: meta)
        }
    }

    private func dismissFullscreenTrailer() {
        withAnimation(.easeInOut(duration: 0.22)) {
            isFullscreenTrailerPresented = false
        }
        applySoundPreference(trailerPreviewSound)
        if !isBackgroundTrailerAllowed() {
            stopBackgroundTrailer(manual: false)
        }
        DispatchQueue.main.async {
            actionFocus = .trailer
        }
    }

    private func startFullscreenTrailer(for meta: NuvioMeta) {
        trailerTask?.cancel()
        let handoff = TrailerPlaybackHandoff.shared.takeHandoff(for: meta.id)
        trailerTask = Task { @MainActor in
            let playbackSource: TrailerPlaybackSource?
            if let source = handoff?.playbackSource {
                playbackSource = source
            } else if let source = await YouTubeTrailerResolver.shared.resolvePreview(for: meta) {
                playbackSource = source
            } else {
                playbackSource = await YouTubeTrailerResolver.shared.resolve(for: meta)
            }

            guard let playbackSource,
                  let url = URL(string: playbackSource.videoUrl),
                  !Task.isCancelled else {
                return
            }

            let asset: AVURLAsset
            if let userAgent = playbackSource.requestHeaders["User-Agent"], !userAgent.isEmpty {
                asset = AVURLAsset(
                    url: url,
                    options: [AVURLAssetHTTPUserAgentKey: userAgent]
                )
            } else {
                asset = AVURLAsset(url: url)
            }

            let item = AVPlayerItem(asset: asset)
            item.preferredForwardBufferDuration = 2.0
            item.preferredPeakBitRate = 0
            item.preferredMaximumResolution = .zero
            trailerPlayer.replaceCurrentItem(with: item)

            if let handoffTime = handoff?.time, handoffTime > 0.1 {
                await trailerPlayer.seek(
                    to: CMTime(seconds: handoffTime, preferredTimescale: 600),
                    toleranceBefore: .zero,
                    toleranceAfter: .zero
                )
            }
            applySoundPreference(true)
            isTrailerPlaying = true
            trailerPlayer.play()
        }
    }

    private func stopBackgroundTrailer(manual: Bool) {
        trailerTask?.cancel()
        trailerTask = nil
        if manual {
            didStopTrailerManually = true
        }
        isTrailerPlaying = false
        isTrailerRenderReady = false
        trailerPlayer.pause()
        trailerPlayer.replaceCurrentItem(with: nil)
    }

    private func applySoundPreference(_ soundEnabled: Bool) {
        trailerPlayer.isMuted = !soundEnabled
        trailerPlayer.volume = soundEnabled ? 1 : 0
        guard soundEnabled else { return }
        PlaybackAudioSession.activateMoviePlayback()
    }

    private func handleDetailsBack() {
        if isFullscreenTrailerPresented {
            dismissFullscreenTrailer()
            return
        }
        if isTrailerPlaying {
            if let metaId = uiState.meta?.id {
                let seconds = trailerPlayer.currentTime().seconds
                if seconds > 0.1 && !seconds.isNaN && !seconds.isInfinite {
                    TrailerPlaybackHandoff.shared.recordHandoff(metaId: metaId, time: seconds)
                }
            }
        }
        stopBackgroundTrailer(manual: false)
        onBack()
    }

    private var isScrolledDown: Bool {
        focusedDetailsSection != .actions || episodeFocus != nil || castHeaderFocus != nil || scrollOffset > 30
    }

    private var backdropBlurRadius: CGFloat {
        isScrolledDown ? 22 : 0
    }

    private func isWatchedForDetails(_ meta: NuvioMeta) -> Bool {
        guard let libraryWatchedContext else {
            return WatchedStore.isWatchedForDisplay(meta: meta)
        }
        return WatchedStore.isWatchedForLibrary(
            meta: meta,
            source: libraryWatchedContext.source,
            profileId: libraryWatchedContext.profileId
        )
    }

    @ViewBuilder
    private func backdropView(for meta: NuvioMeta) -> some View {
        TvDetailsBackdrop(
            meta: meta,
            blurRadius: backdropBlurRadius,
            player: isFullscreenTrailerPresented ? nil : trailerPlayer,
            isTrailerVisible: isTrailerPlaying && isTrailerRenderReady && !isFullscreenTrailerPresented,
            onTrailerReadyForDisplay: handleTrailerReady
        )
    }

    private func handleTrailerReady() {
        guard isTrailerPlaying, !isTrailerRenderReady else { return }
        isTrailerRenderReady = true
    }

    private func hasStoredPlaybackStream(for playTarget: TvDetailsPlayTarget) -> Bool {
        guard let meta = uiState.meta else { return false }
        let season = playTarget.episode?.season
        let episode = playTarget.episode?.episode
        return LastPlaybackStreamStore.load(
            metaId: meta.id,
            season: season,
            episode: episode,
            meta: meta,
            profileId: ProfileSettings.activeProfileID
        ) != nil
    }

    @ViewBuilder
    private func actionRowView(
        meta: NuvioMeta,
        playTarget: TvDetailsPlayTarget,
        scrollProxy: ScrollViewProxy
    ) -> some View {
        let canBypassPicker = smartStreamSelection || (reuseLastLink && hasStoredPlaybackStream(for: playTarget))
        TvDetailsActionRow(
            isInWatchlist: uiState.isInWatchlist,
            isWatched: isWatchedForDetails(meta),
            playTitle: playTarget.label,
            playHint: canBypassPicker
                ? L10n.string("details_play_hint_smart", fallback: "Plays the best link. Hold Select to choose a source manually.")
                : L10n.string("details_play_hint", fallback: "Starts playback or opens stream sources"),
            onPlayClick: {
                handlePlayClick(playTarget: playTarget)
            },
            onPlayLongPress: canBypassPicker ? {
                handlePlayLongPress(playTarget: playTarget)
            } : nil,
            onHostWatchParty: onHostWatchParty == nil ? nil : {
                beginWatchPartyEpisodeSelection(
                    meta: meta,
                    playTarget: playTarget,
                    scrollProxy: scrollProxy
                )
            },
            onWatchlistClick: onWatchlistClick,
            onWatchedClick: onWatchedClick,
            onRateClick: onRateClick != nil ? {
                stopBackgroundTrailer(manual: false)
                onRateClick?()
            } : nil,
            onTrailerClick: {
                presentFullscreenTrailer()
            },
            onBack: handleDetailsBack,
            focus: $actionFocus,
            entryLocked: focusedDetailsSection != .actions,
            onFocus: {
                if focusedDetailsSection != .actions {
                    focusedDetailsSection = .actions
                    withAnimation(.easeOut(duration: TvDetailsScrollTiming.duration)) {
                        scrollProxy.scrollTo(TvDetailsScrollID.topSection, anchor: .top)
                    }
                } else {
                    var transaction = Transaction(animation: nil)
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        scrollProxy.scrollTo(TvDetailsScrollID.topSection, anchor: .top)
                    }
                }
            }
        )
        .disabled(
            restoreEpisodeKey != nil
                || isFullscreenTrailerPresented
                || !isDetailsFocusReachable(.actions)
        )
    }

    @ViewBuilder
    private func renderDetailsSection(
        _ section: TVDetailsSection,
        meta: NuvioMeta,
        episodes: [NuvioVideo],
        episodeGuide: TvEpisodeGuide,
        episodePresentation: TvDetailsEpisodePresentation,
        continueItem: ContinueWatchingItem?,
        networks: [MetaCompany],
        productionCompanies: [MetaCompany],
        scrollProxy: ScrollViewProxy
    ) -> some View {
        switch section {
        case .episodes:
            if !episodes.isEmpty {
                TvDetailsEpisodes(
                    meta: meta,
                    libraryWatchedContext: libraryWatchedContext,
                    episodeGuide: episodeGuide,
                    initialState: episodePresentation.initialState,
                    presentationRevision: episodePresentation.revision,
                    seriesRating: meta.rating,
                    continueItem: continueItem,
                    isChoosingWatchPartyEpisode: isChoosingWatchPartyEpisode,
                    onCancelWatchPartySelection: { isChoosingWatchPartyEpisode = false },
                    onFocus: {
                        cancelPendingFocusHandoff()
                        if focusedDetailsSection != .episodes {
                            focusedDetailsSection = .episodes
                            withAnimation(.easeOut(duration: TvDetailsScrollTiming.duration)) {
                                scrollProxy.scrollTo(TvDetailsScrollID.episodesSection, anchor: .top)
                            }
                        } else {
                            var transaction = Transaction(animation: nil)
                            transaction.disablesAnimations = true
                            withTransaction(transaction) {
                                scrollProxy.scrollTo(TvDetailsScrollID.episodesSection, anchor: .top)
                            }
                        }
                    },
                    onSelect: { video in
                        stopBackgroundTrailer(manual: false)
                        if isChoosingWatchPartyEpisode {
                            isChoosingWatchPartyEpisode = false
                            onHostWatchParty?(video)
                        } else {
                            onEpisodeSelected(video)
                        }
                    },
                    onPlayManually: onEpisodePlayManually != nil ? { video in
                        stopBackgroundTrailer(manual: false)
                        onEpisodePlayManually?(video)
                    } : nil,
                    onEpisodeMenuPresented: { onEpisodeMenuPresented?($0) },
                    onBack: handleDetailsBack,
                    episodeFocus: $episodeFocus,
                    restrictFocusToKey: restoreEpisodeKey,
                    entryLocked: focusedDetailsSection != .episodes,
                    onMoveUpFromSeason: {
                        handleMoveUpFromEpisodes(using: scrollProxy)
                    },
                    onMoveDownFromEpisode: {
                        handleMoveDownFromEpisodes(using: scrollProxy)
                    }
                )
                .padding(.top, 40)
                .id(TvDetailsScrollID.episodesSection)
                .disabled(!isDetailsFocusReachable(.episodes))
            }
        case .cast:
            if hasCastOrTrailer, let meta = uiState.meta {
                TvDetailsCastAndTrailer(
                    meta: meta,
                    people: uiState.people,
                    onPersonClick: { person in
                        let clean = person.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        guard !clean.isEmpty && clean != "cast" else { return }
                        stopBackgroundTrailer(manual: false)
                        onOpenPerson?(person)
                    },
                    onTrailerClick: {
                        presentFullscreenTrailer()
                    },
                    onBack: handleDetailsBack,
                    headerFocus: $castHeaderFocus,
                    entryLocked: focusedDetailsSection != .cast,
                    onFocus: {
                        if focusedDetailsSection != .cast {
                            focusedDetailsSection = .cast
                            withAnimation(.easeOut(duration: TvDetailsScrollTiming.duration)) {
                                scrollProxy.scrollTo(TvDetailsScrollID.castSection, anchor: .top)
                            }
                        } else {
                            var transaction = Transaction(animation: nil)
                            transaction.disablesAnimations = true
                            withTransaction(transaction) {
                                scrollProxy.scrollTo(TvDetailsScrollID.castSection, anchor: .top)
                            }
                        }
                    }
                )
                .padding(.top, 34)
                .padding(.bottom, 52)
                .id(TvDetailsScrollID.castSection)
                .disabled(
                    restoreEpisodeKey != nil
                        || !isDetailsFocusReachable(.cast)
                )
            }
        case .related:
            if !uiState.moreLikeThis.isEmpty {
                TvDetailsRelatedRow(
                    title: L10n.string("settings_tmdb_module_more_like_this", fallback: "More Like This"),
                    items: uiState.moreLikeThis,
                    entryLocked: focusedDetailsSection != .related,
                    onSelect: { item in
                        stopBackgroundTrailer(manual: false)
                        onOpenTitle?(item.id, item.type)
                    },
                    onBack: handleDetailsBack,
                    onFocus: {
                        if focusedDetailsSection != .related {
                            focusedDetailsSection = .related
                            withAnimation(.easeOut(duration: TvDetailsScrollTiming.duration)) {
                                scrollProxy.scrollTo(TvDetailsScrollID.moreLikeThisSection, anchor: .top)
                            }
                        } else {
                            var transaction = Transaction(animation: nil)
                            transaction.disablesAnimations = true
                            withTransaction(transaction) {
                                scrollProxy.scrollTo(TvDetailsScrollID.moreLikeThisSection, anchor: .top)
                            }
                        }
                    }
                )
                .padding(.top, 34)
                .id(TvDetailsScrollID.moreLikeThisSection)
                .disabled(
                    restoreEpisodeKey != nil
                        || !isDetailsFocusReachable(.related)
                )
            }
        case .network:
            if !networks.isEmpty {
                TvDetailsProductionRow(
                    title: L10n.string("details_network", fallback: "Network"),
                    companies: networks,
                    entryLocked: focusedDetailsSection != .network,
                    onSelect: { company in
                        onOpenProduction?(company)
                    },
                    onBack: handleDetailsBack,
                    onFocus: {
                        if focusedDetailsSection != .network {
                            focusedDetailsSection = .network
                            withAnimation(.easeOut(duration: TvDetailsScrollTiming.duration)) {
                                scrollProxy.scrollTo(TvDetailsScrollID.networkSection, anchor: .top)
                            }
                        } else {
                            var transaction = Transaction(animation: nil)
                            transaction.disablesAnimations = true
                            withTransaction(transaction) {
                                scrollProxy.scrollTo(TvDetailsScrollID.networkSection, anchor: .top)
                            }
                        }
                    }
                )
                .padding(.top, 40)
                .id(TvDetailsScrollID.networkSection)
                .disabled(
                    restoreEpisodeKey != nil
                        || !isDetailsFocusReachable(.network)
                )
            }
        case .production:
            if !productionCompanies.isEmpty {
                TvDetailsProductionRow(
                    title: L10n.string("details_production", fallback: "Production"),
                    companies: productionCompanies,
                    entryLocked: focusedDetailsSection != .production,
                    onSelect: { company in
                        onOpenProduction?(company)
                    },
                    onBack: handleDetailsBack,
                    onFocus: {
                        if focusedDetailsSection != .production {
                            focusedDetailsSection = .production
                            withAnimation(.easeOut(duration: TvDetailsScrollTiming.duration)) {
                                scrollProxy.scrollTo(TvDetailsScrollID.productionSection, anchor: .top)
                            }
                        } else {
                            var transaction = Transaction(animation: nil)
                            transaction.disablesAnimations = true
                            withTransaction(transaction) {
                                scrollProxy.scrollTo(TvDetailsScrollID.productionSection, anchor: .top)
                            }
                        }
                    }
                )
                .padding(.top, 40)
                .id(TvDetailsScrollID.productionSection)
                .disabled(
                    restoreEpisodeKey != nil
                        || !isDetailsFocusReachable(.production)
                )
            }
        case .comments:
            if !uiState.comments.isEmpty {
                TvDetailsCommentsRow(
                    comments: uiState.comments,
                    entryLocked: focusedDetailsSection != .comments,
                    onSelect: { comment in
                        onCommentSelect?(comment)
                    },
                    onBack: handleDetailsBack,
                    onFocus: {
                        if focusedDetailsSection != .comments {
                            focusedDetailsSection = .comments
                            withAnimation(.easeOut(duration: TvDetailsScrollTiming.duration)) {
                                scrollProxy.scrollTo(TvDetailsScrollID.commentsSection, anchor: .top)
                            }
                        } else {
                            var transaction = Transaction(animation: nil)
                            transaction.disablesAnimations = true
                            withTransaction(transaction) {
                                scrollProxy.scrollTo(TvDetailsScrollID.commentsSection, anchor: .top)
                            }
                        }
                    }
                )
                .padding(.top, 40)
                .id(TvDetailsScrollID.commentsSection)
                .disabled(
                    restoreEpisodeKey != nil
                        || !isDetailsFocusReachable(.comments)
                )
            }
        }
    }

    private func handlePlayClick(playTarget: TvDetailsPlayTarget) {
        stopBackgroundTrailer(manual: false)
        guard playTarget.isPlayable else { return }
        if let episode = playTarget.episode {
            onEpisodeSelected(episode)
        } else {
            onPlayClick()
        }
    }

    private func handlePlayLongPress(playTarget: TvDetailsPlayTarget) {
        stopBackgroundTrailer(manual: false)
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
    }

    private func beginWatchPartyEpisodeSelection(
        meta: NuvioMeta,
        playTarget: TvDetailsPlayTarget,
        scrollProxy: ScrollViewProxy
    ) {
        stopBackgroundTrailer(manual: false)
        guard meta.isSeries else {
            onHostWatchParty?(nil)
            return
        }
        guard let episode = playTarget.episode else { return }

        isChoosingWatchPartyEpisode = true
        cancelPendingFocusHandoff()
        focusedDetailsSection = .episodes
        withAnimation(.easeOut(duration: TvDetailsScrollTiming.duration)) {
            scrollProxy.scrollTo(TvDetailsScrollID.episodesSection, anchor: .top)
        }
        let target = TvEpisodeFocus.card(episode.id)
        DispatchQueue.main.asyncAfter(deadline: .now() + TvDetailsScrollTiming.duration) {
            guard isChoosingWatchPartyEpisode else { return }
            episodeFocus = target
        }
    }

    var body: some View {
        if let meta = uiState.meta {
            let episodePresentation = episodeCache.resolve(
                meta: meta,
                progressRevision: progressRevision,
                focusEpisode: initialFocusEpisode,
                libraryWatchedContext: libraryWatchedContext,
                continueItemProvider: { currentContinueWatchingItem(for: meta) },
                playTargetBuilder: { episodes, continueItem, watchedKeys in
                    TvDetailsPlayTargetBuilder.makePlayTarget(
                        episodes: episodes,
                        continueItem: continueItem,
                        watchedKeys: watchedKeys
                    )
                }
            )
            let episodeGuide = episodePresentation.guide
            let episodes = episodeGuide.episodes
            let continueItem = episodePresentation.continueItem
            let playTarget = episodePresentation.playTarget

            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    backdropView(for: meta)

                    TvDetailsScrolledBackdropDimmer(isScrolledDown: isScrolledDown)

                    ScrollViewReader { scrollProxy in
                        ScrollView(.vertical, showsIndicators: false) {
                            GeometryReader { geometry in
                                Color.clear
                                    .preference(
                                        key: TvDetailsScrollOffsetKey.self,
                                        value: geometry.frame(in: .named("tv-details-scroll")).minY
                                    )
                            }
                            .frame(height: 0)
                            .id(TvDetailsScrollID.topSection)

                            VStack(alignment: .leading, spacing: 0) {
                                VStack(alignment: .leading, spacing: 32) {
                                    Spacer(minLength: 0)

                                    TvDetailsLogo(meta: meta)

                                    if detailsActionsBelowInfo {
                                        TvDetailsSummary(
                                            meta: meta,
                                            simkl: uiState.simklRatings,
                                            isBackgroundTrailerPlaying: isTrailerPlaying && isTrailerRenderReady,
                                            isSynopsisFocused: false
                                        )

                                        actionRowView(meta: meta, playTarget: playTarget, scrollProxy: scrollProxy)
                                    } else {
                                        actionRowView(meta: meta, playTarget: playTarget, scrollProxy: scrollProxy)

                                        TvDetailsSummary(
                                            meta: meta,
                                            simkl: uiState.simklRatings,
                                            isBackgroundTrailerPlaying: isTrailerPlaying && isTrailerRenderReady,
                                            isSynopsisFocused: false
                                        )
                                    }
                                }
                            .padding(.bottom, 52)
                            .frame(height: max(proxy.size.height, 800), alignment: .bottomLeading)

                            let productionCompanies = uiState.companies.filter { $0.kind == .production && $0.tmdbId != nil }
                            let networks = uiState.companies.filter { $0.kind == .network && $0.tmdbId != nil }

                            ForEach(activeDetailsSections, id: \.self) { section in
                                renderDetailsSection(
                                    section,
                                    meta: meta,
                                    episodes: episodes,
                                    episodeGuide: episodeGuide,
                                    episodePresentation: episodePresentation,
                                    continueItem: continueItem,
                                    networks: networks,
                                    productionCompanies: productionCompanies,
                                    scrollProxy: scrollProxy
                                )
                            }
                            }
                            // Inset and layout metrics matching Android TV.
                            .padding(.leading, 56)
                            .padding(.bottom, 96)
                            .frame(width: detailsWidth(proxy, hasEpisodes: !episodes.isEmpty), alignment: .leading)
                            .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .topLeading)
                        }
                        .scrollClipDisabledIfAvailable()
                        .coordinateSpace(name: "tv-details-scroll")
                        .onChange(of: actionFocus) { _, newFocus in
                            guard newFocus != nil else { return }
                            var transaction = Transaction(animation: nil)
                            transaction.disablesAnimations = true
                            withTransaction(transaction) {
                                scrollProxy.scrollTo(TvDetailsScrollID.topSection, anchor: .top)
                            }
                        }
                        .onChange(of: castHeaderFocus) { _, newFocus in
                            guard newFocus != nil else { return }
                            var transaction = Transaction(animation: nil)
                            transaction.disablesAnimations = true
                            withTransaction(transaction) {
                                scrollProxy.scrollTo(TvDetailsScrollID.castSection, anchor: .top)
                            }
                        }
                        .onChange(of: episodeFocus) { _, newFocus in
                            guard newFocus != nil, focusedDetailsSection == .episodes else { return }
                            var transaction = Transaction(animation: nil)
                            transaction.disablesAnimations = true
                            withTransaction(transaction) {
                                scrollProxy.scrollTo(TvDetailsScrollID.episodesSection, anchor: .top)
                            }
                        }
                    }

                    if isFullscreenTrailerPresented {
                        TvDetailsFullscreenTrailerOverlay(
                            player: trailerPlayer,
                            meta: meta,
                            isReady: isTrailerRenderReady,
                            onTrailerReady: {
                                isTrailerRenderReady = true
                            },
                            onDismiss: dismissFullscreenTrailer
                        )
                        .transition(.opacity)
                        .zIndex(100)
                    }
                }
                .onPreferenceChange(TvDetailsScrollOffsetKey.self) { minY in
                    let newOffset = max(0, -minY)
                    if abs(newOffset - scrollOffset) > 2 {
                        scrollOffset = newOffset
                    }
                }
            }
            .background(Color.black.ignoresSafeArea())
            .onExitCommand(perform: handleDetailsBack)
            // tvOS doesn't re-run default-focus when this content swaps in after
            // the async load finishes, so focus lands nowhere / off the Play
            // button. Move it onto Play explicitly once the content appears
            // (async so it runs after the focus engine's own first pass).
            .onAppear {
                var calendarEpisodeKey: String?
                if hasAppearedBefore {
                    refreshProgressAfterReturn()
                } else {
                    hasAppearedBefore = true
                    // Opened from the calendar: start on that episode card
                    // instead of Play.
                    calendarEpisodeKey = calendarEpisodeFocusKey(in: episodePresentation.guide.episodes)
                    calendarFocusPending = initialFocusEpisode != nil && calendarEpisodeKey == nil
                }
                if let calendarEpisodeKey {
                    focusCalendarEpisode(calendarEpisodeKey)
                } else {
                    focusedDetailsSection = .actions
                    DispatchQueue.main.async { actionFocus = .play }
                }
                configuredDetailsSections = TVDetailsSectionOrder.currentOrder()
                disabledDetailsSections = TVDetailsSectionOrder.disabledSections()
                scheduleBackgroundTrailer(for: meta)
            }
            .onReceive(NotificationCenter.default.publisher(for: TVDetailsSectionOrder.changedNotification).receive(on: RunLoop.main)) { _ in
                configuredDetailsSections = TVDetailsSectionOrder.currentOrder()
                disabledDetailsSections = TVDetailsSectionOrder.disabledSections()
            }
            .onChange(of: episodePresentation.guide.revision) { _, _ in
                guard calendarFocusPending,
                      let key = calendarEpisodeFocusKey(in: episodePresentation.guide.episodes) else { return }
                calendarFocusPending = false
                // Only while focus is still on Play, where the screen put it.
                guard focusedDetailsSection == .actions, actionFocus == nil || actionFocus == .play else { return }
                focusCalendarEpisode(key)
            }
            .onDisappear {
                let seconds = trailerPlayer.currentTime().seconds
                if seconds > 0.1 && !seconds.isNaN && !seconds.isInfinite {
                    TrailerPlaybackHandoff.shared.recordHandoff(metaId: meta.id, time: seconds)
                }
                stopBackgroundTrailer(manual: false)
            }
            .onChange(of: meta.id) { _, _ in
                didStopTrailerManually = false
                stopBackgroundTrailer(manual: false)
                scheduleBackgroundTrailer(for: meta)
            }
            .onChange(of: backgroundTrailersEnabled) { _, enabled in
                if !enabled {
                    stopBackgroundTrailer(manual: false)
                } else {
                    scheduleBackgroundTrailer(for: meta)
                }
            }
            .onChange(of: trailersEnabled) { _, enabled in
                if !enabled {
                    stopBackgroundTrailer(manual: false)
                } else {
                    scheduleBackgroundTrailer(for: meta)
                }
            }
            .onChange(of: trailerDelay) { _, _ in
                if isTrailerPlaying || trailerTask != nil {
                    stopBackgroundTrailer(manual: false)
                    scheduleBackgroundTrailer(for: meta)
                }
            }
            .onChange(of: trailerPreviewSound) { _, soundEnabled in
                applySoundPreference(soundEnabled)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active {
                    trailerPlayer.pause()
                } else if isTrailerPlaying {
                    trailerPlayer.play()
                }
            }
            .onReceive(
                NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification).receive(on: RunLoop.main)
            ) { notification in
                guard let item = notification.object as? AVPlayerItem,
                      item == trailerPlayer.currentItem else {
                    return
                }
                stopBackgroundTrailer(manual: false)
            }
            // Opening the stream picker disables this content, and on the way
            // back tvOS re-places focus geometrically — which is how leaving an
            // episode's picker landed you on the season pills. Capture the
            // episode on the way out, and while that capture stands every other
            // control here is unfocusable, so the engine can only put focus back
            // where it was.
            .onChange(of: isEnabled) { _, enabled in
                if !enabled {
                    restoreGeneration &+= 1
                    restoreEpisodeKey = episodeFocus
                    stopBackgroundTrailer(manual: false)
                } else {
                    refreshProgressAfterReturn()
                    if let target = restoreEpisodeKey {
                        restoreEpisodeFocus(to: target, generation: restoreGeneration)
                    }
                }
            }
            .onChange(of: episodeFocus) { _, newValue in
                // Restoration landed — lift the restriction.
                if let newValue, newValue == restoreEpisodeKey {
                    restoreEpisodeKey = nil
                }
            }
            // Marking an episode watched clears its progress across three
            // stores, and the remote provider's optimistic layer is cleared one
            // hop later — so every one of them has to be able to invalidate this
            // view, not just the mark itself.
            .onReceive(NotificationCenter.default.publisher(for: WatchedStore.changedNotification).receive(on: RunLoop.main)) { _ in
                progressRevision &+= 1
            }
            .onReceive(NotificationCenter.default.publisher(for: TraktSettingsStore.libraryChangedNotification).receive(on: RunLoop.main)) { _ in
                progressRevision &+= 1
            }
            .onReceive(NotificationCenter.default.publisher(for: TraktAuthStore.changedNotification).receive(on: RunLoop.main)) { _ in
                progressRevision &+= 1
            }
            .onReceive(NotificationCenter.default.publisher(for: ContinueWatchingStore.changedNotification).receive(on: RunLoop.main)) { _ in
                progressRevision &+= 1
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: TraktSettingsStore.continueWatchingChangedNotification
                ).receive(on: RunLoop.main)
            ) { _ in
                progressRevision &+= 1
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: AddonRatingsService.ratingOrderChangedNotification
                ).receive(on: RunLoop.main)
            ) { _ in
                progressRevision &+= 1
            }
            #if os(tvOS)
            .onChange(of: initialPlayRequestID, initial: true) { _, requestID in
                guard let requestID,
                      consumedInitialPlayRequestID != requestID else { return }
                consumedInitialPlayRequestID = requestID
                onInitialPlayRequestConsumed?(requestID)
                handlePlayClick(playTarget: playTarget)
            }
            #endif
        } else {
            EmptyView()
        }
    }

    /// Nudges focus back onto the captured episode control. The writes are
    /// delayed because the cards are unfocusable for a few frames while the
    /// picker fades, and the 1s clear is a safety net for a target that is gone
    /// (the season was switched, say) so the strip can't stay unfocusable.
    /// The card of the episode the calendar asked for, when the title lists it.
    private func calendarEpisodeFocusKey(in episodes: [NuvioVideo]) -> String? {
        initialFocusEpisode
            .flatMap { $0.pick(from: episodes) }
            .map { TvEpisodeFocus.card($0.id) }
    }

    private func focusCalendarEpisode(_ key: String) {
        focusedDetailsSection = .episodes
        restoreGeneration &+= 1
        restoreEpisodeKey = key
        restoreEpisodeFocus(to: key, generation: restoreGeneration)
    }

    private func restoreEpisodeFocus(to target: String, generation: Int) {
        for delay in [0.12, 0.45] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                if restoreGeneration == generation, restoreEpisodeKey == target {
                    episodeFocus = target
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if restoreGeneration == generation, restoreEpisodeKey == target {
                restoreEpisodeKey = nil
            }
        }
    }

    /// Cancel a scroll-first handoff when a newly focused episode control
    /// indicates that the user changed direction.
    private func cancelPendingFocusHandoff() {
        guard pendingPlayFocusGeneration != nil else { return }
        pendingPlayFocusGeneration = nil
        detailsFocusMoveGeneration &+= 1
    }

    /// Route the season strip back to the primary action explicitly. tvOS has
    /// no spatial candidate above later season pills because Play sits at the
    /// far-left edge, so geometry alone can leave focus stuck on Season 2/3.
    private func focusPlayFromEpisodes(using scrollProxy: ScrollViewProxy) {
        detailsFocusMoveGeneration &+= 1
        let generation = detailsFocusMoveGeneration
        pendingPlayFocusGeneration = nil
        focusedDetailsSection = .actions
        actionFocus = .play
        withAnimation(.easeOut(duration: TvDetailsScrollTiming.duration)) {
            scrollProxy.scrollTo(TvDetailsScrollID.topSection, anchor: .top)
        }

        // tvOS may reassert its spatial choice on the next run-loop turn.
        DispatchQueue.main.async {
            guard detailsFocusMoveGeneration == generation else { return }
            if actionFocus != .play {
                actionFocus = .play
            }
        }
    }

    /// Episodes enter the next section through its heading, matching the
    /// Settings-style focus graph instead of jumping over it to a person card.
    private func focusCastHeaderFromEpisodes() {
        guard hasCastOrTrailer else { return }
        detailsFocusMoveGeneration &+= 1
        let generation = detailsFocusMoveGeneration
        pendingPlayFocusGeneration = nil
        castHeaderFocus = .creatorAndCast

        DispatchQueue.main.async {
            guard detailsFocusMoveGeneration == generation else { return }
            castHeaderFocus = .creatorAndCast
        }
    }

    private func scrollID(for section: TvDetailsFocusSection) -> String {
        switch section {
        case .actions: return TvDetailsScrollID.topSection
        case .episodes: return TvDetailsScrollID.episodesSection
        case .cast: return TvDetailsScrollID.castSection
        case .related: return TvDetailsScrollID.moreLikeThisSection
        case .network: return TvDetailsScrollID.networkSection
        case .production: return TvDetailsScrollID.productionSection
        case .comments: return TvDetailsScrollID.commentsSection
        }
    }

    private func handleMoveUpFromEpisodes(using scrollProxy: ScrollViewProxy) {
        guard let currentIndex = detailsFocusOrder.firstIndex(of: .episodes), currentIndex > 0 else {
            focusPlayFromEpisodes(using: scrollProxy)
            return
        }
        let targetSection = detailsFocusOrder[currentIndex - 1]
        switch targetSection {
        case .actions:
            focusPlayFromEpisodes(using: scrollProxy)
        case .cast:
            focusCastHeaderFromEpisodes()
            withAnimation(.easeOut(duration: TvDetailsScrollTiming.duration)) {
                scrollProxy.scrollTo(TvDetailsScrollID.castSection, anchor: .top)
            }
        default:
            detailsFocusMoveGeneration &+= 1
            pendingPlayFocusGeneration = nil
            focusedDetailsSection = targetSection
            withAnimation(.easeOut(duration: TvDetailsScrollTiming.duration)) {
                scrollProxy.scrollTo(scrollID(for: targetSection), anchor: .top)
            }
        }
    }

    private func handleMoveDownFromEpisodes(using scrollProxy: ScrollViewProxy) {
        guard let currentIndex = detailsFocusOrder.firstIndex(of: .episodes),
              currentIndex + 1 < detailsFocusOrder.count else {
            return
        }
        let targetSection = detailsFocusOrder[currentIndex + 1]
        switch targetSection {
        case .cast:
            focusCastHeaderFromEpisodes()
            withAnimation(.easeOut(duration: TvDetailsScrollTiming.duration)) {
                scrollProxy.scrollTo(TvDetailsScrollID.castSection, anchor: .top)
            }
        case .actions:
            focusPlayFromEpisodes(using: scrollProxy)
        default:
            detailsFocusMoveGeneration &+= 1
            pendingPlayFocusGeneration = nil
            focusedDetailsSection = targetSection
            withAnimation(.easeOut(duration: TvDetailsScrollTiming.duration)) {
                scrollProxy.scrollTo(scrollID(for: targetSection), anchor: .top)
            }
        }
    }

    private var hasCastOrTrailer: Bool {
        guard let meta = uiState.meta else { return false }
        let hasPeople = !uiState.people.isEmpty
            || !(meta.cast ?? []).isEmpty
            || !((meta.director ?? []) + (meta.writer ?? [])).isEmpty
        return hasPeople
    }

    /// Settings has one destination pane; Details has a vertical chain of
    /// sections. Keep only the current section and its immediate neighbors in
    /// the focus graph so tvOS cannot skip Cast and land two rows away.
    private var detailsFocusOrder: [TvDetailsFocusSection] {
        var order: [TvDetailsFocusSection] = [.actions]
        for section in activeDetailsSections {
            switch section {
            case .episodes:
                if let meta = uiState.meta, !(meta.videos ?? []).isEmpty {
                    order.append(.episodes)
                }
            case .cast:
                if hasCastOrTrailer {
                    order.append(.cast)
                }
            case .related:
                if !uiState.moreLikeThis.isEmpty {
                    order.append(.related)
                }
            case .network:
                if uiState.companies.contains(where: { $0.kind == .network && $0.tmdbId != nil }) {
                    order.append(.network)
                }
            case .production:
                if uiState.companies.contains(where: { $0.kind == .production && $0.tmdbId != nil }) {
                    order.append(.production)
                }
            case .comments:
                if !uiState.comments.isEmpty {
                    order.append(.comments)
                }
            }
        }
        return order
    }

    private func isDetailsFocusReachable(_ section: TvDetailsFocusSection) -> Bool {
        guard let currentIndex = detailsFocusOrder.firstIndex(of: focusedDetailsSection),
              let sectionIndex = detailsFocusOrder.firstIndex(of: section) else {
            return true
        }
        return abs(sectionIndex - currentIndex) <= 1
    }

    // Give series more horizontal room so the episode cards aren't cramped.
    private func detailsWidth(_ proxy: GeometryProxy, hasEpisodes: Bool) -> CGFloat {
        hasEpisodes ? min(proxy.size.width - 96, 2200) : min(proxy.size.width * 0.64, 1180)
    }

    private func currentContinueWatchingItem(
        for meta: NuvioMeta
    ) -> ContinueWatchingItem? {
        if RemoteTrackingState.isProgressSourceAuthenticated {
            return TraktProgressService.currentContinueWatchingItem(for: meta)
        }
        return ContinueWatchingStore.item(for: meta) ?? ContinueWatchingStore.item(for: meta.id)
    }

    private func refreshProgressAfterReturn() {
        guard !reentryProgressRefreshPending else { return }
        reentryProgressRefreshPending = true
        progressRevision &+= 1
        DispatchQueue.main.async {
            reentryProgressRefreshPending = false
        }
    }

}

private enum TvDetailsScrollTiming {
    static let duration = 0.3
}

private enum TvDetailsScrollID {
    static let topSection = "tv-details-top-section"
    static let castSection = "tv-details-cast-section"
    static let episodesSection = "tv-details-episodes-section"
    static let moreLikeThisSection = "tv-details-more-like-this"
    static let productionSection = "tv-details-production"
    static let networkSection = "tv-details-network"
    static let commentsSection = "tv-details-comments"
}

private struct TvDetailsScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct TvDetailsScrolledBackdropDimmer: View {
    var isScrolledDown: Bool = false

    var body: some View {
        ZStack {
            Color.black
                .opacity(isScrolledDown ? 0.45 : 0)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            TvDetailsScrollTransitionShadow(progress: isScrolledDown ? 1 : 0)
        }
        .animation(.easeInOut(duration: 0.35), value: isScrolledDown)
    }
}

private struct TvDetailsScrollTransitionShadow: View {
    let progress: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(
                colors: [
                    .black.opacity(0.34 * progress),
                    .black.opacity(0.12 * progress),
                    .clear
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 72)

            Spacer(minLength: 0)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct TvDetailsBackdrop: View {
    let meta: NuvioMeta
    var blurRadius: CGFloat = 0
    var player: AVPlayer? = nil
    var isTrailerVisible: Bool = false
    var onTrailerReadyForDisplay: (() -> Void)? = nil
    @AppStorage(SettingsKey.amoled) private var amoled = false
    @AppStorage(SettingsKey.bodyColor) private var bodyColor = SettingsBackground.charcoal.rawValue

    var body: some View {
        let backdropColor = Color.nuvioBackground(amoled: amoled, body: bodyColor)

        ZStack {
            if let imageUrl = meta.backgroundUrl ?? meta.posterUrl,
               let url = URL(string: imageUrl.trimmingCharacters(in: .whitespacesAndNewlines)) {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image
                            .resizable()
                            .scaledToFill()
                    } else {
                        backdropColor
                    }
                }
                .blur(radius: blurRadius, opaque: true)
                .animation(.easeInOut(duration: 0.35), value: blurRadius)
                .ignoresSafeArea()
            } else {
                backdropColor.ignoresSafeArea()
            }

            if let player {
                TrailerPlayerSurface(player: player) {
                    onTrailerReadyForDisplay?()
                }
                .scaleEffect(1.35)
                .blur(radius: blurRadius, opaque: true)
                .opacity(isTrailerVisible ? 1 : 0)
                .animation(.easeInOut(duration: 0.35), value: isTrailerVisible)
                .animation(.easeInOut(duration: 0.35), value: blurRadius)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            }

            GeometryReader { proxy in
                    LinearGradient(
                    stops: [
                        .init(color: backdropColor.opacity(0.95), location: 0),
                        .init(color: backdropColor.opacity(0.86), location: 0.25),
                        .init(color: backdropColor.opacity(0.64), location: 0.50),
                        .init(color: backdropColor.opacity(0.34), location: 0.70),
                        .init(color: backdropColor.opacity(0.10), location: 0.88),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: proxy.size.width * 0.76)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }

        }
        .ignoresSafeArea()
    }
}

private struct TvDetailsLogo: View {
    let meta: NuvioMeta
    var alignment: Alignment = .leading

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
        .frame(width: 560, height: 162, alignment: alignment)
    }

    private var titleFallback: some View {
        Text(meta.name)
            .font(.system(size: 58, weight: .heavy))
            .foregroundColor(.white)
            .lineLimit(2)
            .minimumScaleFactor(0.74)
            .shadow(color: .black.opacity(0.65), radius: 14, y: 6)
            .multilineTextAlignment(alignment == .center ? .center : .leading)
            .frame(maxWidth: 560, alignment: alignment)
    }
}

/// Identifies the action-row buttons so focus can be driven programmatically
/// (tvOS doesn't auto-focus the primary button when the details content swaps in
/// after the async load — see `TvDetailsContent`).
private enum DetailsActionFocus: Hashable {
    case play, party, watchlist, watched, rate, trailer
}

private enum DetailsCastHeaderFocus: Hashable {
    case creatorAndCast, trailer
}

private struct TvDetailsActionRow: View {
    let isInWatchlist: Bool
    let isWatched: Bool
    var playTitle: String = L10n.string("action_play", fallback: "Play")
    var playHint: String = L10n.string("details_play_hint", fallback: "Starts playback or opens stream sources")
    let onPlayClick: () -> Void
    var onPlayLongPress: (() -> Void)? = nil
    var onHostWatchParty: (() -> Void)? = nil
    let onWatchlistClick: () -> Void
    let onWatchedClick: () -> Void
    var mdbListUserRating: Int? = nil
    var showMdbListRating: Bool = false
    var onRateClick: (() -> Void)? = nil
    let onTrailerClick: () -> Void
    var onBack: (() -> Void)? = nil
    var focus: FocusState<DetailsActionFocus?>.Binding
    let entryLocked: Bool
    let onFocus: () -> Void

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
                onFocus: onFocus,
                longPressAction: onPlayLongPress,
                onBack: onBack
            )

            if let onHostWatchParty {
                TvDetailsActionButton(
                    title: nil,
                    systemName: "person.2.fill",
                    accessibilityLabel: "Create Watch Party",
                    accessibilityHint: "Host a private room for this title",
                    isPrimary: false,
                    focus: focus,
                    tag: .party,
                    action: onHostWatchParty,
                    onFocus: onFocus,
                    onBack: onBack
                )
                .disabled(entryLocked)
            }

            TvDetailsActionButton(
                title: nil,
                systemName: isInWatchlist ? "checkmark" : "plus",
                accessibilityLabel: isInWatchlist
                    ? L10n.string("details_in_library", fallback: "In library")
                    : L10n.string("details_add_to_library", fallback: "Add to library"),
                accessibilityHint: isInWatchlist
                    ? L10n.string("details_remove_from_library_hint", fallback: "Removes this title from your library")
                    : L10n.string("details_add_to_library_hint", fallback: "Adds this title to your library"),
                isPrimary: false,
                focus: focus,
                tag: .watchlist,
                action: onWatchlistClick,
                onFocus: onFocus,
                onBack: onBack
            )
            .disabled(entryLocked)

            if showMdbListRating {
                TvDetailsActionButton(
                    title: mdbListUserRating.map { "\($0)/10" },
                    systemName: "star.fill",
                    accessibilityLabel: mdbListUserRating.map { "MDBList rating \($0) out of 10" } ?? "Rate on MDBList",
                    accessibilityHint: "Choose a personal rating on MDBList",
                    isPrimary: false,
                    focus: focus,
                    tag: .rate,
                    action: { onRateClick?() },
                    onFocus: onFocus,
                    onBack: onBack
                )
                .disabled(entryLocked)
            }

            TvDetailsActionButton(
                title: nil,
                systemName: isWatched ? "eye.fill" : "eye.slash.fill",
                accessibilityLabel: isWatched
                    ? L10n.string("details_watched", fallback: "Watched")
                    : L10n.string("details_not_watched", fallback: "Not watched"),
                accessibilityHint: isWatched
                    ? L10n.string("details_mark_unwatched_hint", fallback: "Marks this title as unwatched")
                    : L10n.string("details_mark_watched_hint", fallback: "Marks this title as watched"),
                isPrimary: false,
                focus: focus,
                tag: .watched,
                action: onWatchedClick,
                onFocus: onFocus,
                onBack: onBack
            )
            .disabled(entryLocked)

            TvDetailsActionButton(
                title: nil,
                systemName: "play.rectangle.fill",
                accessibilityLabel: L10n.string("details_trailer", fallback: "Trailer"),
                accessibilityHint: L10n.string("details_trailer_hint", fallback: "Plays the trailer when available"),
                isPrimary: false,
                focus: focus,
                tag: .trailer,
                action: onTrailerClick,
                onFocus: onFocus,
                onBack: onBack
            )
            .disabled(entryLocked)
        }
        .focusSection()
        .onExitCommand {
            onBack?()
        }
    }
}

private struct TvPlayActionButtonStyle: ButtonStyle {
    let onHold: (() -> Void)?
    @Binding var didTriggerHold: Bool

    @State private var holdTask: Task<Void, Never>? = nil

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            #if os(tvOS)
            .scaleEffect(configuration.isPressed ? 0.985 : 1.0)
            #else
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            #endif
            .animation(.easeInOut(duration: 0.2), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, isPressed in
                holdTask?.cancel()
                holdTask = nil
                if isPressed {
                    guard let onHold else { return }
                    holdTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        guard !Task.isCancelled else { return }
                        didTriggerHold = true
                        onHold()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            didTriggerHold = false
                        }
                    }
                }
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
    let onFocus: () -> Void
    var longPressAction: (() -> Void)? = nil
    var onBack: (() -> Void)? = nil

    @State private var didTriggerHold = false
    private var isFocused: Bool { focus.wrappedValue == tag }

    var body: some View {
        Button(action: {
            if didTriggerHold {
                didTriggerHold = false
                return
            }
            action()
        }) {
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
        .buttonStyle(TvPlayActionButtonStyle(onHold: longPressAction, didTriggerHold: $didTriggerHold))
        .focused(focus, equals: tag)
        .focusEffectDisabledIfAvailable()
        .scaleEffect(isFocused ? 1.08 : 1)
        .animation(.easeOut(duration: 0.14), value: isFocused)
        .onChange(of: isFocused) { _, focused in
            if focused { onFocus() }
            didTriggerHold = false
        }
        .onExitCommand {
            onBack?()
        }
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
    var simkl: SimklTitleRatings? = nil
    var isBackgroundTrailerPlaying: Bool = false
    var isSynopsisFocused: Bool = false

    private var textOpacity: Double {
        if isBackgroundTrailerPlaying && !isSynopsisFocused {
            return 0.85
        }
        return 1.0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let creatorLine {
                Text(creatorLine)
                    .font(.system(size: 28, weight: .regular))
                    .foregroundColor(.white.opacity(0.65))
                    .padding(.bottom, 24)
            }

            if !externalRatingBadges.isEmpty {
                TvDetailsRatingsRow(badges: externalRatingBadges)
                    .padding(.bottom, 28)
            }

            if let description = meta.description, !description.isEmpty {
                Text(description)
                    .font(.system(size: 30, weight: .regular))
                    .foregroundColor(.white)
                    .lineSpacing(8)
                    .lineLimit(5)
                    .frame(maxWidth: 960, alignment: .leading)
                    .padding(.bottom, 24)
            }

            if !primaryMetaItems.isEmpty || certificationLabel != nil || statusLabel != nil || !secondaryMetaItems.isEmpty {
                VStack(alignment: .leading, spacing: 16) {
                    if !primaryMetaItems.isEmpty {
                        Text(primaryMetaItems.joined(separator: "  •  "))
                            .font(.system(size: 27, weight: .medium))
                            .foregroundColor(.white.opacity(0.60))
                            .lineLimit(2)
                    }

                    if certificationLabel != nil || statusLabel != nil || !secondaryMetaItems.isEmpty {
                        HStack(spacing: 14) {
                            if certificationLabel != nil || statusLabel != nil {
                                HStack(spacing: 10) {
                                    if let certificationLabel {
                                        Text(certificationLabel)
                                            .font(.system(size: 22, weight: .semibold))
                                            .foregroundColor(.white.opacity(0.88))
                                    }

                                    if certificationLabel != nil && statusLabel != nil {
                                        Rectangle()
                                            .fill(Color.white.opacity(0.35))
                                            .frame(width: 1.5, height: 18)
                                    }

                                    if let statusLabel {
                                        Text(statusLabel)
                                            .font(.system(size: 22, weight: .semibold))
                                            .foregroundColor(.white.opacity(0.88))
                                    }
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .stroke(Color.white.opacity(0.45), lineWidth: 1.5)
                                )
                            }

                            if !secondaryMetaItems.isEmpty {
                                Text(((certificationLabel != nil || statusLabel != nil) ? "•  " : "") + secondaryMetaItems.joined(separator: "  •  "))
                                    .font(.system(size: 24, weight: .medium))
                                    .foregroundColor(.white.opacity(0.88))
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
        }
        .opacity(textOpacity)
        .animation(.easeInOut(duration: 0.35), value: textOpacity)
    }

    private var creatorLine: String? {
        if meta.isSeries {
            if let writers = meta.writer, !writers.isEmpty {
                let list = writers.prefix(2).joined(separator: ", ")
                return "Creator: \(list)"
            }
            if let directors = meta.director, !directors.isEmpty {
                let list = directors.prefix(2).joined(separator: ", ")
                return "Creator: \(list)"
            }
        } else {
            if let directors = meta.director, !directors.isEmpty {
                let list = directors.prefix(2).joined(separator: ", ")
                return directors.count > 1 ? "Directors: \(list)" : "Director: \(list)"
            }
            if let writers = meta.writer, !writers.isEmpty {
                let list = writers.prefix(2).joined(separator: ", ")
                return writers.count > 1 ? "Writers: \(list)" : "Writer: \(list)"
            }
        }
        return nil
    }

    private var certificationLabel: String? {
        guard let cert = meta.certification?.trimmingCharacters(in: .whitespacesAndNewlines), !cert.isEmpty else {
            return nil
        }
        return cert
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
        if let country = normalizedCountry(meta.country) {
            items.append(country)
        }
        if let language = normalizedLanguage(meta.language) {
            items.append(language)
        }
        return items
    }

    private func normalizedCountry(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let firstPart = raw.split(separator: ",").first.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? raw
        if firstPart.count == 2, firstPart.range(of: "^[A-Za-z]{2}$", options: .regularExpression) != nil {
            let code = firstPart.uppercased()
            return Locale.current.localizedString(forRegionCode: code) ?? code
        }
        return firstPart
    }

    private func normalizedLanguage(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count == 2 || trimmed.count == 3 {
            return trimmed.uppercased()
        }
        return trimmed.prefix(2).uppercased()
    }

    private var releaseDisplay: String? {
        NuvioDateDisplay.formattedDate(meta.released ?? meta.releaseInfo)
    }

    private var externalRatingBadges: [TvRatingBadge] {
        TvRatingBadge.badges(from: meta.externalRatings ?? [])
    }
}

private struct TvDetailsRatingsRow: View {
    let badges: [TvRatingBadge]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 26) {
                ForEach(badges) { badge in
                    HStack(spacing: 9) {
                        TvRatingIcon(visual: badge.visual, height: 38)

                        Text(badge.formattedValue)
                            .font(.system(size: 28, weight: .regular))
                            .foregroundColor(.white.opacity(0.62))
                    }
                }
            }
        }
        .frame(maxWidth: 950, alignment: .leading)
    }
}

private struct TvDetailsCastAndTrailer: View {
    let meta: NuvioMeta
    let people: [TmdbPersonMetadata]
    let onPersonClick: (TmdbPersonMetadata) -> Void
    let onTrailerClick: () -> Void
    var onBack: (() -> Void)? = nil
    var headerFocus: FocusState<DetailsCastHeaderFocus?>.Binding
    let entryLocked: Bool
    let onFocus: () -> Void

    @State private var focusedPersonIndex = 0

    var body: some View {
        let items = displayPeople
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 18) {
                    TvDetailsSectionButton(
                        title: L10n.string("details_creator_and_cast", fallback: "Creator and Cast"),
                        isSelected: false,
                        focus: headerFocus,
                        tag: .creatorAndCast,
                        onFocus: onFocus,
                        onBack: onBack
                    ) {}

                    Text("|")
                        .font(.system(size: 36, weight: .medium))
                        .foregroundColor(.white.opacity(0.38))

                    TvDetailsSectionButton(
                        title: L10n.string("details_trailer", fallback: "Trailer"),
                        isSelected: false,
                        focus: headerFocus,
                        tag: .trailer,
                        onFocus: onFocus,
                        onBack: onBack,
                        action: onTrailerClick
                    )
                        .disabled(entryLocked)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 58) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, person in
                            TvDetailsPersonCard(
                                person: person,
                                onSelect: { onPersonClick(person) },
                                onFocus: {
                                    focusedPersonIndex = index
                                    onFocus()
                                },
                                onBack: onBack
                            )
                            .disabled(entryLocked)
                        }
                    }
                    .padding(.trailing, 80)
                }
                .scrollClipDisabledIfAvailable()
            }
            .focusSection()
            .onExitCommand {
                onBack?()
            }
        }
    }

    private var displayPeople: [TmdbPersonMetadata] {
        if !people.isEmpty {
            return Array(people.prefix(8))
        }

        let cast = meta.cast ?? []
        if !cast.isEmpty {
            return Array(cast.prefix(8)).map {
                TmdbPersonMetadata(name: $0, role: nil, profileURL: nil, tmdbId: nil)
            }
        }

        let creators = (meta.director ?? []) + (meta.writer ?? [])
        if !creators.isEmpty {
            return Array(creators.prefix(8)).map {
                TmdbPersonMetadata(name: $0, role: nil, profileURL: nil, tmdbId: nil)
            }
        }

        return []
    }
}

private struct TvDetailsSectionButton: View {
    let title: String
    let isSelected: Bool
    var focus: FocusState<DetailsCastHeaderFocus?>.Binding
    let tag: DetailsCastHeaderFocus
    let onFocus: () -> Void
    var onBack: (() -> Void)? = nil
    let action: () -> Void

    private var isFocused: Bool { focus.wrappedValue == tag }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 36, weight: .semibold))
                .foregroundColor(.white.opacity(isFocused || isSelected ? 1 : 0.48))
                .padding(.horizontal, isSelected ? 0 : 4)
                .frame(height: 64)
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused(focus, equals: tag)
        .focusEffectDisabledIfAvailable()
        .scaleEffect(isFocused ? 1.035 : 1)
        .animation(.easeOut(duration: 0.14), value: isFocused)
        .onChange(of: isFocused) { _, focused in
            if focused {
                onFocus()
            }
        }
        .onExitCommand {
            onBack?()
        }
    }
}

// MARK: - More Like This / Production / Comments

private enum TvDetailsHorizontalStrip {
    static let verticalPadding: CGFloat = 28
    static let scrollSpring = Animation.spring(response: 0.3, dampingFraction: 1.0)
}

private struct TvDetailsRelatedRow: View {
    let title: String
    let items: [RelatedTitle]
    let entryLocked: Bool
    let onSelect: (RelatedTitle) -> Void
    var onBack: (() -> Void)? = nil
    let onFocus: () -> Void

    @State private var scrollIndex = 0
    @AppStorage(SettingsKey.homeLayout) private var homeLayout = "Modern"
    @AppStorage(SettingsKey.posterLabels) private var posterLabels = false
    @AppStorage(SettingsKey.smoothFocus) private var smoothFocus = true
    @AppStorage(SettingsKey.focusHighlighter) private var focusHighlighter = false

    private var cardWidth: CGFloat { homeLayout == "Compact" ? 170 : 210 }
    private var cardHeight: CGFloat { homeLayout == "Compact" ? 255 : 315 }
    private var spacing: CGFloat { homeLayout == "Compact" ? 22 : 28 }
    private var step: CGFloat { cardWidth + spacing }
    private var stripHeight: CGFloat {
        cardHeight + 36 + TvDetailsHorizontalStrip.verticalPadding * 2
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(title)
                .font(.system(size: 34, weight: .semibold))
                .foregroundColor(.white.opacity(0.9))

            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    PosterCard(
                        meta: item.asMeta,
                        customPosterScreen: .details,
                        onFocus: { _ in
                            if scrollIndex != index { scrollIndex = index }
                            onFocus()
                        },
                        layoutMode: homeLayout,
                        showPosterLabels: posterLabels,
                        smoothFocusAnimations: smoothFocus,
                        focusHighlighterEnabled: focusHighlighter
                    ) {
                        onSelect(item)
                    }
                    .disabled(entryLocked && index != scrollIndex)
                }
            }
            .padding(.vertical, TvDetailsHorizontalStrip.verticalPadding)
            .offset(x: -CGFloat(scrollIndex) * step)
            // Deliberately do not clip this strip to the text column. Like the
            // Home rows, posters keep drawing all the way to the screen edge.
            .frame(height: stripHeight, alignment: .leading)
            .animation(
                smoothFocus ? TvDetailsHorizontalStrip.scrollSpring : nil,
                value: scrollIndex
            )
        }
        .focusSection()
        .onExitCommand {
            onBack?()
        }
    }
}

private struct TvDetailsProductionRow: View {
    let title: String
    let companies: [MetaCompany]
    let entryLocked: Bool
    let onSelect: (MetaCompany) -> Void
    var onBack: (() -> Void)? = nil
    let onFocus: () -> Void

    @State private var scrollIndex = 0
    @AppStorage(SettingsKey.smoothFocus) private var smoothFocus = true

    private let cardWidth: CGFloat = 200
    private let cardHeight: CGFloat = 166
    private let spacing: CGFloat = 22
    private var step: CGFloat { cardWidth + spacing }
    private var stripHeight: CGFloat {
        cardHeight + TvDetailsHorizontalStrip.verticalPadding * 2
    }

    private var entryCompanyIndex: Int {
        if companies.indices.contains(scrollIndex),
           companies[scrollIndex].tmdbId != nil {
            return scrollIndex
        }
        return companies.firstIndex { $0.tmdbId != nil } ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(title)
                .font(.system(size: 34, weight: .semibold))
                .foregroundColor(.white.opacity(0.9))

            HStack(alignment: .top, spacing: spacing) {
                ForEach(Array(companies.enumerated()), id: \.element.id) { index, company in
                    TvDetailsCompanyCard(
                        company: company,
                        onSelect: { onSelect(company) },
                        onFocus: {
                            if scrollIndex != index { scrollIndex = index }
                            onFocus()
                        },
                        onBack: onBack
                    )
                    .disabled(entryLocked && index != entryCompanyIndex)
                }
            }
            .padding(.vertical, TvDetailsHorizontalStrip.verticalPadding)
            .offset(x: -CGFloat(scrollIndex) * step)
            .frame(height: stripHeight, alignment: .leading)
            .animation(
                smoothFocus ? TvDetailsHorizontalStrip.scrollSpring : nil,
                value: scrollIndex
            )
        }
        .focusSection()
        .onExitCommand {
            onBack?()
        }
    }
}

private struct TvDetailsCompanyCard: View {
    let company: MetaCompany
    let onSelect: () -> Void
    let onFocus: () -> Void
    var onBack: (() -> Void)? = nil

    @FocusState private var isFocused: Bool
    @AppStorage(SettingsKey.cardCornerRadius) private var cardCornerRadiusSetting = AppCardStyle.defaultCornerRadiusRaw
    @AppStorage(SettingsKey.liquidGlassCards) private var liquidGlassCards = true

    private var cardCornerRadius: CGFloat {
        AppCardStyle.cornerRadius(for: cardCornerRadiusSetting, fallback: 14)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 14) {
                ZStack {
                    shape
                        .fill(Color.white.opacity(liquidGlassCards ? 0.90 : 1))
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
                .clipShape(shape)
                .modifier(
                    LiquidGlassCardModifier(
                        cornerRadius: cardCornerRadius,
                        isFocused: isFocused,
                        isEnabled: liquidGlassCards
                    )
                )
                .overlay(
                    shape.stroke(
                        isFocused ? AppFocusOutline.color : Color.clear,
                        lineWidth: isFocused ? AppFocusOutline.width : 0
                    )
                )

                Text(company.name)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(.white.opacity(0.75))
                    .lineLimit(2)
                    // Reserve room for the longest label so one-line names do
                    // not change the vertical position of neighboring cards.
                    .frame(width: 200, height: 52, alignment: .top)
                    .multilineTextAlignment(.center)
            }
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($isFocused)
        .focusEffectDisabledIfAvailable()
        .scaleEffect(isFocused ? 1.05 : 1)
        .animation(.easeOut(duration: 0.14), value: isFocused)
        .onChange(of: isFocused) { _, focused in
            if focused { onFocus() }
        }
        .onExitCommand {
            onBack?()
        }
        .disabled(company.tmdbId == nil)
        .opacity(company.tmdbId == nil ? 0.55 : 1)
    }
}

private struct TvDetailsCommentsRow: View {
    let comments: [TraktCommentReview]
    let entryLocked: Bool
    let onSelect: (TraktCommentReview) -> Void
    var onBack: (() -> Void)? = nil
    let onFocus: () -> Void

    @State private var scrollIndex = 0
    @AppStorage(SettingsKey.smoothFocus) private var smoothFocus = true

    private let cardWidth: CGFloat = 420
    private let cardHeight: CGFloat = 240
    private let spacing: CGFloat = 22

    private var stripHeight: CGFloat {
        cardHeight + TvDetailsHorizontalStrip.verticalPadding * 2
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(L10n.string("details_top_comments", fallback: "Top Comments"))
                .font(.system(size: 34, weight: .semibold))
                .foregroundColor(.white.opacity(0.9))

            HStack(spacing: 22) {
                ForEach(Array(comments.enumerated()), id: \.element.id) { index, comment in
                    TvDetailsCommentCard(
                        comment: comment,
                        onSelect: { onSelect(comment) },
                        onFocus: {
                            if scrollIndex != index { scrollIndex = index }
                            onFocus()
                        },
                        onBack: onBack
                    )
                    .disabled(entryLocked && index != scrollIndex)
                }
            }
            .padding(.vertical, TvDetailsHorizontalStrip.verticalPadding)
            .offset(x: -CGFloat(scrollIndex) * (cardWidth + spacing))
            // Keep comment cards edge-to-edge as well; the parent vertical
            // scroll view owns the viewport instead of this row clipping it.
            .frame(height: stripHeight, alignment: .leading)
            .animation(
                smoothFocus ? TvDetailsHorizontalStrip.scrollSpring : nil,
                value: scrollIndex
            )
        }
        .focusSection()
        .onExitCommand {
            onBack?()
        }
    }
}

private struct TvDetailsCommentCard: View {
    let comment: TraktCommentReview
    let onSelect: () -> Void
    let onFocus: () -> Void
    var onBack: (() -> Void)? = nil

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

                Text(comment.spoiler ? L10n.string("details_spoiler_notice", fallback: "Spoiler — select to read") : comment.comment)
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
        .onChange(of: isFocused) { _, focused in
            if focused { onFocus() }
        }
        .onExitCommand {
            onBack?()
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
                    Button(action: onDismiss) {
                        Text(L10n.string("action_close", fallback: "Close"))
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundColor(closeFocused ? .black : .white)
                            .padding(.horizontal, 26)
                            .frame(height: 54)
                            .modifier(
                                TvDetailsGlassBackground(
                                    filled: closeFocused,
                                    shape: Capsule()
                                )
                            )
                    }
                        .buttonStyle(PosterCardButtonStyle())
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
                    Label(L10n.format("details_likes_count", fallback: "%d likes", comment.likes), systemImage: "heart.fill")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundColor(.white.opacity(0.55))
                }
            }
            .padding(48)
            .frame(maxWidth: 1100, maxHeight: 620)
            .modifier(
                TvStreamGlass(
                    shape: RoundedRectangle(cornerRadius: 28, style: .continuous),
                    tint: Color.black.opacity(0.34)
                )
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

private enum TvDetailsTrailerControlFocus: Hashable {
    case timeline
    case pip
    case subtitles
    case audio
}

private struct TrailerMediaOption: Identifiable, Equatable {
    let id: String
    let title: String
    let isSelected: Bool
    let option: AVMediaSelectionOption?
}

private struct TrailerSubtitleMenuButton: View, Equatable {
    let noneOption: TrailerMediaOption
    let options: [TrailerMediaOption]
    let isFocused: Bool
    let onSelect: (TrailerMediaOption) -> Void

    static func == (lhs: TrailerSubtitleMenuButton, rhs: TrailerSubtitleMenuButton) -> Bool {
        lhs.isFocused == rhs.isFocused
            && lhs.noneOption == rhs.noneOption
            && lhs.options == rhs.options
    }

    var body: some View {
        Menu {
            Button {
                onSelect(noneOption)
            } label: {
                HStack {
                    Text(noneOption.title)
                    Spacer()
                    if noneOption.isSelected {
                        Image(systemName: "checkmark")
                    }
                }
            }

            ForEach(options) { option in
                Button {
                    onSelect(option)
                } label: {
                    HStack {
                        Text(option.title)
                        Spacer()
                        if option.isSelected {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "captions.bubble")
                .font(.system(size: 28, weight: .semibold))
                .foregroundColor(isFocused ? .black : .white)
                .frame(width: 70, height: 70)
                .modifier(PlayerGlassCircleButtonBackground(filled: isFocused))
                .shadow(color: .black.opacity(0.82), radius: 14, x: 0, y: 7)
                .frame(width: 70, height: 70)
                .clipShape(Circle())
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .nuvioFocusEffectDisabledIfAvailable()
        .scaleEffect(isFocused ? 1.06 : 1.0)
        .animation(.easeOut(duration: 0.14), value: isFocused)
        .id("trailer_subtitles_button")
    }
}

private struct TrailerAudioMenuButton: View, Equatable {
    let options: [TrailerMediaOption]
    let isFocused: Bool
    let onSelect: (TrailerMediaOption) -> Void

    static func == (lhs: TrailerAudioMenuButton, rhs: TrailerAudioMenuButton) -> Bool {
        lhs.isFocused == rhs.isFocused
            && lhs.options == rhs.options
    }

    var body: some View {
        Menu {
            if options.isEmpty {
                Button {} label: {
                    HStack {
                        Text(L10n.string("player_default_audio", fallback: "Default Audio"))
                        Spacer()
                        Image(systemName: "checkmark")
                    }
                }
            } else {
                ForEach(options) { option in
                    Button {
                        onSelect(option)
                    } label: {
                        HStack {
                            Text(option.title)
                            Spacer()
                            if option.isSelected {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "waveform")
                .font(.system(size: 28, weight: .semibold))
                .foregroundColor(isFocused ? .black : .white)
                .frame(width: 70, height: 70)
                .modifier(PlayerGlassCircleButtonBackground(filled: isFocused))
                .shadow(color: .black.opacity(0.82), radius: 14, x: 0, y: 7)
                .frame(width: 70, height: 70)
                .clipShape(Circle())
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .nuvioFocusEffectDisabledIfAvailable()
        .scaleEffect(isFocused ? 1.06 : 1.0)
        .animation(.easeOut(duration: 0.14), value: isFocused)
        .id("trailer_audio_button")
    }
}

private struct TvDetailsFullscreenTrailerOverlay: View {
    let player: AVPlayer
    let meta: NuvioMeta
    let isReady: Bool
    let onTrailerReady: () -> Void
    let onDismiss: () -> Void

    @FocusState private var focusedControl: TvDetailsTrailerControlFocus?
    @State private var isPlaying = true
    @State private var isSurfaceReady = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var buffered: Double = 0
    @State private var pendingSeekDelta: Double = 0
    @State private var showControls = true
    @State private var controlsAutoHideSuspended = false
    @State private var pipController: AVPictureInPictureController? = nil
    @State private var audibleGroup: AVMediaSelectionGroup? = nil
    @State private var legibleGroup: AVMediaSelectionGroup? = nil
    @State private var selectedAudioId: String? = nil
    @State private var selectedSubtitleId: String? = nil
    @State private var controlsHideTask: Task<Void, Never>? = nil
    @State private var seekDebounceTask: Task<Void, Never>? = nil
    @State private var timeObserverToken: Any? = nil

    private var transportFocusOrder: [TvDetailsTrailerControlFocus] {
        [.subtitles, .audio]
    }

    private func isTransportButtonFocusable(_ key: TvDetailsTrailerControlFocus) -> Bool {
        if focusedControl == .timeline {
            return key == (transportFocusOrder.first ?? .subtitles)
        }
        return true
    }

    private var targetPosition: Double {
        let position = currentTime + pendingSeekDelta
        return min(max(position, 0), max(duration, 0))
    }

    private var progress: CGFloat {
        let d = max(duration, 0.001)
        return CGFloat(min(max(targetPosition / d, 0), 1))
    }

    private var isTimelineFocused: Bool {
        focusedControl == .timeline || isSeekingOrScrubbing
    }

    private var isSeekingOrScrubbing: Bool {
        pendingSeekDelta != 0
    }

    var body: some View {
        ZStack {
            // 1. Black background
            Color.black.ignoresSafeArea()

            // 2. Video surface - Aspect Fit with zero cropping
            TrailerPlayerSurface(
                player: player,
                videoGravity: .resizeAspect,
                onLayerAvailable: { layer in
                    if AVPictureInPictureController.isPictureInPictureSupported() {
                        pipController = AVPictureInPictureController(playerLayer: layer)
                    }
                }
            ) {
                withAnimation(.easeOut(duration: 0.2)) {
                    isSurfaceReady = true
                }
                onTrailerReady()
            }
            .ignoresSafeArea()

            // 3. Loading Indicator if preparing
            if !isReady && !isSurfaceReady {
                VStack(spacing: 18) {
                    ProgressView()
                        .scaleEffect(1.4)
                        .tint(.white)
                    Text(L10n.string("trailer_loading", fallback: "Loading trailer..."))
                        .font(.system(size: 22, weight: .medium))
                        .foregroundColor(.white.opacity(0.85))
                }
                .padding(32)
                .modifier(TvDetailsGlassBackground(filled: false, shape: RoundedRectangle(cornerRadius: 24, style: .continuous)))
                .transition(.opacity)
            }

            // 4. Remote wake surface when chrome is hidden
            if !showControls {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showControls = true
                    }
                    focusedControl = .timeline
                    scheduleControlsHide(after: 5.0)
                } label: {
                    Color.clear
                }
                .buttonStyle(PosterCardButtonStyle())
                .nuvioFocusEffectDisabledIfAvailable()
                .onExitCommand(perform: onDismiss)
                .onPlayPauseCommand(perform: togglePlayPause)
                .onMoveCommand { _ in
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showControls = true
                    }
                    focusedControl = .timeline
                    scheduleControlsHide(after: 5.0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // 5. Aether-style Player Controls Overlay
            if showControls {
                GlassControlsContainer {
                    VStack {
                        topBar
                        Spacer()
                        bottomControls
                    }
                    .onExitCommand(perform: handleControlsExit)
                }
                .background(
                    LinearGradient(
                        stops: [
                            .init(color: Color.black.opacity(0.72), location: 0),
                            .init(color: Color.clear, location: 0.22),
                            .init(color: Color.clear, location: 0.78),
                            .init(color: Color.black.opacity(0.85), location: 1.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                )
                .transition(.opacity)
            }
        }
        .onAppear {
            setupTimeObserver()
            loadMediaSelectionGroups()
            isPlaying = player.timeControlStatus == .playing || player.rate > 0
            if isReady || isPlaying || (player.currentTime().seconds > 0.05 && !player.currentTime().seconds.isNaN) {
                isSurfaceReady = true
                onTrailerReady()
            }
            showControls = true
            scheduleControlsHide(after: 5.0)
            DispatchQueue.main.async {
                focusedControl = .timeline
            }
        }
        .onChange(of: isPlaying) { _, playing in
            if playing && showControls && !controlsAutoHideSuspended {
                scheduleControlsHide(after: focusedControl == .timeline ? 5.0 : 10.0)
            }
        }
        .onChange(of: isSurfaceReady) { _, ready in
            if ready && showControls && isPlaying && !controlsAutoHideSuspended {
                scheduleControlsHide(after: focusedControl == .timeline ? 5.0 : 10.0)
            }
        }
        .onChange(of: focusedControl) { oldControl, newControl in
            if newControl == .timeline {
                controlsAutoHideSuspended = false
                scheduleControlsHide(after: 5.0)
            } else if newControl == .subtitles || newControl == .audio {
                controlsAutoHideSuspended = false
                scheduleControlsHide(after: 10.0)
            } else if newControl != nil {
                controlsAutoHideSuspended = false
                scheduleControlsHide(after: 10.0)
            } else {
                controlsAutoHideSuspended = true
                controlsHideTask?.cancel()
            }
        }
        .onDisappear {
            teardownTimeObserver()
        }
        .onExitCommand {
            if showControls {
                handleControlsExit()
            } else {
                onDismiss()
            }
        }
        .onPlayPauseCommand(perform: togglePlayPause)
        .onReceive(
            NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime).receive(on: RunLoop.main)
        ) { notification in
            guard let item = notification.object as? AVPlayerItem,
                  item == player.currentItem else {
                return
            }
            onDismiss()
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        Group {
            if !isSeekingOrScrubbing {
                VStack(spacing: 12) {
                    HStack(alignment: .top, spacing: 24) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(meta.name)
                                .font(.system(size: 38, weight: .bold))
                                .foregroundColor(.white)
                                .lineLimit(1)

                            HStack(spacing: 8) {
                                Text(L10n.string("details_trailer", fallback: "Trailer"))
                                    .font(.system(size: 21, weight: .medium))
                                    .foregroundColor(.white.opacity(0.68))
                                    .lineLimit(1)

                                if let year = meta.year {
                                    Text("•")
                                        .font(.system(size: 21, weight: .medium))
                                        .foregroundColor(.white.opacity(0.4))
                                    Text(String(year))
                                        .font(.system(size: 21, weight: .medium))
                                        .foregroundColor(.white.opacity(0.68))
                                }
                            }
                        }

                        Spacer()
                    }
                }
                .padding(.horizontal, 60)
                .padding(.top, 34)
                .shadow(color: .black.opacity(0.82), radius: 18, x: 0, y: 6)
                .transition(.opacity)
            }
        }
        .animation(.playerControls, value: isSeekingOrScrubbing)
    }

    // MARK: - Bottom controls

    private var bottomControls: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !isSeekingOrScrubbing {
                transportRow
                    .transition(.opacity)
            }
            timelineBar
        }
        .padding(.horizontal, 60)
        .padding(.bottom, 54)
        .animation(.playerControls, value: isSeekingOrScrubbing)
    }

    private var transportRow: some View {
        HStack(spacing: 18) {
            Spacer()

            TrailerSubtitleMenuButton(
                noneOption: subtitleNoneOption,
                options: subtitleOptions,
                isFocused: focusedControl == .subtitles,
                onSelect: { opt in
                    selectSubtitleOption(opt)
                }
            )
            .equatable()
            .focused($focusedControl, equals: .subtitles)
            .disabled(!isTransportButtonFocusable(.subtitles))
            .onExitCommand(perform: handleControlsExit)
            .onMoveCommand { direction in
                handleMove(direction, from: .subtitles)
            }

            TrailerAudioMenuButton(
                options: audioOptions,
                isFocused: focusedControl == .audio,
                onSelect: { opt in
                    selectAudioOption(opt)
                }
            )
            .equatable()
            .focused($focusedControl, equals: .audio)
            .disabled(!isTransportButtonFocusable(.audio))
            .onExitCommand(perform: handleControlsExit)
            .onMoveCommand { direction in
                handleMove(direction, from: .audio)
            }
        }
        .onExitCommand(perform: handleControlsExit)
        .shadow(color: .black.opacity(0.74), radius: 20, x: 0, y: 8)
    }

    private func glassIconButton<Icon: View>(
        size: CGFloat,
        iconSize: CGFloat,
        focusKey: TvDetailsTrailerControlFocus,
        isFocused: Bool,
        action: @escaping () -> Void,
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        Button {
            focusedControl = focusKey
            scheduleControlsHide(after: 10.0)
            action()
        } label: {
            icon()
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundColor(isFocused ? .black : .white)
                .frame(width: size, height: size)
                .modifier(PlayerGlassCircleButtonBackground(filled: isFocused))
                .shadow(color: .black.opacity(0.82), radius: 14, x: 0, y: 7)
                .frame(width: size, height: size)
                .clipShape(Circle())
                .contentShape(Circle())
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($focusedControl, equals: focusKey)
        .disabled(!isTransportButtonFocusable(focusKey))
        .nuvioFocusEffectDisabledIfAvailable()
        .onExitCommand(perform: handleControlsExit)
        .onMoveCommand { direction in
            handleMove(direction, from: focusKey)
        }
        .scaleEffect(isFocused ? 1.06 : 1.0)
        .animation(.easeOut(duration: 0.14), value: isFocused)
    }

    // MARK: - Timeline bar

    private var timelineBar: some View {
        VStack(spacing: 10) {
            GeometryReader { geo in
                let w = geo.size.width
                let targetX = min(max(w * progress, 0), w)
                let trackHeight: CGFloat = (isTimelineFocused || isSeekingOrScrubbing) ? 10 : 7
                let h: CGFloat = (isTimelineFocused || isSeekingOrScrubbing) ? trackHeight + 2 : trackHeight
                let needleHeight: CGFloat = 22
                let originalProgress = CGFloat(min(max(currentTime / max(duration, 0.001), 0), 1))
                let originalX = min(max(w * originalProgress, 0), w)
                let bottomOfTrack = geo.size.height / 2 + h / 2

                ZStack(alignment: .leading) {
                    PlayerProgressTrack(
                        played: Double(progress),
                        buffered: duration > 0 ? (buffered / duration) : 0,
                        height: trackHeight,
                        showThumb: false,
                        emphasized: isTimelineFocused || isSeekingOrScrubbing,
                        glassTrack: true
                    )

                    if isSeekingOrScrubbing {
                        // Ghost tick: original paused playback position flush within track
                        if abs(targetX - originalX) > 3 {
                            Rectangle()
                                .fill(Color.white.opacity(0.4))
                                .frame(width: 1.5, height: h)
                                .position(x: originalX, y: geo.size.height / 2)
                        }

                        // Active scrub needle
                        Rectangle()
                            .fill(Color.white)
                            .frame(width: 2, height: needleHeight)
                            .shadow(color: .black.opacity(0.45), radius: 1.5)
                            .position(x: targetX, y: bottomOfTrack - needleHeight / 2)
                    }
                }
            }
            .frame(height: (isTimelineFocused || isSeekingOrScrubbing) ? 16 : 11)

            if isSeekingOrScrubbing {
                GeometryReader { geo in
                    let w = geo.size.width
                    let targetX = min(max(w * progress, 60), w - 60)
                    HStack(spacing: 8) {
                        Text(PlayerTime.formatted(time: targetPosition))
                            .font(.system(size: 26, weight: .bold).monospacedDigit())
                            .foregroundColor(.white)

                        let isForward = pendingSeekDelta >= 0
                        Image(systemName: isForward ? "goforward.10" : "gobackward.10")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(.white)
                    }
                    .shadow(color: .black.opacity(0.85), radius: 6, x: 0, y: 2)
                    .position(x: targetX, y: 14)
                }
                .frame(height: 28)
            } else {
                HStack(spacing: 10) {
                    Text(PlayerTime.formatted(time: targetPosition))
                    Spacer()
                    Text("-" + PlayerTime.formatted(time: max(0, duration - targetPosition)))
                }
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(.white.opacity(isTimelineFocused ? 0.82 : 0.54))
            }
        }
        .focusable(showControls)
        .focused($focusedControl, equals: .timeline)
        .nuvioFocusEffectDisabledIfAvailable()
        .onExitCommand(perform: handleControlsExit)
        .onTapGesture {
            if pendingSeekDelta != 0 {
                commitPendingSeek()
            } else {
                togglePlayPause()
            }
        }
        .onMoveCommand { direction in
            handleMove(direction, from: .timeline)
        }
        .shadow(color: .black.opacity(0.82), radius: 16, x: 0, y: 7)
        .animation(.easeOut(duration: 0.14), value: focusedControl)
        .animation(.easeOut(duration: 0.12), value: pendingSeekDelta)
    }

    // MARK: - Actions & Focus Navigation

    private func handleMove(_ direction: MoveCommandDirection, from origin: TvDetailsTrailerControlFocus) {
        scheduleControlsHide(after: origin == .timeline ? 5.0 : 10.0)
        switch direction {
        case .up:
            if origin == .timeline {
                focusedControl = transportFocusOrder.first ?? .subtitles
            }
        case .down:
            if origin != .timeline {
                focusedControl = .timeline
            }
        case .left:
            if origin == .timeline {
                handleSeekStep(delta: -10)
            } else if let index = transportFocusOrder.firstIndex(of: origin), index > 0 {
                focusedControl = transportFocusOrder[index - 1]
            }
        case .right:
            if origin == .timeline {
                handleSeekStep(delta: 10)
            } else if let index = transportFocusOrder.firstIndex(of: origin), index < transportFocusOrder.count - 1 {
                focusedControl = transportFocusOrder[index + 1]
            }
        default:
            break
        }
    }

    private func handleSeekStep(delta: Double) {
        scheduleControlsHide(after: 5.0)
        let current = player.currentTime().seconds
        guard !current.isNaN, !current.isInfinite else { return }
        let baseTime = current + pendingSeekDelta
        let newTarget = min(max(baseTime + delta, 0), max(duration, 0))
        pendingSeekDelta = newTarget - current

        seekDebounceTask?.cancel()
        seekDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            if !Task.isCancelled {
                commitPendingSeek()
            }
        }
    }

    private func commitPendingSeek() {
        seekDebounceTask?.cancel()
        seekDebounceTask = nil
        guard pendingSeekDelta != 0 else { return }
        let current = player.currentTime().seconds
        guard !current.isNaN, !current.isInfinite else { return }
        let target = min(max(current + pendingSeekDelta, 0), max(duration, 0))
        pendingSeekDelta = 0
        currentTime = target
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    private func togglePlayPause() {
        commitPendingSeek()
        if player.timeControlStatus == .playing || player.rate > 0 {
            player.pause()
            isPlaying = false
            withAnimation(.easeInOut(duration: 0.2)) {
                showControls = true
            }
            controlsHideTask?.cancel()
        } else {
            player.play()
            isPlaying = true
            withAnimation(.easeInOut(duration: 0.2)) {
                showControls = true
            }
            scheduleControlsHide(after: focusedControl == .timeline ? 5.0 : 10.0)
        }
    }

    private func togglePictureInPicture() {
        scheduleControlsHide(after: 10.0)
        guard let pipController else { return }
        if pipController.isPictureInPictureActive {
            pipController.stopPictureInPicture()
        } else {
            pipController.startPictureInPicture()
        }
    }

    private func loadMediaSelectionGroups() {
        guard let item = player.currentItem else { return }
        let asset = item.asset
        Task { @MainActor in
            let audible = try? await asset.loadMediaSelectionGroup(for: .audible)
            let legible = try? await asset.loadMediaSelectionGroup(for: .legible)
            self.audibleGroup = audible
            self.legibleGroup = legible
        }
    }

    private var audioOptions: [TrailerMediaOption] {
        guard let group = audibleGroup, let item = player.currentItem else {
            return []
        }
        let selected = item.currentMediaSelection.selectedMediaOption(in: group)
        return group.options.map { opt in
            let name = opt.displayName.isEmpty ? (opt.locale?.localizedString(forIdentifier: opt.locale?.identifier ?? "") ?? "Audio") : opt.displayName
            let id = opt.displayName + (opt.locale?.identifier ?? "")
            let isSel = (selectedAudioId != nil) ? (selectedAudioId == id) : ((selected == opt) || (selected == nil && opt == group.defaultOption))
            return TrailerMediaOption(
                id: id,
                title: name,
                isSelected: isSel,
                option: opt
            )
        }
    }

    private var subtitleNoneOption: TrailerMediaOption {
        guard let group = legibleGroup, let item = player.currentItem else {
            return TrailerMediaOption(id: "off", title: L10n.string("action_none", fallback: "None"), isSelected: true, option: nil)
        }
        let selected = item.currentMediaSelection.selectedMediaOption(in: group)
        let isSel = (selectedSubtitleId != nil) ? (selectedSubtitleId == "off") : (selected == nil)
        return TrailerMediaOption(id: "off", title: L10n.string("action_none", fallback: "None"), isSelected: isSel, option: nil)
    }

    private var subtitleOptions: [TrailerMediaOption] {
        guard let group = legibleGroup, let item = player.currentItem else {
            return []
        }
        let selected = item.currentMediaSelection.selectedMediaOption(in: group)
        return group.options.map { opt in
            let name = opt.displayName.isEmpty ? (opt.locale?.localizedString(forIdentifier: opt.locale?.identifier ?? "") ?? "Subtitles") : opt.displayName
            let id = opt.displayName + (opt.locale?.identifier ?? "")
            let isSel = (selectedSubtitleId != nil) ? (selectedSubtitleId == id) : (selected == opt)
            return TrailerMediaOption(
                id: id,
                title: name,
                isSelected: isSel,
                option: opt
            )
        }
    }

    private func selectAudioOption(_ option: TrailerMediaOption) {
        guard let item = player.currentItem,
              let group = audibleGroup,
              let opt = option.option else { return }
        item.select(opt, in: group)
        selectedAudioId = option.id
        controlsAutoHideSuspended = false
        scheduleControlsHide(after: 10.0)
    }

    private func selectSubtitleOption(_ option: TrailerMediaOption) {
        guard let item = player.currentItem,
              let group = legibleGroup else { return }
        if let opt = option.option {
            item.select(opt, in: group)
            selectedSubtitleId = option.id
        } else {
            item.select(nil, in: group)
            selectedSubtitleId = "off"
        }
        controlsAutoHideSuspended = false
        scheduleControlsHide(after: 10.0)
    }

    private func handleControlsExit() {
        if pendingSeekDelta != 0 {
            cancelPendingSeek()
            scheduleControlsHide(after: 5.0)
        } else {
            hideControls()
        }
    }

    private func cancelPendingSeek() {
        seekDebounceTask?.cancel()
        seekDebounceTask = nil
        pendingSeekDelta = 0
    }

    private func hideControls() {
        controlsHideTask?.cancel()
        controlsHideTask = nil
        controlsAutoHideSuspended = false
        withAnimation(.easeInOut(duration: 0.2)) {
            showControls = false
        }
    }

    private func scheduleControlsHide(after seconds: Double = 5.0) {
        controlsHideTask?.cancel()
        guard !controlsAutoHideSuspended else { return }
        controlsHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, !controlsAutoHideSuspended, pendingSeekDelta == 0 else { return }
            let playing = player.timeControlStatus == .playing || player.rate > 0
            if playing {
                withAnimation(.easeInOut(duration: 0.25)) {
                    showControls = false
                }
            }
        }
    }

    private func setupTimeObserver() {
        let interval = CMTime(value: 1, timescale: 4)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak player] time in
            guard let player else { return }
            let sec = time.seconds
            if !sec.isNaN && !sec.isInfinite {
                currentTime = sec
                if sec > 0.05 {
                    if !isSurfaceReady {
                        withAnimation(.easeOut(duration: 0.2)) {
                            isSurfaceReady = true
                        }
                    }
                    onTrailerReady()
                }
            }
            if let itemDuration = player.currentItem?.duration.seconds,
               !itemDuration.isNaN && !itemDuration.isInfinite && itemDuration > 0 {
                duration = itemDuration
            }
            if let timeRange = player.currentItem?.loadedTimeRanges.first?.timeRangeValue {
                let buf = timeRange.start.seconds + timeRange.duration.seconds
                if !buf.isNaN && !buf.isInfinite && buf >= 0 {
                    buffered = buf
                }
            }
            let playing = player.timeControlStatus == .playing || player.rate > 0
            if isPlaying != playing {
                isPlaying = playing
            }
            if playing && !isSurfaceReady {
                withAnimation(.easeOut(duration: 0.2)) {
                    isSurfaceReady = true
                }
                onTrailerReady()
            }
            if audibleGroup == nil || legibleGroup == nil {
                loadMediaSelectionGroups()
            }
        }
    }

    private func teardownTimeObserver() {
        controlsHideTask?.cancel()
        controlsHideTask = nil
        seekDebounceTask?.cancel()
        seekDebounceTask = nil
        if let timeObserverToken {
            player.removeTimeObserver(timeObserverToken)
            self.timeObserverToken = nil
        }
    }
}

actor PersonProfileImageCache {
    static let shared = PersonProfileImageCache()
    private static let tracker = NSCacheMemoryTracker(maxCost: 20 * 1024 * 1024)

    static func telemetryMetrics() -> (count: Int, totalBytes: Int, maxCost: Int) {
        tracker.metrics()
    }

    private let cache = NSCache<NSURL, UIImage>()

    init() {
        cache.countLimit = 60
        cache.totalCostLimit = Self.tracker.maxCost
        cache.delegate = Self.tracker
        #if canImport(UIKit)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { _ in
            Task {
                await PersonProfileImageCache.shared.purge()
            }
        }
        #endif
    }

    func purge() {
        cache.removeAllObjects()
        Self.tracker.reset()
    }

    func image(for url: NSURL) -> UIImage? {
        cache.object(forKey: url)
    }

    func insert(_ image: UIImage, for url: NSURL) {
        let cost = image.decodedByteCost
        cache.setObject(image, forKey: url, cost: cost)
        Self.tracker.recordInsertion(cost: cost)
    }
}

private struct TvDetailsPersonCard: View {
    let person: TmdbPersonMetadata
    let onSelect: () -> Void
    let onFocus: () -> Void
    var onBack: (() -> Void)? = nil

    @FocusState private var isFocused: Bool
    @State private var profileImage: UIImage?

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 18) {
                Circle()
                    .frame(width: 188, height: 188)
                    .modifier(TvDetailsGlassBackground(filled: isFocused, shape: Circle()))
                    .overlay(
                        Circle()
                            .strokeBorder(Color.white.opacity(isFocused ? 0.0 : 0.22), lineWidth: 1)
                    )
                    .overlay {
                        if let profileImage {
                            Image(uiImage: profileImage)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 188, height: 188)
                                .clipShape(Circle())
                        } else {
                            Text(initials)
                                .font(.system(size: 44, weight: .medium))
                                .foregroundColor(isFocused ? .black : .white)
                        }
                    }

                Text(person.name)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundColor(isFocused ? .white : .white.opacity(0.74))
                    .lineLimit(1)
                    .frame(width: 210)

                if let role = person.role,
                   !role.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(role)
                        .font(.system(size: 20, weight: .regular))
                        .foregroundColor(.white.opacity(isFocused ? 0.82 : 0.55))
                        .lineLimit(1)
                        .frame(width: 210)
                }
            }
            .frame(width: 220)
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($isFocused)
        .focusEffectDisabledIfAvailable()
        .scaleEffect(isFocused ? 1.08 : 1)
        .animation(.easeOut(duration: 0.14), value: isFocused)
        .onChange(of: isFocused) { _, focused in
            if focused {
                onFocus()
            }
        }
        .onExitCommand {
            onBack?()
        }
        .task(id: person.profileURL) {
            await loadProfileImage()
        }
    }

    private var initials: String {
        let words = person.name
            .split(separator: " ")
            .prefix(2)
            .compactMap { $0.first }
        let value = String(words).uppercased()
        return value.isEmpty ? "?" : value
    }

    private var profileURL: URL? {
        guard let profileURL = person.profileURL,
              !profileURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return URL(string: profileURL)
    }

    private func loadProfileImage() async {
        guard profileImage == nil, let url = profileURL else { return }
        let cacheKey = url as NSURL
        if let cached = await PersonProfileImageCache.shared.image(for: cacheKey) {
            profileImage = cached
            return
        }

        guard let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              !Task.isCancelled else {
            return
        }

        let targetPixelSize: CGFloat = 376
        let downsampledImage: UIImage? = {
            let options: [CFString: Any] = [
                kCGImageSourceShouldCache: false
            ]
            guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary) else {
                return UIImage(data: data)
            }
            guard CGImageSourceGetCount(source) > 0, CGImageSourceGetType(source) != nil else {
                return UIImage(data: data)
            }
            let thumbnailOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: targetPixelSize
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
                return UIImage(data: data)
            }
            return UIImage(cgImage: cgImage)
        }()

        guard let image = downsampledImage, !Task.isCancelled else { return }
        await PersonProfileImageCache.shared.insert(image, for: cacheKey)
        profileImage = image
    }
}

// MARK: - Series episodes

private struct TvEpisodeGuideInput: Equatable {
    let metaID: String
    let videos: [NuvioVideo]
}

private struct TvEpisodeLookupIdentity: Equatable {
    let metaID: String
    let imdbId: String?
    let tmdbId: Int?
    let canonicalType: String
}

/// Sorted once when the metadata episode list changes. Focus-driven Details
/// updates reuse both the ordered guide and its per-season slices.
private struct TvEpisodeGuide {
    let metaID: String
    let revision: Int
    let episodes: [NuvioVideo]
    let seasons: [Int]
    let episodesBySeason: [Int: [NuvioVideo]]

    init(metaID: String, videos: [NuvioVideo], revision: Int) {
        self.metaID = metaID
        self.revision = revision

        let ordered = TvDetailsPlayTargetBuilder.orderedEpisodes(videos)
        var grouped: [Int: [NuvioVideo]] = [:]
        var orderedSeasons: [Int] = []
        for episode in ordered {
            if grouped[episode.season] == nil {
                orderedSeasons.append(episode.season)
            }
            grouped[episode.season, default: []].append(episode)
        }

        episodes = ordered
        episodesBySeason = grouped
        seasons = orderedSeasons
    }

    func defaultSeason() -> Int {
        seasons.first(where: { $0 > 0 }) ?? seasons.first ?? 1
    }

    func initialEpisode(
        continueItem: ContinueWatchingItem?,
        watchedKeys: Set<String>
    ) -> NuvioVideo? {
        TvDetailsInitialEpisodeResolver.resolve(
            episodes: episodes,
            continueItem: continueItem,
            watchedKeys: watchedKeys
        )
    }
}

enum TvDetailsInitialEpisodeResolver {
    static func resolve(
        episodes: [NuvioVideo],
        continueItem: ContinueWatchingItem?,
        watchedKeys: Set<String>
    ) -> NuvioVideo? {
        if let numbers = continueItem?.episodeNumbers,
           let progressEpisode = episodes.first(where: {
               $0.season == numbers.season && $0.episode == numbers.episode
           }) {
            return progressEpisode
        }

        guard let latestWatchedIndex = episodes.lastIndex(where: {
            watchedKeys.contains("\($0.season):\($0.episode)")
        }) else {
            return nil
        }

        if latestWatchedIndex + 1 < episodes.count,
           let nextEpisode = episodes[(latestWatchedIndex + 1)...].first(where: {
               !watchedKeys.contains("\($0.season):\($0.episode)")
           }) {
            return nextEpisode
        }
        return episodes[latestWatchedIndex]
    }
}

struct TvDetailsPlayTarget {
    let episode: NuvioVideo?
    let label: String
    let isPlayable: Bool
}

enum TvDetailsPlayTargetBuilder {
    static func orderedEpisodes(_ videos: [NuvioVideo]) -> [NuvioVideo] {
        videos.sorted {
            (seasonSortKey($0.season), $0.episode)
                < (seasonSortKey($1.season), $1.episode)
        }
    }

    static func makePlayTarget(
        episodes: [NuvioVideo],
        continueItem: ContinueWatchingItem?,
        watchedKeys: Set<String>
    ) -> TvDetailsPlayTarget {
        guard !episodes.isEmpty else {
            return TvDetailsPlayTarget(
                episode: nil,
                label: continueItem == nil
                    ? L10n.string("action_play", fallback: "Play")
                    : L10n.string("action_resume", fallback: "Resume"),
                isPlayable: true
            )
        }

        if let continueItem,
           let numbers = continueItem.episodeNumbers,
           let target = episodes.first(where: { $0.season == numbers.season && $0.episode == numbers.episode }) {
            if continueItem.isUpNextEntry, !continueItem.hasAired {
                let label = continueItem.airDateText.map { L10n.format("details_airs_date", fallback: "Airs %@", $0) }
                    ?? L10n.string("details_upcoming", fallback: "Upcoming")
                return TvDetailsPlayTarget(episode: target, label: label, isPlayable: false)
            }
            let verb = continueItem.isUpNextEntry
                ? L10n.string("details_next", fallback: "Next")
                : L10n.string("action_resume", fallback: "Resume")
            return TvDetailsPlayTarget(
                episode: target,
                label: "\(verb) S\(target.season) E\(target.episode)",
                isPlayable: true
            )
        }

        let watched = watchedKeys
        if !watched.isEmpty {
            let watchedPairs: [(season: Int, episode: Int)] = watched.compactMap { key in
                let parts = key.split(separator: ":").compactMap { Int($0) }
                guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return nil }
                return (parts[0], parts[1])
            }
            if let latestWatched = watchedPairs.max(by: { ($0.season, $0.episode) < ($1.season, $1.episode) }),
               let next = episodes.first(where: {
                   $0.season > 0
                       && ($0.season, $0.episode) > (latestWatched.season, latestWatched.episode)
                       && !watched.contains("\($0.season):\($0.episode)")
               }) {
                let verb = EpisodeReleasePolicy.hasAired(next.released)
                    ? L10n.string("details_next", fallback: "Next")
                    : L10n.string("details_upcoming", fallback: "Upcoming")
                return TvDetailsPlayTarget(
                    episode: next,
                    label: "\(verb) S\(next.season) E\(next.episode)",
                    isPlayable: EpisodeReleasePolicy.hasAired(next.released)
                )
            }
            if let firstUnwatched = episodes.first(where: {
                $0.season > 0 && !watched.contains("\($0.season):\($0.episode)")
            }) {
                return TvDetailsPlayTarget(
                    episode: firstUnwatched,
                    label: "\(L10n.string("details_next", fallback: "Next")) S\(firstUnwatched.season) E\(firstUnwatched.episode)",
                    isPlayable: true
                )
            }
        }

        let first = episodes.first(where: { $0.season > 0 }) ?? episodes.first
        return TvDetailsPlayTarget(
            episode: first,
            label: first.map { "\(L10n.string("action_play", fallback: "Play")) S\($0.season) E\($0.episode)" }
                ?? L10n.string("action_play", fallback: "Play"),
            isPlayable: true
        )
    }

    private static func seasonSortKey(_ season: Int) -> Int {
        season <= 0 ? Int.max : season
    }
}

private struct TvDetailsEpisodeInitialState {
    let selectedSeason: Int
    let seasonEpisodes: [NuvioVideo]
    let seasonEpisodeIndexByID: [String: Int]
    let episodeScrollIndex: Int
    let watchedEpisodeKeys: Set<String>
    let episodeWatchCounts: [String: Int]
    let watchedSummary: WatchedEpisodeSummary?
    let seasonIsWatched: Bool
}

/// Separates Library-scoped episode indicators from the progress owner used to
/// select playback. Details can originate in a provider-filtered Library while
/// Continue Watching and the initial play target remain global.
struct TvDetailsEpisodeWatchedKeys {
    let display: Set<String>
    let playTarget: Set<String>

    init(meta: NuvioMeta, progressSnapshot: WatchedSnapshot, librarySnapshot: WatchedSnapshot?) {
        playTarget = progressSnapshot.watchedEpisodeKeys(meta: meta)
        display = librarySnapshot?.catalogWatchedEpisodeKeys(meta: meta) ?? playTarget
    }
}

private struct TvDetailsEpisodePresentation {
    let guide: TvEpisodeGuide
    let continueItem: ContinueWatchingItem?
    let playTarget: TvDetailsPlayTarget
    let initialState: TvDetailsEpisodeInitialState
    let revision: TvDetailsEpisodePresentationRevision
}

private struct TvDetailsEpisodePresentationRevision: Equatable {
    let watched: Int
    let selection: Int
}

/// Builds episode-derived state synchronously on the first Details render and
/// refreshes it only when episode metadata or watched/progress state changes.
@MainActor
private final class TvDetailsEpisodeCache: ObservableObject {
    private var input: TvEpisodeGuideInput?
    private var lookupIdentity: TvEpisodeLookupIdentity?
    private var progressRevision: Int?
    private var libraryWatchedContextIdentity: String?
    private var focusEpisode: DetailsEpisodeFocus?
    private var presentation: TvDetailsEpisodePresentation?

    func resolve(
        meta: NuvioMeta,
        progressRevision: Int,
        focusEpisode: DetailsEpisodeFocus? = nil,
        libraryWatchedContext: LibraryWatchedContext? = nil,
        continueItemProvider: () -> ContinueWatchingItem?,
        playTargetBuilder: ([NuvioVideo], ContinueWatchingItem?, Set<String>) -> TvDetailsPlayTarget
    ) -> TvDetailsEpisodePresentation {
        let input = TvEpisodeGuideInput(metaID: meta.id, videos: meta.videos ?? [])
        let lookupIdentity = TvEpisodeLookupIdentity(
            metaID: meta.id,
            imdbId: meta.imdbId,
            tmdbId: meta.tmdbId,
            canonicalType: meta.canonicalType
        )
        let guideChanged = self.input != input
        let lookupIdentityChanged = self.lookupIdentity != lookupIdentity
        let progressChanged = self.progressRevision != progressRevision
        let watchedContextChanged = self.libraryWatchedContextIdentity != libraryWatchedContext?.cacheIdentity
        let focusChanged = self.focusEpisode != focusEpisode

        if guideChanged || lookupIdentityChanged || progressChanged || focusChanged || watchedContextChanged {
            let guideRevision = guideChanged
                ? (presentation.map { $0.guide.revision &+ 1 } ?? 0)
                : presentation!.guide.revision
            let guide = guideChanged
                ? TvEpisodeGuide(metaID: input.metaID, videos: input.videos, revision: guideRevision)
                : presentation!.guide
            let continueItem = continueItemProvider()
            let progressSnapshot = WatchedStore.currentSnapshot()
            let librarySnapshot = libraryWatchedContext.map {
                WatchedStore.librarySnapshot(for: $0.source, profileId: $0.profileId)
            }
            let watchedKeys = TvDetailsEpisodeWatchedKeys(
                meta: meta,
                progressSnapshot: progressSnapshot,
                librarySnapshot: librarySnapshot
            )
            let progressWatchedKeys = watchedKeys.playTarget
            let displayWatchedKeys = watchedKeys.display
            let displaySnapshot = librarySnapshot ?? progressSnapshot
            let episodeWatchCounts = displaySnapshot.catalogEpisodeWatchCounts(meta: meta)
            // A calendar entry asks for a specific episode; otherwise follow
            // progress as before.
            let focusedEpisode = focusEpisode.flatMap { $0.pick(from: guide.episodes) }
            let initialEpisode = focusedEpisode ?? guide.initialEpisode(
                continueItem: continueItem,
                watchedKeys: progressWatchedKeys
            )
            let selectedSeason = initialEpisode?.season ?? guide.defaultSeason()
            let seasonEpisodes = guide.episodesBySeason[selectedSeason] ?? []
            let episodeScrollIndex = initialEpisode.flatMap { target in
                seasonEpisodes.firstIndex(where: { $0.id == target.id })
            } ?? 0
            let seasonEpisodeIndexByID = seasonEpisodes.enumerated().reduce(into: [:]) { indices, entry in
                indices[entry.element.id] = entry.offset
            }
            let seasonIsWatched = !seasonEpisodes.isEmpty && seasonEpisodes.allSatisfy {
                displayWatchedKeys.contains("\($0.season):\($0.episode)")
            }
            let initialState = TvDetailsEpisodeInitialState(
                selectedSeason: selectedSeason,
                seasonEpisodes: seasonEpisodes,
                seasonEpisodeIndexByID: seasonEpisodeIndexByID,
                episodeScrollIndex: episodeScrollIndex,
                watchedEpisodeKeys: displayWatchedKeys,
                episodeWatchCounts: episodeWatchCounts,
                watchedSummary: WatchedEpisodeSummary.make(
                    videos: guide.episodes,
                    watchedEpisodeKeys: displayWatchedKeys
                ),
                seasonIsWatched: seasonIsWatched
            )
            let nextRevision = TvDetailsEpisodePresentationRevision(
                watched: (presentation?.revision.watched ?? -1) &+ 1,
                selection: guideChanged || lookupIdentityChanged || focusChanged
                    ? (presentation?.revision.selection ?? -1) &+ 1
                    : (presentation?.revision.selection ?? 0)
            )
            presentation = TvDetailsEpisodePresentation(
                guide: guide,
                continueItem: continueItem,
                playTarget: playTargetBuilder(guide.episodes, continueItem, progressWatchedKeys),
                initialState: initialState,
                revision: nextRevision
            )
            self.input = input
            self.lookupIdentity = lookupIdentity
            self.progressRevision = progressRevision
            self.focusEpisode = focusEpisode
            self.libraryWatchedContextIdentity = libraryWatchedContext?.cacheIdentity
        }

        return presentation!
    }
}

private struct TvDetailsEpisodes: View {
    let meta: NuvioMeta
    var libraryWatchedContext: LibraryWatchedContext? = nil
    let episodeGuide: TvEpisodeGuide
    let initialState: TvDetailsEpisodeInitialState
    let presentationRevision: TvDetailsEpisodePresentationRevision
    let seriesRating: Double?
    let continueItem: ContinueWatchingItem?
    let isChoosingWatchPartyEpisode: Bool
    let onCancelWatchPartySelection: () -> Void
    let onFocus: () -> Void
    let onSelect: (NuvioVideo) -> Void
    var onPlayManually: ((NuvioVideo) -> Void)? = nil
    let onEpisodeMenuPresented: (Bool) -> Void
    var onBack: (() -> Void)? = nil
    var episodeFocus: FocusState<String?>.Binding
    /// While set, only the control with this key can take focus — see the
    /// restore in `TvDetailsContent`.
    let restrictFocusToKey: String?
    let entryLocked: Bool
    let onMoveUpFromSeason: () -> Void
    let onMoveDownFromEpisode: () -> Void

    @State private var selectedSeason: Int
    @State private var seasonEpisodes: [NuvioVideo]
    @State private var seasonEpisodeIndexByID: [String: Int]
    @State private var episodeScrollIndex: Int
    @State private var watchedEpisodeKeys: Set<String>
    @State private var episodeWatchCounts: [String: Int]
    @State private var watchedSummary: WatchedEpisodeSummary?
    @State private var seasonIsWatched: Bool
    @State private var userDidSelectSeason = false
    @State private var episodeRatings: [String: [NuvioExternalRating]] = [:]
    @State private var ratingOrderRevision: UInt64 = 0
    @AppStorage(SettingsKey.smoothFocus) private var smoothFocus = true
    @AppStorage(SettingsKey.smartStreamSelection) private var smartStreamSelection = false
    @AppStorage(SettingsKey.reuseLastLink) private var reuseLastLink = false

    init(
        meta: NuvioMeta,
        libraryWatchedContext: LibraryWatchedContext? = nil,
        episodeGuide: TvEpisodeGuide,
        initialState: TvDetailsEpisodeInitialState,
        presentationRevision: TvDetailsEpisodePresentationRevision,
        seriesRating: Double?,
        continueItem: ContinueWatchingItem?,
        isChoosingWatchPartyEpisode: Bool = false,
        onCancelWatchPartySelection: @escaping () -> Void = {},
        onFocus: @escaping () -> Void,
        onSelect: @escaping (NuvioVideo) -> Void,
        onPlayManually: ((NuvioVideo) -> Void)? = nil,
        onEpisodeMenuPresented: @escaping (Bool) -> Void,
        onBack: (() -> Void)? = nil,
        episodeFocus: FocusState<String?>.Binding,
        restrictFocusToKey: String?,
        entryLocked: Bool,
        onMoveUpFromSeason: @escaping () -> Void,
        onMoveDownFromEpisode: @escaping () -> Void
    ) {
        self.meta = meta
        self.libraryWatchedContext = libraryWatchedContext
        self.episodeGuide = episodeGuide
        self.initialState = initialState
        self.presentationRevision = presentationRevision
        self.seriesRating = seriesRating
        self.continueItem = continueItem
        self.isChoosingWatchPartyEpisode = isChoosingWatchPartyEpisode
        self.onCancelWatchPartySelection = onCancelWatchPartySelection
        self.onFocus = onFocus
        self.onSelect = onSelect
        self.onPlayManually = onPlayManually
        self.onEpisodeMenuPresented = onEpisodeMenuPresented
        self.onBack = onBack
        self.episodeFocus = episodeFocus
        self.restrictFocusToKey = restrictFocusToKey
        self.entryLocked = entryLocked
        self.onMoveUpFromSeason = onMoveUpFromSeason
        self.onMoveDownFromEpisode = onMoveDownFromEpisode
        _selectedSeason = State(initialValue: initialState.selectedSeason)
        _seasonEpisodes = State(initialValue: initialState.seasonEpisodes)
        _seasonEpisodeIndexByID = State(initialValue: initialState.seasonEpisodeIndexByID)
        _episodeScrollIndex = State(initialValue: initialState.episodeScrollIndex)
        _watchedEpisodeKeys = State(initialValue: initialState.watchedEpisodeKeys)
        _episodeWatchCounts = State(initialValue: initialState.episodeWatchCounts)
        _watchedSummary = State(initialValue: initialState.watchedSummary)
        _seasonIsWatched = State(initialValue: initialState.seasonIsWatched)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            if isChoosingWatchPartyEpisode {
                watchPartySelectionPrompt
            }
            watchedProgressSummary
            seasonSelector
            episodeCardStrip
        }
        .focusSection()
        .onExitCommand {
            if isChoosingWatchPartyEpisode {
                onCancelWatchPartySelection()
            } else {
                onBack?()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: WatchedStore.changedNotification).receive(on: RunLoop.main)) { _ in
            refreshWatchedState()
        }
        .onReceive(NotificationCenter.default.publisher(for: TraktAuthStore.changedNotification).receive(on: RunLoop.main)) { _ in
            refreshWatchedState()
        }
        .onReceive(NotificationCenter.default.publisher(for: TraktSettingsStore.continueWatchingChangedNotification).receive(on: RunLoop.main)) { _ in
            refreshWatchedState()
        }
        .onReceive(NotificationCenter.default.publisher(for: TraktSettingsStore.libraryChangedNotification).receive(on: RunLoop.main)) { _ in
            refreshWatchedState()
        }
        .onReceive(NotificationCenter.default.publisher(for: AddonRatingsService.ratingOrderChangedNotification).receive(on: RunLoop.main)) { _ in
            ratingOrderRevision &+= 1
        }
        .onChange(of: presentationRevision) { oldRevision, newRevision in
            if oldRevision.selection != newRevision.selection {
                refreshEpisodeGuideState()
            } else {
                refreshWatchedState(
                    using: initialState.watchedEpisodeKeys,
                    episodeWatchCounts: initialState.episodeWatchCounts
                )
            }
        }
        .onChange(of: selectedSeason) { _, newSeason in
            setSeasonEpisodes(episodeGuide.episodesBySeason[newSeason] ?? [])
        }
    }

    private var watchPartySelectionPrompt: some View {
        HStack(spacing: 18) {
            Label("Choose an episode for your Watch Party", systemImage: "person.2.fill")
                .font(.system(size: 23, weight: .semibold))
                .foregroundStyle(.white)
            Spacer()
            Button("Cancel", action: onCancelWatchPartySelection)
                .buttonStyle(PosterCardButtonStyle())
                .focusEffectDisabledIfAvailable()
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 18)
        .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func refreshEpisodeGuideState() {
        let watchedKeys = initialState.watchedEpisodeKeys
        watchedEpisodeKeys = watchedKeys
        episodeWatchCounts = initialState.episodeWatchCounts
        watchedSummary = initialState.watchedSummary
        if !userDidSelectSeason || !episodeGuide.seasons.contains(selectedSeason) {
            selectedSeason = initialState.selectedSeason
            setSeasonEpisodes(initialState.seasonEpisodes, watchedKeys: watchedKeys)
            episodeScrollIndex = initialState.episodeScrollIndex
        } else {
            setSeasonEpisodes(
                episodeGuide.episodesBySeason[selectedSeason] ?? [],
                watchedKeys: watchedKeys
            )
        }
    }

    private func refreshWatchedState() {
        let snapshot = libraryWatchedContext.map {
            WatchedStore.librarySnapshot(for: $0.source, profileId: $0.profileId)
        } ?? WatchedStore.currentSnapshot()
        refreshWatchedState(
            using: libraryWatchedContext == nil
                ? snapshot.watchedEpisodeKeys(meta: meta)
                : snapshot.catalogWatchedEpisodeKeys(meta: meta),
            episodeWatchCounts: snapshot.catalogEpisodeWatchCounts(meta: meta)
        )
    }

    private func refreshWatchedState(
        using watchedKeys: Set<String>,
        episodeWatchCounts: [String: Int]
    ) {
        watchedEpisodeKeys = watchedKeys
        self.episodeWatchCounts = episodeWatchCounts
        watchedSummary = WatchedEpisodeSummary.make(
            videos: episodeGuide.episodes,
            watchedEpisodeKeys: watchedKeys
        )
        refreshSeasonWatchedState(for: seasonEpisodes, watchedKeys: watchedKeys)
    }

    private func setSeasonEpisodes(_ newEpisodes: [NuvioVideo], watchedKeys: Set<String>? = nil) {
        seasonEpisodes = newEpisodes
        seasonEpisodeIndexByID = Self.episodeIndexByID(newEpisodes)
        refreshSeasonWatchedState(for: newEpisodes, watchedKeys: watchedKeys ?? watchedEpisodeKeys)
    }

    private static func episodeIndexByID(_ episodes: [NuvioVideo]) -> [String: Int] {
        episodes.enumerated().reduce(into: [:]) { indices, entry in
            indices[entry.element.id] = entry.offset
        }
    }

    private func refreshSeasonWatchedState(for seasonEpisodes: [NuvioVideo], watchedKeys: Set<String>) {
        seasonIsWatched = !seasonEpisodes.isEmpty && seasonEpisodes.allSatisfy {
            watchedKeys.contains("\($0.season):\($0.episode)")
        }
    }

    @ViewBuilder
    private var watchedProgressSummary: some View {
        if let summary = watchedSummary {
            HStack(spacing: 18) {
                Label {
                    Text(
                        L10n.format(
                            "details_watched_progress",
                            fallback: "Watched %d/%d episodes",
                            summary.watchedCount,
                            summary.totalCount
                        )
                    )
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                }
                .font(.system(size: 24, weight: .semibold))
                .foregroundColor(.white.opacity(0.84))

                ProgressView(value: summary.progress, total: 1)
                    .progressViewStyle(LinearProgressViewStyle(tint: Color(red: 0.10, green: 0.68, blue: 0.34)))
                    .frame(width: 260)
                    .accessibilityLabel(
                        L10n.format(
                            "details_watched_progress",
                            fallback: "Watched %d/%d episodes",
                            summary.watchedCount,
                            summary.totalCount
                        )
                    )
            }
            .padding(.horizontal, 34)
            .padding(.vertical, 14)
            .background(
                Capsule()
                    .fill(Color.white.opacity(0.10))
            )
        }
    }

    private func materializedEpisodeIndices(visibleCardCount: Int) -> [Int] {
        guard !seasonEpisodes.isEmpty else { return [] }
        let focusIndex = min(max(episodeScrollIndex, 0), seasonEpisodes.count - 1)
        var lowerBound = max(0, focusIndex - 4)
        var upperBound = min(seasonEpisodes.count - 1, focusIndex + visibleCardCount + 2)

        if let restriction = effectiveFocusRestriction {
            let prefix = "episode-card\u{1}"
            if restriction.hasPrefix(prefix) {
                let targetID = String(restriction.dropFirst(prefix.count))
                if let targetIndex = seasonEpisodeIndexByID[targetID] {
                    lowerBound = min(lowerBound, targetIndex)
                    upperBound = max(upperBound, targetIndex)
                }
            }
        }

        return Array(lowerBound...upperBound)
    }

    private var episodeCardStrip: some View {
        GeometryReader { geo in
            let edgeInset = max(0, geo.frame(in: .global).minX)
            let stripWidth = geo.size.width + edgeInset * 2
            let visibleCardCount = max(1, Int(ceil(stripWidth / TvEpisodeCardLayout.step)) + 1)
            let materializedIndices = materializedEpisodeIndices(visibleCardCount: visibleCardCount)
            let materializedEpisodes = materializedIndices.map { seasonEpisodes[$0] }

            HStack(alignment: .bottom, spacing: TvEpisodeCardLayout.spacing) {
                ForEach(materializedEpisodes) { video in
                    let itemIndex = seasonEpisodeIndexByID[video.id] ?? 0
                    let watchKey = "\(video.season):\(video.episode)"
                    let episodeWatchCount = episodeWatchCounts[watchKey]
                        ?? (watchedEpisodeKeys.contains(watchKey) ? 1 : 0)
                    let epRating = episodeRatings[meta.canonicalEpisodeStreamId(for: video)] ?? []
                    TvEpisodeCard(
                        video: video,
                        fallbackArtworkURL: meta.backdropUrl,
                        fallbackRating: seriesRating,
                        continueProgress: continueProgress(for: video),
                        isWatched: watchedEpisodeKeys.contains(watchKey),
                        watchCount: episodeWatchCount,
                        isSeasonWatched: isSeasonWatched,
                        episodeRatings: epRating,
                        onFocus: {
                            episodeScrollIndex = itemIndex
                            onFocus()
                        },
                        onToggleWatched: {
                            let isWatched = watchedEpisodeKeys.contains(watchKey)
                            if let libraryWatchedContext {
                                _ = libraryWatchedContext.setWatched(
                                    meta,
                                    season: video.season,
                                    episode: video.episode,
                                    isWatched: !isWatched
                                )
                            } else {
                                _ = WatchedStore.toggleEpisode(
                                    meta: meta,
                                    season: video.season,
                                    episode: video.episode
                                )
                            }
                        },
                        onMarkWatchedUpTo: {
                            if let libraryWatchedContext {
                                _ = libraryWatchedContext.setWatchedUpTo(
                                    meta,
                                    season: video.season,
                                    episode: video.episode
                                )
                            } else {
                                WatchedStore.markWatchedUpTo(
                                    meta: meta,
                                    season: video.season,
                                    episode: video.episode
                                )
                            }
                        },
                        onToggleSeasonWatched: {
                            if let libraryWatchedContext {
                                _ = libraryWatchedContext.setSeasonWatched(
                                    meta,
                                    season: selectedSeason,
                                    episodes: seasonEpisodes.map(\.episode),
                                    isWatched: !isSeasonWatched
                                )
                            } else {
                                WatchedStore.setSeasonWatched(
                                    meta: meta,
                                    season: selectedSeason,
                                    episodes: seasonEpisodes.map(\.episode),
                                    isWatched: !isSeasonWatched
                                )
                            }
                        },
                        onMenuOpened: { onEpisodeMenuPresented(true) },
                        onMenuClosed: { onEpisodeMenuPresented(false) },
                        action: { onSelect(video) },
                        onPlayManually: onPlayManually != nil ? { onPlayManually?(video) } : nil,
                        smartStreamSelection: smartStreamSelection || (reuseLastLink && LastPlaybackStreamStore.load(metaId: meta.id, season: video.season, episode: video.episode, meta: meta, profileId: ProfileSettings.activeProfileID) != nil),
                        onBack: onBack,
                        focus: episodeFocus,
                        restrictFocusToKey: effectiveFocusRestriction,
                        onMoveDown: onMoveDownFromEpisode,
                        onMoveUp: seasons.count <= 1 ? onMoveUpFromSeason : nil
                    )
                }
            }
            .padding(.leading, CGFloat(materializedIndices.first ?? 0) * TvEpisodeCardLayout.step)
            .padding(.vertical, TvEpisodeCardLayout.verticalPadding)
            .offset(x: edgeInset - CGFloat(episodeScrollIndex) * TvEpisodeCardLayout.step)
            .frame(width: stripWidth, height: TvEpisodeCardLayout.stripHeight, alignment: .leading)
            // Match the cast rail: episode cards may draw through the details
            // column up to the screen edge instead of being cut off early.
            .offset(x: -edgeInset)
            // Critically damped — same no-bounce Home strip feel.
            .animation(smoothFocus ? .spring(response: 0.3, dampingFraction: 1.0) : nil, value: episodeScrollIndex)
        }
        .frame(height: TvEpisodeCardLayout.stripHeight)
        .task(id: "\(selectedSeason)-\(materializedEpisodeIndices(visibleCardCount: 6).first ?? 0)-\(materializedEpisodeIndices(visibleCardCount: 6).last ?? 0)") {
            let visibleCount = max(1, Int(ceil(1920 / TvEpisodeCardLayout.step)) + 1)
            let indices = materializedEpisodeIndices(visibleCardCount: visibleCount)
            let episodes = indices.compactMap { seasonEpisodes.indices.contains($0) ? seasonEpisodes[$0] : nil }
            guard !episodes.isEmpty else { return }
            let ids = episodes.map { meta.canonicalEpisodeStreamId(for: $0) }
            let results = await AddonRatingsService.fetchRatingsForEpisodes(episodeIds: ids)
            if !results.isEmpty {
                episodeRatings.merge(results) { _, new in new }
            }
        }
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
                            onMoveUp: onMoveUpFromSeason,
                            onBack: onBack,
                            action: {
                                userDidSelectSeason = true
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
            // The pills are the strip's other focus target, and the one the
            // engine picked when an episode's picker closed.
            .disabled(effectiveFocusRestriction != nil)
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
        episodeGuide.seasons
    }

    private var effectiveFocusRestriction: String? {
        if let restrictFocusToKey { return restrictFocusToKey }
        guard entryLocked, !seasonEpisodes.isEmpty else { return nil }
        let index = min(max(episodeScrollIndex, 0), seasonEpisodes.count - 1)
        return TvEpisodeFocus.card(seasonEpisodes[index].id)
    }

    /// A season counts as watched only when every episode in it is, which is
    /// what makes the menu item a genuine toggle rather than a re-mark.
    private var isSeasonWatched: Bool {
        seasonIsWatched
    }

    private func seasonTitle(_ season: Int) -> String {
        season <= 0 ? "Specials" : "Season \(season)"
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

/// Focus keys for episode cards in the strip.
private enum TvEpisodeFocus {
    static func card(_ videoID: String) -> String { "episode-card\u{1}\(videoID)" }
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
    let onMoveUp: () -> Void
    var onBack: (() -> Void)? = nil
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
        .onChange(of: isFocused) { _, focused in
            if focused { onFocus() }
        }
        .onExitCommand {
            onBack?()
        }
        .onMoveCommand { direction in
            if direction == .up {
                onMoveUp()
            }
        }
    }
}

private struct TvEpisodeRatingItem: Identifiable {
    let id: String
    let source: String
    let displayName: String
    let valueText: String
    let iconUrl: URL?
    let assetName: String?
    let color: Color
}

private struct TvEpisodeCard: View {
    let video: NuvioVideo
    let fallbackArtworkURL: String?
    let fallbackRating: Double?
    let continueProgress: Double?
    let isWatched: Bool
    let watchCount: Int
    let isSeasonWatched: Bool
    var episodeRatings: [NuvioExternalRating] = []
    let onFocus: () -> Void
    let onToggleWatched: () -> Void
    let onMarkWatchedUpTo: () -> Void
    let onToggleSeasonWatched: () -> Void
    /// Called when a long press raises the context menu, and again when one of
    /// its items closes it — see the `.contextMenu` below.
    let onMenuOpened: () -> Void
    let onMenuClosed: () -> Void
    let action: () -> Void
    var onPlayManually: (() -> Void)? = nil
    var smartStreamSelection: Bool = false
    var onBack: (() -> Void)? = nil
    var focus: FocusState<String?>.Binding
    let restrictFocusToKey: String?
    let onMoveDown: () -> Void
    var onMoveUp: (() -> Void)? = nil

    @AppStorage(SettingsKey.cardCornerRadius) private var cardCornerRadiusSetting = AppCardStyle.defaultCornerRadiusRaw
    @AppStorage(SettingsKey.liquidGlassCards) private var liquidGlassCards = true

    private var cardKey: String { TvEpisodeFocus.card(video.id) }
    private var isFocused: Bool { focus.wrappedValue == cardKey }

    private let cardWidth: CGFloat = TvEpisodeCardLayout.width
    private let thumbHeight: CGFloat = 300
    private let cardHeight: CGFloat = TvEpisodeCardLayout.height

    private var episodeCornerRadius: CGFloat {
        AppCardStyle.episodeCornerRadius(for: cardCornerRadiusSetting)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: episodeCornerRadius, style: .continuous)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
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
                    Text(L10n.format("details_episode_number", fallback: "EPISODE %d", video.episode))
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background {
                            if liquidGlassCards {
                                Capsule()
                                    .fill(Color.white.opacity(0.14))
                                    .modifier(LiquidGlassBadgeModifier(cornerRadius: 16))
                            } else {
                                Capsule()
                                    .fill(Color.black.opacity(0.52))
                            }
                        }

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

                    HStack(spacing: 16) {
                        ForEach(episodeRatingItems) { item in
                            HStack(spacing: 6) {
                                if let iconUrl = item.iconUrl {
                                    CachedRatingIcon(url: iconUrl, fallbackColor: item.color)
                                        .frame(width: 22, height: 22)
                                } else if let assetName = item.assetName {
                                    Image(assetName)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(height: 20)
                                } else {
                                    Text(item.displayName)
                                        .font(.system(size: 20, weight: .bold))
                                        .foregroundColor(.white.opacity(0.78))
                                }

                                Text(item.valueText)
                                    .font(.system(size: 20, weight: .bold))
                                    .foregroundColor(item.color)
                            }
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
                }
                .frame(width: cardWidth, height: cardHeight)
                .background {
                    if liquidGlassCards {
                        #if os(tvOS)
                        if #available(tvOS 26.0, *) {
                            shape
                                .fill(isFocused ? Color.white.opacity(0.18) : Color.white.opacity(0.08))
                                .glassEffect(.regular, in: shape)
                        } else {
                            shape
                                .fill(isFocused ? Color.white.opacity(0.18) : Color.white.opacity(0.08))
                        }
                        #else
                        shape.fill(isFocused ? Color.white.opacity(0.18) : Color.white.opacity(0.08))
                        #endif
                    } else {
                        shape
                            .fill(isFocused ? Color.white.opacity(0.18) : Color.white.opacity(0.08))
                    }
                }
                .clipShape(shape)
                .modifier(
                    LiquidGlassCardModifier(
                        cornerRadius: episodeCornerRadius,
                        isFocused: isFocused,
                        isEnabled: liquidGlassCards
                    )
                )
                .overlay(alignment: .topTrailing) {
                    if watchCount > 0 {
                        WatchedCheckmarkIcon(watchCount: watchCount)
                    }
                }
                .overlay(
                    shape.stroke(
                        isFocused ? AppFocusOutline.color : Color.clear,
                        lineWidth: isFocused ? AppFocusOutline.width : 0
                    )
                )
                .shadow(
                    color: Color.black.opacity(isFocused ? 0.45 : 0.22),
                    radius: isFocused ? 20 : 10,
                    y: isFocused ? 14 : 6
                )
            }
            .buttonStyle(PosterCardButtonStyle())
            .focused(focus, equals: cardKey)
            .focusEffectDisabledIfAvailable()
            .disabled(restrictFocusToKey != nil && restrictFocusToKey != cardKey)
            .scaleEffect(isFocused ? 1.05 : 1)
            .animation(.easeOut(duration: 0.14), value: isFocused)
            .onChange(of: isFocused) { _, focused in
                if focused { onFocus() }
            }
            .onExitCommand {
                onBack?()
            }
            .contextMenu {
                if smartStreamSelection, let onPlayManually {
                    Button {
                        performAfterMenuDismissal(onPlayManually)
                    } label: {
                        Label(
                            L10n.string("action_select_stream_manually", fallback: "Choose Source Manually"),
                            systemImage: "list.bullet"
                        )
                    }
                }

                Button {
                    performAfterMenuDismissal(onToggleWatched)
                } label: {
                    Label(
                        isWatched
                            ? L10n.string("details_mark_as_unwatched", fallback: "Mark as unwatched")
                            : L10n.string("details_mark_as_watched", fallback: "Mark as watched"),
                        systemImage: isWatched ? "eye.slash.fill" : "eye.fill"
                    )
                }

                Button {
                    performAfterMenuDismissal(onMarkWatchedUpTo)
                } label: {
                    Label(
                        L10n.string("details_mark_up_to_this_point_as_watched", fallback: "Mark up to this point as watched"),
                        systemImage: "checklist.checked"
                    )
                }

                Button {
                    performAfterMenuDismissal(onToggleSeasonWatched)
                } label: {
                    Label(
                        isSeasonWatched
                            ? L10n.string("details_mark_season_as_unwatched", fallback: "Mark season as unwatched")
                            : L10n.string("details_mark_season_as_watched", fallback: "Mark season as watched"),
                        systemImage: isSeasonWatched ? "eye.slash" : "eye"
                    )
                }
            }
        }
        .onMoveCommand { direction in
            if direction == .down {
                onMoveDown()
            } else if direction == .up {
                onMoveUp?()
            }
        }
    }

    /// A native tvOS context-menu action runs before the menu's presentation
    /// transaction has finished. Rebuilding the episode rail from a watched
    /// notification in that transaction produces SwiftUI's
    /// `setPresentationValue`/menu-lock warnings, so commit on the next settled
    /// main-loop turn instead.
    private func performAfterMenuDismissal(_ action: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            onMenuClosed()
            action()
        }
    }

    private var episodeArtwork: some View {
        CachedPosterArtwork(
            urlString: video.thumbnail,
            fallbackURLString: fallbackArtworkURL,
            width: cardWidth,
            height: cardHeight,
            placeholder: { placeholderThumb }
        )
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

            HStack(spacing: 16) {
                ForEach(episodeRatingItems) { item in
                    HStack(spacing: 6) {
                        if let iconUrl = item.iconUrl {
                            CachedRatingIcon(url: iconUrl, fallbackColor: item.color)
                                .frame(width: 22, height: 22)
                        } else if let assetName = item.assetName {
                            Image(assetName)
                                .resizable()
                                .scaledToFit()
                                .frame(height: 20)
                        } else {
                            Text(item.displayName)
                                .font(.system(size: 20, weight: .bold))
                                .foregroundColor(.white.opacity(0.78))
                        }

                        Text(item.valueText)
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(item.color)
                    }
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

    private var episodeRatingItems: [TvEpisodeRatingItem] {
        var items: [TvEpisodeRatingItem] = []

        for rating in episodeRatings {
            let formatted = AddonRatingsService.formatRating(value: rating.value, max: rating.max)
            items.append(
                TvEpisodeRatingItem(
                    id: rating.source,
                    source: rating.source,
                    displayName: rating.name ?? rating.source.capitalized,
                    valueText: formatted,
                    iconUrl: rating.iconUrl.flatMap { URL(string: $0) },
                    assetName: nil,
                    color: Color(red: 0.96, green: 0.77, blue: 0.22)
                )
            )
        }

        if let ratingText {
            items.append(
                TvEpisodeRatingItem(
                    id: "imdb",
                    source: "imdb",
                    displayName: "IMDb",
                    valueText: ratingText,
                    iconUrl: nil,
                    assetName: "rating_imdb",
                    color: Color(red: 0.96, green: 0.77, blue: 0.22)
                )
            )
        }

        return AddonRatingsService.sortRatings(items, by: { $0.source })
    }

    private var ratingText: String? {
        if let r = video.rating?.trimmingCharacters(in: .whitespaces), !r.isEmpty {
            return r
        }
        if episodeRatings.isEmpty, let fb = fallbackRating {
            return String(format: "%.1f", fb)
        }
        return nil
    }

    private var dateText: String? {
        if let formatted = NuvioDateDisplay.formattedDate(video.released) {
            return formatted
        }
        return L10n.string("details_date_tbd", fallback: "TBD")
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
                .background(Color.black.opacity(0.20), in: shape)
                .background(Color.white.opacity(0.08), in: shape)
                .glassEffect(.regular, in: shape)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .background(Color.black.opacity(0.30), in: shape)
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
private struct TvStreamPickerOverlay: View {
    let meta: NuvioMeta
    let episode: NuvioVideo?
    let streams: [NuvioStream]
    let groups: [AddonStreamGroup]
    let streamsRevision: UInt64
    let isLoading: Bool
    let emptyReason: StreamsEmptyStateReason?
    /// Whether torrent-only streams should be listed (Debrid or local P2P is enabled).
    var includeDebrid: Bool = true
    /// A torrent stream is being turned into a playable link right now.
    let isResolvingDebrid: Bool
    var initialAvailabilityMessage: String? = nil
    let onSelect: (NuvioStream, ExternalPlayer?) -> Void
    var onRefresh: (() -> Void)? = nil
    let onDismiss: () -> Void

    /// Filter by stable add-on id (not display name).
    @State private var selectedAddonId: String?
    @AppStorage(SettingsKey.streamSortOption) private var sortOption: StreamSortOption = .quality
    @State private var showSortOptions = false
    @AppStorage(SettingsKey.cachedOnlyStreams) private var cachedOnly = false
    @AppStorage(SettingsKey.preserveAddonStreamOrder) private var preserveAddonOrder = false
    /// Cached filter+sort result. Rebuilt only when derivation inputs change —
    /// never when focus moves between cards.
    @State private var displayedStreams: [NuvioStream] = []
    @State private var displayedStreamsCacheKey: StreamPickerListCacheKey?
    /// Number of streams currently materialized in the picker list for lazy loading.
    @State private var visibleStreamLimit: Int = StreamPickerListBuilder.defaultPageSize
    /// Badge matching is regex-heavy, so derive it with the stream-list cache
    /// instead of from SwiftUI card initializers during focus updates.
    @State private var streamCardPresentations: [String: TvStreamCardPresentation] = [:]
    @State private var streamBadgeSettingsRevision: UInt64 = 0
    // A single focus state for the whole picker (filter chips + stream cards),
    // keyed by string. Filter chips use the "filter::" prefix; stream cards use
    // their natural id. One shared state makes programmatic focus moves reliable
    // and lets us seed focus on appear so the picker is never in limbo.
    @FocusState private var focusedItem: String?
    /// Whether focus has been handed to a stream card yet. The picker usually
    /// mounts while discovery is still running, so the first seed can only land
    /// on the All chip; this drives the hand-off once results exist, once.
    @State private var didSeedStreamFocus = false
    @State private var restoredSourceFocusID: String?
    @State private var pickerProfileID: String?
    @State private var pickerIsVisible = false
    @State private var streamBadgeSettings = StreamBadgeSettingsStore.snapshot
    @State private var showRefreshToast = false
    @State private var isRefreshing = false
    @State private var refreshToastTask: Task<Void, Never>?
    @State private var unavailableAlertMessage: String?
    @State private var didPresentInitialAvailabilityMessage = false
    @State private var episodeRatings: [NuvioExternalRating] = []
    @State private var ratingOrderRevision: UInt64 = 0
    @State private var showingP2PConsent = false
    @State private var pendingTorrentSelection: (stream: NuvioStream, player: ExternalPlayer?)? = nil


    private let filterAllKey = "filter::all"
    private let sortKey = "filter::sort"
    private let cachedKey = "filter::cached"
    private func filterKey(_ addonId: String) -> String { "filter::\(addonId)" }

    private var effectiveCachedOnly: Bool {
        SmartPlaybackSelector.effectiveCachedOnly(cachedOnly, contentType: meta.type)
    }

    private var showsCachedOnlyFilter: Bool {
        DebridResolver(store: ProfileSettings.current).isEnabled && SmartPlaybackSelector.effectiveCachedOnly(true, contentType: meta.type)
    }

    /// Inputs that may change the visible stream list (not focus).
    private var listCacheKey: StreamPickerListCacheKey {
        StreamPickerListBuilder.cacheKey(
            revision: streamsRevision,
            selectedAddonId: selectedAddonId,
            sortOption: sortOption,
            includeDebrid: includeDebrid,
            cachedOnly: effectiveCachedOnly,
            preserveAddonStreams: preserveAddonOrder
        )
    }

    private var streamCardPresentationCacheKey: TvStreamCardPresentationCacheKey {
        TvStreamCardPresentationCacheKey(
            listKey: displayedStreamsCacheKey,
            badgeSettingsRevision: streamBadgeSettingsRevision,
            visibleLimit: visibleStreamLimit
        )
    }

    var body: some View {
        GeometryReader { proxy in
            // Keep the picker anchored to a stable top inset. A centered stack
            // can be displaced when tvOS gives the full-screen cover an
            // oversized height while its focus hierarchy is settling; that
            // leaves the filters and the first stream card below the viewport.
            let canvasWidth = min(proxy.size.width, 1_920)
            let canvasHeight = min(proxy.size.height, 1_080)
            let summaryWidth = min(canvasWidth * 0.34, 620)
            let panelWidth = min(canvasWidth * 0.56, 1_080)
            let panelHeight = min(max(canvasHeight - 300, 440), 720)
            let panelStackHeight = panelHeight + 118
            let panelCenterY = canvasHeight / 2
            let panelTopY = panelCenterY - panelStackHeight / 2
            let streamBoxCenterY = panelTopY + 118 + panelHeight / 2

            ZStack {
                TvDetailsBackdrop(meta: meta)
                Color.black.opacity(0.55).ignoresSafeArea()

                // The summary and picker are independent layers. Their former
                // shared HStack let the summary's async logo/intrinsic height
                // move the picker during tvOS focus layout.
                leftSummary
                    .frame(width: summaryWidth, alignment: .center)
                    .position(
                        x: 96 + summaryWidth / 2,
                        y: streamBoxCenterY
                    )

                VStack(alignment: .leading, spacing: 28) {
                    filterRow
                        // A horizontal ScrollView has no intrinsic cross-axis
                        // size, so constrain it independently of focus changes.
                        .frame(height: 90)

                    streamPanel
                        .frame(
                            width: panelWidth,
                            height: panelHeight
                        )
                }
                .frame(width: panelWidth, height: panelStackHeight, alignment: .top)
                .position(
                    x: canvasWidth - 64 - panelWidth / 2,
                    y: panelCenterY
                )

                if showRefreshToast {
                    VStack {
                        HStack(spacing: 14) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 22, weight: .semibold))
                                .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                                .animation(
                                    isRefreshing
                                        ? .linear(duration: 0.9).repeatForever(autoreverses: false)
                                        : .default,
                                    value: isRefreshing
                                )
                            Text(L10n.string("details_refreshing_sources", fallback: "Refreshing sources…"))
                                .font(.system(size: 22, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 14)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(
                            Capsule().stroke(Color.white.opacity(0.15), lineWidth: 1)
                        )
                        .padding(.top, 40)
                        Spacer()
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .allowsHitTesting(false)
                    .zIndex(10)
                }
            }
            .background(
                RemoteUpHoldPressCatcher(isActive: !isResolvingDebrid) {
                    performRefresh()
                }
            )
            // The picker mounts before discovery finishes, so this seed usually
            // lands on the All chip; seedStreamFocusIfNeeded hands focus to the
            // first card once results exist.
            .onAppear {
                pickerIsVisible = true
                pickerProfileID = ProfileSettings.activeProfileID
                refreshDisplayedStreamsIfNeeded()
                seedInitialFocus()
                if !didPresentInitialAvailabilityMessage {
                    didPresentInitialAvailabilityMessage = true
                    unavailableAlertMessage = initialAvailabilityMessage
                }
            }
            // Progressive add-on results, filter chips, sort, and debrid toggle
            // all flow through this cache key. Focus is excluded.
            .onChange(of: listCacheKey) { _, _ in
                refreshDisplayedStreamsIfNeeded()
                seedStreamFocusIfNeeded()
            }
            .onChange(of: isLoading) { _, loading in
                if !loading {
                    seedStreamFocusIfNeeded()
                    withAnimation(.easeInOut(duration: 0.25)) {
                        isRefreshing = false
                    }
                }
            }
            // The focus engine can still reject the seed after grabFocus reads
            // back its own write and stops retrying — e.g. the panel's loading
            // spinner keeps real focus while it fades out, then its removal
            // makes the engine re-resolve and write nil into this binding,
            // visibly un-highlighting the first card. If focus evaporates while
            // the picker is up, grab it again — but only if it's *still* gone
            // after a beat. A fast scroll blips `focusedItem` to nil between
            // cards before landing on the next one; re-seeding on that blip
            // snaps focus back to the first stream (the reported bug), so we
            // debounce and bail when focus has already landed somewhere.
            .onChange(of: focusedItem) { _, newValue in
                if let newValue, newValue != filterAllKey, !didSeedStreamFocus {
                    didSeedStreamFocus = true
                }
                guard newValue == nil else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    if focusedItem == nil {
                        seedInitialFocus()
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: StreamBadgeSettingsStore.changedNotification).receive(on: RunLoop.main)) { _ in
                streamCardPresentations.removeAll(keepingCapacity: true)
                streamBadgeSettings = StreamBadgeSettingsStore.snapshot
                streamBadgeSettingsRevision &+= 1
            }
            .onDisappear { pickerIsVisible = false }
            .onExitCommand(perform: onDismiss)
        }
        .background(Color.black.ignoresSafeArea())
        .onReceive(NotificationCenter.default.publisher(for: AddonRatingsService.ratingOrderChangedNotification).receive(on: RunLoop.main)) { _ in
            ratingOrderRevision &+= 1
        }
        .task(id: episode?.id) {
            guard let episode else {
                episodeRatings = []
                return
            }
            let episodeId = meta.canonicalEpisodeStreamId(for: episode)
            let ratings = await AddonRatingsService.fetchRatingsForEpisode(episodeId: episodeId)
            episodeRatings = ratings
        }
        .task(id: streamCardPresentationCacheKey, priority: .utility) {
            await rebuildStreamCardPresentations()
        }
        .alert(
            L10n.string("details_source_unavailable", fallback: "Source unavailable"),
            isPresented: Binding(
                get: { unavailableAlertMessage != nil },
                set: { if !$0 { unavailableAlertMessage = nil } }
            )
        ) {
            Button(L10n.string("common_ok", fallback: "OK"), role: .cancel) {
                unavailableAlertMessage = nil
            }
        } message: {
            Text(unavailableAlertMessage ?? "")
        }
        .alert(
            L10n.string("tvos_settings_p2p_consent_title", fallback: "P2P Torrent Streaming"),
            isPresented: $showingP2PConsent
        ) {
            Button(L10n.string("tvos_settings_p2p_consent_enable", fallback: "Enable P2P")) {
                TorrentSettings.setConsentAccepted(true)
                TorrentSettings.setEnabled(true)
                if let pending = pendingTorrentSelection {
                    pendingTorrentSelection = nil
                    onSelect(pending.stream, pending.player)
                }
            }
            Button(L10n.string("tvos_settings_p2p_consent_cancel", fallback: "Cancel"), role: .cancel) {
                pendingTorrentSelection = nil
            }
        } message: {
            Text(L10n.string(
                "tvos_settings_p2p_consent_message",
                fallback: "P2P connects directly to other peers. Your public IP address may be visible to them, and your device may upload data. Enable this only for content you have the legal right to access."
            ))
        }
    }

    /// Rendering always uses the cached list. A progressive source revision may
    /// leave it one SwiftUI update behind while `onChange` refreshes the cache,
    /// which is preferable to repeating the full filter pass during body layout.
    private var activeDisplayedStreams: [NuvioStream] {
        displayedStreams
    }

    /// Paginated active slice of streams for instantaneous initial display and smooth scrolling.
    private var activeVisibleStreams: [NuvioStream] {
        StreamPickerListBuilder.paginatedSlice(
            streams: activeDisplayedStreams,
            limit: visibleStreamLimit
        )
    }

    private func loadMoreStreams() {
        guard visibleStreamLimit < activeDisplayedStreams.count else { return }
        visibleStreamLimit = min(
            visibleStreamLimit + StreamPickerListBuilder.defaultPageSize,
            activeDisplayedStreams.count
        )
    }

    private func select(_ stream: NuvioStream, player: ExternalPlayer?) {
        guard let reason = stream.unavailabilityReason else {
            let hasDebrid = DebridResolver(store: ProfileSettings.current).isEnabled
            let hasP2P = TorrentSettings.isEnabled()
            if stream.isTorrentStream && !hasDebrid && !hasP2P {
                pendingTorrentSelection = (stream, player)
                showingP2PConsent = true
                return
            }
            onSelect(stream, player)
            return
        }
        unavailableAlertMessage = reason
    }

    /// Rebuilds the cached list only when derivation inputs actually change.
    private func refreshDisplayedStreamsIfNeeded() {
        let key = listCacheKey
        guard key != displayedStreamsCacheKey else { return }
        let refreshedStreams = StreamPickerListBuilder.displayedStreams(
            streams: streams,
            groups: groups,
            selectedAddonId: selectedAddonId,
            sortOption: sortOption,
            includeDebrid: includeDebrid,
            cachedOnly: effectiveCachedOnly,
            preserveAddonStreams: preserveAddonOrder
        )
        displayedStreams = refreshedStreams
        displayedStreamsCacheKey = key
        let focusedIndex = focusedItem.flatMap { id in refreshedStreams.firstIndex { $0.id == id } }
        visibleStreamLimit = max(StreamPickerListBuilder.defaultPageSize, (focusedIndex ?? -1) + 1)
    }

    @MainActor
    private func rebuildStreamCardPresentations() async {
        let cacheKey = streamCardPresentationCacheKey
        let maxNeeded = min(visibleStreamLimit + StreamPickerListBuilder.defaultPageSize, activeDisplayedStreams.count)
        let streamsToBuild = Array(activeDisplayedStreams.prefix(maxNeeded))
        let settings = streamBadgeSettings
        let missingStreams = streamsToBuild.filter {
            streamCardPresentations[$0.id] == nil
        }
        guard !missingStreams.isEmpty else { return }

        // Preserve completed cards as add-ons publish progressively. Larger
        // batches reduce whole-overlay SwiftUI invalidations while still giving
        // cancellation a chance between chunks when a new revision arrives.
        for startIndex in stride(from: 0, to: missingStreams.count, by: 16) {
            guard !Task.isCancelled else { return }
            let endIndex = min(startIndex + 16, missingStreams.count)
            let batch = Array(missingStreams[startIndex..<endIndex])
            let batchPresentations = await TvStreamCardPresentationBuilder.shared.build(
                streams: batch,
                settings: settings
            )
            guard !Task.isCancelled,
                  cacheKey == streamCardPresentationCacheKey else { return }
            var updatedPresentations = streamCardPresentations
            updatedPresentations.merge(batchPresentations) { _, new in new }
            streamCardPresentations = updatedPresentations
        }
    }

    private var leftSummary: some View {
        VStack(alignment: .center, spacing: 30) {
            TvDetailsLogo(meta: meta, alignment: .center)

            if let episode {
                VStack(spacing: 12) {
                    Text(L10n.format("details_season_episode", fallback: "Season %1$d · Episode %2$d", episode.season, episode.episode))
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)

                    Text(episode.title)
                        .font(.system(size: 30, weight: .regular))
                        .foregroundColor(.white.opacity(0.7))
                        .lineSpacing(6)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)

                    if !episodeRatingItems.isEmpty {
                        HStack(spacing: 16) {
                            ForEach(episodeRatingItems) { item in
                                HStack(spacing: 6) {
                                    if let iconUrl = item.iconUrl {
                                        CachedRatingIcon(url: iconUrl, fallbackColor: item.color)
                                            .frame(width: 24, height: 24)
                                    } else if let assetName = item.assetName {
                                        Image(assetName)
                                            .resizable()
                                            .scaledToFit()
                                            .frame(height: 22)
                                    } else {
                                        Text(item.displayName)
                                            .font(.system(size: 22, weight: .bold))
                                            .foregroundColor(.white.opacity(0.78))
                                    }

                                    Text(item.valueText)
                                        .font(.system(size: 22, weight: .bold))
                                        .foregroundColor(item.color)
                                }
                            }
                        }
                        .padding(.top, 4)
                    }
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

    private var episodeRatingItems: [TvEpisodeRatingItem] {
        _ = ratingOrderRevision
        guard let episode else { return [] }
        var items: [TvEpisodeRatingItem] = []

        for rating in episodeRatings {
            let formatted = AddonRatingsService.formatRating(value: rating.value, max: rating.max)
            items.append(
                TvEpisodeRatingItem(
                    id: rating.source,
                    source: rating.source,
                    displayName: rating.name ?? rating.source.capitalized,
                    valueText: formatted,
                    iconUrl: rating.iconUrl.flatMap { URL(string: $0) },
                    assetName: nil,
                    color: Color(red: 0.96, green: 0.77, blue: 0.22)
                )
            )
        }

        if let ratingText = episode.rating?.trimmingCharacters(in: .whitespaces), !ratingText.isEmpty {
            items.append(
                TvEpisodeRatingItem(
                    id: "imdb",
                    source: "imdb",
                    displayName: "IMDb",
                    valueText: ratingText,
                    iconUrl: nil,
                    assetName: "rating_imdb",
                    color: Color(red: 0.96, green: 0.77, blue: 0.22)
                )
            )
        }

        return AddonRatingsService.sortRatings(items, by: { $0.source })
    }

    private var filterRow: some View {
        HStack(spacing: 18) {
            // Only add-on filters scroll. Vertical/edge padding gives the 1.06x
            // focused scale room to draw without the ScrollView clipping it.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 18) {
                    TvStreamFilterButton(
                        title: L10n.string("action_all", fallback: "All"),
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

            if showsCachedOnlyFilter {
                TvStreamFilterButton(
                    title: cachedOnly
                        ? L10n.string("details_cached_only", fallback: "Cached only")
                        : L10n.string("details_all_cache", fallback: "All cache"),
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
                title: L10n.format("details_sort_format", fallback: "Sort: %@", L10n.optionLabel(sortOption.rawValue)),
                isSelected: sortOption != .quality,
                focusBinding: $focusedItem,
                focusValue: sortKey,
                action: { showSortOptions = true }
            )
            .fixedSize(horizontal: true, vertical: false)
            .confirmationDialog(
                L10n.string("details_sort_streams_by", fallback: "Sort streams by"),
                isPresented: $showSortOptions,
                titleVisibility: .visible
            ) {
                ForEach(StreamSortOption.allCases) { option in
                    Button(L10n.optionLabel(option.rawValue)) { sortOption = option }
                }
            }
        }
        .padding(.vertical, 4)
        .focusSection()
    }

    private var streamPanel: some View {
        // Resolve once per panel body — focus changes hit the cache path only.
        let streamsToShow = activeVisibleStreams
        let totalCount = activeDisplayedStreams.count
        let badgeSettings = streamBadgeSettings
        let hasMore = totalCount > streamsToShow.count
        return ZStack {
            if isLoading && streamsToShow.isEmpty && selectedGroupError == nil {
                VStack(spacing: 24) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(1.6)

                    Text(L10n.string("details_finding_streams", fallback: "Finding streams"))
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundColor(.white.opacity(0.74))
                }
            } else if streamsToShow.isEmpty {
                VStack(spacing: 18) {
                    if selectedGroupIsLoading {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(1.4)
                        Text(L10n.format("details_checking_addon", fallback: "Checking %@…", selectedGroupName))
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
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(spacing: 28) {
                            ForEach(streamsToShow) { stream in
                                // Focus appearance is owned by the card via local
                                // @FocusState + ExternalFocusBinding so only the
                                // old/new cards pay for outline/scale updates.
                                TvStreamCard(
                                    stream: stream,
                                    presentation: streamCardPresentations[stream.id]
                                        ?? TvStreamCardPresentation(pending: badgeSettings),
                                    externalFocus: $focusedItem,
                                    action: { select(stream, player: nil) },
                                    onSelectPlayer: { player in select(stream, player: player) }
                                )
                                .id(stream.id)
                                .onAppear {
                                    if let index = streamsToShow.firstIndex(where: { $0.id == stream.id }),
                                       index >= streamsToShow.count - 4,
                                       hasMore {
                                        loadMoreStreams()
                                    }
                                }
                            }

                            if hasMore {
                                HStack(spacing: 16) {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                        .scaleEffect(1.0)
                                    Text(L10n.format("details_showing_sources_format", fallback: "Showing %1$d of %2$d sources…", streamsToShow.count, totalCount))
                                        .font(.system(size: 24, weight: .medium))
                                        .foregroundColor(.white.opacity(0.60))
                                }
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.top, 12)
                                .padding(.bottom, 20)
                                .onAppear {
                                    loadMoreStreams()
                                }
                            } else if isLoading {
                                HStack(spacing: 18) {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    Text(L10n.string("details_checking_more_addons", fallback: "Checking more add-ons…"))
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
                    .onAppear {
                        if let id = restoredSourceFocusID { proxy.scrollTo(id, anchor: .center) }
                    }
                    .onChange(of: restoredSourceFocusID) { _, id in
                        if let id { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }

            // Torrent streams take a moment to cache/unrestrict on the debrid
            // provider; cover the panel so it doesn't look frozen.
            if isResolvingDebrid {
                VStack(spacing: 24) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(1.6)

                    Text(L10n.string("details_preparing_stream", fallback: "Preparing stream"))
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
        selectedGroup?.displayName ?? L10n.string("details_addon_fallback", fallback: "add-on")
    }

    private var selectedGroupError: String? {
        selectedGroup?.error
    }

    private var emptyPanelTitle: String {
        if let selectedGroup {
            if selectedGroup.error != nil {
                return L10n.format("details_addon_failed", fallback: "%@ failed", selectedGroup.displayName)
            }
            return L10n.format("details_no_streams_from_addon", fallback: "No streams from %@", selectedGroup.displayName)
        }
        switch emptyReason {
        case .noAddonsConfigured:
            return L10n.string("details_no_stream_addons_configured", fallback: "No stream add-ons configured")
        case .noCompatibleAddons:
            return L10n.string("details_no_compatible_addons", fallback: "No compatible add-ons")
        case .noStreamsFound, .none:
            return isLoading
                ? L10n.string("details_finding_streams", fallback: "Finding streams")
                : L10n.string("details_no_playable_streams_found", fallback: "No playable streams found")
        }
    }

    private var emptyPanelDetail: String? {
        if let error = selectedGroupError {
            return error
        }
        switch emptyReason {
        case .noAddonsConfigured:
            return L10n.string("details_enable_stream_addon_settings", fallback: "Enable a stream add-on in Settings.")
        case .noCompatibleAddons:
            return L10n.string("details_addons_do_not_support_title", fallback: "Installed add-ons do not support this title.")
        case .noStreamsFound:
            return isLoading ? nil : L10n.string("details_try_another_addon_later", fallback: "Try another add-on or check back later.")
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

    private var rememberedSourceScope: (profileID: String, season: Int?, episode: Int?)? {
        guard let profileID = pickerProfileID,
              profileID == ProfileSettings.activeProfileID else { return nil }
        return (profileID, episode?.season, episode?.episode)
    }

    private func initialStreamFocusID() -> String? {
        guard ProfileSettings.current.bool(forKey: SettingsKey.rememberLastSourceFocus),
              let scope = rememberedSourceScope else { return activeDisplayedStreams.first?.id }
        let candidates = activeDisplayedStreams.filter { !$0.isNotPlayable && $0.unavailabilityReason == nil }
        if let id = LastManualSourceStore.matchingID(
            in: candidates.map(\.id), profileID: scope.profileID, metaID: meta.id, type: meta.type,
            season: scope.season, episode: scope.episode
        ), let index = activeDisplayedStreams.firstIndex(where: { $0.id == id }) {
            visibleStreamLimit = max(visibleStreamLimit, index + 1)
            restoredSourceFocusID = id
            return id
        }
        // Let progressive discovery finish before deciding the saved source is absent.
        if isLoading, LastManualSourceStore.hasRememberedSource(
            profileID: scope.profileID, metaID: meta.id, type: meta.type,
            season: scope.season, episode: scope.episode
        ) { return nil }
        return activeDisplayedStreams.first?.id
    }

    private func seedInitialFocus() {
        DispatchQueue.main.async {
            guard pickerIsVisible else { return }
            refreshDisplayedStreamsIfNeeded()
            guard focusedItem == nil || focusedItem == filterAllKey else { return }
            if didSeedStreamFocus {
                let restored = restoredSourceFocusID.flatMap { id in
                    activeDisplayedStreams.contains(where: { $0.id == id }) ? id : nil
                }
                grabFocus(restored ?? activeDisplayedStreams.first?.id ?? filterAllKey, attempt: 0)
            } else if let id = initialStreamFocusID() {
                didSeedStreamFocus = true
                grabFocus(id, attempt: 0)
            } else {
                grabFocus(filterAllKey, attempt: 0)
            }
        }
    }

    private func seedStreamFocusIfNeeded() {
        guard !didSeedStreamFocus else { return }
        guard focusedItem == nil || focusedItem == filterAllKey else {
            didSeedStreamFocus = true
            return
        }
        guard let id = initialStreamFocusID() else { return }
        didSeedStreamFocus = true
        grabFocus(id, attempt: 0)
    }

    /// Asserts focus on `id` and retries for a short window, because the target
    /// view may not be hit-testable on the very first runloop tick after it
    /// renders. `id` is captured by value (never reads a stale `streams`), and
    /// it stops the moment focus lands.
    private func grabFocus(_ id: String, attempt: Int) {
        guard pickerIsVisible else { return }
        if attempt > 0, let current = focusedItem, current != id { return }
        if focusedItem == id { return }
        focusedItem = id
        guard attempt < 12 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.07) {
            grabFocus(id, attempt: attempt + 1)
        }
    }

    private func performRefresh() {
        guard !isResolvingDebrid else { return }
        didSeedStreamFocus = false
        restoredSourceFocusID = nil
        isRefreshing = true
        withAnimation(.easeInOut(duration: 0.25)) {
            showRefreshToast = true
        }
        onRefresh?()

        refreshToastTask?.cancel()
        refreshToastTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.25)) {
                isRefreshing = false
                showRefreshToast = false
            }
        }
    }
}

private struct RemoteUpHoldPressCatcher: UIViewRepresentable {
    let isActive: Bool
    let onHoldUp: () -> Void

    func makeUIView(context: Context) -> UpHoldPressHostView {
        let view = UpHoldPressHostView()
        view.configure(isActive: isActive, onHoldUp: onHoldUp)
        return view
    }

    func updateUIView(_ uiView: UpHoldPressHostView, context: Context) {
        uiView.configure(isActive: isActive, onHoldUp: onHoldUp)
    }

    static func dismantleUIView(_ uiView: UpHoldPressHostView, coordinator: ()) {
        uiView.removeRecognizers()
    }
}

private final class UpHoldPressHostView: UIView, UIGestureRecognizerDelegate {
    private var onHoldUp: () -> Void = {}
    private var isActive = true
    private weak var attachedWindow: UIWindow?
    private var upHoldRecognizer: UILongPressGestureRecognizer?

    func configure(isActive: Bool, onHoldUp: @escaping () -> Void) {
        self.isActive = isActive
        self.onHoldUp = onHoldUp
        updateRecognizerState()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        removeRecognizers()
        guard let window else { return }

        let upHold = UILongPressGestureRecognizer(
            target: self,
            action: #selector(handleUpHold(_:))
        )
        upHold.allowedPressTypes = [NSNumber(value: UIPress.PressType.upArrow.rawValue)]
        upHold.minimumPressDuration = 0.5
        upHold.cancelsTouchesInView = false
        upHold.delegate = self
        upHold.isEnabled = isActive

        window.addGestureRecognizer(upHold)
        upHoldRecognizer = upHold
        attachedWindow = window
        updateRecognizerState()
    }

    func removeRecognizers() {
        if let attachedWindow, let upHoldRecognizer {
            attachedWindow.removeGestureRecognizer(upHoldRecognizer)
        }
        upHoldRecognizer = nil
        attachedWindow = nil
    }

    private func updateRecognizerState() {
        upHoldRecognizer?.isEnabled = isActive
    }

    @objc private func handleUpHold(_ recognizer: UILongPressGestureRecognizer) {
        guard isActive else { return }
        if recognizer.state == .began {
            onHoldUp()
        }
    }

    // MARK: - UIGestureRecognizerDelegate

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive press: UIPress) -> Bool {
        isActive
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
                .foregroundColor(isSelected || isFocused ? .black : .white.opacity(0.85))
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

private struct TvStreamCardPresentationCacheKey: Equatable {
    let listKey: StreamPickerListCacheKey?
    let badgeSettingsRevision: UInt64
    let visibleLimit: Int
}

private struct TvStreamCardPresentation {
    let importedBadges: [StreamBadgeFilter]
    let fileSizeLabel: String?
    let badgePlacement: StreamBadgePlacement
    let showAddonLogo: Bool

    init(stream: NuvioStream, badgeSettings: StreamBadgeSettingsSnapshot) {
        importedBadges = StreamBadgeMatcher.matchedBadges(
            for: stream,
            rules: badgeSettings.rules
        )
        fileSizeLabel = badgeSettings.showFileSizeBadges
            ? StreamBadgeSizing.fileSizeLabel(for: stream)
            : nil
        badgePlacement = badgeSettings.badgePlacement
        showAddonLogo = badgeSettings.showAddonLogo
    }

    init(pending badgeSettings: StreamBadgeSettingsSnapshot) {
        importedBadges = []
        fileSizeLabel = nil
        badgePlacement = badgeSettings.badgePlacement
        showAddonLogo = badgeSettings.showAddonLogo
    }
}

private actor TvStreamCardPresentationBuilder {
    static let shared = TvStreamCardPresentationBuilder()

    func build(
        streams: [NuvioStream],
        settings: StreamBadgeSettingsSnapshot
    ) -> [String: TvStreamCardPresentation] {
        var presentations: [String: TvStreamCardPresentation] = [:]
        presentations.reserveCapacity(streams.count)
        for stream in streams {
            guard !Task.isCancelled else { return [:] }
            presentations[stream.id] = TvStreamCardPresentation(
                stream: stream,
                badgeSettings: settings
            )
        }
        return presentations
    }
}

private struct TvStreamCard: View {
    let stream: NuvioStream
    private let importedBadges: [StreamBadgeFilter]
    private let fileSizeLabel: String?
    private let badgePlacement: StreamBadgePlacement
    private let showAddonLogo: Bool
    let externalFocus: FocusState<String?>.Binding
    let action: () -> Void
    var onSelectPlayer: ((ExternalPlayer) -> Void)? = nil

    /// Local focus drives appearance only for this card, so focus moves do not
    /// push `isFocused` through the parent ForEach for every sibling.
    @FocusState private var isFocused: Bool

    /// Precomputed once per card identity — not re-derived on every body tick.
    private let primaryName: String
    private let secondaryName: String?

    init(
        stream: NuvioStream,
        presentation: TvStreamCardPresentation,
        externalFocus: FocusState<String?>.Binding,
        action: @escaping () -> Void,
        onSelectPlayer: ((ExternalPlayer) -> Void)? = nil
    ) {
        self.stream = stream
        self.importedBadges = presentation.importedBadges
        self.fileSizeLabel = presentation.fileSizeLabel
        self.badgePlacement = presentation.badgePlacement
        self.showAddonLogo = presentation.showAddonLogo
        self.externalFocus = externalFocus
        self.action = action
        self.onSelectPlayer = onSelectPlayer
        let lines = Self.nameLines(for: stream)
        self.primaryName = lines.first ?? "Stream"
        let rest = lines.dropFirst().joined(separator: " ")
        self.secondaryName = rest.isEmpty ? nil : rest
    }

    var body: some View {
        let showImportedBadges = !importedBadges.isEmpty || fileSizeLabel != nil

        Button(action: action) {
            HStack(alignment: .center, spacing: 34) {
                VStack(alignment: .leading, spacing: 14) {
                    if showImportedBadges && badgePlacement == .top {
                        TvStreamImportedBadgeRow(
                            badges: importedBadges,
                            fileSizeLabel: fileSizeLabel,
                            isScrolling: isFocused
                        )
                    }

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

                    if showImportedBadges && badgePlacement == .bottom {
                        TvStreamImportedBadgeRow(
                            badges: importedBadges,
                            fileSizeLabel: fileSizeLabel,
                            isScrolling: isFocused
                        )
                            .padding(.top, 4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if showAddonLogo {
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
        .contextMenu {
            Section(L10n.string("details_play_with", fallback: "Play with")) {
                ForEach(ExternalPlayer.allCases) { player in
                    Button {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            onSelectPlayer?(player)
                        }
                    } label: {
                        Label(player.rawValue, systemImage: player.systemImage)
                    }
                }
            }
        }
    }

    static func nameLines(for stream: NuvioStream) -> [String] {
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

private struct TvStreamBadgeRowWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct TvStreamImportedBadgeRow: View {
    let badges: [StreamBadgeFilter]
    let fileSizeLabel: String?
    let isScrolling: Bool

    @State private var contentWidth: CGFloat = 0
    @State private var animationStart = Date()

    var body: some View {
        GeometryReader { geometry in
            ViewThatFits(in: .horizontal) {
                // `fixedSize` gives this candidate its intrinsic width. It is
                // selected unchanged when every badge fits in the viewport.
                badgeContent

                // This fallback is selected only when the intrinsic row does
                // not fit, avoiding unreliable preference-width comparisons.
                overflowContent
            }
            .frame(width: geometry.size.width, alignment: .leading)
            .compositingGroup()
            .onAppear {
                animationStart = Date()
            }
            .onChange(of: geometry.size.width) { _, width in
                _ = width
                animationStart = Date()
            }
            .onChange(of: isScrolling) { _, _ in
                animationStart = Date()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .frame(height: 42)
        .onPreferenceChange(TvStreamBadgeRowWidthKey.self) { width in
            guard abs(width - contentWidth) > 0.5 else { return }
            contentWidth = width
            animationStart = Date()
        }
    }

    @ViewBuilder
    private var overflowContent: some View {
        if isScrolling {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                let cycleWidth = max(contentWidth + 28, 1)
                let elapsed = max(0, timeline.date.timeIntervalSince(animationStart))
                let offset = CGFloat(elapsed * 70)
                    .truncatingRemainder(dividingBy: cycleWidth)

                HStack(spacing: 28) {
                    badgeContent
                    badgeContent
                }
                .fixedSize(horizontal: true, vertical: false)
                .offset(x: -offset)
            }
        } else {
            badgeContent
        }
    }

    private var badgeContent: some View {
        HStack(spacing: 10) {
            ForEach(Array(badges.enumerated()), id: \.offset) { _, badge in
                TvStreamImportedBadge(badge: badge)
            }

            if let fileSizeLabel {
                Text(fileSizeLabel)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white.opacity(0.9))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(
                        Capsule().fill(Color.white.opacity(0.12))
                    )
                    .overlay(
                        Capsule().stroke(Color.white.opacity(0.20), lineWidth: 1)
                    )
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .background(
            GeometryReader { geometry in
                Color.clear.preference(
                    key: TvStreamBadgeRowWidthKey.self,
                    value: geometry.size.width
                )
            }
        )
    }

}

private struct TvStreamImportedBadge: View {
    let badge: StreamBadgeFilter

    var body: some View {
        Group {
            if !badge.imageURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let url = URL(string: badge.imageURL.trimmingCharacters(in: .whitespacesAndNewlines)) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFit()
                    case .failure:
                        fallbackText
                    default:
                        ProgressView().tint(.white)
                    }
                }
            } else {
                fallbackText
            }
        }
        .frame(minWidth: 54, maxWidth: 150, minHeight: 30, maxHeight: 30)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(background)
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(border, lineWidth: border == .clear ? 0 : 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var fallbackText: some View {
        Text(badge.name)
            .font(.system(size: 16, weight: .bold))
            .foregroundColor(color(from: badge.textColor) ?? .white)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    private var background: Color {
        guard badge.tagStyle.caseInsensitiveCompare("filled") == .orderedSame,
              let color = color(from: badge.tagColor) else {
            return Color.white.opacity(0.10)
        }
        return color.opacity(0.84)
    }

    private var border: Color {
        color(from: badge.borderColor) ?? .clear
    }

    private func color(from raw: String) -> Color? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        guard value.count == 6 || value.count == 8,
              let number = UInt64(value, radix: 16) else { return nil }
        let alpha: Double
        let red: Double
        let green: Double
        let blue: Double
        if value.count == 8 {
            alpha = Double((number >> 24) & 0xff) / 255
            red = Double((number >> 16) & 0xff) / 255
            green = Double((number >> 8) & 0xff) / 255
            blue = Double(number & 0xff) / 255
        } else {
            alpha = 1
            red = Double((number >> 16) & 0xff) / 255
            green = Double((number >> 8) & 0xff) / 255
            blue = Double(number & 0xff) / 255
        }
        return Color(red: red, green: green, blue: blue, opacity: alpha)
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
            Text(L10n.string("common_error", fallback: "Error"))
                .font(.title)
                .foregroundColor(.red)

            Text(error)
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 16) {
                Button(L10n.string("action_retry", fallback: "Retry"), action: onRetry)
                    .buttonStyle(.borderedProminent)

                Button(L10n.string("action_go_back", fallback: "Go Back"), action: onBack)
                    .buttonStyle(.bordered)
            }
        }
        .padding(32)
    }
}
