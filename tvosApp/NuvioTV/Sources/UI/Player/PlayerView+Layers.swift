import SwiftUI

// The ZStack children of PlayerView.body, one property per original child so
// the stack's arity and child order — and therefore SwiftUI's view identity and
// transitions — are exactly as before.
extension PlayerView {
    @ViewBuilder
    var playerLayers: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            videoSurfaceLayer
            postPlayRecommendationLayer
            remoteTouchCatcherLayer
            remoteSeekPressCatcherLayer
            playerStatusOverlay
            playerToastLayer
            focusSinkLayer
            pauseOverlayLayer
            skipSegmentLayer
            nextEpisodeLayer
            playerControlsLayer
            settingsPanelLayer
            sidePanelLayer
            debugOverlayLayer
        }
    }

    @ViewBuilder
    var videoSurfaceLayer: some View {
        // Main video surface (or top-right mini window during post-play recommendations)
        if !viewModel.postPlayState.isTrailerPlaying &&
            (!viewModel.postPlayState.isVisible || viewModel.postPlayState.canReturnToPlayer) {
            ZStack {
                Group {
                    switch viewModel.activeEngineKind {
                    case .aether:
                        if let controller = viewModel.aetherController {
                            AetherPlayerSurface(controller: controller)
                        } else {
                            Color.black
                        }
                    case .mpv:
                        MPVVideoSurface(controller: viewModel.playerController)
                    }
                }

                if viewModel.activeEngineKind == .aether,
                   let aetherController = viewModel.aetherController {
                    PlayerSubtitleOverlay(
                        playback: aetherController.subtitleOverlayState,
                        translation: aetherController.subtitleTranslationState,
                        subtitleDelaySeconds: Double(viewModel.subtitleDelayMs) / 1000.0,
                        videoNaturalSize: viewModel.videoNaturalSize,
                        aspectMode: viewModel.aspectMode,
                        style: viewModel.subtitleStyle
                    )
                    .ignoresSafeArea(edges: viewModel.postPlayState.isVisible ? [] : .all)
                } else {
                    MPVSubtitleOverlay(
                        translation: viewModel.playerController.subtitleTranslationState,
                        videoNaturalSize: viewModel.videoNaturalSize,
                        aspectMode: viewModel.aspectMode,
                        style: viewModel.subtitleStyle
                    )
                    .ignoresSafeArea(edges: viewModel.postPlayState.isVisible ? [] : .all)
                }

                if viewModel.postPlayState.isVisible && viewModel.postPlayState.canReturnToPlayer {
                    miniPlayerReturnButton
                }
            }
            .frame(
                width: viewModel.postPlayState.isVisible ? 580 : nil,
                height: viewModel.postPlayState.isVisible ? 326 : nil
            )
            .clipShape(RoundedRectangle(cornerRadius: viewModel.postPlayState.isVisible ? 16 : 0))
            .scaleEffect(viewModel.postPlayState.isVisible && postPlayFocus == .miniPlayer ? 1.05 : 1.0)
            .animation(.easeOut(duration: 0.16), value: postPlayFocus)
            .overlay {
                if viewModel.postPlayState.isVisible {
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(
                            postPlayFocus == .miniPlayer ? Color.white : Color.white.opacity(0.35),
                            lineWidth: postPlayFocus == .miniPlayer ? 4 : 2
                        )
                        .shadow(
                            color: postPlayFocus == .miniPlayer ? Color.white.opacity(0.6) : Color.clear,
                            radius: 12
                        )
                }
            }
            .shadow(color: Color.black.opacity(viewModel.postPlayState.isVisible ? 0.6 : 0), radius: 16)
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: viewModel.postPlayState.isVisible ? .topTrailing : .center
            )
            .padding(.top, viewModel.postPlayState.isVisible ? 50 : 0)
            .padding(.trailing, viewModel.postPlayState.isVisible ? 60 : 0)
            .zIndex(viewModel.postPlayState.isVisible ? 5 : 0)
            .ignoresSafeArea(edges: viewModel.postPlayState.isVisible ? [] : .all)
        }
    }

    @ViewBuilder
    var postPlayRecommendationLayer: some View {
        // Post-Play Recommendation Overlay
        if viewModel.postPlayState.isVisible {
            PostPlayRecommendationOverlay(
                state: viewModel.postPlayState,
                currentTitle: meta.name,
                showManualPlayOption: autoPlayNextEnabled,
                focus: $postPlayFocus,
                onPlay: { rec, manual in
                    onPlayRecommendation?(rec.asMeta, manual)
                },
                onOpenDetails: { rec in
                    onOpenRecommendationDetails?(rec.asMeta)
                },
                onPlayTrailer: {
                    viewModel.playPostPlayTrailer()
                },
                onStopTrailer: {
                    viewModel.stopPostPlayTrailer()
                },
                onPreviousRecommendation: {
                    viewModel.showPreviousRecommendation()
                },
                onNextRecommendation: {
                    viewModel.showNextRecommendation()
                },
                onBack: {
                    if viewModel.postPlayState.isTrailerPlaying {
                        viewModel.stopPostPlayTrailer()
                    } else {
                        let endGuard: Double = max(0, viewModel.time.duration - 3)
                        if viewModel.postPlayState.canReturnToPlayer,
                           viewModel.time.current < endGuard,
                           viewModel.status != .ended {
                            viewModel.returnToPlayerFromPostPlay()
                        } else {
                            onBack()
                        }
                    }
                }
            )
            .zIndex(2)
            .transition(.opacity)
        }
    }

    @ViewBuilder
    var remoteTouchCatcherLayer: some View {
        // Window-level trackpad capture for scrubbing.
        RemoteTouchCatcher(
            isActive: {
                !isWakingFromBackground
                    && viewModel.playbackStartupError == nil && !viewModel.showSettingsPanel
                    && viewModel.sidePanel == nil
                    && !viewModel.postPlayState.isVisible
                    && viewModel.status == .paused
            },
            onBegan: { viewModel.remoteTouchBegan() },
            onMoved: { dx, dy in viewModel.remoteTouchMoved(dx: dx, dy: dy) },
            onEnded: { dx, dy in viewModel.remoteTouchEnded(dx: dx, dy: dy) }
        )
        .allowsHitTesting(false)
        .frame(width: 0, height: 0)
    }

    @ViewBuilder
    var remoteSeekPressCatcherLayer: some View {
        RemoteSeekPressCatcher(
            // Hold left/right continuous seek is active during video playback,
            // whether controls are shown or hidden and regardless of button focus.
            isActive: !isWakingFromBackground
                && viewModel.playbackStartupError == nil
                && !viewModel.showSettingsPanel
                && viewModel.sidePanel == nil
                && !viewModel.isScrubbing
                && !viewModel.postPlayState.isVisible,
            onBeginBackward: { viewModel.beginRepeatingSkipBackward() },
            onBeginForward: { viewModel.beginRepeatingSkipForward() },
            onEnd: { viewModel.stopRepeatingSkip() }
        )
        .allowsHitTesting(false)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    var playerToastLayer: some View {
        if let toast = viewModel.playerToast {
            VStack {
                Text(toast)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 14)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 48)
                Spacer()
            }
            .transition(.opacity)
            .allowsHitTesting(false)
            .zIndex(6)
        }
    }

    @ViewBuilder
    var focusSinkLayer: some View {
        // Focus sink for when the controls are hidden. tvOS routes the Menu
        // button to the system (which quits the app) and drops directional
        // input whenever no view holds focus, so something must always own it
        // while the controls are down. A bare focusable `Color.clear` is used
        // deliberately, not a Button: a Button draws a white full-screen focus
        // glow on tvOS 26+ (even with `.buttonStyle(.plain)` + focus effect
        // disabled), and dropping its opacity to hide that glow also makes the
        // focus engine skip it entirely — so `up` produced no move command.
        // A focusable Color draws no highlight yet stays reliably focusable at
        // full opacity. Kept mounted full-time (mounting it only when the
        // controls hide raced the timeline losing focusability, leaving focus in
        // a void); non-focusable while the controls are up so focus hands cleanly
        // to the timeline, focusable again the instant they hide. `up`/`down`
        // reveal via the PlayerView `onMoveCommand`; the select click toggles
        // play/pause via the tap gesture.
        Color.clear
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .focusable(
                (!viewModel.showControls || !didReportPlaybackStarted || viewModel.isSwitchingSource || viewModel.showPauseOverlay)
                    && !viewModel.isScrubbing
                    && viewModel.playbackStartupError == nil
                    && !viewModel.showNextEpisodeCard
                    && !viewModel.showSkipSegmentCard
                    && !viewModel.showSettingsPanel
                    && !viewModel.postPlayState.isVisible
                    && viewModel.sidePanel == nil
            )
            .focused($remoteInputFocused)
            .onTapGesture {
                guard !isWakingFromBackground else { return }
                if viewModel.isScrubbing {
                    viewModel.commitScrub()
                } else if viewModel.showPauseOverlay {
                    viewModel.play()
                } else {
                    viewModel.togglePlayPause()
                }
            }
            .accessibilityHidden(true)
    }

    @ViewBuilder
    var pauseOverlayLayer: some View {
        // Pause metadata sheet ("You're watching…").
        if viewModel.showPauseOverlay {
            PauseOverlayView(
                title: viewModel.title,
                episodeLine: viewModel.pauseOverlayEpisodeLine,
                year: viewModel.pauseOverlayYear,
                description: viewModel.pauseOverlayDescription,
                cast: viewModel.pauseOverlayCast,
                logoURL: viewModel.pauseOverlayLogoURL
            )
            .transition(.opacity)
            .zIndex(2)
        }
    }

    @ViewBuilder
    var skipSegmentLayer: some View {
        if viewModel.showSkipSegmentCard && !viewModel.isScrubbing, let interval = viewModel.activeSkipInterval {
            Button(action: {
                guard !isWakingFromBackground else { return }
                viewModel.skipActiveInterval()
            }) {
                SkipSegmentOverlay(
                    interval: interval,
                    countdown: viewModel.skipSegmentCountdown,
                    isFocused: skipSegmentFocused
                )
            }
            .buttonStyle(PosterCardButtonStyle())
            .focusEffectDisabledIfAvailable()
            .focused($skipSegmentFocused)
            .onMoveCommand { direction in
                guard !isWakingFromBackground else { return }
                switch direction {
                case .down:
                    skipSegmentFocused = false
                    requestedControlFocus = .timeline
                case .right:
                    if viewModel.showNextEpisodeCard {
                        skipSegmentFocused = false
                        focusNextEpisode()
                    } else {
                        skipSegmentFocused = false
                        requestedControlFocus = .pip
                    }
                default:
                    break
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(.leading, 60)
            .padding(.bottom, viewModel.showControls ? 120 : 54)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .zIndex(3)
        }
    }

    @ViewBuilder
    var nextEpisodeLayer: some View {
        // Next-episode prompt, shown near the end. Auto-play occurs only
        // after the current episode reaches genuine end-of-media.
        if viewModel.showNextEpisodeCard && !viewModel.isScrubbing, let next = viewModel.nextEpisode {
            VStack(spacing: 8) {
                Button(action: {
                    guard !isWakingFromBackground else { return }
                    viewModel.playNextEpisode()
                }) {
                    NextEpisodeOverlay(episode: next, isAdvancing: viewModel.isAdvancingEpisode, isFocused: nextEpisodeFocused, isAutoPlayCancelled: viewModel.isAutoPlayCancelled)
                }
                .buttonStyle(PosterCardButtonStyle())
                .focusEffectDisabledIfAvailable()
                .focused($nextEpisodeFocused)
                .onMoveCommand { direction in
                    guard !isWakingFromBackground else { return }
                    switch direction {
                    case .down:
                        if autoPlayNextEnabled && !viewModel.isAutoPlayCancelled && !viewModel.isAdvancingEpisode {
                            nextEpisodeFocused = false
                            cancelAutoPlayFocused = true
                        } else {
                            nextEpisodeFocused = false
                            requestedControlFocus = .settings
                        }
                    case .left:
                        if viewModel.showSkipSegmentCard {
                            nextEpisodeFocused = false
                            focusSkipSegment()
                        }
                    default:
                        break
                    }
                }
                if autoPlayNextEnabled && !viewModel.isAutoPlayCancelled && !viewModel.isAdvancingEpisode {
                    Button(action: { viewModel.cancelAutoPlay() }) {
                        Text(L10n.string("player_cancel_autoplay", fallback: "Cancel Auto-Play"))
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(cancelAutoPlayFocused ? .black : .white.opacity(0.85))
                            .padding(.horizontal, 18).padding(.vertical, 8)
                            .background(cancelAutoPlayFocused ? Color.white : Color.white.opacity(0.14), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .focused($cancelAutoPlayFocused)
                    .onMoveCommand { direction in
                        guard !isWakingFromBackground else { return }
                        switch direction {
                        case .up:
                            cancelAutoPlayFocused = false
                            nextEpisodeFocused = true
                        case .down:
                            cancelAutoPlayFocused = false
                            requestedControlFocus = .settings
                        case .left:
                            if viewModel.showSkipSegmentCard {
                                cancelAutoPlayFocused = false
                                focusSkipSegment()
                            }
                        default:
                            break
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(.trailing, 60)
            .padding(.bottom, viewModel.showControls ? 208 : 54)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .zIndex(3)
        }
    }

    @ViewBuilder
    var playerControlsLayer: some View {
        // Kept mounted (not gated by an `if`) so the hide animates too: removing
        // a view that holds tvOS focus makes the focus engine finalize the
        // removal before the transition can play, so only the appear would
        // animate. Animating opacity/scale on a mounted view sidesteps that —
        // focusability is gated inside PlayerControls so focus still hands off
        // cleanly to the remote-input overlay when hidden.
        PlayerControls(
            viewModel: viewModel,
            isSkipSegmentFocused: skipSegmentFocused,
            isNextEpisodeFocused: nextEpisodeFocused || cancelAutoPlayFocused,
            requestedFocus: $requestedControlFocus,
            onFocusSkipSegment: { focusSkipSegment() },
            onFocusNextEpisode: { focusNextEpisode() }
        )
            .opacity(
                (viewModel.showControls || viewModel.isScrubbing)
                    && didReportPlaybackStarted
                    && !viewModel.isSwitchingSource
                    && !viewModel.showSettingsPanel
                    && !viewModel.showPauseOverlay
                ? 1 : 0
            )
            .scaleEffect(
                (viewModel.showControls || viewModel.isScrubbing)
                    && didReportPlaybackStarted
                    && !viewModel.isSwitchingSource
                    && !viewModel.showPauseOverlay
                ? 1 : 0.95
            )
            .allowsHitTesting(
                (viewModel.showControls || viewModel.isScrubbing)
                    && didReportPlaybackStarted
                    && !viewModel.isSwitchingSource
                    && !viewModel.showSettingsPanel
                    && !viewModel.showPauseOverlay
            )
            .animation(.playerControls, value: viewModel.showControls)
            .animation(.playerControls, value: didReportPlaybackStarted)
            .animation(.playerControls, value: viewModel.isSwitchingSource)
            .animation(.playerControls, value: viewModel.showSettingsPanel)
            .animation(.playerControls, value: viewModel.isScrubbing)
            .animation(.playerControls, value: viewModel.showPauseOverlay)
    }

    @ViewBuilder
    var settingsPanelLayer: some View {
        // Settings panel (subtitles / audio / speed), over the dimmed video.
        if viewModel.showSettingsPanel {
            PlayerSettingsPanel(viewModel: viewModel) {
                viewModel.showSettingsPanel = false
            }
            .transition(.opacity)
            .zIndex(2)
        }
    }

    @ViewBuilder
    var sidePanelLayer: some View {
        // Episodes / Sources side panels.
        if viewModel.sidePanel == .episodes {
            PlayerEpisodesPanel(viewModel: viewModel)
                .zIndex(7)
        } else if viewModel.sidePanel == .sources {
            PlayerSourcesPanel(viewModel: viewModel)
                .zIndex(7)
        }
    }
}
