import SwiftUI

struct ScenePanelView: View {
    @ObservedObject var viewModel: SceneViewModel
    var isAdvancing: Bool = false
    let onDismiss: () -> Void
    let onPlayNextEpisode: (() -> Void)?
    let watchPartyContent: ((FocusState<String?>.Binding, FocusState<SceneTab?>.Binding) -> AnyView)?
    let watchPartyFocusTarget: String
    
    @FocusState private var focusedTab: SceneTab?
    @FocusState private var focusedCardID: String?
    
    init(
        viewModel: SceneViewModel,
        isAdvancing: Bool = false,
        onDismiss: @escaping () -> Void,
        onPlayNextEpisode: (() -> Void)? = nil,
        watchPartyContent: ((FocusState<String?>.Binding, FocusState<SceneTab?>.Binding) -> AnyView)? = nil,
        watchPartyFocusTarget: String = "party.start"
    ) {
        self.viewModel = viewModel
        self.isAdvancing = isAdvancing
        self.onDismiss = onDismiss
        self.onPlayNextEpisode = onPlayNextEpisode
        self.watchPartyContent = watchPartyContent
        self.watchPartyFocusTarget = watchPartyFocusTarget
    }
    
    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            
            // Bottom third panel
            VStack(alignment: .leading, spacing: 22) {
                // Tab Header Bar
                tabHeaderBar
                    .padding(.top, 10)
                
                // Active Tab Content
                Group {
                    switch viewModel.selectedTab {
                    case .scene:
                        sceneTabContent
                    case .info:
                        infoTabContent
                    case .upNext:
                        upNextTabContent
                    case .watchParty:
                        watchPartyContent?($focusedCardID, $focusedTab) ?? AnyView(EmptyView())
                    }
                }
                // Keep the bottom-anchored panel at a constant size across tab navigation.
                // The previous 272/300pt switch made InSight visibly jump vertically.
                .frame(height: 300, alignment: .top)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onExitCommand {
            onDismiss()
        }
        .onAppear {
            if viewModel.selectedTab == .watchParty && watchPartyContent == nil {
                viewModel.selectTab(.info)
            }
            if focusedTab == nil {
                focusedTab = viewModel.selectedTab
            }
        }
        .onChange(of: watchPartyContent != nil) { _, available in
            // The room can end while InSight is open. Remove the stale tab
            // and give focus back to Info without dismissing the player.
            if !available && viewModel.selectedTab == .watchParty {
                focusedCardID = nil
                viewModel.selectTab(.info)
                focusedTab = .info
            }
        }
        .onChange(of: focusedTab) { _, newTab in
            if let newTab, viewModel.selectedTab != newTab {
                withAnimation(.easeInOut(duration: 0.18)) {
                    viewModel.selectTab(newTab)
                }
            }
        }
        .defaultFocus($focusedTab, viewModel.selectedTab)
    }
    
    // MARK: - Tab Header Bar
    
    private var tabHeaderBar: some View {
        HStack(spacing: 20) {
            ForEach(visibleTabs) { tab in
                let isSelected = viewModel.selectedTab == tab
                let isTabFocused = focusedTab == tab
                
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        viewModel.selectTab(tab)
                    }
                }) {
                    Text(tab.localizedTitle)
                        .font(.system(size: 26, weight: isTabFocused ? .bold : .semibold))
                        .foregroundColor(isTabFocused ? .black : .white.opacity(0.92))
                        .padding(.horizontal, 36)
                        .frame(height: 64)
                        .modifier(TvDetailsGlassBackground(filled: isTabFocused, shape: Capsule()))
                        .overlay {
                            ZStack {
                                if isSelected && !isTabFocused {
                                    Capsule().fill(Color.white.opacity(0.22))
                                }
                                Capsule()
                                    .stroke(Color.white.opacity(isSelected && !isTabFocused ? 0.26 : 0), lineWidth: 1)
                            }
                            .allowsHitTesting(false)
                        }
                }
                .buttonStyle(PosterCardButtonStyle())
                .focused($focusedTab, equals: tab)
                .focusEffectDisabledIfAvailable()
                .scaleEffect(isTabFocused ? 1.05 : 1.0)
                .animation(.easeOut(duration: 0.14), value: isTabFocused)
                .onExitCommand(perform: onDismiss)
                .onMoveCommand { direction in
                    switch direction {
                    case .up:
                        onDismiss()
                    case .down:
                        focusFirstCard()
                    default:
                        break
                    }
                }
            }
        }
        .padding(.horizontal, 60)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var visibleTabs: [SceneTab] {
        guard watchPartyContent != nil else { return viewModel.availableTabs }
        return viewModel.availableTabs + [.watchParty]
    }
    
    // MARK: - Scene Tab Content
    
    private var sceneTabContent: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 20) {
                let recognizedActors = viewModel.snapshot.actors
                let playingSong = viewModel.snapshot.song
                
                if recognizedActors.isEmpty, let song = playingSong {
                    let isSongFocused = focusedCardID == "song-\(song.id)"
                    SceneSongCard(song: song, isFocused: isSongFocused) {
                        viewModel.openDetail(.song(song))
                    }
                    .focused($focusedCardID, equals: "song-\(song.id)")
                    .onExitCommand(perform: onDismiss)
                    .onMoveCommand { direction in
                        if direction == .up {
                            focusedCardID = nil
                            focusedTab = viewModel.selectedTab
                        }
                    }
                } else if !recognizedActors.isEmpty {
                    ForEach(recognizedActors) { actor in
                        let isActorFocused = focusedCardID == "actor-\(actor.id)"
                        SceneActorCard(
                            actor: actor,
                            isLiveRecognized: true,
                            isFocused: isActorFocused
                        ) {
                            viewModel.openDetail(.actor(actor, detail: nil))
                        }
                        .focused($focusedCardID, equals: "actor-\(actor.id)")
                        .onExitCommand(perform: onDismiss)
                        .onMoveCommand { direction in
                            if direction == .up {
                                focusedCardID = nil
                                focusedTab = viewModel.selectedTab
                            }
                        }
                    }
                    
                    if let song = playingSong {
                        let isSongFocused = focusedCardID == "song-\(song.id)"
                        SceneSongCard(song: song, isFocused: isSongFocused) {
                            viewModel.openDetail(.song(song))
                        }
                        .focused($focusedCardID, equals: "song-\(song.id)")
                        .onExitCommand(perform: onDismiss)
                        .onMoveCommand { direction in
                            if direction == .up {
                                focusedCardID = nil
                                focusedTab = viewModel.selectedTab
                            }
                        }
                    }
                } else {
                    statusCard
                }
            }
            .padding(.horizontal, 60)
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
        .scrollClipDisabled()
    }
    
    @ViewBuilder
    private var statusCard: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 0)
            switch viewModel.snapshot.actorStatus {
            case .analyzing, .preparingReferences:
                ProgressView()
                    .scaleEffect(1.2)
                    .padding(.bottom, 6)
                Text(viewModel.isAnime ? "Loading cast…" : "Scanning scene…")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
            case .unavailable(let reason):
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.system(size: 38))
                    .foregroundColor(.white.opacity(0.35))
                    .padding(.bottom, 4)
                Text(reason.isEmpty ? (viewModel.isAnime ? "No cast available" : "No actors in this shot") : reason)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
            default:
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.system(size: 38))
                    .foregroundColor(.white.opacity(0.35))
                    .padding(.bottom, 4)
                Text(viewModel.isAnime ? "No cast for this episode" : "No actors in this shot")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 12)
        .frame(width: 184, height: 256)
        .modifier(TvCardGlassBackground(isFocused: false, shape: RoundedRectangle(cornerRadius: 32, style: .continuous)))
    }
    
    // MARK: - Info Tab Content (Horizontal Playback Telemetry)
    
    private var infoTabContent: some View {
        let info = viewModel.playbackInfo ?? ScenePlaybackInfo()
        
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 20) {
                // Section 1: PLAYBACK ENGINE
                telemetryCard(title: "PLAYBACK ENGINE", width: 340, height: 256) {
                    VStack(alignment: .leading, spacing: 6) {
                        infoRow(label: "Engine", value: info.engine)
                        infoRow(label: "Version", value: info.version)
                    }
                }
                
                // Section 2: VIDEO STREAM
                telemetryCard(title: "VIDEO STREAM", width: 560, height: 256) {
                    VStack(alignment: .leading, spacing: 4) {
                        infoRow(label: "Codec", value: info.videoCodec)
                        infoRow(label: "Resolution", value: info.resolution)
                        infoRow(label: "Frame Rate", value: info.frameRate)
                        infoRow(label: "Dynamic Range", value: info.dynamicRange)
                        if let profile = info.dolbyVisionProfile, !profile.isEmpty {
                            infoRow(label: "Dolby Vision Profile", value: profile)
                        }
                        infoRow(label: "Bitrate", value: info.videoBitrate)
                        infoRow(label: "Container", value: info.container)
                        infoRow(label: "Decoder", value: info.videoDecoder)
                    }
                }
                
                // Section 3: AUDIO STREAM
                telemetryCard(title: "AUDIO STREAM", width: 540, height: 256) {
                    VStack(alignment: .leading, spacing: 6) {
                        infoRow(label: "Codec", value: info.audioCodec)
                        infoRow(label: "Channels", value: info.audioChannels)
                        infoRow(label: "Language", value: info.audioLanguage)
                        infoRow(label: "Bitrate", value: info.audioBitrate)
                        infoRow(label: "A/V producer gap", value: formattedAVSyncGap(info.avSyncGapMs))
                        infoRow(label: "Spatial format", value: info.audioSpatialFormat)
                        infoRow(label: "Audio pipeline", value: info.audioDecoder, lineLimit: 2)
                    }
                }
            }
            .padding(.horizontal, 60)
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
        .scrollClipDisabled()
    }
    
    private func telemetryCard<Content: View>(
        title: String,
        width: CGFloat,
        height: CGFloat = 236,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 15, weight: .heavy))
                .foregroundColor(.white)
                .tracking(1.2)
            
            Rectangle()
                .fill(Color.white.opacity(0.14))
                .frame(height: 1)
                .padding(.bottom, 2)
            
            content()
            
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .frame(width: width, height: height, alignment: .topLeading)
        .modifier(TvCardGlassBackground(isFocused: false, shape: RoundedRectangle(cornerRadius: 32, style: .continuous)))
    }
    
    private func infoRow(label: String, value: String, lineLimit: Int = 1) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(label)
                .font(.system(size: 15, weight: .regular))
                .foregroundColor(Color.white.opacity(0.65))
                .lineLimit(1)
                .frame(minWidth: 90, alignment: .leading)
            
            Spacer(minLength: 12)
            
            Text(value)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(lineLimit)
                .truncationMode(.tail)
                .multilineTextAlignment(.trailing)
        }
    }
    
    // MARK: - Up Next Tab Content
    
    @ViewBuilder
    private var upNextTabContent: some View {
        let isNextFocused = focusedCardID == "upNext"
        
        VStack(alignment: .leading, spacing: 0) {
            if let next = viewModel.nextEpisode {
                let isPlayable = EpisodeReleasePolicy.hasAired(next.released)
                let airDateText = EpisodeReleasePolicy.airDateText(for: next.released).map { "Airs \($0)" } ?? "Upcoming"
                
                Button(action: {
                    guard isPlayable else { return }
                    onPlayNextEpisode?()
                }) {
                    HStack(spacing: 24) {
                        // Thumbnail
                        ZStack {
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .fill(isNextFocused ? Color.black.opacity(0.08) : Color.white.opacity(0.12))
                                .frame(width: 300, height: 170)
                            
                            if let thumb = next.thumbnail, let url = URL(string: thumb) {
                                AsyncImage(url: url) { phase in
                                    if let img = phase.image {
                                        img.resizable().scaledToFill()
                                            .frame(width: 300, height: 170)
                                            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                                    }
                                }
                            }
                            
                            Image(systemName: isPlayable ? "play.fill" : "calendar")
                                .font(.system(size: 30))
                                .foregroundColor(.white)
                                .padding(16)
                                .background(Circle().fill(Color.black.opacity(0.6)))
                        }
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Up Next")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(isNextFocused ? Color(red: 0.0, green: 0.45, blue: 0.85) : Color(red: 0.10, green: 0.68, blue: 1.0))
                                .textCase(.uppercase)
                            
                            Text("S\(next.season) · E\(next.episode): \(next.title)")
                                .font(.system(size: 24, weight: .bold))
                                .foregroundColor(isNextFocused ? .black : .white)
                                .lineLimit(1)
                            
                            if !isPlayable {
                                Text(airDateText)
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundColor(isNextFocused ? Color.black.opacity(0.7) : Color.white.opacity(0.7))
                            } else if let overview = next.overview, !overview.isEmpty {
                                Text(overview)
                                    .font(.system(size: 16, weight: .regular))
                                    .foregroundColor(isNextFocused ? Color.black.opacity(0.7) : Color.white.opacity(0.7))
                                    .lineLimit(2)
                            }
                            
                            HStack(spacing: 8) {
                                if isAdvancing {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: isNextFocused && isPlayable ? .black : .white))
                                        .scaleEffect(0.8)
                                    Text(L10n.string("player_starting", fallback: "Starting…"))
                                        .font(.system(size: 16, weight: .semibold))
                                } else {
                                    Image(systemName: isPlayable ? "play.fill" : "calendar")
                                        .font(.system(size: 14))
                                    Text(isPlayable ? L10n.string("tvos_play_next_episode", fallback: "Play Next Episode") : L10n.string("player_not_yet", fallback: "Not Yet"))
                                        .font(.system(size: 16, weight: .semibold))
                                }
                            }
                            .foregroundColor(isNextFocused && isPlayable ? .black : .white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .background(
                                Capsule()
                                    .fill(isNextFocused && isPlayable ? Color.white : Color.white.opacity(0.2))
                            )
                            .padding(.top, 4)
                        }
                        .frame(maxWidth: 520, alignment: .leading)
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 16)
                    .frame(height: 256)
                    .modifier(TvDetailsGlassBackground(filled: isNextFocused, shape: RoundedRectangle(cornerRadius: 32, style: .continuous)))
                    .shadow(color: Color.black.opacity(isNextFocused ? 0.22 : 0.25), radius: isNextFocused ? 10 : 6, y: isNextFocused ? 5 : 3)
                }
                .buttonStyle(PosterCardButtonStyle())
                .focused($focusedCardID, equals: "upNext")
                .focusEffectDisabledIfAvailable()
                .scaleEffect(isNextFocused ? 1.03 : 1.0)
                .animation(.easeOut(duration: 0.14), value: isNextFocused)
                .onExitCommand(perform: onDismiss)
                .onMoveCommand { direction in
                    if direction == .up {
                        focusedCardID = nil
                        focusedTab = viewModel.selectedTab
                    }
                }
                .padding(.horizontal, 60)
                .padding(.top, 16)
            } else {
                Text("No upcoming episode")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
                    .padding(.horizontal, 60)
                    .padding(.top, 24)
            }
            
            Spacer(minLength: 0)
        }
    }
    
    // MARK: - Focus Management
    
    private func focusFirstCard() {
        switch viewModel.selectedTab {
        case .scene:
            if viewModel.snapshot.actors.isEmpty, let song = viewModel.snapshot.song {
                focusedTab = nil
                focusedCardID = "song-\(song.id)"
            } else if let firstActor = viewModel.snapshot.actors.first {
                focusedTab = nil
                focusedCardID = "actor-\(firstActor.id)"
            } else if let song = viewModel.snapshot.song {
                focusedTab = nil
                focusedCardID = "song-\(song.id)"
            } else {
                focusedTab = viewModel.selectedTab
            }
        case .upNext:
            if viewModel.nextEpisode != nil {
                focusedTab = nil
                focusedCardID = "upNext"
            } else {
                focusedTab = viewModel.selectedTab
            }
        case .info:
            focusedTab = viewModel.selectedTab
        case .watchParty:
            // Room status is intentionally read-only; keep focus on its tab.
            focusedCardID = nil
            focusedTab = .watchParty
        }
    }
}
