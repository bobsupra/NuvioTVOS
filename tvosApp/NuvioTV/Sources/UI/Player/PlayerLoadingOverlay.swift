//
//  PlayerLoadingOverlay.swift
//  NuvioTV
//
//  Cinematic loading overlay displaying backdrop, logo / title, and loading status.
//

import SwiftUI

// MARK: - Playback Startup Benchmark & Timing

@MainActor
final class PlaybackStartupBenchmark {
    static let shared = PlaybackStartupBenchmark()

    private(set) var title: String = ""
    private(set) var streamName: String = ""
    private(set) var addonName: String = ""

    private(set) var t0_initiated: Date?
    private(set) var t1_sourcePicked: Date?
    private(set) var t2_debridResolved: Date?
    private(set) var t3_playbackStarted: Date?

    private init() {}

    func start(title: String = "") {
        self.title = title
        self.streamName = ""
        self.addonName = ""
        self.t0_initiated = Date()
        self.t1_sourcePicked = nil
        self.t2_debridResolved = nil
        self.t3_playbackStarted = nil
        let target = title.isEmpty ? "playback" : "\"\(title)\""
        print("[StartupBenchmark] ⏱ [0/3] Started startup timer for \(target)")
    }

    func markSourcePicked(stream: NuvioStream) {
        guard let t0 = t0_initiated else { return }
        let now = Date()
        self.t1_sourcePicked = now
        self.streamName = stream.name ?? stream.description ?? "Direct URL"
        self.addonName = stream.addonName ?? "Unknown"
        let pickDuration = now.timeIntervalSince(t0)
        let cleanName = streamName.replacingOccurrences(of: "\n", with: " ")
        print("[StartupBenchmark] 🔍 [1/3] Source picked in \(String(format: "%.3fs", pickDuration)) (\(addonName) · \(cleanName))")
    }

    func markDebridResolved() {
        guard let t1 = t1_sourcePicked else { return }
        let now = Date()
        self.t2_debridResolved = now
        let debridDuration = now.timeIntervalSince(t1)
        let totalSoFar = now.timeIntervalSince(t0_initiated ?? t1)
        print("[StartupBenchmark] ⚡️ [2/3] Debrid link resolved in \(String(format: "%.3fs", debridDuration)) (elapsed: \(String(format: "%.3fs", totalSoFar)))")
    }

    @discardableResult
    func markPlaybackStarted() -> TimeInterval? {
        guard let t0 = t0_initiated, t3_playbackStarted == nil else { return nil }
        let now = Date()
        self.t3_playbackStarted = now

        let totalDuration = now.timeIntervalSince(t0)
        let pickDuration = t1_sourcePicked.map { $0.timeIntervalSince(t0) } ?? 0
        let debridDuration: Double = {
            if let t2 = t2_debridResolved, let t1 = t1_sourcePicked {
                return t2.timeIntervalSince(t1)
            }
            return 0
        }()
        let engineBase = t2_debridResolved ?? t1_sourcePicked ?? t0
        let engineDuration = now.timeIntervalSince(engineBase)

        var lines: [String] = []
        lines.append("\n============================================================")
        lines.append("[StartupBenchmark] 🚀 PLAYBACK STARTUP BREAKDOWN:")
        if !title.isEmpty {
            lines.append("  • Title:              \(title)")
        }
        if !addonName.isEmpty || !streamName.isEmpty {
            let cleanName = streamName.replacingOccurrences(of: "\n", with: " ")
            lines.append("  • Selected Source:    \(addonName) · \(cleanName)")
        }
        lines.append("  ----------------------------------------------------------")
        lines.append("  1. Pick Source:       \(String(format: "%.3fs", pickDuration))  (stream discovery & selection)")
        if t2_debridResolved != nil {
            lines.append("  2. Debrid Resolve:    \(String(format: "%.3fs", debridDuration))  (provider unrestrict & URL ready)")
            lines.append("  3. Engine Startup:    \(String(format: "%.3fs", engineDuration))  (player buffer & first frame)")
        } else {
            lines.append("  2. Engine Startup:    \(String(format: "%.3fs", engineDuration))  (player buffer & first frame)")
        }
        lines.append("  ----------------------------------------------------------")
        lines.append("  ⏱ TOTAL TIME TO PLAY: \(String(format: "%.3fs", totalDuration))")
        lines.append("============================================================\n")

        print(lines.joined(separator: "\n"))
        return totalDuration
    }

    func cancel() {
        if t0_initiated != nil && t3_playbackStarted == nil {
            print("[StartupBenchmark] ❌ Startup timer cancelled")
        }
        t0_initiated = nil
        t1_sourcePicked = nil
        t2_debridResolved = nil
        t3_playbackStarted = nil
    }
}

@MainActor
enum PlaybackStartupTiming {
    static var requestDate: Date? {
        PlaybackStartupBenchmark.shared.t0_initiated
    }

    static func start(title: String = "") {
        PlaybackStartupBenchmark.shared.start(title: title)
    }

    @discardableResult
    static func complete() -> TimeInterval? {
        PlaybackStartupBenchmark.shared.markPlaybackStarted()
    }

    static func cancel() {
        PlaybackStartupBenchmark.shared.cancel()
    }
}

struct PlayerLoadingOverlay: View {
    let backdropUrl: String?
    let logoUrl: String?
    let title: String?
    var message: String = L10n.string("player_status_starting_stream", fallback: "Starting stream")
    var startTime: Date? = nil
    var showTimer: Bool = true

    @State private var isPulsing = false
    @State private var logoLoadFailed = false
    @State private var mountedDate = Date()

    private var effectiveStartTime: Date {
        startTime ?? PlaybackStartupTiming.requestDate ?? mountedDate
    }

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
                    VStack(spacing: 12) {
                        HStack(spacing: 10) {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white.opacity(0.85)))
                                .scaleEffect(0.9)
                            Text(message)
                                .font(.system(size: 22, weight: .medium))
                                .foregroundColor(Color.white.opacity(0.85))
                        }
                        .shadow(color: .black.opacity(0.6), radius: 8, y: 2)

                        if showTimer {
                            TimelineView(.periodic(from: .now, by: 0.05)) { timeline in
                                let elapsed = max(0, timeline.date.timeIntervalSince(effectiveStartTime))
                                HStack(spacing: 6) {
                                    Image(systemName: "timer")
                                        .font(.system(size: 14, weight: .semibold))
                                    Text(formattedElapsedTime(elapsed))
                                        .font(.system(size: 16, weight: .semibold, design: .monospaced))
                                }
                                .foregroundColor(Color.white.opacity(0.75))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 5)
                                .background(
                                    Capsule()
                                        .fill(Color.black.opacity(0.45))
                                        .overlay(
                                            Capsule()
                                                .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                                        )
                                )
                                .shadow(color: .black.opacity(0.5), radius: 4, y: 1)
                            }
                        }
                    }
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

    private func formattedElapsedTime(_ elapsed: TimeInterval) -> String {
        if elapsed < 60 {
            return String(format: "%.1fs", elapsed)
        } else {
            let minutes = Int(elapsed) / 60
            let seconds = elapsed.truncatingRemainder(dividingBy: 60)
            return String(format: "%d:%04.1fs", minutes, seconds)
        }
    }
}
