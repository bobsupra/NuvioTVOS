import SwiftUI

// MARK: - Progress track

/// Shared transport bar used by the controls timeline, Seek HUD, and Infuse scrub HUD.
///
/// `glassTrack` uses a single frosted capsule (material + soft white tint) so it
/// matches the liquid-glass control chrome without `glassEffect`, which draws a
/// second raised pill and reads as a double bar.
struct PlayerProgressTrack: View {
    var played: Double
    var buffered: Double
    var height: CGFloat = 10
    var showThumb: Bool = true
    var emphasized: Bool = false
    /// When true, the track is a frosted glass capsule (one bar, not glassEffect).
    var glassTrack: Bool = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let p = CGFloat(min(max(played, 0), 1))
            let b = CGFloat(min(max(buffered, 0), 1))
            let h = emphasized ? height + 2 : height
            let thumbSize: CGFloat = emphasized ? 22 : 16

            ZStack(alignment: .leading) {
                // Single track layer (fills + clip = one bar, not glassEffect).
                ZStack(alignment: .leading) {
                    if glassTrack {
                        Capsule()
                            .fill(.ultraThinMaterial)
                            .overlay(
                                Capsule().fill(Color.white.opacity(emphasized ? 0.28 : 0.14))
                            )
                    } else {
                        Capsule()
                            .fill(Color.white.opacity(emphasized ? 0.28 : 0.18))
                    }

                    if b > p {
                        Capsule()
                            .fill(Color.white.opacity(glassTrack ? 0.22 : 0.42))
                            .frame(width: w * b)
                    }

                    Capsule()
                        .fill(Color.white.opacity(0.95))
                        .frame(width: max(w * p, h))
                        .shadow(
                            color: .white.opacity(emphasized ? 0.75 : 0.4),
                            radius: emphasized ? 5 : 2
                        )
                }
                .frame(height: h)
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipShape(Capsule())

                if showThumb {
                    Circle()
                        .fill(Color.white)
                        .frame(width: thumbSize, height: thumbSize)
                        .shadow(color: .black.opacity(0.45), radius: 4)
                        .offset(x: min(max(w * p - thumbSize / 2, 0), w - thumbSize))
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(height: emphasized ? height + 6 : height + 4)
        .animation(.easeOut(duration: 0.16), value: emphasized)
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
                HStack(spacing: 16) {
                    Image(systemName: delta >= 0 ? "forward.fill" : "backward.fill")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(.white.opacity(0.9))
                    Text(PlayerTimeFormat.signedDelta(delta))
                        .font(.system(size: 44, weight: .heavy).monospacedDigit())
                        .foregroundStyle(.white)
                }

                PlayerProgressTrack(
                    played: duration > 0 ? target / duration : 0,
                    buffered: duration > 0 ? buffered / duration : 0,
                    height: 10,
                    showThumb: true,
                    emphasized: true
                )
                .frame(height: 14)

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(PlayerTimeFormat.clock(target))
                            .font(.system(size: 26, weight: .bold).monospacedDigit())
                            .foregroundStyle(.white)
                        Text("elapsed")
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
                        Text("remaining")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
            }
            .padding(.horizontal, 60)
            .padding(.bottom, 54)
            .background(
                LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 320)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .ignoresSafeArea()
            )
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Infuse-style scrub HUD

/// Full scrub overlay. Observes `PlaybackClock` so high-frequency scrub updates
/// re-render only this bar — not the whole player stack.
struct InfuseScrubHUD: View {
    @ObservedObject var clock: PlaybackClock
    let title: String
    var episodeLine: String?
    var wheelEngaged: Bool = false

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
                    ZStack(alignment: .topLeading) {
                        PlayerProgressTrack(
                            played: target / duration,
                            buffered: buffered / duration,
                            height: 10,
                            showThumb: true,
                            emphasized: true
                        )
                        .frame(height: 14)
                        .offset(y: 54)

                        // Ghost tick: live playback position while scrubbing.
                        Rectangle()
                            .fill(Color.white.opacity(0.45))
                            .frame(width: 3, height: 22)
                            .offset(
                                x: w * CGFloat(min(max(current / duration, 0), 1)) - 1.5,
                                y: 50
                            )

                        Text(PlayerTimeFormat.clock(target))
                            .font(.system(size: 26, weight: .bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: Capsule())
                            .frame(width: 200, alignment: .center)
                            .offset(x: x - 100, y: 0)
                    }
                }
                .frame(height: 90)

                HStack {
                    Text(PlayerTimeFormat.clock(target))
                        .font(.system(size: 22, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                    Text(PlayerTimeFormat.signedDelta(target - current))
                        .font(.system(size: 20, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.75))
                    Spacer()
                    if wheelEngaged {
                        Label("Fine-tuning", systemImage: "arrow.triangle.2.circlepath")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))
                    } else {
                        Label("Click to seek", systemImage: "hand.tap")
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
                    showThumb: true,
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
