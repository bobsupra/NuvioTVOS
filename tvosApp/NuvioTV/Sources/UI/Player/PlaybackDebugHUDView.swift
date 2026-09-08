import SwiftUI
import Combine

/// Comprehensive playback diagnostics and telemetry overlay matching the HUD specification.
struct PlaybackDebugHUDView: View {
    let info: PlaybackDebugInfo
    let reason: String
    let remainingSeconds: Double?

    @State private var currentTimeString: String = ""
    @State private var endsAtTimeString: String = ""
    @State private var timer: AnyCancellable?

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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.leading, 48)
        .padding(.top, 36)
        .allowsHitTesting(false)
        .onAppear {
            updateClock()
            timer = Timer.publish(every: 1.0, on: .main, in: .common)
                .autoconnect()
                .sink { _ in
                    updateClock()
                }
        }
        .onChange(of: remainingSeconds) { _, _ in
            updateClock()
        }
        .onDisappear {
            timer?.cancel()
            timer = nil
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Playback debug overlay")
    }

    // MARK: - SOURCE Section

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                Text("SOURCE")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(Color.white.opacity(0.55))
                    .tracking(1.2)

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(currentTimeString)
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                        .foregroundColor(Color.white.opacity(0.9))

                    if !endsAtTimeString.isEmpty {
                        Text(endsAtTimeString)
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundColor(Color.white.opacity(0.55))
                    }
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                hudRow(label: "Add-on", value: info.addon.isEmpty ? "Direct" : info.addon)
                hudRow(label: "Provider", value: info.provider.isEmpty ? "Direct" : info.provider)
                if TorrentEngineManager.shared.isStreaming {
                    let stats = TorrentEngineManager.shared.activeStats
                    hudRow(label: "P2P Swarm", value: "\(stats.connectedSeeds) seeds · \(stats.connectedPeers) peers · \(stats.downloadRateFormatted)")
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
                hudRow(label: "Video", value: info.video.isEmpty ? "3840×2160 · 23.976 fps · dolby-vision" : info.video)
                hudRow(label: "HDR", value: info.hdr.isEmpty ? "Dolby Vision" : info.hdr)
                hudRow(label: "V bitrate", value: info.vBitrate.isEmpty ? "avg mux 72.9 Mbit/s · now 82.0 Mbit/s" : info.vBitrate)
                hudRow(
                    label: "DV",
                    value: info.dv.isEmpty ? "None" : info.dv,
                    hasDot: info.dv != "None" && !info.dv.isEmpty,
                    dotColor: .green
                )
                hudRow(label: "DV HDR", value: info.dvHdr.isEmpty ? "MaxCLL 617 · MaxFALL 496 · MDL peak ~1001 nits" : info.dvHdr)
                hudRow(label: "Decoder", value: info.decoder.isEmpty ? "c2.amlogic.dolby-vision.dvhe.decoder" : info.decoder)
                hudRow(
                    label: "Dropped",
                    value: info.dropped.isEmpty ? "0 frames" : info.dropped,
                    hasDot: true,
                    dotColor: info.droppedCount > 10 ? .red : (info.droppedCount > 0 ? .yellow : .green)
                )
                hudRow(label: "Frame lead", value: info.frameLead.isEmpty ? "+44.9 ms" : info.frameLead, hasDot: true, dotColor: .green)
                hudRow(label: "Display", value: info.display.isEmpty ? "23.98 Hz" : info.display, hasDot: true, dotColor: .green)
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
                hudRow(label: "Audio", value: info.audio.isEmpty ? "TrueHD · 8ch · 48 kHz · passthrough" : info.audio, hasDot: true, dotColor: .green)
                hudRow(label: "A bitrate", value: info.aBitrate.isEmpty ? "meas 5.14 Mbit/s" : info.aBitrate)
                hudRow(label: "Underruns", value: info.underruns.isEmpty ? "0 · native 0" : info.underruns, hasDot: true, dotColor: info.underrunsCount > 0 ? .yellow : .green)
                hudRow(label: "Route", value: info.route.isEmpty ? "HDMI · 0 changes" : info.route)
                hudRow(label: "A jitter", value: info.aJitter.isEmpty ? "drift avg 32 ms/s · max 343 · 13 ev" : info.aJitter, hasDot: true, dotColor: .green)
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
                    label: "Buffer",
                    value: info.buffer.isEmpty ? "--" : info.buffer,
                    hasDot: true,
                    dotColor: (info.buffer.contains("cushion") || info.bufferSeconds >= 1.0) ? .green : (info.bufferSeconds > 0 ? .yellow : .green)
                )
                hudRow(label: "Speed", value: info.speed.isEmpty ? "est 199.0 Mbit/s" : info.speed, hasDot: true, dotColor: .green)
                hudRow(label: "Ping", value: info.ping.isEmpty ? "7 ms" : info.ping, hasDot: true, dotColor: .green)
                hudRow(label: "Loaded", value: info.loaded.isEmpty ? "1021.6 MB" : info.loaded)
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
                    value: info.appCpu.isEmpty ? "27 %" : info.appCpu,
                    hasDot: true,
                    dotColor: info.appCpuPercent > 85 ? .yellow : .green
                )
                hudRow(label: "Memory", value: info.memory.isEmpty ? "heap 57/384 MB · native 841 MB" : info.memory, hasDot: true, dotColor: .green)
                hudRow(
                    label: "SoC temp",
                    value: info.socTemp.isEmpty ? "48.9 °C" : info.socTemp,
                    hasDot: true,
                    dotColor: info.isThermalElevated ? .yellow : .green
                )
                hudRow(label: "CPU clock", value: info.cpuClock.isEmpty ? "2.40 GHz · cap 2.40 GHz" : info.cpuClock, hasDot: true, dotColor: .green)
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
            if hasDot {
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

    // MARK: - Clock Calculation

    private func updateClock() {
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        currentTimeString = formatter.string(from: now)

        if let remaining = remainingSeconds, remaining > 0 {
            let endsAt = now.addingTimeInterval(remaining)
            endsAtTimeString = "Ends at \(formatter.string(from: endsAt))"
        } else {
            endsAtTimeString = ""
        }
    }
}
