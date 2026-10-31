import SwiftUI

struct SceneActorCard: View {
    let actor: SceneRecognizedActor
    let isLiveRecognized: Bool
    var isFocused: Bool = false
    let onSelect: () -> Void
    
    @Environment(\.isFocused) private var envFocused: Bool
    
    private var isCardFocused: Bool {
        isFocused || envFocused
    }
    
    init(
        actor: SceneRecognizedActor,
        isLiveRecognized: Bool = false,
        isFocused: Bool = false,
        onSelect: @escaping () -> Void
    ) {
        self.actor = actor
        self.isLiveRecognized = isLiveRecognized
        self.isFocused = isFocused
        self.onSelect = onSelect
    }
    
    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 14) {
                Spacer(minLength: 0)
                
                // Circular portrait with optional active glowing ring
                ZStack {
                    Circle()
                        .fill(isCardFocused ? Color.black.opacity(0.08) : Color.white.opacity(0.12))
                        .frame(width: 92, height: 92)
                    
                    if let url = actor.profileURL {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let image):
                                image
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 92, height: 92)
                                    .clipShape(Circle())
                            case .failure, .empty:
                                placeholderAvatar
                            @unknown default:
                                placeholderAvatar
                            }
                        }
                    } else {
                        placeholderAvatar
                    }
                }
                .overlay(
                    Circle()
                        .stroke(
                            isCardFocused ? Color.black.opacity(0.12) : Color.white.opacity(0.18),
                            lineWidth: 1
                        )
                )
                
                // Name & Character labels
                VStack(spacing: 4) {
                    Text(actor.name)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(isCardFocused ? .black : .white)
                        .lineLimit(1)
                        .multilineTextAlignment(.center)
                    
                    if let character = actor.character, !character.isEmpty {
                        Text(character)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(isCardFocused ? Color.black.opacity(0.7) : Color.white.opacity(0.72))
                            .lineLimit(1)
                            .multilineTextAlignment(.center)
                    } else {
                        Text(" ")
                            .font(.system(size: 15, weight: .medium))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity)
                
                Spacer(minLength: 0)
            }
            .padding(.vertical, 16)
            .padding(.horizontal, 12)
            .frame(width: 184, height: 256)
            .modifier(TvDetailsGlassBackground(filled: isCardFocused, shape: RoundedRectangle(cornerRadius: 32, style: .continuous)))
        }
        .buttonStyle(PosterCardButtonStyle())
        .focusEffectDisabledIfAvailable()
        .scaleEffect(isCardFocused ? 1.05 : 1.0)
        .animation(.easeOut(duration: 0.14), value: isCardFocused)
        .accessibilityLabel("\(actor.name), \(actor.character ?? "")")
    }
    
    private var placeholderAvatar: some View {
        Image(systemName: "person.fill")
            .resizable()
            .scaledToFit()
            .frame(width: 44, height: 44)
            .foregroundColor(isCardFocused ? Color.black.opacity(0.35) : Color.white.opacity(0.4))
    }
}
