import SwiftUI

/// Every kind of gesture the remote can do, each card looping through its
/// variants; the focused card lists them all with what each does now. Back closes.
struct PlayerGestureGalleryView: View {
    let bindings: PlayerGestureBindings
    let onClose: () -> Void

    @FocusState private var focused: GestureFamily?
    @State private var shown: GestureFamily = .click

    private static let note = Color(red: 1.0, green: 0.82, blue: 0.55)

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.string("player_gesture_overview", fallback: "Gesture overview"))
                        .font(.system(size: 40, weight: .bold))
                        .foregroundColor(.white)
                    Text(L10n.string("player_gesture_overview_hint", fallback: "Pick a card to see all its variants below and what each does during playback now · Back closes"))
                        .font(.system(size: 21, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))
                }

                VStack(spacing: 18) {
                    row(Array(GestureFamily.shown.prefix(6)), offset: 0)
                    row(Array(GestureFamily.shown.dropFirst(6)), offset: 6)
                }
                .focusSection()

                variants(of: shown)
            }
            .padding(.horizontal, 90)
            .padding(.top, 56)
        }
        .onAppear {
            DispatchQueue.main.async { focused = .click }
        }
        .onChange(of: focused) { _, family in
            if let family { shown = family }
        }
        .onExitCommand(perform: onClose)
        .transition(.opacity)
    }

    private func row(_ families: [GestureFamily], offset: Int) -> some View {
        HStack(spacing: 18) {
            ForEach(Array(families.enumerated()), id: \.element) { index, family in
                card(family, offset: Double(offset + index) * 0.37)
            }
        }
    }

    private func card(_ family: GestureFamily, offset: Double) -> some View {
        let isFocused = focused == family
        return Button {
            shown = family
        } label: {
            VStack(spacing: 8) {
                AnimatedGestureFamilyPad(family: family, offset: offset)
                    .frame(width: 130, height: 130 * RemotePadCanvas.aspect + 28)
                Text(family.title)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)
            }
            .frame(width: 260, height: 250)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.white.opacity(isFocused ? 0.18 : 0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.white.opacity(isFocused ? 0.9 : 0), lineWidth: 3)
            )
            .scaleEffect(isFocused ? 1.04 : 1)
            .animation(.easeOut(duration: 0.15), value: isFocused)
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($focused, equals: family)
        .focusEffectDisabledIfAvailable()
    }

    private func variants(of family: GestureFamily) -> some View {
        let columns = Array(repeating: GridItem(.fixed(560), spacing: 18, alignment: .leading), count: 3)
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
            ForEach(family.variants, id: \.self) { gesture in
                let meaning = PlayerGestureMeaning(of: gesture, in: bindings)
                HStack(spacing: 12) {
                    Text(gesture.title)
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Spacer(minLength: 8)
                    Text(meaning.title)
                        .font(.system(size: 19, weight: .bold))
                        .foregroundColor(color(of: meaning))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .padding(.horizontal, 18)
                .frame(width: 560, height: 46)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.06)))
            }
        }
    }

    private func color(of meaning: PlayerGestureMeaning) -> Color {
        switch meaning {
        case .action: return Self.note
        case .builtIn: return .white.opacity(0.6)
        case .free: return .white.opacity(0.3)
        }
    }
}
