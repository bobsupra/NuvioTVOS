//
//  PlayerLoadingOverlay.swift
//  NuvioTV
//
//  Cinematic loading overlay displaying backdrop, logo / title, and loading status.
//

import SwiftUI

// MARK: - Playback Startup Benchmark & Timing

#if DEBUG
@inline(__always)
private func startupBenchmarkLog(_ message: @autoclosure () -> String) {
    print(message())
}
#else
@inline(__always)
private func startupBenchmarkLog(_ message: @autoclosure () -> String) {}
#endif

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
    private(set) var t_engineDispatched: Date?
    private(set) var activeToken: UUID?

    // Engine startup breakdown checkpoints
    private var t_sourceOpened: Date?
    private var t_streamsProbed: Date?
    private var t_displayPrepared: Date?
    private var t_sessionConstructed: Date?
    private let dateProvider: () -> Date

    init(dateProvider: @escaping () -> Date = { Date() }) {
        self.dateProvider = dateProvider
    }

    @discardableResult
    func start(title: String = "") -> UUID {
        let token = UUID()
        activeToken = token
        self.title = title
        self.streamName = ""
        self.addonName = ""
        self.t0_initiated = dateProvider()
        self.t1_sourcePicked = nil
        self.t2_debridResolved = nil
        self.t3_playbackStarted = nil
        self.t_engineDispatched = nil
        self.t_sourceOpened = nil
        self.t_streamsProbed = nil
        self.t_displayPrepared = nil
        self.t_sessionConstructed = nil
        let target = title.isEmpty ? "playback" : "\"\(title)\""
        startupBenchmarkLog("[StartupBenchmark] ⏱ [0/3] Started startup timer for \(target)")
        return token
    }

    func markSourcePicked(stream: NuvioStream, token: UUID?) {
        guard owns(token), let t0 = t0_initiated else { return }
        let now = dateProvider()
        self.t1_sourcePicked = now
        self.streamName = stream.name ?? stream.description ?? "Direct URL"
        self.addonName = stream.addonName ?? "Unknown"
        let pickDuration = now.timeIntervalSince(t0)
        let cleanName = streamName.replacingOccurrences(of: "\n", with: " ")
        startupBenchmarkLog("[StartupBenchmark] 🔍 [1/3] Source picked in \(String(format: "%.3fs", pickDuration)) (\(addonName) · \(cleanName))")
    }

    func markDebridResolved(token: UUID?) {
        guard owns(token), let t1 = t1_sourcePicked else { return }
        let now = dateProvider()
        self.t2_debridResolved = now
        let debridDuration = now.timeIntervalSince(t1)
        let totalSoFar = now.timeIntervalSince(t0_initiated ?? t1)
        startupBenchmarkLog("[StartupBenchmark] ⚡️ [2/3] Debrid link resolved in \(String(format: "%.3fs", debridDuration)) (elapsed: \(String(format: "%.3fs", totalSoFar)))")
    }

    func markEngineCheckpoint(_ name: String, token: UUID?) {
        guard owns(token) else { return }
        let now = dateProvider()
        switch name {
        case "dispatched":
            if t_engineDispatched == nil { t_engineDispatched = now }
        case "sourceOpened":
            if t_sourceOpened == nil { t_sourceOpened = now }
        case "streamsProbed":
            if t_streamsProbed == nil { t_streamsProbed = now }
        case "displayPrepared":
            if t_displayPrepared == nil { t_displayPrepared = now }
        case "sessionConstructed":
            if t_sessionConstructed == nil { t_sessionConstructed = now }
        default:
            break
        }
    }

    @discardableResult
    func markPlaybackStarted(token: UUID?) -> TimeInterval? {
        guard owns(token), let t0 = t0_initiated else { return nil }
        let now = dateProvider()
        self.t3_playbackStarted = now
        self.activeToken = nil

        let totalDuration = now.timeIntervalSince(t0)
#if DEBUG
        let pickDuration = t1_sourcePicked.map { $0.timeIntervalSince(t0) }
        let debridDuration: Double = {
            if let t2 = t2_debridResolved, let t1 = t1_sourcePicked {
                return t2.timeIntervalSince(t1)
            }
            return 0
        }()
        let preEngineBase = t2_debridResolved ?? t1_sourcePicked ?? t0
        let preEngineDuration = t_engineDispatched.map {
            max(0, $0.timeIntervalSince(preEngineBase))
        }
        let engineDuration = t_engineDispatched.map {
            max(0, now.timeIntervalSince($0))
        }

        let sourceOpeningDuration: Double? = {
            guard let dispatched = t_engineDispatched, let opened = t_sourceOpened else { return nil }
            return max(0, opened.timeIntervalSince(dispatched))
        }()
        let probeDuration: Double? = {
            guard let dispatched = t_engineDispatched, let probed = t_streamsProbed else { return nil }
            let prev = t_sourceOpened ?? dispatched
            return max(0, probed.timeIntervalSince(prev))
        }()
        let displayDuration: Double? = {
            guard let dispatched = t_engineDispatched, let display = t_displayPrepared else { return nil }
            let prev = t_streamsProbed ?? t_sourceOpened ?? dispatched
            return max(0, display.timeIntervalSince(prev))
        }()
        let bufferDuration: Double? = {
            let prev = t_displayPrepared ?? t_streamsProbed ?? t_sourceOpened
            guard let prev, t_engineDispatched != nil else { return nil }
            return max(0, now.timeIntervalSince(prev))
        }()

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
        if let pickDuration {
            lines.append("  1. Pick Source:       \(String(format: "%.3fs", pickDuration))  (stream discovery & selection)")
        } else {
            lines.append("  1. Pick Source:       unavailable (source selection checkpoint missing)")
        }
        var phaseNumber = 2
        if t2_debridResolved != nil {
            lines.append("  \(phaseNumber). Debrid Resolve:    \(String(format: "%.3fs", debridDuration))  (provider unrestrict & URL ready)")
            phaseNumber += 1
        }
        if let preEngineDuration {
            let context = t1_sourcePicked == nil
                ? "discovery, selection & preparation"
                : "source ready to engine dispatch"
            lines.append("  \(phaseNumber). Pre-engine Prep:   \(String(format: "%.3fs", preEngineDuration))  (\(context))")
        } else {
            lines.append("  \(phaseNumber). Pre-engine Prep:   unavailable (engine dispatch checkpoint missing)")
        }
        phaseNumber += 1
        if let engineDuration {
            lines.append("  \(phaseNumber). Engine Startup:    \(String(format: "%.3fs", engineDuration))  (dispatch to playback start)")
        } else {
            lines.append("  \(phaseNumber). Engine Startup:    unavailable (engine dispatch checkpoint missing)")
        }

        if let sourceOpening = sourceOpeningDuration, sourceOpening >= 0.05 {
            lines.append("     ├─ Source Opening: \(String(format: "%.3fs", sourceOpening))  (connection, open & initial data)")
        }
        if let probe = probeDuration, probe >= 0.05 {
            lines.append("     ├─ Stream Probe:   \(String(format: "%.3fs", probe))  (demux container & tracks)")
        }
        if let display = displayDuration, display >= 0.05 {
            lines.append("     ├─ HDMI Handshake: \(String(format: "%.3fs", display))  (tvOS match rate & range)")
        }
        if let buffer = bufferDuration, buffer >= 0.05 {
            lines.append("     └─ Mux & Buffer:   \(String(format: "%.3fs", buffer))  (HLS segment 0 & AVPlayer)")
        }

        lines.append("  ----------------------------------------------------------")
        lines.append("  ⏱ TOTAL TIME TO PLAY: \(String(format: "%.3fs", totalDuration))")
        lines.append("============================================================\n")

        print(lines.joined(separator: "\n"))
#endif
        return totalDuration
    }

    func cancel(token: UUID?) {
        guard owns(token) else { return }
        startupBenchmarkLog("[StartupBenchmark] ❌ Startup timer cancelled")
        activeToken = nil
        t0_initiated = nil
        t1_sourcePicked = nil
        t2_debridResolved = nil
        t3_playbackStarted = nil
        t_engineDispatched = nil
        t_sourceOpened = nil
        t_streamsProbed = nil
        t_displayPrepared = nil
        t_sessionConstructed = nil
    }

    private func owns(_ token: UUID?) -> Bool {
        guard let token else { return false }
        return activeToken == token && t3_playbackStarted == nil
    }
}

@MainActor
enum PlaybackStartupTiming {
    static var activeToken: UUID? {
        PlaybackStartupBenchmark.shared.activeToken
    }

    static func isActive(token: UUID?) -> Bool {
        guard let token else { return false }
        return PlaybackStartupBenchmark.shared.activeToken == token
    }

    /// Display-only fallback for loading overlays; benchmark mutations always
    /// require an explicit owner token.
    static var requestDate: Date? {
        PlaybackStartupBenchmark.shared.t0_initiated
    }

    static func requestDate(for token: UUID?) -> Date? {
        guard let token, PlaybackStartupBenchmark.shared.activeToken == token else { return nil }
        return PlaybackStartupBenchmark.shared.t0_initiated
    }

    @discardableResult
    static func start(title: String = "") -> UUID {
        PlaybackStartupBenchmark.shared.start(title: title)
    }

    static func markSourcePicked(stream: NuvioStream, token: UUID?) {
        PlaybackStartupBenchmark.shared.markSourcePicked(stream: stream, token: token)
    }

    static func markDebridResolved(token: UUID?) {
        PlaybackStartupBenchmark.shared.markDebridResolved(token: token)
    }

    @discardableResult
    static func complete(token: UUID?) -> TimeInterval? {
        PlaybackStartupBenchmark.shared.markPlaybackStarted(token: token)
    }

    static func cancel(token: UUID?) {
        PlaybackStartupBenchmark.shared.cancel(token: token)
    }
}

struct PlayerLoadingOverlay: View {
    let backdropUrl: String?
    let logoUrl: String?
    let title: String?
    var message: String = L10n.string("player_status_starting_stream", fallback: "Starting stream")
    var startTime: Date? = nil
    var showTimer: Bool = true
    var onDismiss: (() -> Void)? = nil
    var focusEnabled: Bool = true
    var onSelect: (() -> Void)? = nil
    var onMove: ((MoveCommandDirection) -> Void)? = nil

    @AppStorage(SettingsKey.showLoadingStatus) private var showLoadingStatus = true
    @FocusState private var isFocusActive: Bool
    @State private var isPulsing = false
    @State private var logoLoadFailed = false
    @State private var mountedDate = Date()
    @ObservedObject private var torrentManager = TorrentEngineManager.shared
    @ObservedObject private var usenetManager = UsenetEngineManager.shared

    private var effectiveStartTime: Date {
        startTime ?? mountedDate
    }

    var body: some View {
        ZStack {
            #if os(tvOS)
            Color.clear
                .frame(width: 1, height: 1)
                .contentShape(Rectangle())
                .focusable(focusEnabled)
                .focused($isFocusActive)
                .onTapGesture {
                    if focusEnabled {
                        onSelect?()
                    }
                }
                .onMoveCommand { direction in
                    if focusEnabled {
                        onMove?(direction)
                    }
                }
            #endif

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

                if showLoadingStatus && !message.isEmpty {
                    VStack(spacing: 12) {
                        Text(message)
                            .font(.system(size: 22, weight: .medium))
                            .foregroundColor(Color.white.opacity(0.85))
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

                if torrentManager.isStreaming && !TorrentSettings.hideStats() {
                    let stats = torrentManager.activeStats
                    VStack(spacing: 8) {
                        HStack(spacing: 12) {
                            HStack(spacing: 5) {
                                Image(systemName: "arrow.down.circle.fill")
                                    .font(.system(size: 13))
                                    .foregroundColor(.green)
                                Text(stats.downloadRateFormatted)
                                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                            }

                            Text("•")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.4))

                            HStack(spacing: 4) {
                                Text("\(stats.connectedSeeds)")
                                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                                    .foregroundColor(.green)
                                Text(L10n.string("player_torrent_seeds", fallback: "seeds"))
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.white.opacity(0.7))
                            }

                            Text("•")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.4))

                            HStack(spacing: 4) {
                                Text("\(stats.connectedPeers)")
                                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                                    .foregroundColor(.blue)
                                Text(L10n.string("player_torrent_peers", fallback: "peers"))
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.white.opacity(0.7))
                            }
                        }
                        .foregroundColor(.white)
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

                        if let stage = torrentManager.startupStage, !stage.isEmpty {
                            Text(stage)
                                .font(.system(size: 14, weight: .medium, design: .monospaced))
                                .foregroundColor(.white.opacity(0.65))
                                .shadow(color: .black.opacity(0.6), radius: 4, y: 1)
                        }
                    }
                }

                if showLoadingStatus && usenetManager.isStreaming && !TorrentSettings.hideStats() {
                    let stats = usenetManager.activeStats
                    HStack(spacing: 12) {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.system(size: 13))
                                .foregroundColor(.green)
                            Text(stats.downloadRateFormatted)
                                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        }

                        Text("•")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.4))

                        HStack(spacing: 4) {
                            Text(stats.connectionsText)
                                .font(.system(size: 14, weight: .bold, design: .monospaced))
                                .foregroundColor(.green)
                            Text(L10n.string("player_usenet_connections", fallback: "connections"))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.white.opacity(0.7))
                        }

                        Text("•")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.4))

                        HStack(spacing: 4) {
                            Text(stats.bufferedFormatted)
                                .font(.system(size: 14, weight: .bold, design: .monospaced))
                                .foregroundColor(.blue)
                            Text(L10n.string("player_usenet_buffered", fallback: "buffered"))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.white.opacity(0.7))
                        }

                        if stats.missingArticles > 0 {
                            Text("•")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.4))
                            Text(L10n.format("player_usenet_missing", fallback: "%d missing", stats.missingArticles))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.orange)
                        }
                    }
                    .foregroundColor(.white)
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
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .padding(.horizontal, 80)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        #if os(tvOS)
        .onExitCommand {
            if focusEnabled {
                onDismiss?()
            }
        }
        #endif
        .onAppear {
            isPulsing = true
            #if os(tvOS)
            DispatchQueue.main.async {
                isFocusActive = focusEnabled
            }
            #endif
        }
        #if os(tvOS)
        .onChange(of: focusEnabled) { _, enabled in
            if enabled {
                DispatchQueue.main.async { isFocusActive = focusEnabled }
            } else {
                isFocusActive = false
            }
        }
        #endif
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
