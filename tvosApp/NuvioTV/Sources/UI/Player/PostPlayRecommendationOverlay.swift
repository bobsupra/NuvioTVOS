//
//  PostPlayRecommendationOverlay.swift
//  NuvioTV
//
//  Full-screen paged post-play recommendation overlay for movies and series on tvOS.
//

import SwiftUI
import AVFoundation

struct PostPlayRecommendationOverlay: View {
    let state: PostPlayRecommendationUiState
    let currentTitle: String
    let showManualPlayOption: Bool
    var focus: FocusState<PostPlayFocusItem?>.Binding
    let onPlay: (PostPlayRecommendation, _ playManually: Bool) -> Void
    let onOpenDetails: (PostPlayRecommendation) -> Void
    let onPlayTrailer: () -> Void
    let onStopTrailer: () -> Void
    let onPreviousRecommendation: () -> Void
    let onNextRecommendation: () -> Void
    let onBack: () -> Void

    @State private var trailerPlayer = AVPlayer()
    @State private var isTrailerReady = false
    @State private var showSynopsisModal = false
    @AppStorage(SettingsKey.trailerPreviewSound) private var trailerPreviewSound = false

    var body: some View {
        guard let recommendation = state.recommendation else {
            return AnyView(EmptyView())
        }

        return AnyView(
            ZStack(alignment: .bottomLeading) {
                // 1. Full-screen backdrop or Trailer preview
                backdropLayer(for: recommendation)

                // 2. Gradient Scrims for text contrast
                scrimsLayer

                // 3. Bottom-Leading Content Summary & Actions
                VStack(alignment: .leading, spacing: 0) {
                    summarySection(for: recommendation)
                        .padding(.bottom, state.isTrailerPlaying ? 24 : 36)

                    actionButtonsRow(for: recommendation)
                }
                .frame(maxWidth: 960, alignment: .leading)
                .padding(.leading, 80)
                .padding(.bottom, 60)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
            .onExitCommand {
                onBack()
            }
            .sheet(isPresented: $showSynopsisModal) {
                if let desc = recommendation.description, !desc.isEmpty {
                    SynopsisSheet(title: recommendation.title, description: desc)
                }
            }
            .onAppear {
                DispatchQueue.main.async {
                    focus.wrappedValue = .primaryAction
                }
            }
            .onChange(of: state.isVisible) { _, isVisible in
                if isVisible {
                    DispatchQueue.main.async {
                        focus.wrappedValue = .primaryAction
                    }
                }
            }
            .onChange(of: state.isTrailerPlaying) { _, isPlaying in
                if isPlaying {
                    startTrailerPlayback(recommendation: recommendation)
                } else {
                    stopTrailerPlayback()
                }
            }
            .onChange(of: state.recommendationIndex) { _, _ in
                if state.isTrailerPlaying {
                    stopTrailerPlayback()
                }
            }
            .onReceive(
                NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)
            ) { notification in
                guard let item = notification.object as? AVPlayerItem,
                      item == trailerPlayer.currentItem else {
                    return
                }
                onStopTrailer()
            }
        )
    }

    // MARK: - Subviews

    @ViewBuilder
    private func backdropLayer(for recommendation: PostPlayRecommendation) -> some View {
        ZStack {
            Color.black

            if let backdropUrl = recommendation.backdrop ?? recommendation.poster,
               let url = URL(string: backdropUrl) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipped()
                    default:
                        Color.black
                    }
                }
                .transition(.opacity)
                .id("backdrop-\(recommendation.id)")
            }

            if state.isTrailerPlaying {
                TrailerPlayerSurface(player: trailerPlayer) {
                    isTrailerReady = true
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(isTrailerReady ? 1 : 0)
                .animation(.easeInOut(duration: 0.32), value: isTrailerReady)
            }
        }
        .ignoresSafeArea()
    }

    private var scrimsLayer: some View {
        ZStack {
            // Horizontal gradient (left heavy)
            LinearGradient(
                stops: [
                    .init(color: Color.black.opacity(0.92), location: 0),
                    .init(color: Color.black.opacity(0.65), location: 0.45),
                    .init(color: Color.black.opacity(0.18), location: 0.8),
                    .init(color: Color.black.opacity(0.35), location: 1.0)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )

            // Vertical gradient (bottom heavy)
            LinearGradient(
                stops: [
                    .init(color: Color.black.opacity(0.2), location: 0),
                    .init(color: Color.clear, location: 0.3),
                    .init(color: Color.black.opacity(0.85), location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private func summarySection(for recommendation: PostPlayRecommendation) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header tag
            Text(headerText)
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.white.opacity(0.65))
                .textCase(.uppercase)
                .tracking(1.5)
                .lineLimit(1)

            // Logo or Title
            if let logoUrl = recommendation.logo, let url = URL(string: logoUrl) {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: 520, maxHeight: state.isTrailerPlaying ? 64 : 96, alignment: .leading)
                    } else {
                        titleView(for: recommendation)
                    }
                }
                .id("logo-\(recommendation.id)")
            } else {
                titleView(for: recommendation)
            }

            // Metadata Line
            if !recommendation.metadataLine.isEmpty {
                HStack(spacing: 12) {
                    Text(recommendation.metadataLine)
                        .font(.system(size: 24, weight: .medium))
                        .foregroundColor(.white.opacity(0.8))
                        .lineLimit(1)

                    if let rating = recommendation.rating, rating > 0 {
                        Text("•")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundColor(.white.opacity(0.4))

                        HStack(spacing: 5) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 18))
                                .foregroundColor(Color(red: 0.96, green: 0.77, blue: 0.09))
                            Text(String(format: "%.1f", rating))
                                .font(.system(size: 22, weight: .bold))
                                .foregroundColor(.white)
                        }
                    }

                    if let tmdbRating = recommendation.tmdbRating, tmdbRating > 0, recommendation.rating == nil {
                        Text("•")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundColor(.white.opacity(0.4))

                        HStack(spacing: 5) {
                            Text("TMDB")
                                .font(.system(size: 16, weight: .black))
                                .foregroundColor(Color(red: 0.00, green: 0.71, blue: 0.89))
                            Text(String(format: "%.1f", tmdbRating))
                                .font(.system(size: 22, weight: .bold))
                                .foregroundColor(.white)
                        }
                    }
                }
            }

            // Synopsis
            if let desc = recommendation.description, !desc.isEmpty {
                Text(desc)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundColor(.white.opacity(0.85))
                    .lineLimit(state.isTrailerPlaying ? 2 : 3)
                    .lineSpacing(4)
                    .frame(maxWidth: 820, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        showSynopsisModal = true
                    }
            }
        }
        .animation(.easeInOut(duration: 0.3), value: state.isTrailerPlaying)
    }

    private func titleView(for recommendation: PostPlayRecommendation) -> some View {
        Text(recommendation.title)
            .font(.system(size: state.isTrailerPlaying ? 40 : 54, weight: .heavy))
            .foregroundColor(.white)
            .lineLimit(2)
            .shadow(color: .black.opacity(0.6), radius: 8, x: 0, y: 3)
            .id("title-\(recommendation.id)")
    }

    private var headerText: String {
        if currentTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return L10n.string("post_play_recommended_for_you", fallback: "Recommended for You")
        }
        return L10n.format("post_play_because_you_watched", fallback: "Because you watched %@", currentTitle)
    }

    @ViewBuilder
    private func actionButtonsRow(for recommendation: PostPlayRecommendation) -> some View {
        HStack(spacing: 20) {
            // 1. Primary Action Button (Play / Details) - Solid White Liquid Glass
            let isPrimaryFocused = focus.wrappedValue == .primaryAction
            Button {
                if recommendation.isSeries {
                    onOpenDetails(recommendation)
                } else {
                    onPlay(recommendation, false)
                }
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: recommendation.isSeries ? "info.circle.fill" : "play.fill")
                        .font(.system(size: 26, weight: .bold))
                    Text(recommendation.isSeries
                        ? L10n.string("action_details", fallback: "Details")
                        : L10n.string("action_play", fallback: "Play"))
                        .font(.system(size: 26, weight: .semibold))
                }
                .foregroundColor(.black)
                .padding(.horizontal, 38)
                .frame(minWidth: 200, minHeight: 76)
                .frame(height: 76)
                .modifier(TvDetailsGlassBackground(filled: true, shape: Capsule()))
                .shadow(color: .black.opacity(isPrimaryFocused ? 0.38 : 0.18), radius: isPrimaryFocused ? 18 : 7, y: 8)
            }
            .buttonStyle(PosterCardButtonStyle())
            .focusEffectDisabledIfAvailable()
            .focused(focus, equals: .primaryAction)
            .scaleEffect(isPrimaryFocused ? 1.08 : 1.0)
            .animation(.easeOut(duration: 0.14), value: isPrimaryFocused)
            .onMoveCommand { direction in
                if direction == .up {
                    focus.wrappedValue = .miniPlayer
                }
            }
            .contextMenu {
                if !recommendation.isSeries && showManualPlayOption {
                    Button {
                        onPlay(recommendation, true)
                    } label: {
                        Label(
                            L10n.string("action_select_stream_manually", fallback: "Select Stream Manually"),
                            systemImage: "list.bullet"
                        )
                    }
                }
            }

            // 2. Trailer Button (if available) - Liquid Glass (Translucent -> Solid White on Focus)
            if recommendation.hasTrailer {
                let isTrailerFocused = focus.wrappedValue == .trailerAction
                Button {
                    if state.isTrailerPlaying {
                        onStopTrailer()
                    } else {
                        onPlayTrailer()
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: state.isTrailerPlaying ? "stop.fill" : "play.rectangle.fill")
                            .font(.system(size: 24, weight: .semibold))
                        Text(trailerButtonLabel)
                            .font(.system(size: 24, weight: .semibold))
                    }
                    .foregroundColor(isTrailerFocused ? .black : .white)
                    .padding(.horizontal, 30)
                    .frame(minHeight: 76)
                    .frame(height: 76)
                    .modifier(TvDetailsGlassBackground(filled: isTrailerFocused, shape: Capsule()))
                    .shadow(color: .black.opacity(isTrailerFocused ? 0.38 : 0.18), radius: isTrailerFocused ? 18 : 7, y: 8)
                }
                .buttonStyle(PosterCardButtonStyle())
                .focusEffectDisabledIfAvailable()
                .focused(focus, equals: .trailerAction)
                .scaleEffect(isTrailerFocused ? 1.08 : 1.0)
                .animation(.easeOut(duration: 0.14), value: isTrailerFocused)
                .onMoveCommand { direction in
                    if direction == .up {
                        focus.wrappedValue = .miniPlayer
                    }
                }
            }

            // 3. Navigation Paging Buttons (Previous / Next) - Liquid Glass Circular Buttons
            if state.recommendationCount > 1 {
                let isPrevFocused = focus.wrappedValue == .prevAction
                Button {
                    onPreviousRecommendation()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(isPrevFocused ? .black : .white)
                        .frame(width: 76, height: 76)
                        .modifier(TvDetailsGlassBackground(filled: isPrevFocused, shape: Circle()))
                        .shadow(color: .black.opacity(isPrevFocused ? 0.38 : 0.18), radius: isPrevFocused ? 18 : 7, y: 8)
                }
                .buttonStyle(PosterCardButtonStyle())
                .focusEffectDisabledIfAvailable()
                .disabled(!state.canNavigatePrevious)
                .opacity(state.canNavigatePrevious ? 1.0 : 0.35)
                .focused(focus, equals: .prevAction)
                .scaleEffect(isPrevFocused ? 1.08 : 1.0)
                .animation(.easeOut(duration: 0.14), value: isPrevFocused)
                .onMoveCommand { direction in
                    if direction == .up {
                        focus.wrappedValue = .miniPlayer
                    }
                }

                let isNextFocused = focus.wrappedValue == .nextAction
                Button {
                    onNextRecommendation()
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(isNextFocused ? .black : .white)
                        .frame(width: 76, height: 76)
                        .modifier(TvDetailsGlassBackground(filled: isNextFocused, shape: Circle()))
                        .shadow(color: .black.opacity(isNextFocused ? 0.38 : 0.18), radius: isNextFocused ? 18 : 7, y: 8)
                }
                .buttonStyle(PosterCardButtonStyle())
                .focusEffectDisabledIfAvailable()
                .disabled(!state.canNavigateNext)
                .opacity(state.canNavigateNext ? 1.0 : 0.35)
                .focused(focus, equals: .nextAction)
                .scaleEffect(isNextFocused ? 1.08 : 1.0)
                .animation(.easeOut(duration: 0.14), value: isNextFocused)
                .onMoveCommand { direction in
                    if direction == .up {
                        focus.wrappedValue = .miniPlayer
                    }
                }
            }
        }
    }

    private var trailerButtonLabel: String {
        if state.isTrailerPlaying {
            return L10n.string("action_stop_trailer", fallback: "Stop Trailer")
        }
        if let count = state.countdownSeconds {
            return L10n.format("action_trailer_countdown", fallback: "Trailer (%ds)", count)
        }
        return L10n.string("action_trailer", fallback: "Trailer")
    }

    // MARK: - Trailer Playback Helpers

    private func startTrailerPlayback(recommendation: PostPlayRecommendation) {
        guard let videoUrl = recommendation.trailerVideoUrl, let url = URL(string: videoUrl) else { return }
        isTrailerReady = false

        let asset: AVURLAsset
        if let userAgent = recommendation.trailerHeaders["User-Agent"], !userAgent.isEmpty {
            asset = AVURLAsset(url: url, options: [AVURLAssetHTTPUserAgentKey: userAgent])
        } else {
            asset = AVURLAsset(url: url)
        }

        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 2.0
        trailerPlayer.replaceCurrentItem(with: item)
        trailerPlayer.isMuted = !trailerPreviewSound
        trailerPlayer.volume = trailerPreviewSound ? 1.0 : 0.0
        trailerPlayer.play()
    }

    private func stopTrailerPlayback() {
        trailerPlayer.pause()
        trailerPlayer.replaceCurrentItem(with: nil)
        isTrailerReady = false
    }
}

private struct SynopsisSheet: View {
    let title: String
    let description: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(title)
                .font(.system(size: 38, weight: .bold))
                .foregroundColor(.white)

            ScrollView {
                Text(description)
                    .font(.system(size: 24, weight: .regular))
                    .foregroundColor(.white.opacity(0.85))
                    .lineSpacing(6)
            }

            Spacer()

            Button(L10n.string("action_close", fallback: "Close")) {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(50)
        .frame(maxWidth: 1000, maxHeight: 700)
        .background(Color.black.opacity(0.9).ignoresSafeArea())
    }
}
