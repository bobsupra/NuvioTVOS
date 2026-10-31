import SwiftUI

struct SceneDetailView: View {
    let item: SceneDetailItem
    let onDismiss: () -> Void
    
    @FocusState private var focusedCardID: String?
    @FocusState private var placeholderFocused: Bool
    @FocusState private var focusedButton: DetailButtonFocus?
    
    private enum DetailButtonFocus: Hashable {
        case primary
        case dismiss
    }
    
    init(item: SceneDetailItem, onDismiss: @escaping () -> Void) {
        self.item = item
        self.onDismiss = onDismiss
    }
    
    var body: some View {
        ZStack(alignment: .top) {
            // Translucent see-through backdrop over video
            Color.black.opacity(0.85)
                .ignoresSafeArea()
                .onTapGesture {
                    onDismiss()
                }
            
            switch item {
            case .actor(let actor, let detail):
                actorDetailView(actor: actor, detail: detail)
            case .song(let song):
                songDetailView(song: song)
            }
        }
        .ignoresSafeArea(edges: .top)
        .onExitCommand {
            onDismiss()
        }
    }
    
    // MARK: - Actor Detail Layout
    
    private func rails(for detail: ScenePersonDetail?) -> [TmdbNetworkBrowseRail] {
        guard let detail else { return [] }
        var list: [TmdbNetworkBrowseRail] = []
        if !detail.movies.isEmpty {
            list.append(
                TmdbNetworkBrowseRail(
                    id: "movies",
                    title: L10n.format("details_movies_count", fallback: "Movies • %d", detail.movies.count),
                    items: detail.movies.map(\.asRelatedTitle)
                )
            )
        }
        if !detail.series.isEmpty {
            list.append(
                TmdbNetworkBrowseRail(
                    id: "series",
                    title: L10n.format("details_series_count", fallback: "Series • %d", detail.series.count),
                    items: detail.series.map(\.asRelatedTitle)
                )
            )
        }
        return list
    }
    
    @ViewBuilder
    private func actorDetailView(actor: SceneRecognizedActor, detail: ScenePersonDetail?) -> some View {
        let personRails = rails(for: detail)
        
        ZStack(alignment: .topLeading) {
            ScrollView {
                VStack(alignment: .leading, spacing: 34) {
                    // Hero: Category + Name + Birth/Origin metadata + Bio + Portrait Card
                    actorHero(actor: actor, detail: detail)
                    
                    // Filmography Rails: Movies & Series
                    if let detail {
                        if personRails.isEmpty {
                            Text(L10n.format("details_no_titles_found_for_person", fallback: "No movies or series found for %@", detail.name))
                                .font(.system(size: 30, weight: .medium))
                                .foregroundColor(.white.opacity(0.7))
                                .frame(maxWidth: .infinity, minHeight: 260)
                        } else {
                            ForEach(personRails) { rail in
                                NetworkBrowseRail(rail: rail, externalFocus: $focusedCardID, onSelect: { _ in })
                            }
                        }
                    } else if actor.tmdbId != nil {
                        ProgressView()
                            .scaleEffect(1.6)
                            .frame(maxWidth: .infinity, minHeight: 260)
                    }
                }
                .padding(.bottom, 70)
            }
            .focusSection()
            .coordinateSpace(name: "insight-actor-scroll")
            
            if detail == nil || personRails.isEmpty {
                placeholderFocusAnchor
            }
        }
        .defaultFocusIfAvailable($focusedCardID, personRails.first?.items.first?.id)
        .onChange(of: personRails.first?.items.first?.id) { _, newFirstID in
            if focusedCardID == nil, let newFirstID {
                focusedCardID = newFirstID
            }
        }
        .onAppear {
            if focusedCardID == nil, let firstID = personRails.first?.items.first?.id {
                focusedCardID = firstID
            }
        }
    }
    
    @ViewBuilder
    private func actorHero(actor: SceneRecognizedActor, detail: ScenePersonDetail?) -> some View {
        HStack(alignment: .bottom, spacing: 50) {
            VStack(alignment: .leading, spacing: 12) {
                Text(categoryLabel(actor: actor))
                    .font(.system(size: 32, weight: .medium))
                    .foregroundColor(.white.opacity(0.72))
                
                Text(detail?.name ?? actor.name)
                    .font(.system(size: 64, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(2)
                
                let metaParts = [
                    detail?.birthInfo,
                    detail?.placeOfBirth
                ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                
                if !metaParts.isEmpty {
                    Text(metaParts.joined(separator: " • "))
                        .font(.system(size: 26, weight: .regular))
                        .foregroundColor(.white.opacity(0.68))
                        .lineLimit(2)
                }
                
                if let bio = detail?.biography, !bio.isEmpty {
                    Text(bio)
                        .font(.system(size: 20, weight: .regular))
                        .foregroundColor(.white.opacity(0.82))
                        .lineSpacing(4)
                        .lineLimit(4)
                        .padding(.top, 4)
                }
            }
            
            Spacer(minLength: 20)
            
            // Right-side portrait card matching streaming service template collection
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 200, height: 280)
                
                let profileURL = detail?.profileURL ?? actor.profileURL
                if let profileURL {
                    AsyncImage(url: profileURL) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFill()
                                .frame(width: 200, height: 280)
                                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                        case .failure, .empty:
                            actorPlaceholderAvatar
                        @unknown default:
                            actorPlaceholderAvatar
                        }
                    }
                } else {
                    actorPlaceholderAvatar
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 1.5)
            )
        }
        .padding(.horizontal, 80)
        .padding(.top, 72)
        .frame(maxWidth: .infinity, minHeight: 390, alignment: .bottom)
    }
    
    private func categoryLabel(actor: SceneRecognizedActor) -> String {
        if let char = actor.character, !char.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "as \(char)"
        }
        return "Actor"
    }
    
    private var actorPlaceholderAvatar: some View {
        Image(systemName: "person.fill")
            .resizable()
            .scaledToFit()
            .frame(width: 80, height: 80)
            .foregroundColor(.white.opacity(0.35))
    }
    
    private var placeholderFocusAnchor: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .focusable(true)
            .focused($placeholderFocused)
            .focusEffectDisabledIfAvailable()
            .onAppear {
                DispatchQueue.main.async { placeholderFocused = true }
            }
    }
    
    // MARK: - Song Detail Layout
    
    @ViewBuilder
    private func songDetailView(song: SceneRecognizedSong) -> some View {
        VStack {
            Spacer()
            VStack(spacing: 24) {
                songDetailContent(song: song)
            }
            .padding(40)
            .frame(maxWidth: 880)
            .background {
                if #available(tvOS 26.0, *) {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(Color.black.opacity(0.28))
                        .background(Color.white.opacity(0.08), in: .rect(cornerRadius: 28))
                        .glassEffect(.regular, in: .rect(cornerRadius: 28))
                } else {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(Color.black.opacity(0.40))
                        .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(.ultraThinMaterial))
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 1.5)
            )
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .defaultFocus($focusedButton, .dismiss)
    }
    
    @ViewBuilder
    private func songDetailContent(song: SceneRecognizedSong) -> some View {
        HStack(alignment: .top, spacing: 32) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(0.1))
                    .frame(width: 180, height: 180)
                
                if let url = song.artworkURL {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image
                                .resizable()
                                .scaledToFill()
                                .frame(width: 180, height: 180)
                                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        } else {
                            Image(systemName: "music.note")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 80, height: 80)
                                .foregroundColor(.white.opacity(0.4))
                        }
                    }
                } else {
                    Image(systemName: "music.note")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 80, height: 80)
                        .foregroundColor(.white.opacity(0.4))
                }
            }
            
            VStack(alignment: .leading, spacing: 10) {
                Text(song.title)
                    .font(.system(size: 34, weight: .bold))
                    .foregroundColor(.white)
                
                Text(song.artist)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundColor(.white.opacity(0.75))
                
                if let desc = song.sceneDescription, !desc.isEmpty {
                    Text(desc)
                        .font(.system(size: 19, weight: .regular))
                        .foregroundColor(.white.opacity(0.85))
                        .lineLimit(3)
                        .padding(.top, 2)
                } else if let genre = song.genres.first {
                    Text(genre)
                        .font(.system(size: 19, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))
                }
                
                Spacer()
                
                HStack(spacing: 16) {
                    if let appleMusicURL = song.appleMusicURL {
                        Button(action: {
                            UIApplication.shared.open(appleMusicURL)
                        }) {
                            HStack(spacing: 8) {
                                Image(systemName: "applelogo")
                                Text("Open in Music")
                            }
                            .font(.system(size: 20, weight: .semibold))
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                        }
                        .buttonStyle(PosterCardButtonStyle())
                        .focused($focusedButton, equals: .primary)
                        .onExitCommand(perform: onDismiss)
                    }
                    
                    Button(action: onDismiss) {
                        Text("Done")
                            .font(.system(size: 20, weight: .semibold))
                            .frame(minWidth: 140)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(PosterCardButtonStyle())
                    .focused($focusedButton, equals: .dismiss)
                    .onExitCommand(perform: onDismiss)
                }
            }
        }
        .frame(minHeight: 240)
    }
}
