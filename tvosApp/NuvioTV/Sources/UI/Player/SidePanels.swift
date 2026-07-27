import SwiftUI

// MARK: - Panel kind

enum PlayerSidePanel: Equatable {
    case episodes
    case sources
}

// MARK: - Chrome

/// Right-anchored in-player side sheet (episodes / sources).
struct PlayerSidePanelChrome<Content: View>: View {
    let title: String
    var onExit: () -> Void = {}
    @ViewBuilder var content: Content

    private let panelCornerRadius: CGFloat = 34

    var body: some View {
        HStack(spacing: 0) {
            // Nothing is drawn beside the panel: any scrim here is laid out
            // inside the safe area (the chrome only ignores the trailing edge),
            // so it renders as a dimmed rectangle with visible seams at the
            // screen's left and bottom instead of a full-bleed wash.
            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 20) {
                Text(title)
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(.white)

                content
                    .frame(maxHeight: .infinity)
            }
            .padding(28)
            .frame(width: 640, alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous)
                    .fill(Color.black.opacity(0.22))
                    .glassRoundedRect(cornerRadius: panelCornerRadius)
            }
            .overlay {
                RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.4), radius: 28, x: -8, y: 0)
            .padding(.vertical, 32)
            .padding(.trailing, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(edges: .trailing)
        .transition(.move(edge: .trailing).combined(with: .opacity))
        .onExitCommand(perform: onExit)
    }
}

// MARK: - Row

struct PlayerPanelRow: View {
    let title: String
    var subtitle: String?
    var trailing: String?
    var selected: Bool = false
    var isFocused: Bool = false

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(isFocused ? .black : .white)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(isFocused ? .black.opacity(0.55) : .white.opacity(0.55))
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            if let trailing, !trailing.isEmpty {
                Text(trailing)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(isFocused ? .black.opacity(0.7) : .white.opacity(0.75))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        Capsule().fill(isFocused ? Color.black.opacity(0.08) : Color.white.opacity(0.12))
                    )
                    .fixedSize()
            }
            if selected {
                Image(systemName: "checkmark")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(isFocused ? .black : .white)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isFocused ? Color.white : Color.white.opacity(0.07))
        )
        .scaleEffect(isFocused ? 1.02 : 1)
        .animation(.easeOut(duration: 0.14), value: isFocused)
    }
}

// MARK: - Episodes

struct PlayerEpisodesPanel: View {
    @ObservedObject var viewModel: PlayerViewModel
    @FocusState private var focusedID: String?

    private var episodes: [NuvioVideo] {
        viewModel.panelEpisodes
    }

    var body: some View {
        PlayerSidePanelChrome(title: "Episodes", onExit: { viewModel.closeSidePanel() }) {
            ScrollView {
                LazyVStack(spacing: 12) {
                    if episodes.isEmpty {
                        Button {} label: {
                            PlayerPanelRow(
                                title: "Episodes unavailable",
                                subtitle: "No episode list for this session.",
                                isFocused: focusedID == "empty"
                            )
                        }
                        .buttonStyle(PosterCardButtonStyle())
                        .focusEffectDisabledIfAvailable()
                        .focused($focusedID, equals: "empty")
                    } else {
                        ForEach(episodes) { episode in
                            let isCurrent = episode.id == viewModel.panelCurrentEpisodeId
                            Button {
                                viewModel.selectEpisode(episode)
                            } label: {
                                episodeRow(episode, isCurrent: isCurrent, isFocused: focusedID == episode.id)
                            }
                            .buttonStyle(PosterCardButtonStyle())
                            .focusEffectDisabledIfAvailable()
                            .focused($focusedID, equals: episode.id)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 12)
            }
            .focusSection()
        }
        .onAppear {
            DispatchQueue.main.async {
                focusedID = viewModel.panelCurrentEpisodeId ?? episodes.first?.id
            }
        }
    }

    private func episodeRow(_ episode: NuvioVideo, isCurrent: Bool, isFocused: Bool) -> some View {
        HStack(spacing: 16) {
            ZStack {
                Color.white.opacity(0.08)
                if let thumb = episode.thumbnail, let url = URL(string: thumb) {
                    AsyncImage(url: url) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Image(systemName: "play.rectangle")
                            .foregroundStyle(.white.opacity(0.35))
                    }
                } else {
                    Image(systemName: "play.rectangle")
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
            .frame(width: 150, height: 84)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text("S\(episode.season) E\(episode.episode)")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(isFocused ? .black.opacity(0.55) : .white.opacity(0.55))
                Text(episode.title)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(isFocused ? .black : .white)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                if isCurrent {
                    Text("Now Playing")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(isFocused ? .black.opacity(0.65) : .white.opacity(0.75))
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 4)
            if isCurrent {
                Image(systemName: "checkmark")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(isFocused ? .black : .white)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(isFocused ? Color.white : Color.white.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(isCurrent && !isFocused ? Color.white.opacity(0.35) : .clear, lineWidth: 2)
        )
        .scaleEffect(isFocused ? 1.02 : 1)
        .animation(.easeOut(duration: 0.14), value: isFocused)
    }
}

// MARK: - Sources

struct PlayerSourcesPanel: View {
    @ObservedObject var viewModel: PlayerViewModel
    @FocusState private var focusedID: String?

    var body: some View {
        PlayerSidePanelChrome(title: "Sources", onExit: { viewModel.closeSidePanel() }) {
            ScrollView {
                LazyVStack(spacing: 12) {
                    if viewModel.isLoadingSources {
                        HStack(spacing: 14) {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .tint(.white)
                            Text("Searching sources…")
                                .font(.system(size: 22, weight: .medium))
                                .foregroundStyle(.white.opacity(0.8))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 12)
                    } else if viewModel.availableSources.isEmpty {
                        Button {} label: {
                            PlayerPanelRow(
                                title: "No sources found",
                                subtitle: "None of your stream add-ons returned a link.",
                                isFocused: focusedID == "empty"
                            )
                        }
                        .buttonStyle(PosterCardButtonStyle())
                        .focusEffectDisabledIfAvailable()
                        .focused($focusedID, equals: "empty")
                    } else {
                        ForEach(viewModel.availableSources, id: \.id) { stream in
                            let selected = viewModel.isCurrentSource(stream)
                            Button {
                                viewModel.selectSource(stream)
                            } label: {
                                PlayerPanelRow(
                                    title: stream.panelTitle,
                                    subtitle: stream.panelSubtitle,
                                    trailing: stream.panelResolutionLabel,
                                    selected: selected,
                                    isFocused: focusedID == stream.id
                                )
                            }
                            .buttonStyle(PosterCardButtonStyle())
                            .focusEffectDisabledIfAvailable()
                            .focused($focusedID, equals: stream.id)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 12)
            }
            .focusSection()
        }
        .onAppear {
            viewModel.loadSourcesIfNeeded()
            requestSourceFocus()
        }
        .onChange(of: viewModel.availableSources.map(\.id)) { sourceIDs in
            guard !sourceIDs.isEmpty,
                  focusedID == nil || !sourceIDs.contains(focusedID ?? "") else {
                return
            }
            requestSourceFocus()
        }
    }

    private func requestSourceFocus() {
        DispatchQueue.main.async {
            if let current = viewModel.availableSources.first(where: { viewModel.isCurrentSource($0) }) {
                focusedID = current.id
            } else {
                focusedID = viewModel.availableSources.first?.id
            }
        }
    }
}

// MARK: - Stream display helpers

private extension NuvioStream {
    var panelTitle: String {
        let raw = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let raw, !raw.isEmpty { return raw }
        if let filename, !filename.isEmpty { return filename }
        return "Stream"
    }

    var panelSubtitle: String {
        var parts: [String] = []
        if let addonName, !addonName.isEmpty { parts.append(addonName) }
        if let description, !description.isEmpty,
           description.caseInsensitiveCompare(panelTitle) != .orderedSame {
            parts.append(description)
        }
        if isDebridResolvable { parts.append("Debrid") }
        return parts.joined(separator: " · ")
    }

    var panelResolutionLabel: String? {
        let blob = [name, description, filename].compactMap { $0 }.joined(separator: " ").lowercased()
        if blob.contains("2160") || blob.contains("4k") || blob.contains("uhd") { return "4K" }
        if blob.contains("1080") { return "1080p" }
        if blob.contains("720") { return "720p" }
        if blob.contains("480") { return "480p" }
        return nil
    }
}
