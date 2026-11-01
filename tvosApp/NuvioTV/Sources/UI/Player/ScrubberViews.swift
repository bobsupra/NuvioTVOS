import SwiftUI
import CoreGraphics

// MARK: - Progress track

/// A stretch of the timeline drawn in its own color (the opening, the ending).
struct PlayerTrackSegment: Equatable {
    var start: Double
    var end: Double
    var color: Color
}

extension PlaybackChapters.Kind {
    /// The opening's and the ending's color (Settings → Player; yellow and blue by default):
    /// on the timeline and as the chapter badges.
    var color: Color {
        Color(hex: PlaybackChapters.colorHex(for: self, in: ProfileSettings.current))
    }

    /// The text on a badge of `color`.
    var labelColor: Color {
        PlaybackChapters.prefersDarkText(on: PlaybackChapters.colorHex(for: self, in: ProfileSettings.current))
            ? .black : .white
    }
}

/// Shared transport bar used by the controls timeline, Seek HUD, and Infuse scrub HUD.
///
/// `glassTrack` uses a single frosted bar (material + soft white tint) so it
/// matches the liquid-glass control chrome without `glassEffect`, which draws a
/// second raised pill and reads as a double bar.
///
/// With chapters (or an opening / ending) the bar is cut into pieces with a gap between
/// them, and the piece under the playhead stands about twice as tall as the rest.
struct PlayerProgressTrack: View {
    /// How much taller the piece under the playhead is than the track's height.
    static let currentPieceLift: CGFloat = 4
    /// The gap between two pieces of the track.
    static let pieceGap: CGFloat = 3
    /// The mark of where playback is (`position`).
    static let positionColor = Color(red: 1, green: 0.23, blue: 0.19)

    /// The pieces away from the playhead: two thirds of the track's height (5 of 7, 8 of 12).
    static func otherPieceHeight(for height: CGFloat) -> CGFloat {
        max(3, (height * 2 / 3).rounded())
    }

    var played: Double
    var buffered: Double
    var height: CGFloat = 10
    var showThumb: Bool = false
    var emphasized: Bool = false
    /// When true, the track is a frosted glass bar (one bar, not glassEffect).
    var glassTrack: Bool = false
    /// Chapter starts as fractions of the track: the track is cut into pieces there.
    var markers: [Double] = []
    /// Colored stretches: dimmed ahead of the playhead, full color once played.
    var segments: [PlayerTrackSegment] = []
    /// The played part's white.
    var playedOpacity: Double = 0.65
    /// Where playback is, as a fraction, drawn as a red mark through its piece (while seeking
    /// `played` follows the seek instead). Nil: the played part ends in a white tick.
    var position: Double? = nil

    @State private var animatedBuffered: Double = 0

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let p = CGFloat(min(max(played, 0), 1))
            let b = CGFloat(min(max(animatedBuffered, 0), 1))
            let h = emphasized ? height + 2 : height
            let pieces = PlaybackChapters.timelinePieces(
                markers: markers,
                segments: segments.map { (start: $0.start, end: $0.end) }
            )
            let current = PlaybackChapters.pieceIndex(at: Double(p), in: pieces)
            // The layers are drawn at the lifted piece's height; the pieces cut them to shape.
            let full = pieces.isEmpty ? h : h + Self.currentPieceLift
            let other = pieces.isEmpty ? h : Self.otherPieceHeight(for: h)

            ZStack(alignment: .leading) {
                // Single track layer (fills + mask = one bar, not glassEffect).
                ZStack(alignment: .leading) {
                    if glassTrack {
                        Rectangle()
                            .fill(.ultraThinMaterial)
                            .overlay(
                                Rectangle().fill(Color.white.opacity(emphasized ? 0.28 : 0.14))
                            )
                    } else {
                        Rectangle()
                            .fill(Color.white.opacity(emphasized ? 0.28 : 0.18))
                    }

                    if b > p {
                        Rectangle()
                            .fill(Color.white.opacity(glassTrack ? 0.22 : 0.35))
                            .frame(width: w * b)
                    }

                    ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                        let start = CGFloat(min(max(segment.start, 0), 1))
                        let end = CGFloat(min(max(segment.end, 0), 1))
                        if end > start {
                            Rectangle()
                                .fill(segment.color.opacity(0.8))
                                .frame(width: w * (end - start), height: full)
                                .position(x: w * (start + end) / 2, y: full / 2)
                        }
                    }

                    if p > 0 {
                        // Played progress bar (semi-opaque grey)
                        Rectangle()
                            .fill(Color.white.opacity(playedOpacity))
                            .frame(width: w * p)

                        ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                            let start = CGFloat(min(max(segment.start, 0), 1))
                            let end = min(CGFloat(min(max(segment.end, 0), 1)), p)
                            if end > start {
                                Rectangle()
                                    .fill(segment.color)
                                    .frame(width: w * (end - start), height: full)
                                    .position(x: w * (start + end) / 2, y: full / 2)
                            }
                        }

                        if position == nil {
                            // Leading edge tick: bright white cap flush with the track height
                            Rectangle()
                                .fill(Color.white)
                                .frame(width: 2, height: full)
                                .position(x: min(max(w * p - 1, 1), w - 1), y: full / 2)
                        }
                    }
                }
                .frame(height: full)
                .frame(maxWidth: .infinity, alignment: .leading)
                .mask(alignment: .leading) {
                    trackShape(pieces: pieces, current: current, width: w, height: other, full: full)
                }
                .overlay(alignment: .topLeading) {
                    if let position {
                        // Red mark of where playback is: through its piece and a little past it,
                        // with a dark edge against the white and the opening / ending colors.
                        let x = CGFloat(min(max(position, 0), 1))
                        let index = PlaybackChapters.pieceIndex(at: Double(x), in: pieces)
                        let markHeight = (pieces.isEmpty || index == current ? full : other) + 6
                        ZStack {
                            Rectangle()
                                .fill(Color.black.opacity(0.8))
                                .frame(width: 7, height: markHeight + 3)
                            Rectangle()
                                .fill(Self.positionColor)
                                .frame(width: 4, height: markHeight)
                        }
                        .position(x: min(max(w * x, 3.5), w - 3.5), y: full / 2)
                        .animation(.easeOut(duration: 0.2), value: markHeight)
                    }
                }

                if showThumb {
                    Circle()
                        .fill(Color.white)
                        .frame(width: emphasized ? 22 : 16, height: emphasized ? 22 : 16)
                        .shadow(color: .black.opacity(0.45), radius: 4)
                        .offset(x: min(max(w * p - (emphasized ? 11 : 8), 0), w - (emphasized ? 22 : 16)))
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(height: emphasized ? height + 6 : height + 4)
        .animation(.easeOut(duration: 0.16), value: emphasized)
        .onAppear {
            animatedBuffered = buffered
        }
        .onChange(of: buffered) { _, newBuffered in
            updateAnimatedBuffered(to: newBuffered)
        }
    }

    /// The track's outline: one bar, or the pieces side by side with a gap between them,
    /// the one under the playhead `full` tall and the others `height`.
    @ViewBuilder
    private func trackShape(
        pieces: [PlaybackChapters.TimelinePiece],
        current: Int?,
        width w: CGFloat,
        height h: CGFloat,
        full: CGFloat
    ) -> some View {
        if pieces.isEmpty {
            Rectangle()
        } else {
            ZStack(alignment: .topLeading) {
                ForEach(Array(pieces.enumerated()), id: \.offset) { index, piece in
                    let lead = index > 0 ? Self.pieceGap / 2 : 0
                    let trail = index < pieces.count - 1 ? Self.pieceGap / 2 : 0
                    let x0 = w * CGFloat(piece.start) + lead
                    let x1 = w * CGFloat(piece.end) - trail
                    Rectangle()
                        .frame(width: max(0, x1 - x0), height: index == current ? full : h)
                        .position(x: (x0 + x1) / 2, y: full / 2)
                }
            }
            .frame(width: w, height: full, alignment: .topLeading)
            .animation(.easeOut(duration: 0.2), value: current)
        }
    }

    private func updateAnimatedBuffered(to target: Double) {
        // If buffer reset or jumped backwards (e.g. seek / track reload), snap without animation
        if target < animatedBuffered || animatedBuffered == 0 {
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) {
                animatedBuffered = target
            }
        } else {
            // Smoothly interpolate forward from current presentation position to new target
            withAnimation(.easeOut(duration: 0.45)) {
                animatedBuffered = target
            }
        }
    }
}

// MARK: - Time helpers

enum PlayerTimeFormat {
    static func clock(_ seconds: Double) -> String {
        PlayerTime.formatted(time: max(seconds, 0))
    }

    static func signedDelta(_ seconds: Double) -> String {
        let sign = seconds >= 0 ? "+" : "−"
        return "\(sign)\(clock(abs(seconds)))"
    }
}

enum WatchClock {
    static func started(position: Double) -> String {
        format(Date().addingTimeInterval(-position))
    }

    static func ends(position: Double, duration: Double) -> String {
        format(Date().addingTimeInterval(max(duration - position, 0)))
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    private static func format(_ date: Date) -> String {
        formatter.string(from: date)
    }
}

// MARK: - Quick-seek HUD (D-pad accumulation)

/// Shown while left/right skips accumulate over bare video before the seek commits.
struct SeekHUD: View {
    @ObservedObject var clock: PlaybackClock
    let delta: Double
    var thumbnail: CGImage?
    var naturalSize: CGSize = CGSize(width: 16, height: 9)
    var speedMultiplier: Int? = nil

    private var position: Double { clock.position }
    private var duration: Double { clock.duration }
    private var buffered: Double { clock.buffered }
    private var target: Double {
        min(max(position + delta, 0), max(duration, 0))
    }

    var body: some View {
        VStack {
            Spacer()
            VStack(spacing: 22) {
                if let thumbnail {
                    SeekPreviewCard(image: thumbnail, naturalSize: naturalSize)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }

                HStack(spacing: 16) {
                    Image(systemName: delta >= 0 ? "forward.fill" : "backward.fill")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(.white.opacity(0.9))
                    if let speedMultiplier {
                        Text("\(speedMultiplier)x")
                            .font(.system(size: 26, weight: .bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                            .background(.ultraThinMaterial, in: Capsule())
                            .overlay(
                                Capsule().strokeBorder(Color.white.opacity(0.24), lineWidth: 1)
                            )
                    }
                    Text(PlayerTimeFormat.signedDelta(delta))
                        .font(.system(size: 44, weight: .heavy).monospacedDigit())
                        .foregroundStyle(.white)
                }

                PlayerProgressTrack(
                    played: duration > 0 ? target / duration : 0,
                    buffered: duration > 0 ? buffered / duration : 0,
                    height: 10,
                    showThumb: false,
                    emphasized: true
                )
                .frame(height: 14)

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(PlayerTimeFormat.clock(target))
                            .font(.system(size: 26, weight: .bold).monospacedDigit())
                            .foregroundStyle(.white)
                        Text(L10n.string("player_time_elapsed", fallback: "elapsed"))
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    Spacer()
                    Text(PlayerTimeFormat.clock(duration))
                        .font(.system(size: 22, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.5))
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("-\(PlayerTimeFormat.clock(max(duration - target, 0)))")
                            .font(.system(size: 26, weight: .bold).monospacedDigit())
                            .foregroundStyle(.white)
                        Text(L10n.string("player_time_remaining", fallback: "remaining"))
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
            }
            .padding(.horizontal, 60)
            .padding(.bottom, 54)
            .background(
                LinearGradient(colors: [.clear, .black.opacity(0.88)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 560)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .ignoresSafeArea()
            )
            .animation(.easeOut(duration: 0.18), value: thumbnail != nil)
        }
        .allowsHitTesting(false)
    }
}

/// Shared still card used by seek HUDs. Its radius follows the
/// same profile setting as poster and episode cards, and adapts to the
/// stream's natural aspect ratio within standard bounds.
struct SeekPreviewCard: View {
    let image: CGImage?
    var width: CGFloat = 480
    var naturalSize: CGSize = CGSize(width: 16, height: 9)
    /// The still belongs to a passed position while the target's own is on its way: dimmed, so
    /// it does not read as the preview of where the remote rests.
    var isStale: Bool = false

    @AppStorage(SettingsKey.cardCornerRadius) private var cardCornerRadiusSetting = AppCardStyle.defaultCornerRadiusRaw

    private var cardSize: CGSize {
        AppCardStyle.seekCardSize(for: naturalSize, maxWidth: width, maxHeight: width * 9 / 16)
    }

    private var cornerRadius: CGFloat {
        AppCardStyle.cornerRadius(for: cardCornerRadiusSetting, fallback: 16)
    }

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1, orientation: .up)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: cardSize.width, height: cardSize.height)
                    .clipped()
                    .blur(radius: isStale ? 8 : 0)
                    .opacity(isStale ? 0.35 : 1)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)
                    ProgressView()
                        .tint(.white.opacity(0.8))
                }
                .frame(width: cardSize.width, height: cardSize.height)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 10, x: 0, y: 4)
    }
}

// MARK: - Infuse-style scrub HUD

/// Full scrub overlay. Observes `PlaybackClock` so high-frequency scrub updates
/// re-render only this bar — not the whole player stack.
struct InfuseScrubHUD: View {
    @ObservedObject var clock: PlaybackClock
    let title: String
    var episodeLine: String?
    var thumbnail: CGImage?
    var naturalSize: CGSize = CGSize(width: 16, height: 9)
    var wheelEngaged: Bool = false
    var showThumbnailCard: Bool = true

    private var target: Double { clock.scrubTarget ?? clock.position }
    private var current: Double { clock.position }
    private var duration: Double { max(clock.duration, 1) }
    private var buffered: Double { clock.buffered }
    private var fraction: CGFloat { CGFloat(min(max(target / duration, 0), 1)) }

    var body: some View {
        VStack {
            Spacer()
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if let episodeLine, !episodeLine.isEmpty {
                        Text(episodeLine)
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1)
                    }
                }

                GeometryReader { geo in
                    let w = geo.size.width
                    let x = min(max(w * fraction, 120), w - 120)
                    let previewWidth = min(CGFloat(480), max(CGFloat(1), w - 32))
                    let previewHeight = previewWidth * 9 / 16
                    let cardSize = AppCardStyle.seekCardSize(
                        for: naturalSize,
                        maxWidth: previewWidth,
                        maxHeight: previewHeight
                    )
                    let previewX = min(
                        max(w * fraction, cardSize.width / 2 + 16),
                        w - cardSize.width / 2 - 16
                    )
                    ZStack(alignment: .topLeading) {
                        if showThumbnailCard {
                            SeekPreviewCard(
                                image: thumbnail,
                                width: previewWidth,
                                naturalSize: naturalSize
                            )
                            .offset(x: previewX - cardSize.width / 2, y: previewHeight - cardSize.height)
                        }

                        PlayerProgressTrack(
                            played: target / duration,
                            buffered: buffered / duration,
                            height: 10,
                            showThumb: false,
                            emphasized: true
                        )
                        .frame(height: 14)
                        .offset(y: previewHeight + 54)

                        // Ghost tick: live playback position while scrubbing.
                        Rectangle()
                            .fill(Color.white.opacity(0.45))
                            .frame(width: 3, height: 22)
                            .offset(
                                x: w * CGFloat(min(max(current / duration, 0), 1)) - 1.5,
                                y: previewHeight + 50
                            )

                        Text(PlayerTimeFormat.clock(target))
                            .font(.system(size: 26, weight: .bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: Capsule())
                            .frame(width: 200, alignment: .center)
                            .offset(x: x - 100, y: previewHeight)
                    }
                }
                .frame(height: 90 + 270)

                HStack {
                    Text(PlayerTimeFormat.clock(target))
                        .font(.system(size: 22, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                    Text(PlayerTimeFormat.signedDelta(target - current))
                        .font(.system(size: 20, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.75))
                    Spacer()
                    if wheelEngaged {
                        Label(L10n.string("player_seek_fine_tuning", fallback: "Fine-tuning"), systemImage: "arrow.triangle.2.circlepath")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))
                    } else {
                        Label(L10n.string("player_seek_click_to_seek", fallback: "Click to seek"), systemImage: "hand.tap")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    Spacer()
                    Text(PlayerTimeFormat.clock(duration))
                        .font(.system(size: 22, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
            .padding(.horizontal, 60)
            .padding(.bottom, 54)
            .background(
                LinearGradient(colors: [.clear, .black.opacity(0.9)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 420)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .ignoresSafeArea()
            )
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Peek bar (light touch)

/// Minimal timeline on a light touchpad contact. A click while visible opens scrub.
struct PeekBar: View {
    @ObservedObject var clock: PlaybackClock

    var body: some View {
        VStack {
            Spacer()
            VStack(spacing: 12) {
                PlayerProgressTrack(
                    played: clock.duration > 0 ? min(clock.position / clock.duration, 1) : 0,
                    buffered: clock.duration > 0 ? min(clock.buffered / clock.duration, 1) : 0,
                    height: 8,
                    showThumb: false,
                    emphasized: false
                )
                HStack {
                    endpointLabel(
                        "Started",
                        WatchClock.started(position: clock.position),
                        sub: PlayerTimeFormat.clock(clock.position)
                    )
                    Spacer()
                    Text(PlayerTimeFormat.clock(clock.position))
                        .font(.system(size: 24, weight: .bold).monospacedDigit())
                        .foregroundStyle(.white)
                    Spacer()
                    endpointLabel(
                        "Ends",
                        WatchClock.ends(position: clock.position, duration: clock.duration),
                        sub: "-\(PlayerTimeFormat.clock(max(clock.duration - clock.position, 0)))",
                        trailing: true
                    )
                }
            }
            .padding(.horizontal, 60)
            .padding(.bottom, 54)
            .background(
                LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 280)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .ignoresSafeArea()
            )
        }
        .allowsHitTesting(false)
    }

    private func endpointLabel(
        _ caption: String,
        _ time: String,
        sub: String,
        trailing: Bool = false
    ) -> some View {
        VStack(alignment: trailing ? .trailing : .leading, spacing: 1) {
            Text(caption.uppercased())
                .font(.system(size: 13, weight: .bold))
                .kerning(1)
                .foregroundStyle(.white.opacity(0.45))
            Text(time)
                .font(.system(size: 22, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.9))
            Text(sub)
                .font(.system(size: 16, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.5))
        }
    }
}
