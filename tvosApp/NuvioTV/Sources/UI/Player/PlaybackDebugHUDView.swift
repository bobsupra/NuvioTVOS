import SwiftUI

/// Comprehensive playback diagnostics and telemetry overlay matching the HUD specification.
struct PlaybackDebugHUDView: View {
    let info: PlaybackDebugInfo
    let reason: String

    @AppStorage private var hideTorrentStats: Bool

    init(info: PlaybackDebugInfo, reason: String) {
        self.info = info
        self.reason = reason
        _hideTorrentStats = AppStorage(
            wrappedValue: false,
            SettingsKey.p2pHideTorrentStats,
            store: ProfileSettings.current
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Top Section: SOURCE & Clock
            sourceSection

            sectionDivider

            // VIDEO Section
            videoSection

            sectionDivider

            // AUDIO Section
            audioSection

            sectionDivider

            // NETWORK Section
            networkSection

            sectionDivider

            // SYSTEM Section
            systemSection

            // Optional Backend Diagnostics / Policy Trace
            if !reason.isEmpty || !info.diagnostics.isEmpty {
                sectionDivider
                diagnosticsSection
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .frame(width: 680, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.88))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.16), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.7), radius: 24, x: 0, y: 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(.trailing, 48)
        .padding(.top, 36)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Playback debug overlay")
    }

    // MARK: - SOURCE Section

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("SOURCE")
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundColor(Color.white.opacity(0.55))
                .tracking(1.2)

            VStack(alignment: .leading, spacing: 3) {
                hudRow(label: "Add-on", value: info.addon.isEmpty ? "Direct" : info.addon)
                hudRow(label: "Provider", value: info.provider.isEmpty ? "Direct" : info.provider)
                if !hideTorrentStats && TorrentEngineManager.shared.isStreaming {
                    let stats = TorrentEngineManager.shared.activeStats
                    hudRow(label: "P2P Swarm", value: "\(stats.connectedSeeds) seeds · \(stats.connectedPeers) peers · \(stats.downloadRateFormatted)")
                    if let diag = TorrentEngineManager.shared.activeDiagnostics {
                        hudRow(label: "P2P Net", value: "DHT: \(diag.dhtNodes) nodes · Peers: \(diag.listPeers) · Fails: \(diag.connectFailures)")
                        if !diag.lastPeerSource.isEmpty {
                            hudRow(label: "Last Tracker", value: diag.lastPeerSource)
                        }
                    }
                }
                if !hideTorrentStats && UsenetEngineManager.shared.isStreaming {
                    let usenet = UsenetEngineManager.shared.activeStats
                    hudRow(label: "Usenet", value: usenet.connectionLine)
                    hudRow(label: "NNTP cache", value: usenet.cacheLine)
                }
                hudRow(label: "Server", value: info.server.isEmpty ? "--" : info.server)
                fileRow
                hudRow(label: "Size", value: info.size.isEmpty ? "--" : info.size)
            }
        }
    }

    private var fileRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            statusDotSpacer

            Text("File")
                .font(.system(size: 14, weight: .regular, design: .monospaced))
                .foregroundColor(Color.white.opacity(0.60))
                .frame(width: 105, alignment: .leading)

            HStack(spacing: 8) {
                Text(info.fileExtension.isEmpty ? "MKV" : info.fileExtension.uppercased())
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(Color.white.opacity(0.90))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color.white.opacity(0.12))
                    )

                Text(info.fileName.isEmpty ? "Top.Gun.Maverick.2022.L" : info.fileName)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundColor(Color.white.opacity(0.95))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: - VIDEO Section

    private var videoSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("VIDEO")
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundColor(Color.white.opacity(0.55))
                .tracking(1.2)

            VStack(alignment: .leading, spacing: 3) {
                hudRow(label: "Video", value: info.video.isEmpty ? "Unavailable" : info.video)
                hudRow(label: "HDR", value: info.hdr.isEmpty ? "Unavailable" : info.hdr)
                hudRow(label: "V bitrate", value: info.vBitrate.isEmpty ? "Unavailable" : info.vBitrate)
                hudRow(
                    label: "DV",
                    value: info.dv.isEmpty ? "None" : info.dv,
                    hasDot: info.dv != "None" && !info.dv.isEmpty,
                    dotColor: .green
                )
                hudRow(label: "DV HDR", value: info.dvHdr.isEmpty ? "Unavailable" : info.dvHdr)
                hudRow(label: "Decoder", value: info.decoder.isEmpty ? "Unavailable" : info.decoder)
                hudRow(
                    label: "Dropped",
                    value: info.dropped.isEmpty ? "0 frames" : info.dropped,
                    hasDot: true,
                    dotColor: info.droppedCount > 10 ? .red : (info.droppedCount > 0 ? .yellow : .green)
                )
                hudRow(label: "Frame lead", value: info.frameLead.isEmpty ? "Unavailable" : info.frameLead, hasDot: true, dotColor: info.frameLead == "Unavailable" ? .gray : .green)
                hudRow(label: "Display", value: info.display.isEmpty ? "Unavailable" : info.display, hasDot: true, dotColor: info.display == "Unavailable" ? .gray : .green)
            }
        }
    }

    // MARK: - AUDIO Section

    private var audioSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("AUDIO")
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundColor(Color.white.opacity(0.55))
                .tracking(1.2)

            VStack(alignment: .leading, spacing: 3) {
                hudRow(label: "Audio", value: info.audio.isEmpty ? "Unavailable" : info.audio, hasDot: true, dotColor: info.audio == "Unavailable" ? .gray : .green)
                hudRow(label: "A bitrate", value: info.aBitrate.isEmpty ? "Unavailable" : info.aBitrate)
                hudRow(label: "Underruns", value: info.underruns.isEmpty ? "0 · native 0" : info.underruns, hasDot: true, dotColor: info.underrunsCount > 0 ? .yellow : .green)
                hudRow(label: "Route", value: info.route.isEmpty ? "Unavailable" : info.route)
                hudRow(label: "A jitter", value: info.aJitter.isEmpty ? "Unavailable" : info.aJitter, hasDot: true, dotColor: info.aJitter == "Unavailable" ? .gray : .green)
            }
        }
    }

    // MARK: - NETWORK Section

    private var networkSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("NETWORK")
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundColor(Color.white.opacity(0.55))
                .tracking(1.2)

            VStack(alignment: .leading, spacing: 3) {
                hudRow(
                    label: "RAM buffer",
                    value: info.buffer.isEmpty ? "--" : info.buffer,
                    hasDot: true,
                    dotColor: (info.buffer.contains("cushion") || info.bufferSeconds >= 1.0) ? .green : (info.bufferSeconds > 0 ? .yellow : .green)
                )
                hudRow(
                    label: "Disk cache",
                    value: info.diskBuffer.isEmpty ? "--" : info.diskBuffer,
                    hasDot: true,
                    dotColor: info.diskBufferSeconds >= 10.0 ? .green : (info.diskBufferSeconds > 0 ? .yellow : .gray)
                )
                hudRow(
                    label: "Concurrency",
                    value: info.concurrency.isEmpty ? "--" : info.concurrency,
                    hasDot: true,
                    dotColor: (info.concurrency.isEmpty || info.concurrency == "--") ? .gray : (info.concurrency.contains("idle") ? .yellow : .green)
                )
                hudRow(label: "Speed", value: info.speed.isEmpty ? "Unavailable" : info.speed, hasDot: true, dotColor: info.speed == "Unavailable" ? .gray : .green)
                hudRow(label: "Ping", value: info.ping.isEmpty ? "--" : info.ping, hasDot: true, dotColor: info.ping == "--" ? .gray : .green)
                hudRow(label: "Loaded", value: info.loaded.isEmpty ? "Unavailable" : info.loaded)
                hudRow(
                    label: "Stalls",
                    value: info.stalls.isEmpty ? "0" : info.stalls,
                    hasDot: true,
                    dotColor: info.stallsCount > 1 ? .red : (info.stallsCount == 1 ? .yellow : .green)
                )
            }
        }
    }

    // MARK: - SYSTEM Section

    private var systemSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("SYSTEM")
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundColor(Color.white.opacity(0.55))
                .tracking(1.2)

            VStack(alignment: .leading, spacing: 3) {
                hudRow(
                    label: "App CPU",
                    value: info.appCpu.isEmpty ? "-- %" : info.appCpu,
                    hasDot: true,
                    dotColor: info.appCpuPercent > 85 ? .yellow : .green
                )
                hudRow(label: "Memory", value: info.memory.isEmpty ? "Unavailable" : info.memory, hasDot: true, dotColor: info.memory == "Unavailable" ? .gray : .green)
                hudRow(
                    label: "SoC temp",
                    value: info.socTemp.isEmpty ? "Unavailable" : info.socTemp,
                    hasDot: true,
                    dotColor: info.isThermalElevated ? .yellow : .green
                )
                hudRow(label: "CPU clock", value: info.cpuClock.isEmpty ? "Unavailable" : info.cpuClock, hasDot: true, dotColor: info.cpuClock == "Unavailable" ? .gray : .green)
            }
        }
    }

    // MARK: - Optional Diagnostics / Policy Section

    private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            if !reason.isEmpty {
                Text("POLICY   \(reason)")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(.yellow.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(info.diagnostics, id: \.self) { line in
                Text(line)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.cyan.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Row Helpers

    private var sectionDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(height: 1)
            .padding(.vertical, 2)
    }

    private var statusDotSpacer: some View {
        Color.clear
            .frame(width: 14, height: 14)
    }

    private func statusDot(_ color: Color) -> some View {
        ZStack {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
        }
        .frame(width: 14, height: 14)
    }

    private func hudRow(
        label: String,
        value: String,
        hasDot: Bool = false,
        dotColor: Color = .green
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            if hasDot && value != "--" {
                statusDot(dotColor)
            } else {
                statusDotSpacer
            }

            Text(label)
                .font(.system(size: 14, weight: .regular, design: .monospaced))
                .foregroundColor(Color.white.opacity(0.60))
                .frame(width: 105, alignment: .leading)

            Text(value)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundColor(Color.white.opacity(0.95))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)
        }
    }

}
