import SwiftUI

struct SceneSongCard: View {
    let song: SceneRecognizedSong
    var isFocused: Bool = false
    let onSelect: () -> Void
    
    @Environment(\.isFocused) private var envFocused: Bool
    
    private var isCardFocused: Bool {
        isFocused || envFocused
    }
    
    init(
        song: SceneRecognizedSong,
        isFocused: Bool = false,
        onSelect: @escaping () -> Void
    ) {
        self.song = song
        self.isFocused = isFocused
        self.onSelect = onSelect
    }
    
    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 20) {
                // Album artwork
                ZStack {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(isCardFocused ? Color.black.opacity(0.08) : Color.white.opacity(0.12))
                        .frame(width: 170, height: 170)
                    
                    if let url = song.artworkURL {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let image):
                                image
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 170, height: 170)
                                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                            case .failure, .empty:
                                musicPlaceholder
                            @unknown default:
                                musicPlaceholder
                            }
                        }
                    } else {
                        musicPlaceholder
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(isCardFocused ? Color.black.opacity(0.12) : Color.white.opacity(0.18), lineWidth: 1)
                )
                
                // Song Title, Artist, & Shazam/Music info
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "music.note")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(isCardFocused ? Color(red: 0.0, green: 0.45, blue: 0.85) : .blue)
                        Text("Music")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(isCardFocused ? Color.black.opacity(0.6) : Color.white.opacity(0.6))
                            .textCase(.uppercase)
                    }
                    
                    Text(song.title)
                        .font(.system(size: 21, weight: .bold))
                        .foregroundColor(isCardFocused ? .black : .white.opacity(0.95))
                        .lineLimit(2)
                    
                    Text(song.artist)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(isCardFocused ? Color.black.opacity(0.75) : Color.white.opacity(0.75))
                        .lineLimit(1)
                    
                    if let desc = song.sceneDescription, !desc.isEmpty {
                        Text(desc)
                            .font(.system(size: 13, weight: .regular))
                            .foregroundColor(isCardFocused ? Color.black.opacity(0.65) : Color.white.opacity(0.65))
                            .lineLimit(1)
                    } else if let genre = song.genres.first, !genre.isEmpty {
                        Text(genre)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(isCardFocused ? Color.black.opacity(0.55) : Color.white.opacity(0.5))
                            .lineLimit(1)
                    }
                }
                
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(width: 480, height: 236)
            .modifier(TvDetailsGlassBackground(filled: isCardFocused, shape: RoundedRectangle(cornerRadius: 32, style: .continuous)))
        }
        .buttonStyle(PosterCardButtonStyle())
        .focusEffectDisabledIfAvailable()
        .scaleEffect(isCardFocused ? 1.05 : 1.0)
        .animation(.easeOut(duration: 0.14), value: isCardFocused)
        .accessibilityLabel("\(song.title), \(song.artist)")
    }
    
    private var musicPlaceholder: some View {
        Image(systemName: "music.quarternote.3")
            .resizable()
            .scaledToFit()
            .frame(width: 54, height: 54)
            .foregroundColor(isCardFocused ? Color.black.opacity(0.35) : Color.white.opacity(0.4))
    }
}
