//
//  PlayerLoadingOverlay.swift
//  NuvioTV
//
//  Cinematic loading overlay displaying backdrop, logo / title, and loading status.
//

import SwiftUI

struct PlayerLoadingOverlay: View {
    let backdropUrl: String?
    let logoUrl: String?
    let title: String?
    var message: String = L10n.string("player_status_starting_stream", fallback: "Starting stream")

    @State private var isPulsing = false
    @State private var logoLoadFailed = false

    var body: some View {
        ZStack {
            // 1. Solid Black Base
            Color.black.ignoresSafeArea()

            // 2. Fullscreen Backdrop Image
            if let backdrop = backdropUrl, let url = URL(string: backdrop) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .ignoresSafeArea()
                    default:
                        Color.clear
                    }
                }
            }

            // 3. Cinematic Vignette Gradient Overlays (matching Android TV)
            LinearGradient(
                stops: [
                    .init(color: Color.black.opacity(0.30), location: 0.0),
                    .init(color: Color.black.opacity(0.60), location: 0.35),
                    .init(color: Color.black.opacity(0.80), location: 0.70),
                    .init(color: Color.black.opacity(0.90), location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            RadialGradient(
                gradient: Gradient(colors: [
                    Color.black.opacity(0.15),
                    Color.black.opacity(0.75)
                ]),
                center: .center,
                startRadius: 200,
                endRadius: 900
            )
            .ignoresSafeArea()

            // 4. Center Logo / Title + Status Text
            VStack(spacing: 24) {
                if let logo = logoUrl, !logo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !logoLoadFailed, let url = URL(string: logo) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: 440, maxHeight: 180)
                        case .failure:
                            fallbackTitleView
                                .onAppear { logoLoadFailed = true }
                        default:
                            fallbackTitleView
                        }
                    }
                    .scaleEffect(isPulsing ? 1.04 : 1.0)
                    .animation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true), value: isPulsing)
                } else {
                    fallbackTitleView
                        .scaleEffect(isPulsing ? 1.04 : 1.0)
                        .animation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true), value: isPulsing)
                }

                if !message.isEmpty {
                    Text(message)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundColor(Color.white.opacity(0.72))
                        .shadow(color: .black.opacity(0.6), radius: 8, y: 2)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .padding(.horizontal, 80)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .onAppear {
            isPulsing = true
        }
    }

    @ViewBuilder
    private var fallbackTitleView: some View {
        if let title, !title.isEmpty {
            Text(title)
                .font(.system(size: 44, weight: .bold))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .shadow(color: .black.opacity(0.8), radius: 12, y: 4)
        }
    }
}
