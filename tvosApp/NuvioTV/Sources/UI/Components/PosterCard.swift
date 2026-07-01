//
//  PosterCard.swift
//  NuvioTV
//
//  Created by Claude Code
//  Reusable poster card component for iOS/tvOS
//

import SwiftUI

/// Poster card component with focus animation (tvOS) and tap handling (iOS)
struct PosterCard: View {
    let meta: NuvioMeta
    var isLandscape: Bool = false
    var continueProgress: Double? = nil
    var continueRemainingText: String? = nil
    var shouldRequestInitialFocus: Bool = false
    var onInitialFocusRequested: (() -> Void)? = nil
    var onFocus: ((NuvioMeta) -> Void)? = nil
    var onBlur: ((NuvioMeta) -> Void)? = nil
    /// Optional shared focus state so a parent can drive `.defaultFocus`
    /// restoration — e.g. returning to the exact card after the menu. Keyed by
    /// `externalFocusValue` (must be unique per card instance, since the same
    /// meta.id can appear in more than one row), falling back to meta.id.
    var externalFocus: FocusState<String?>.Binding? = nil
    var externalFocusValue: String? = nil
    let onClick: () -> Void

    #if os(tvOS)
    @FocusState private var isFocused: Bool
    @State private var didRequestInitialFocus = false
    @AppStorage(SettingsKey.homeLayout) private var homeLayout = "Modern"
    @AppStorage(SettingsKey.posterLabels) private var posterLabels = false
    @AppStorage(SettingsKey.smoothFocus) private var smoothFocus = true
    @AppStorage(SettingsKey.focusHighlighter) private var focusHighlighter = false
    #endif

    var body: some View {
        Button(action: onClick) {
            VStack(alignment: .leading, spacing: 9) {
                AsyncImage(url: URL(string: imageUrl ?? "")) { phase in
                    switch phase {
                    case .empty:
                        placeholderView
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    case .failure:
                        placeholderView
                    @unknown default:
                        placeholderView
                    }
                }
                .frame(width: cardWidth, height: cardHeight)
                .clipShape(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
                .overlay(alignment: .bottomLeading) {
                    if isLandscape {
                        landscapeOverlay
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    continueProgressOverlay
                }
                .overlay(alignment: .topTrailing) {
                    continueBadge
                }
                .overlay(alignment: .topTrailing) {
                    WatchedCheckmarkBadge(metaId: meta.id, type: meta.type)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                        .stroke(focusedBorderColor, lineWidth: focusedBorderWidth)
                )
                .shadow(color: .black.opacity(shadowOpacity), radius: shadowRadius)

                if showsPosterTitle {
                    Text(meta.name)
                        .font(.system(size: homeLayout == "Compact" ? 18 : 20, weight: isFocused ? .semibold : .medium))
                        .foregroundColor(titleColor)
                        .lineLimit(1)
                        .frame(width: cardWidth, alignment: .leading)
                }
            }
            .frame(width: layoutWidth, height: totalCardHeight, alignment: .topLeading)
        }
        .buttonStyle(PosterCardButtonStyle())
        #if os(tvOS)
        .focused($isFocused)
        .modifier(ExternalFocusBinding(binding: externalFocus, id: externalFocusValue ?? meta.id))
        .nuvioFocusEffectDisabledIfAvailable()
        .onChange(of: isFocused) { focused in
            if focused {
                onFocus?(meta)
            } else {
                onBlur?(meta)
            }
        }
        .onAppear {
            guard shouldRequestInitialFocus, !didRequestInitialFocus else {
                return
            }

            didRequestInitialFocus = true
            onInitialFocusRequested?()
            DispatchQueue.main.async {
                isFocused = true
            }
        }
        #endif
        // The row cell takes the full (landscape) width so neighbouring cards
        // are pushed aside rather than overlapped, while the focusable button
        // above stays portrait-width — keeping the focus frame (and thus up/down
        // navigation) aligned to the card directly below.
        .frame(width: cardWidth, height: totalCardHeight, alignment: .topLeading)
        #if os(tvOS)
        .animation(smoothFocus ? .spring(response: 0.28, dampingFraction: 0.86) : nil, value: isLandscape)
        #endif
    }

    // MARK: - Helper Views

    private var placeholderView: some View {
        ZStack {
            Rectangle()
                .fill(Color.white.opacity(0.08))
            Image(systemName: "photo")
                .resizable()
                .scaledToFit()
                .frame(width: 42, height: 42)
                .foregroundColor(.white.opacity(0.38))
        }
    }

    @ViewBuilder
    private var landscapeOverlay: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(
                colors: [.clear, .black.opacity(0.78)],
                startPoint: .center,
                endPoint: .bottom
            )

            if let logoUrl = meta.logoUrl {
                AsyncImage(url: URL(string: logoUrl)) { phase in
                    if case .success(let image) = phase {
                        image
                            .resizable()
                            .scaledToFit()
                    } else {
                        fallbackTitle
                    }
                }
                .frame(width: landscapeLogoWidth, height: landscapeLogoHeight, alignment: .leading)
                .padding(22)
            } else {
                fallbackTitle
                    .frame(maxWidth: cardWidth * 0.62, alignment: .leading)
                    .padding(22)
            }
        }
    }

    private var fallbackTitle: some View {
        Text(meta.name)
            .font(.custom("Inter-Bold", size: 34))
            .foregroundColor(.white)
            .lineLimit(2)
    }

    @ViewBuilder
    private var continueBadge: some View {
        if let continueRemainingText {
            Text(continueRemainingText)
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.black.opacity(0.72))
                )
                .padding(16)
        }
    }

    @ViewBuilder
    private var continueProgressOverlay: some View {
        if let continueProgress {
            let progress = CGFloat(min(max(continueProgress, 0), 1))
            GeometryReader { geo in
                let width = max(0, geo.size.width - 44)

                VStack {
                    Spacer()
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.38))
                            .frame(width: width, height: 8)

                        Capsule()
                            .fill(Color.white)
                            .frame(width: max(8, width * progress), height: 8)
                    }
                    .padding(.leading, 22)
                    .padding(.bottom, 16)
                }
            }
        }
    }

    // MARK: - Computed Properties

    #if os(tvOS)
    private var cardWidth: CGFloat {
        if isLandscape {
            return 560
        }
        return homeLayout == "Compact" ? 170 : 210
    }

    /// Width the card occupies in the row layout — and therefore its focus
    /// frame. Always the portrait width, even while the landscape art is shown,
    /// so a focused landscape card does NOT widen its focus region and bump
    /// vertical navigation onto the neighbouring column. The 560pt landscape art
    /// overflows this frame to the right and is drawn above siblings (zIndex).
    private var layoutWidth: CGFloat {
        homeLayout == "Compact" ? 170 : 210
    }

    private var cardHeight: CGFloat {
        isLandscape ? 315 : (homeLayout == "Compact" ? 255 : 315)
    }

    private var totalCardHeight: CGFloat {
        cardHeight + (showsPosterTitle ? 36 : 0)
    }

    private var landscapeLogoWidth: CGFloat {
        250
    }

    private var landscapeLogoHeight: CGFloat {
        76
    }

    private var cardCornerRadius: CGFloat {
        16
    }

    private var imageUrl: String? {
        isLandscape ? (meta.backgroundUrl ?? meta.posterUrl) : meta.posterUrl
    }

    private var focusedBorderColor: Color {
        guard isFocused else { return .clear }
        return .white.opacity(0.86)
    }

    private var focusedBorderWidth: CGFloat {
        isFocused ? (focusHighlighter ? 5 : 3) : 0
    }

    private var shadowOpacity: Double {
        isFocused ? 0.24 : 0.12
    }

    private var shadowRadius: CGFloat {
        isFocused ? 10 : 4
    }

    private var titleColor: Color {
        isFocused ? .white : .white.opacity(0.55)
    }

    private var showsPosterTitle: Bool {
        posterLabels && !isLandscape
    }
    #else
    private var cardWidth: CGFloat {
        150
    }

    private var layoutWidth: CGFloat {
        150
    }

    private var cardHeight: CGFloat {
        225
    }

    private var cardCornerRadius: CGFloat {
        8
    }

    private var landscapeLogoWidth: CGFloat {
        0
    }

    private var landscapeLogoHeight: CGFloat {
        0
    }

    private var imageUrl: String? {
        meta.posterUrl
    }

    private var focusedBorderColor: Color {
        .clear
    }

    private var focusedBorderWidth: CGFloat {
        0
    }

    private var shadowOpacity: Double {
        0.2
    }

    private var shadowRadius: CGFloat {
        4
    }

    private var titleColor: Color {
        .primary
    }

    private var totalCardHeight: CGFloat {
        cardHeight
    }

    private var showsPosterTitle: Bool {
        false
    }
    #endif
}

struct WatchedCheckmarkBadge: View {
    let metaId: String
    let type: String
    var size: CGFloat = 38

    @State private var isWatched = false

    var body: some View {
        Group {
            if isWatched {
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.48, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: size, height: size)
                    .background(
                        Circle()
                            .fill(Color(red: 0.10, green: 0.68, blue: 0.34))
                    )
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.45), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
                    .padding(12)
            }
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: WatchedStore.changedNotification)) { _ in
            refresh()
        }
    }

    private func refresh() {
        isWatched = WatchedStore.contains(metaId: metaId, type: type)
    }
}

/// Custom button style for poster cards
struct PosterCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            #if os(tvOS)
            .scaleEffect(configuration.isPressed ? 0.985 : 1.0)
            #else
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            #endif
            .animation(.easeInOut(duration: 0.2), value: configuration.isPressed)
    }
}

#if os(tvOS)
private extension View {
    @ViewBuilder
    func nuvioFocusEffectDisabledIfAvailable() -> some View {
        if #available(tvOS 17.0, *) {
            focusEffectDisabled()
        } else {
            self
        }
    }
}

/// Binds a view's focus to a shared `FocusState<String?>` (no-op when nil),
/// so a parent can track/restore which card is focused.
struct ExternalFocusBinding: ViewModifier {
    let binding: FocusState<String?>.Binding?
    let id: String

    func body(content: Content) -> some View {
        if let binding {
            content.focused(binding, equals: id)
        } else {
            content
        }
    }
}

extension View {
    /// `.defaultFocus` guarded for tvOS 17+ (no-op below). Lets a focus scope
    /// restore to a specific value when it regains focus (e.g. from the menu,
    /// or returning to a sidebar's selected item).
    @ViewBuilder
    func defaultFocusIfAvailable<V: Hashable>(_ binding: FocusState<V>.Binding, _ value: V) -> some View {
        if #available(tvOS 17.0, *) {
            self.defaultFocus(binding, value)
        } else {
            self
        }
    }
}
#endif

// MARK: - Preview

#if DEBUG
struct PosterCard_Previews: PreviewProvider {
    static var previews: some View {
        let sampleMeta = NuvioMeta(
            id: "1",
            name: "Sample Movie",
            description: "A sample movie description",
            posterUrl: "https://via.placeholder.com/300x450",
            backgroundUrl: nil,
            logoUrl: nil,
            imdbId: "tt1234567",
            tmdbId: nil,
            type: "movie",
            year: 2024,
            genres: ["Action", "Drama"],
            rating: 8.5,
            releaseInfo: nil,
            runtime: "120 min",
            cast: nil,
            director: nil,
            writer: nil,
            certification: nil,
            country: nil,
            released: nil
        )

        PosterCard(meta: sampleMeta) {
            print("Tapped!")
        }
        .previewLayout(.sizeThatFits)
        .padding()
        .background(Color.black)
    }
}
#endif
