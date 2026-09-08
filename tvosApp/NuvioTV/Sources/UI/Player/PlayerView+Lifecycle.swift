import SwiftUI

// The modifier chain from PlayerView.body, in the original order, broken into
// stages. Each stage is a separate expression for the type-checker; chaining
// them reproduces the same modifier sequence.
extension PlayerView {
    var animatedLayers: some View {
        playerLayers
            .animation(.playerControls, value: viewModel.showSettingsPanel)
            .animation(.playerControls, value: viewModel.showNextEpisodeCard)
            .animation(.playerControls, value: viewModel.showSkipSegmentCard)
            .animation(.easeOut(duration: 0.16), value: viewModel.isScrubbing)
            .animation(.easeOut(duration: 0.16), value: viewModel.peekVisible)
            .animation(.easeOut(duration: 0.16), value: viewModel.pendingSeekDelta != 0)
            .animation(.easeOut(duration: 0.2), value: viewModel.isSwitchingSource)
            .animation(.easeOut(duration: 0.2), value: viewModel.playerToast)
            .animation(.easeOut(duration: 0.22), value: viewModel.showPauseOverlay)
            .animation(.easeOut(duration: 0.22), value: viewModel.sidePanel)
    }

    var layersWithLifecycle: some View {
        animatedLayers
            .onAppear {
                TVHomeDebugTrace.log("player.appear meta=\(meta.id)")
                // Hold for the player session, then sync so pause/end can sleep
                // without dropping the lock during buffering or source switches.
                PlaybackWakeLock.acquire()
                syncPlaybackWakeLock()
                viewModel.load(
                    url: url,
                    meta: meta,
                    subtitle: subtitle,
                    httpHeaders: httpHeaders,
                    externalSubtitles: externalSubtitles,
                    resumeFrom: resumeFrom,
                    playbackOrigin: playbackOrigin,
                    addonName: addonName,
                    provider: provider,
                    filename: filename,
                    videoSize: videoSize
                )
                if subtitle != PlaybackMarkers.trailerSubtitle {
                    viewModel.fetchExternalSubtitles(
                        contentId: subtitleContentId,
                        type: meta.isSeries ? "series" : meta.type
                    )
                }
                viewModel.reloadCurrentStream = reloadCurrentStream
                viewModel.fetchPlaybackSources = fetchPlaybackSources
                viewModel.resolvePlaybackStream = resolvePlaybackStream
                if let resolveNextStream {
                    viewModel.configureNextEpisode(
                        episodes: episodes,
                        current: currentEpisode,
                        autoPlayEnabled: autoPlayNextEnabled,
                        autoPlayCountdownSeconds: autoPlayNextCountdownSeconds,
                        resolver: resolveNextStream
                    )
                }
            }
            .onDisappear {
                TVHomeDebugTrace.log("player.disappear meta=\(meta.id)")
                PlaybackStartupTiming.cancel()
                if !PictureInPictureManager.shared.isPictureInPictureActive {
                    PlaybackWakeLock.release()
                    viewModel.shutdown()
                    Task {
                        await TorrentEngineManager.shared.stopActiveStream()
                    }
                }
            }
    }

    /// Playback-state observers: picture-in-picture, status, source switching,
    /// stream reloads, and scene phase.
    var layersObservingPlayback: some View {
        layersWithLifecycle
            .onChange(of: viewModel.isPictureInPictureActive) { _, isActive in
                if isActive {
                    onBack()
                }
            }
            .onChange(of: viewModel.status) { _, status in
                syncPlaybackWakeLock()
                if status == .playing,
                   !viewModel.isSwitchingSource,
                   !viewModel.isReloadingStream,
                   !viewModel.didDetectReplacementStream,
                   !didReportPlaybackStarted {
                    didReportPlaybackStarted = true
                    PlaybackStartupTiming.complete()
                    onPlaybackStarted?()
                }
                guard status == .ended,
                      !didHandleFinished,
                      !viewModel.postPlayState.blocksNaturalCompletion,
                      let onFinished else {
                    return
                }
                didHandleFinished = true
                onFinished()
            }
            .onChange(of: viewModel.isSwitchingSource) { _, isSwitching in
                syncPlaybackWakeLock()
                if isSwitching {
                    PlaybackStartupTiming.start()
                    didReportPlaybackStarted = false
                }
            }
            .onChange(of: viewModel.isReloadingStream) { _, _ in
                syncPlaybackWakeLock()
            }
            .onChange(of: viewModel.didDetectReplacementStream) { _, isReplacement in
                if isReplacement {
                    PlaybackStartupTiming.start()
                    didReportPlaybackStarted = false
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    syncPlaybackWakeLock()
                }
            }
    }

    /// Focus observers. tvOS drops directional input when nothing holds focus,
    /// so each of these hands focus to whichever layer is now on top.
    var layersObservingFocus: some View {
        layersObservingPlayback
            .onChange(of: viewModel.showControls) { _, isVisible in
                if viewModel.sidePanel != nil || viewModel.postPlayState.isVisible {
                    remoteInputFocused = false
                    nextEpisodeFocused = false
                    cancelAutoPlayFocused = false
                    skipSegmentFocused = false
                    return
                }
                if isVisible, !viewModel.isScrubbing, !viewModel.showPauseOverlay {
                    remoteInputFocused = false
                    nextEpisodeFocused = false
                    cancelAutoPlayFocused = false
                    skipSegmentFocused = false
                } else if viewModel.isScrubbing || viewModel.showPauseOverlay {
                    focusRemoteInput()
                } else if viewModel.showNextEpisodeCard {
                    focusNextEpisode()
                } else if viewModel.showSkipSegmentCard {
                    focusSkipSegment()
                } else {
                    focusRemoteInput()
                }
            }
            .onChange(of: viewModel.postPlayState.isVisible) { _, isVisible in
                if isVisible {
                    remoteInputFocused = false
                    nextEpisodeFocused = false
                    cancelAutoPlayFocused = false
                    skipSegmentFocused = false
                    DispatchQueue.main.async {
                        postPlayFocus = .primaryAction
                    }
                } else {
                    postPlayFocus = nil
                }
            }
            .onChange(of: viewModel.sidePanel) { _, panel in
                if panel != nil {
                    remoteInputFocused = false
                    nextEpisodeFocused = false
                    cancelAutoPlayFocused = false
                    skipSegmentFocused = false
                }
            }
            .onChange(of: viewModel.showPauseOverlay) { _, visible in
                if visible {
                    nextEpisodeFocused = false
                    cancelAutoPlayFocused = false
                    skipSegmentFocused = false
                    focusRemoteInput()
                }
            }
            .onChange(of: viewModel.isScrubbing) { _, scrubbing in
                if scrubbing {
                    nextEpisodeFocused = false
                    cancelAutoPlayFocused = false
                    skipSegmentFocused = false
                    focusRemoteInput()
                } else if viewModel.showControls {
                    remoteInputFocused = false
                } else {
                    focusRemoteInput()
                }
            }
            .onChange(of: viewModel.showNextEpisodeCard) { _, visible in
                guard !viewModel.showControls else { return }
                if visible {
                    focusNextEpisode()
                } else if viewModel.showSkipSegmentCard {
                    nextEpisodeFocused = false
                    cancelAutoPlayFocused = false
                    focusSkipSegment()
                } else {
                    nextEpisodeFocused = false
                    cancelAutoPlayFocused = false
                    focusRemoteInput()
                }
            }
            .onChange(of: viewModel.isAutoPlayCancelled) { _, cancelled in
                if cancelled {
                    cancelAutoPlayFocused = false
                    focusNextEpisode()
                }
            }
            .onChange(of: viewModel.showSkipSegmentCard) { _, visible in
                guard !viewModel.showControls, !viewModel.showNextEpisodeCard else { return }
                if visible {
                    focusSkipSegment()
                } else {
                    skipSegmentFocused = false
                    focusRemoteInput()
                }
            }
    }
}
