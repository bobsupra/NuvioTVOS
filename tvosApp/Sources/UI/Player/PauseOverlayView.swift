import SwiftUI
import Combine

/// Metadata sheet shown while paused — logo/title, episode line, synopsis,
/// cast chips, and a wall-clock in the corner. Video stays visible underneath.
struct PauseOverlayView: View {
    let title: String
    let episodeLine: String?
    let year: Int?
    let description: String?
    let cast: [String]
    let logoURL: URL?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            gradients

            PauseClock()
                .padding(.top, 50)
                .padding(.trailing, 60)

            VStack(alignment: .leading, spacing: 14) {
                Spacer()

                Text("YOU'RE WATCHING")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                    .kerning(2)

                if let logoURL {
                    AsyncImage(url: logoURL) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: 440, maxHeight: 120, alignment: .bottomLeading)
                        default:
                            titleText
                        }
                    }
                } else {
                    titleText
                }

                metaLine

                if let episodeLine, !episodeLine.isEmpty {
                    Text(episodeLine)
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                }

                if let description, !description.isEmpty {
                    Text(description)
                        .font(.system(size: 24))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(3)
                        .frame(maxWidth: 950, alignment: .leading)
                        .padding(.top, 4)
                }

                if !cast.isEmpty {
                    Text("CAST")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.45))
                        .kerning(2)
                        .padding(.top, 18)

                    HStack(spacing: 12) {
                        ForEach(cast.prefix(6), id: \.self) { member in
                            Text(member)
                                .font(.system(size: 20, weight: .medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 18)
                                .padding(.vertical, 10)
                                .background(
                                    Color.white.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                                )
                        }
                    }
                }
            }
            .padding(.horizontal, 60)
            .padding(.bottom, 100)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .allowsHitTesting(false)
    }

    private var titleText: some View {
        Text(title)
            .font(.system(size: 52, weight: .heavy))
            .foregroundStyle(.white)
            .lineLimit(2)
    }

    @ViewBuilder
    private var metaLine: some View {
        let parts = [year.map(String.init), episodeCode].compactMap { $0 }.filter { !$0.isEmpty }
        if !parts.isEmpty {
            Text(parts.joined(separator: "  •  "))
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    /// "S1 · E3 · Title" → "S1E3" for the year line when possible.
    private var episodeCode: String? {
        guard let episodeLine, !episodeLine.isEmpty else { return nil }
        // Prefer S/E from a "S1 · E2 · Name" subtitle; otherwise omit here
        // (full episode line is shown below).
        if let numbers = EpisodeTagResolver.episodeNumbers(in: episodeLine) {
            return "S\(numbers.season)E\(numbers.episode)"
        }
        return nil
    }

    private var gradients: some View {
        ZStack {
            LinearGradient(
                colors: [.black.opacity(0.88), .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            Color.black.opacity(0.32)
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.55), location: 0),
                    .init(color: .black.opacity(0.35), location: 0.35),
                    .init(color: .black.opacity(0.15), location: 0.65),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }
}

private struct PauseClock: View {
    @State private var now = Date()
    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        Text(now, style: .time)
            .font(.system(size: 40, weight: .regular))
            .foregroundStyle(.white.opacity(0.95))
            .onReceive(timer) { now = $0 }
    }
}
