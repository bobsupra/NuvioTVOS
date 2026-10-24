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
            .animation(.playerControls, value: viewModel.postPlayState.isVisible)
            .animation(.easeOut(duration: 0.16), value: viewModel.isScrubbing)
            .animation(.easeOut(duration: 0.16), value: viewModel.isHoldingSeek)
            .animation(.easeOut(duration: 0.2), value: viewModel.isSwitchingSource)
            .animation(.easeOut(duration: 0.2), value: viewModel.playerToast)
            .animation(.easeOut(duration: 0.22), value: viewModel.showPauseOverlay)
            .animation(.easeOut(duration: 0.22), value: viewModel.sidePanel)
    }

    var layersWithLifecycle: some View {
        animatedLayers
            .onAppear {
                if let partyPlayback {
                    // A changed root identity must mount a new StateObject for a new runtime.
                    guard partyPlayback.viewModel === viewModel else { return }
                    do {
                        let attachment = try partyPlayback.attach()
                        partySurface = attachment.surface
                        if !attachment.startsLoad {
                            guard viewModel.rebindWatchPartyFullscreen() else {
                                partyPlayback.finish()
                                return
                            }
                            viewModel.reloadCurrentStream = reloadCurrentStream
                            viewModel.fetchPlaybackSources = fetchPlaybackSources
                            viewModel.resolvePlaybackStream = resolvePlaybackStream
                            viewModel.onWatchPartySourceChanged = onWatchPartySourceChanged
                            configureEpisodeControls()
                            PlaybackWakeLock.acquire(ownerID: viewModel.sessionCoordinator.wakeLockOwnerID)
                            syncPlaybackWakeLock()
                            focusRemoteInput()
                            // Preserve active episode/source, subtitle task, resolver, benchmark and poller.
                            return
                        }
                    } catch {
                        return // Obsolete membership/context; never fall through to a fresh load.
                    }
                }
                TVHomeDebugTrace.log("player.appear meta=\(meta.id)")
                focusRemoteInput()
                viewModel.adoptStartupBenchmarkToken(initialStartupBenchmarkToken)
                let cachedBinge = BingeGroupStore.load(seriesId: meta.id)
                viewModel.reloadCurrentStream = reloadCurrentStream
                viewModel.fetchPlaybackSources = fetchPlaybackSources
                viewModel.resolvePlaybackStream = resolvePlaybackStream
                viewModel.onWatchPartySourceChanged = onWatchPartySourceChanged
                viewModel.load(
                    url: url,
                    meta: meta,
                    subtitle: subtitle,
                    httpHeaders: httpHeaders,
                    externalSubtitles: externalSubtitles,
                    resumeFrom: resumeFrom,
                    playbackOrigin: playbackOrigin,
                    bingeGroup: bingeGroup ?? cachedBinge?.bingeGroup,
                    addonName: addonName ?? cachedBinge?.addonName,
                    provider: provider,
                    filename: filename,
                    videoSize: videoSize,
                    videoHash: videoHash,
                    cacheFileIdentity: cacheFileIdentity,
                    trickplayURL: trickplayURL,
                    sourceID: sourceID,
                    currentEpisode: currentEpisode,
                    isActionPlaybackSession: isActionPlaybackSession
                )
                // load() may adopt the retained PiP coordinator. Acquire for
                // that session so restoring fullscreen cannot add another hold.
                PlaybackWakeLock.acquire(ownerID: viewModel.sessionCoordinator.wakeLockOwnerID)
                syncPlaybackWakeLock()
                if !isStandalonePlaybackSession {
                    viewModel.fetchExternalSubtitles(
                        contentId: subtitleContentId,
                        type: meta.isSeries ? "series" : meta.type,
                        videoHash: videoHash,
                        videoSize: videoSize,
                        filename: filename
                    )
                }
                configureEpisodeControls()
            }
            .onChange(of: partyPlaybackIdentity) { oldIdentity, newIdentity in
                if oldIdentity != nil, newIdentity == nil {
                    viewModel.onWatchPartySourceChanged = nil
                    configureEpisodeControls()
                    return
                }
                // In-place room adoption keeps this PlayerView and its StateObject alive.
                // Attach the runtime surface without repeating load() for the current source.
                guard oldIdentity == nil, newIdentity != nil,
                      let partyPlayback, partySurface == nil,
                      partyPlayback.viewModel === viewModel else { return }
                do {
                    let attachment = try partyPlayback.attach()
                    partySurface = attachment.surface
                    viewModel.reloadCurrentStream = reloadCurrentStream
                    viewModel.fetchPlaybackSources = fetchPlaybackSources
                    viewModel.resolvePlaybackStream = resolvePlaybackStream
                    viewModel.onWatchPartySourceChanged = onWatchPartySourceChanged
                    guard viewModel.rebindWatchPartyFullscreen() else {
                        partyPlayback.finish()
                        return
                    }
                    configureEpisodeControls()
                    PlaybackWakeLock.acquire(ownerID: viewModel.sessionCoordinator.wakeLockOwnerID)
                    syncPlaybackWakeLock()
                } catch {
                    return
                }
            }
            .onDisappear {
                if let partyPlayback {
                    guard let surface = partySurface else { return }
                    partySurface = nil
                    // Only the current surface may close the owner; old callbacks are inert.
                    // The runtime's resource cleanup handles progress, wake lock, PiP and torrent.
                    partyPlayback.detach(surface)
                    return
                }
                TVHomeDebugTrace.log("player.disappear meta=\(meta.id)")
                let sourceURL = viewModel.sessionCoordinator.torrentStreamSourceURL
                viewModel.cancelStartupBenchmark()
                if subtitle == PlaybackMarkers.trailerSubtitle {
                    let pos = viewModel.clock.position
                    if pos > 0.1 && !pos.isNaN && !pos.isInfinite {
                        TrailerPlaybackHandoff.shared.recordHandoff(metaId: meta.id, time: pos)
                    }
                }
                if !PictureInPictureManager.shared.isPictureInPictureActive {
                    PlaybackWakeLock.release(ownerID: viewModel.sessionCoordinator.wakeLockOwnerID)
                    viewModel.shutdown()
                    Task {
                        guard let sourceURL else { return }
                        await TorrentEngineManager.shared.stopActiveStream(for: sourceURL)
                        await UsenetEngineManager.shared.stopActiveStream(for: sourceURL)
                    }
                }
            }
    }

    /// Playback-state observers: picture-in-picture, status, source switching,
    /// stream reloads, and scene phase.
    var layersObservingPlayback: some View {
        layersWithLifecycle
            .onChange(of: viewModel.isPictureInPictureActive) { _, isActive in
                if let partyPlayback {
                    guard partyPlayback.isCurrent,
                          PictureInPictureManager.shared.activeCoordinator === viewModel.sessionCoordinator else { return }
                }
                if isActive {
                    onBack()
                }
            }
            .onChange(of: viewModel.status) { _, status in
                syncPlaybackWakeLock()
                if status == .playing,
                   (viewModel.hasRenderedFirstFrame || viewModel.isLiveStream),
                   !viewModel.isSwitchingSource,
                   !viewModel.isReloadingStream,
                   !viewModel.didDetectReplacementStream,
                   !viewModel.isAdvancingEpisode,
                   !didReportPlaybackStarted {
                    didReportPlaybackStarted = true
                    _ = viewModel.completeStartupBenchmark()
                    if !viewModel.showControls {
                        focusRemoteInput()
                    }
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
            .onChange(of: viewModel.hasRenderedFirstFrame) { _, ready in
                if ready,
                   (viewModel.status == .playing || viewModel.isLiveStream),
                   !viewModel.isSwitchingSource,
                   !viewModel.isReloadingStream,
                   !viewModel.didDetectReplacementStream,
                   !viewModel.isAdvancingEpisode,
                   !didReportPlaybackStarted {
                    didReportPlaybackStarted = true
                    _ = viewModel.completeStartupBenchmark()
                    if !viewModel.showControls {
                        focusRemoteInput()
                    }
                    onPlaybackStarted?()
                }
            }
            .onChange(of: viewModel.isSwitchingSource) { _, isSwitching in
                syncPlaybackWakeLock()
                if isSwitching {
                    didReportPlaybackStarted = false
                }
            }
            .onChange(of: viewModel.isAdvancingEpisode) { _, isAdvancing in
                syncPlaybackWakeLock()
                if isAdvancing {
                    didReportPlaybackStarted = false
                }
            }
            .onChange(of: viewModel.isReloadingStream) { _, _ in
                syncPlaybackWakeLock()
            }
            .onChange(of: viewModel.didDetectReplacementStream) { _, isReplacement in
                if isReplacement {
                    didReportPlaybackStarted = false
                }
            }
            .onChange(of: scenePhase) { oldPhase, phase in
                screensaverDebugLog("[ScreensaverDebug][PlayerView] scenePhase changed from \(oldPhase) to \(phase), status=\(viewModel.status), time=\(viewModel.time.current)/\(viewModel.time.duration), showPauseOverlay=\(viewModel.showPauseOverlay), showControls=\(viewModel.showControls)")
                switch phase {
                case .inactive:
                    break
                case .background:
                    if !PictureInPictureManager.shared.isPictureInPictureActive {
                        viewModel.saveProgress(force: true, eventAction: .pause)
                    }
                case .active:
                    lastBecameActiveAt = Date()
                    syncPlaybackWakeLock()
                    if !viewModel.showControls {
                        focusRemoteInput()
                    }
                @unknown default:
                    break
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                screensaverDebugLog("[ScreensaverDebug][PlayerView] willResignActiveNotification received, status=\(viewModel.status), time=\(viewModel.time.current)")
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
                screensaverDebugLog("[ScreensaverDebug][PlayerView] didEnterBackgroundNotification received, status=\(viewModel.status), time=\(viewModel.time.current)")
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                screensaverDebugLog("[ScreensaverDebug][PlayerView] willEnterForegroundNotification received, status=\(viewModel.status), time=\(viewModel.time.current)")
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                screensaverDebugLog("[ScreensaverDebug][PlayerView] didBecomeActiveNotification received, status=\(viewModel.status), time=\(viewModel.time.current), setting lastBecameActiveAt")
                lastBecameActiveAt = Date()
                if !viewModel.showControls {
                    focusRemoteInput()
                }
            }
    }

    /// Focus observers. tvOS drops directional input when nothing holds focus,
    /// so each of these hands focus to whichever layer is now on top.
    var layersObservingFocus: some View {
        layersObservingPlayback
            .onChange(of: remoteInputFocused) { _, isFocused in
                PlaybackTimelineRecorder.record(
                    isFocused ? .focusSinkFocused : .focusSinkUnfocused,
                    engine: viewModel.activeEngineKind
                )
            }
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
                    focusRemoteInput()
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
            .onChange(of: viewModel.showSettingsPanel) { _, isPresented in
                if isPresented {
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
                guard !viewModel.showControls, !viewModel.postPlayState.isVisible, !viewModel.showSettingsPanel, !viewModel.showScenePanel, !viewModel.isSceneDetailVisible, viewModel.sidePanel == nil else { return }
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
                    nextEpisodeFocused = false
                    focusRemoteInput()
                }
            }
            .onChange(of: viewModel.showSkipSegmentCard) { _, visible in
                guard !viewModel.showControls, !viewModel.showNextEpisodeCard, !viewModel.postPlayState.isVisible, !viewModel.showSettingsPanel, !viewModel.showScenePanel, !viewModel.isSceneDetailVisible, viewModel.sidePanel == nil else { return }
                if visible {
                    focusSkipSegment()
                } else {
                    skipSegmentFocused = false
                    focusRemoteInput()
                }
            }
            .onChange(of: viewModel.showScenePanel) { _, isVisible in
                if isVisible {
                    remoteInputFocused = false
                    nextEpisodeFocused = false
                    cancelAutoPlayFocused = false
                    skipSegmentFocused = false
                } else if !viewModel.showControls {
                    focusRemoteInput()
                }
            }
    }

    private func configureEpisodeControls() {
        guard !isStandalonePlaybackSession, let resolveNextStream else { return }
        viewModel.configureNextEpisode(
            episodes: episodes,
            current: currentEpisode,
            autoPlayEnabled: partyPlayback == nil && autoPlayNextEnabled,
            autoPlayCountdownSeconds: autoPlayNextCountdownSeconds,
            resolver: resolveNextStream,
            allowsManualEpisodeSelection: allowsManualEpisodeSelection,
            isCurrentPlayerSurface: isCurrentPlayerSurface,
            onWatchPartyEpisodeResolved: onWatchPartyEpisodeResolved,
            onWatchPartyIncomingMediaResolved: onWatchPartyIncomingMediaResolved
        )
    }
}
