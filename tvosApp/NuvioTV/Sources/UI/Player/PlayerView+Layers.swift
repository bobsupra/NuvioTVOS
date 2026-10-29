import SwiftUI

enum PlayerWindowInputCapturePolicy {
    static func allowsCapture(
        existingConditions: Bool,
        isNextEpisodeFocused: Bool,
        isCancelAutoPlayFocused: Bool,
        isSkipSegmentFocused: Bool
    ) -> Bool {
        existingConditions
            && !isNextEpisodeFocused
            && !isCancelAutoPlayFocused
            && !isSkipSegmentFocused
    }
}

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
                .zIndex(10)
            playerToastLayer
                .zIndex(22)
            focusSinkLayer
            pauseOverlayLayer
            skipSegmentLayer
            nextEpisodeLayer
            playerControlsLayer
            scenePanelLayer
            sceneDetailLayer
            settingsPanelLayer
            sidePanelLayer
            debugOverlayLayer
        }
    }

    @ViewBuilder
    var videoSurfaceLayer: some View {
        // Keep MPV mounted through trailer/EOF states; hiding this layer must not
        // tear down the still-live native surface.
        let shouldShowSurface = !viewModel.postPlayState.isTrailerPlaying &&
            (!viewModel.postPlayState.isVisible || viewModel.postPlayState.canReturnToPlayer)

        if viewModel.activeEngineKind == .mpv {
            GeometryReader { geometry in
                let insets = geometry.safeAreaInsets
                let viewportSize = CGSize(
                    width: geometry.size.width + insets.leading + insets.trailing,
                    height: geometry.size.height + insets.top + insets.bottom
                )
                let miniSize = CGSize(width: 580, height: 326)
                videoSurfaceStack {
                    StablePlayerSurfacePresentation(
                        viewportSize: viewportSize,
                        presentationSize: viewModel.postPlayState.isVisible ? miniSize : viewportSize
                    ) {
                        MPVVideoSurface(controller: viewModel.playerController)
                    }
                }
            }
            // Measure in the parent's safe area for every state, then include
            // the insets in the stable native viewport and scale only its output.
            .zIndex(viewModel.postPlayState.isVisible ? 5 : 0)
            .opacity(shouldShowSurface ? 1 : 0)
            .accessibilityHidden(!shouldShowSurface)
            .allowsHitTesting(shouldShowSurface)
        } else if shouldShowSurface {
            videoSurfaceStack {
                if let controller = viewModel.aetherController {
                    AetherPlayerSurface(controller: controller)
                } else {
                    Color.black
                }
            }
        }
    }

    @ViewBuilder
    private func videoSurfaceStack<Surface: View>(
        @ViewBuilder surface: () -> Surface
    ) -> some View {
        ZStack {
            surface()

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
                .offset(y: viewModel.showScenePanel ? -430 : 0)
                .ignoresSafeArea(edges: viewModel.postPlayState.isVisible ? [] : .all)
            } else {
                MPVSubtitleOverlay(
                    translation: viewModel.playerController.subtitleTranslationState,
                    videoNaturalSize: viewModel.videoNaturalSize,
                    aspectMode: viewModel.aspectMode,
                    style: viewModel.subtitleStyle
                )
                .offset(y: viewModel.showScenePanel ? -430 : 0)
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
        // Window-level trackpad capture for scrubbing. Active only during bare video / scrubbing,
        // never while transport controls or native menus are active so the Focus Engine can navigate.
        RemoteTouchCatcher(
            isActive: {
                PlayerWindowInputCapturePolicy.allowsCapture(
                    existingConditions: didReportPlaybackStarted
                    && !isWakingFromBackground
                    && viewModel.currentErrorDiagnostic == nil && !viewModel.showSettingsPanel
                    && !viewModel.showScenePanel
                    && !viewModel.isSceneDetailVisible
                    && viewModel.sidePanel == nil
                    && !viewModel.postPlayState.isVisible
                    && !viewModel.isHoldingSeek
                    && viewModel.pendingSeekDelta == 0
                    && (!viewModel.showControls || viewModel.isScrubbing || viewModel.isTimelineFocused)
                    && !viewModel.controlsAutoHideSuspended,
                    isNextEpisodeFocused: nextEpisodeFocused,
                    isCancelAutoPlayFocused: cancelAutoPlayFocused,
                    isSkipSegmentFocused: skipSegmentFocused
                )
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
            // Tap or hold left/right seek is active during video playback,
            // when controls are hidden or when the timeline is focused.
            isActive: PlayerWindowInputCapturePolicy.allowsCapture(
                existingConditions: didReportPlaybackStarted
                && !isWakingFromBackground
                && viewModel.currentErrorDiagnostic == nil
                && !viewModel.showSettingsPanel
                && !viewModel.showScenePanel
                && !viewModel.isSceneDetailVisible
                && viewModel.sidePanel == nil
                && !viewModel.isScrubbing
                && !viewModel.postPlayState.isVisible
                && (!viewModel.showControls || viewModel.isTimelineFocused),
                isNextEpisodeFocused: nextEpisodeFocused,
                isCancelAutoPlayFocused: cancelAutoPlayFocused,
                isSkipSegmentFocused: skipSegmentFocused
            ),
            onTapBackward: {
                screensaverDebugLog("[ScreensaverDebug][Input] RemoteSeekPressCatcher onTapBackward: isWaking=\(isWakingFromBackground)")
                viewModel.handleMoveSeek(direction: .left)
            },
            onTapForward: {
                screensaverDebugLog("[ScreensaverDebug][Input] RemoteSeekPressCatcher onTapForward: isWaking=\(isWakingFromBackground)")
                viewModel.handleMoveSeek(direction: .right)
            },
            onBeginBackward: {
                screensaverDebugLog("[ScreensaverDebug][Input] RemoteSeekPressCatcher onBeginBackward: isWaking=\(isWakingFromBackground)")
                viewModel.beginRepeatingSkipBackward()
            },
            onBeginForward: {
                screensaverDebugLog("[ScreensaverDebug][Input] RemoteSeekPressCatcher onBeginForward: isWaking=\(isWakingFromBackground)")
                viewModel.beginRepeatingSkipForward()
            },
            onEnd: {
                screensaverDebugLog("[ScreensaverDebug][Input] RemoteSeekPressCatcher onEnd: isWaking=\(isWakingFromBackground)")
                viewModel.stopRepeatingSkip()
            },
            canRevealControls: { canRevealControlsFromRemotePress },
            onTapUp: {
                // Capture the first physical Up after Back/Menu returns from controls;
                // the focus sink can consume that press during focus handoff.
                guard canRevealControlsFromRemotePress else { return }
                viewModel.revealControls()
            }
        )
        .allowsHitTesting(false)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private var canRevealControlsFromRemotePress: Bool {
        !viewModel.showControls
            && !viewModel.showSettingsPanel
            && !viewModel.showScenePanel
            && !viewModel.isSceneDetailVisible
            && !viewModel.postPlayState.isVisible
            && viewModel.sidePanel == nil
            && viewModel.currentErrorDiagnostic == nil
            && !viewModel.isScrubbing
            && !viewModel.isHoldingSeek
            && viewModel.pendingSeekDelta == 0
            && !viewModel.moveSuppressed
            && !viewModel.controlsAutoHideSuspended
            && !isWakingFromBackground
            && !isLoadingOverlayVisible
    }

    @ViewBuilder
    var playerToastLayer: some View {
        if let toast = viewModel.playerToast {
            let hasAvatar = toast.avatarURL != nil || toast.initials != nil
            VStack {
                HStack(spacing: 12) {
                    if hasAvatar {
                        toastAvatar(toast)
                    }
                    if let sender = toast.senderName, !sender.isEmpty {
                        Text("\(sender):")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(.white)
                        Text(toast.message)
                            .font(.system(size: 20, weight: .medium))
                            .foregroundColor(.white.opacity(0.9))
                            .lineLimit(2)
                    } else {
                        Text(toast.message)
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundColor(.white)
                    }
                }
                .padding(.leading, hasAvatar ? 12 : 28)
                .padding(.trailing, 28)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
                .padding(.top, 48)
                Spacer()
            }
            .transition(.opacity)
            .allowsHitTesting(false)
            .zIndex(22)
        }
    }

    @ViewBuilder
    private func toastAvatar(_ toast: PlayerToastItem) -> some View {
        let size: CGFloat = 34
        if let rawURL = toast.avatarURL,
           let url = URL(string: rawURL.trimmingCharacters(in: .whitespacesAndNewlines)),
           url.scheme?.lowercased() == "https", url.host != nil {
            AsyncImage(url: url) { phase in
                if case .success(let image) = phase {
                    image
                        .resizable()
                        .scaledToFill()
                } else {
                    toastFallbackAvatar(toast, size: size)
                }
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.2), lineWidth: 1))
        } else {
            toastFallbackAvatar(toast, size: size)
        }
    }

    private func toastFallbackAvatar(_ toast: PlayerToastItem, size: CGFloat) -> some View {
        let bg = toastAvatarColor(toast.avatarColor)
        let initial = toast.initials?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Text(initial?.isEmpty == false ? String(initial!.prefix(1)) : "?")
            .font(.system(size: size * 0.45, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(bg, in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.2), lineWidth: 1))
    }

    private func toastAvatarColor(_ value: String?) -> Color {
        guard let value,
              value.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil,
              let hex = UInt64(String(value.dropFirst()), radix: 16) else {
            return Color(red: 0.18, green: 0.34, blue: 0.54)
        }
        return Color(
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255
        )
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
        // full opacity. Kept mounted full-time; it is disabled during startup so
        // the loading overlay can route input and the controls can take focus.
        // After playback starts, it owns focus while controls are hidden and
        // hands focus to the timeline when they appear. Select toggles playback
        // only after startup is ready.
        Color.clear
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .focusable(
                didReportPlaybackStarted
                    && (!viewModel.showControls || viewModel.isSwitchingSource || viewModel.showPauseOverlay)
                    && !viewModel.isScrubbing
                    && !viewModel.isHoldingSeek
                    && viewModel.currentErrorDiagnostic == nil
                    && !viewModel.showNextEpisodeCard
                    && !viewModel.showSkipSegmentCard
                    && !viewModel.showSettingsPanel
                    && !viewModel.showScenePanel
                    && !viewModel.isSceneDetailVisible
                    && !viewModel.postPlayState.isVisible
                    && viewModel.sidePanel == nil
            )
            .focused($remoteInputFocused)
            .onTapGesture {
                let elapsedWake = Date().timeIntervalSince(lastBecameActiveAt)
                screensaverDebugLog("[ScreensaverDebug][Input] onTapGesture: isWakingFromBg=\(isWakingFromBackground) (elapsedWake=\(String(format: "%.3f", elapsedWake))s), isScrubbing=\(viewModel.isScrubbing), showPauseOverlay=\(viewModel.showPauseOverlay), status=\(viewModel.status), pos=\(viewModel.time.current)")
                guard !isWakingFromBackground else {
                    screensaverDebugLog("[ScreensaverDebug][Input] onTapGesture suppressed by isWakingFromBackground")
                    return
                }
                guard didReportPlaybackStarted else {
                    revealControlsAndFocusSettings()
                    return
                }
                viewModel.handleSelectTap(
                    isOverlayFocused: nextEpisodeFocused || cancelAutoPlayFocused || skipSegmentFocused
                )
            }
            .onMoveCommand { direction in
                let elapsedWake = Date().timeIntervalSince(lastBecameActiveAt)
                screensaverDebugLog("[ScreensaverDebug][Input] onMoveCommand direction=\(direction): isWakingFromBg=\(isWakingFromBackground) (elapsedWake=\(String(format: "%.3f", elapsedWake))s), showPauseOverlay=\(viewModel.showPauseOverlay), showControls=\(viewModel.showControls), status=\(viewModel.status)")
                guard !isWakingFromBackground else {
                    screensaverDebugLog("[ScreensaverDebug][Input] onMoveCommand suppressed by isWakingFromBackground")
                    return
                }
                if viewModel.moveSuppressed { return }
                if viewModel.showPauseOverlay {
                    viewModel.revealControls()
                    return
                }
                guard !viewModel.showControls else { return }
                switch direction {
                case .left, .right:
                    // Swipes on the remote touchpad trigger onMoveCommand (.left / .right).
                    // We do NOT seek on swipe gestures while playing.
                    // Discrete seeking is exclusively triggered by physical button / D-pad taps via RemoteSeekPressCatcher.
                    break
                case .down:
                    if viewModel.isSceneEnabled {
                        viewModel.openScene()
                    } else {
                        viewModel.revealControls()
                    }
                default:
                    viewModel.revealControls()
                }
            }
            .accessibilityHidden(true)
    }

    @ViewBuilder
    var scenePanelLayer: some View {
        if viewModel.showScenePanel {
            ScenePanelView(
                viewModel: viewModel.sceneViewModel,
                isAdvancing: viewModel.isAdvancingEpisode,
                onDismiss: {
                    withAnimation(.playerControls) {
                        viewModel.closeScene()
                        focusRemoteInput()
                    }
                },
                onPlayNextEpisode: {
                    guard !isWakingFromBackground else { return }
                    withAnimation(.playerControls) {
                        viewModel.closeScene()
                        viewModel.playNextEpisode()
                    }
                },
                watchPartyContent: WatchPartyConfiguration.isEnabled && watchPartyOwner?.service != nil && !isStandalonePlaybackSession
                    ? { focus, focusContext in
                        guard let owner = watchPartyOwner, let service = owner.service else {
                            return AnyView(EmptyView())
                        }
                        return AnyView(PlayerWatchPartyPanel(
                            viewModel: viewModel, owner: owner, service: service,
                            focusedControlID: focus,
                            focusContext: focusContext,
                            isCurrentPlayerSurface: isCurrentPlayerSurface,
                            onOpenLobby: onOpenWatchPartyLobby
                        ))
                    }
                    : nil,
                watchPartyFocusTarget: {
                    if watchPartyOwner?.presentation?.mount.isCurrent == true { return "party.catchUp" }
                    guard let room = watchPartyOwner?.service?.session, let party = room.party else { return "party.create" }
                    return party.hostMemberID == room.memberID ? "party.hostOnly" : "party.lobby"
                }()
            )
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .zIndex(15)
        }
    }

    @ViewBuilder
    var sceneDetailLayer: some View {
        if let item = viewModel.sceneViewModel.selectedDetailItem {
            SceneDetailView(
                item: item,
                onDismiss: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        viewModel.closeSceneDetail()
                    }
                }
            )
            .transition(.opacity)
            .zIndex(16)
        }
    }

    @ViewBuilder
    var pauseOverlayLayer: some View {
        // Pause metadata sheet ("You're watching…").
        if viewModel.showPauseOverlay && viewModel.canShowPauseOverlay {
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
        if viewModel.showSkipSegmentCard
            && !viewModel.postPlayState.isVisible
            && !viewModel.showSettingsPanel
            && !viewModel.showScenePanel
            && !viewModel.isSceneDetailVisible
            && viewModel.sidePanel == nil
            && !viewModel.isScrubbing
            && !viewModel.isHoldingSeek,
           let interval = viewModel.activeSkipInterval {
            Button(action: {
                guard !isWakingFromBackground else { return }
                viewModel.skipActiveInterval()
            }) {
                SkipSegmentOverlay(
                    interval: interval,
                    countdown: viewModel.skipSegmentCountdown,
                    isFocused: skipSegmentFocused,
                    targetsPostCredits: viewModel.activeSkipTargetsPostCredits
                )
            }
            .buttonStyle(PosterCardButtonStyle())
            .focusEffectDisabledIfAvailable()
            .focused($skipSegmentFocused)
            .onMoveCommand { direction in
                guard !isWakingFromBackground else { return }
                switch direction {
                case .up:
                    if !viewModel.showControls {
                        withAnimation(.playerControls) {
                            viewModel.revealControls()
                        }
                    }
                case .down:
                    if !viewModel.showControls {
                        if viewModel.isSceneEnabled {
                            skipSegmentFocused = false
                            viewModel.openScene()
                        } else {
                            withAnimation(.playerControls) {
                                viewModel.revealControls()
                            }
                            skipSegmentFocused = false
                            requestedControlFocus = .timeline
                        }
                    } else {
                        skipSegmentFocused = false
                        requestedControlFocus = .timeline
                    }
                case .right:
                    if viewModel.showNextEpisodeCard {
                        skipSegmentFocused = false
                        focusNextEpisode(allowWhenControlsVisible: true)
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
        if viewModel.showNextEpisodeCard
            && !viewModel.postPlayState.isVisible
            && !viewModel.showSettingsPanel
            && !viewModel.showScenePanel
            && !viewModel.isSceneDetailVisible
            && viewModel.sidePanel == nil
            && !viewModel.isScrubbing
            && !viewModel.isHoldingSeek,
           let next = viewModel.nextEpisode {
            VStack(spacing: 8) {
                Button(action: {
                    guard !isWakingFromBackground else { return }
                    viewModel.playNextEpisode()
                }) {
                    NextEpisodeOverlay(
                        episode: next,
                        isAdvancing: viewModel.isAdvancingEpisode,
                        isFocused: nextEpisodeFocused,
                        isAutoPlayCancelled: viewModel.isAutoPlayCancelled
                    )
                }
                .buttonStyle(PosterCardButtonStyle())
                .focusEffectDisabledIfAvailable()
                .focused($nextEpisodeFocused)
                .onMoveCommand { direction in
                    guard !isWakingFromBackground else { return }
                    switch direction {
                    case .up:
                        if !viewModel.showControls {
                            withAnimation(.playerControls) {
                                viewModel.revealControls()
                            }
                        }
                    case .down:
                        if viewModel.nextEpisodeCountdown != nil {
                            nextEpisodeFocused = false
                            cancelAutoPlayFocused = true
                        } else if !viewModel.showControls {
                            if viewModel.isSceneEnabled {
                                nextEpisodeFocused = false
                                viewModel.openScene()
                            } else {
                                withAnimation(.playerControls) {
                                    viewModel.revealControls()
                                }
                                nextEpisodeFocused = false
                                requestedControlFocus = .settings
                            }
                        } else {
                            nextEpisodeFocused = false
                            requestedControlFocus = .settings
                        }
                    case .left:
                        if viewModel.showSkipSegmentCard {
                            nextEpisodeFocused = false
                            focusSkipSegment()
                        } else if viewModel.showControls {
                            nextEpisodeFocused = false
                            requestedControlFocus = .settings
                        }
                    default:
                        break
                    }
                }

                if viewModel.nextEpisodeCountdown != nil {
                    Button(action: {
                        guard !isWakingFromBackground else { return }
                        viewModel.cancelAutoPlay()
                    }) {
                        Text(L10n.string("cancel", fallback: "Cancel"))
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(cancelAutoPlayFocused ? .black : .white)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 8)
                            .background(
                                Capsule()
                                    .fill(cancelAutoPlayFocused ? Color.white : Color.white.opacity(0.15))
                            )
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
                            if !viewModel.showControls {
                                if viewModel.isSceneEnabled {
                                    cancelAutoPlayFocused = false
                                    viewModel.openScene()
                                } else {
                                    withAnimation(.playerControls) {
                                        viewModel.revealControls()
                                    }
                                    cancelAutoPlayFocused = false
                                    requestedControlFocus = .settings
                                }
                            } else {
                                cancelAutoPlayFocused = false
                                requestedControlFocus = .settings
                            }
                        case .left:
                            if viewModel.showSkipSegmentCard {
                                cancelAutoPlayFocused = false
                                focusSkipSegment()
                            } else if viewModel.showControls {
                                cancelAutoPlayFocused = false
                                requestedControlFocus = .settings
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
        if viewModel.currentErrorDiagnostic == nil {
            let isSeekingOrControlsVisible = (viewModel.showControls || viewModel.isScrubbing || viewModel.isHoldingSeek || viewModel.pendingSeekDelta != 0) && !viewModel.showScenePanel && !viewModel.isSceneDetailVisible
            PlayerControls(
                viewModel: viewModel,
                didReportPlaybackStarted: didReportPlaybackStarted,
                isSkipSegmentFocused: skipSegmentFocused,
                isNextEpisodeFocused: nextEpisodeFocused || cancelAutoPlayFocused,
                requestedFocus: $requestedControlFocus,
                onFocusSkipSegment: { focusSkipSegment() },
                onFocusNextEpisode: { focusNextEpisode(allowWhenControlsVisible: true) }
            )
            .offset(y: viewModel.showScenePanel ? -160 : 0)
            .opacity(
                isSeekingOrControlsVisible
                    && !isLoadingOverlayVisible
                    && !viewModel.showSettingsPanel
                    && !viewModel.showPauseOverlay
                ? 1 : 0
            )
            .scaleEffect(
                isSeekingOrControlsVisible
                    && !isLoadingOverlayVisible
                    && !viewModel.showSettingsPanel
                    && !viewModel.showPauseOverlay
                ? 1 : 0.95
            )
            .allowsHitTesting(
                isSeekingOrControlsVisible
                    && !isLoadingOverlayVisible
                    && !viewModel.showSettingsPanel
                    && !viewModel.showPauseOverlay
            )
            .disabled(!isSeekingOrControlsVisible || isLoadingOverlayVisible || viewModel.showScenePanel || viewModel.isSceneDetailVisible)
            .animation(.playerControls, value: viewModel.showControls)
            .animation(.playerControls, value: didReportPlaybackStarted)
            .animation(.playerControls, value: viewModel.isSwitchingSource)
            .animation(.playerControls, value: viewModel.isAwaitingStreamStart)
            .animation(.playerControls, value: viewModel.isAdvancingEpisode)
            .animation(.playerControls, value: viewModel.showSettingsPanel)
            .animation(.playerControls, value: viewModel.isScrubbing)
            .animation(.playerControls, value: viewModel.isHoldingSeek)
            .animation(.playerControls, value: viewModel.pendingSeekDelta)
            .animation(.playerControls, value: viewModel.showPauseOverlay)
            .animation(.playerControls, value: viewModel.showScenePanel)
            .animation(.playerControls, value: viewModel.isSceneDetailVisible)
            .zIndex(20)
        }
    }

    @ViewBuilder
    var settingsPanelLayer: some View {
        // Settings panel (subtitles / audio / speed), over the dimmed video.
        if viewModel.showSettingsPanel {
            PlayerSettingsPanel(viewModel: viewModel, didReportPlaybackStarted: didReportPlaybackStarted) {
                viewModel.showSettingsPanel = false
            }
            .transition(.opacity)
            .zIndex(15)
        }
    }

    @ViewBuilder
    var sidePanelLayer: some View {
        // Episodes / Sources side panels.
        if viewModel.sidePanel == .episodes {
            PlayerEpisodesPanel(viewModel: viewModel)
                .zIndex(25)
        } else if viewModel.sidePanel == .sources {
            PlayerSourcesPanel(viewModel: viewModel)
                .zIndex(25)
        }
    }
}
