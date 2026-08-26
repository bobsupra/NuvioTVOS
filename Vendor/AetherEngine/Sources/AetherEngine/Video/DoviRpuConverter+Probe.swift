import Foundation
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil

/// Extract VPS/SPS/PPS NALs from hvcC extradata (22-byte header + numOfArrays arrays). Returns raw NAL bytes without length prefix or start code.
private func parseHVCCParameterSets(_ ed: UnsafePointer<UInt8>, _ size: Int) -> [[UInt8]] {
    guard size > 23 else { return [] }
    var out: [[UInt8]] = []
    let numArrays = Int(ed[22])
    var p = 23
    for _ in 0..<numArrays {
        guard p + 3 <= size else { break }
        let numNalus = (Int(ed[p + 1]) << 8) | Int(ed[p + 2])
        p += 3
        for _ in 0..<numNalus {
            guard p + 2 <= size else { return out }
            let nalLen = (Int(ed[p]) << 8) | Int(ed[p + 1])
            p += 2
            guard nalLen > 0, p + nalLen <= size else { return out }
            out.append([UInt8](UnsafeBufferPointer(start: ed + p, count: nalLen)))
            p += nalLen
        }
    }
    return out
}

/// Result of a `doviConvertProbe` run over a source's HEVC video stream.
public struct DoviConvertProbeResult: Sendable {
    public let packetsProcessed: Int
    public let conversions: Int
    public let failures: Int
    public let outputPath: String
    public let videoStreamFound: Bool
    /// Enhancement-layer type of the first P7 RPU seen ("FEL"/"MEL"), or nil if not a P7 source.
    public let enhancementLayerType: String?
}

extension AetherEngine {

    // MARK: - Dovi convert probe (aetherctl dovitest)

    /// Walk every HEVC video packet, resolve NAL framing from a small packet sample (falling back to
    /// stream configuration when the sample is inconclusive), run `convertPacketToProfile81`, and
    /// write Annex-B output for validation with `dovi_tool extract-rpu`. False returns are counted
    /// as failures but still emitted.
    public nonisolated static func doviConvertProbe(
        url: URL,
        outputPath: String,
        options: LoadOptions = .init()
    ) throws -> DoviConvertProbeResult {
        let demuxer = Demuxer()
        try demuxer.open(url: url, extraHeaders: options.httpHeaders)
        defer { demuxer.close() }

        let videoIdx = demuxer.videoStreamIndex
        guard videoIdx >= 0, let stream = demuxer.stream(at: videoIdx) else {
            return DoviConvertProbeResult(
                packetsProcessed: 0, conversions: 0, failures: 0,
                outputPath: outputPath, videoStreamFound: false,
                enhancementLayerType: nil
            )
        }

        FileManager.default.createFile(atPath: outputPath, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: outputPath) else {
            throw AetherEngineError.noVideoStream
        }
        defer { try? handle.close() }

        let configuredFraming: A53SEIParser.NALFraming = {
            guard let cp = stream.pointee.codecpar,
                  let ed = cp.pointee.extradata,
                  cp.pointee.extradata_size > 0 else { return .annexB }
            return A53SEIParser.nalFraming(
                codec: .hevc,
                extradata: UnsafePointer(ed),
                size: Int(cp.pointee.extradata_size)
            )
        }()

        let startCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]

        // MP4 hvcC keeps VPS/SPS/PPS out-of-band; emit them once as Annex-B so dovi_tool's parser can walk the stream.
        if case .lengthPrefixed = configuredFraming,
           let cp = stream.pointee.codecpar,
           let ed = cp.pointee.extradata, cp.pointee.extradata_size > 0 {
            let edSize = Int(cp.pointee.extradata_size)
            for nal in parseHVCCParameterSets(ed, edSize) {
                handle.write(Data(startCode))
                handle.write(Data(nal))
            }
        }

        var packetsProcessed = 0
        var conversions = 0
        var failures = 0
        var elType: String? = nil
        let framingSampleLimit = 8
        var sampledPackets: [UnsafeMutablePointer<AVPacket>] = []
        var streamFraming: A53SEIParser.NALFraming?

        func framingForPacket(
            _ packet: UnsafeMutablePointer<AVPacket>, preferred: A53SEIParser.NALFraming
        ) -> A53SEIParser.NALFraming? {
            guard let data = packet.pointee.data, packet.pointee.size > 0 else { return nil }
            let valid = A53SEIParser.allValidNALFramings(data, Int(packet.pointee.size))
            // If a packet is ambiguous, preserve the resolved stream framing rather than allowing
            // a packet-local first-match choice to flip the output framing.
            if valid.contains(preferred) { return preferred }
            return A53SEIParser.detectNALFraming(data, Int(packet.pointee.size), preferred: preferred)
        }

        func processVideoPacket(
            _ packet: UnsafeMutablePointer<AVPacket>, preferred: A53SEIParser.NALFraming
        ) {
            let packetFraming = framingForPacket(packet, preferred: preferred)
            if let packetFraming {
                if elType == nil {
                    elType = DoviRpuConverter.enhancementLayerType(packet, framing: packetFraming)
                }
                if DoviRpuConverter.convertPacketToProfile81(packet, framing: packetFraming) {
                    conversions += 1
                } else {
                    failures += 1
                }
                if let data = packet.pointee.data, packet.pointee.size > 0 {
                    let size = Int(packet.pointee.size)
                    A53SEIParser.forEachNAL(data, size, packetFraming) { nal, nalSize in
                        handle.write(Data(startCode))
                        handle.write(Data(bytes: nal, count: nalSize))
                    }
                }
            } else if let data = packet.pointee.data, packet.pointee.size > 0 {
                // Preserve an undecodable packet for probe output instead of silently dropping it.
                failures += 1
                handle.write(Data(startCode))
                handle.write(Data(bytes: data, count: Int(packet.pointee.size)))
            }
        }

        func resolveAndProcessSample() {
            guard !sampledPackets.isEmpty else { return }
            let evidence = sampledPackets.compactMap { packet -> [A53SEIParser.NALFraming]? in
                guard let data = packet.pointee.data, packet.pointee.size > 0 else { return nil }
                return A53SEIParser.allValidNALFramings(data, Int(packet.pointee.size))
            }
            let chosen = A53SEIParser.resolveNALFraming(
                samples: evidence, configured: configuredFraming
            ) ?? configuredFraming
            streamFraming = chosen
            for packet in sampledPackets {
                processVideoPacket(packet, preferred: chosen)
                av_packet_unref(packet)
                av_packet_free_safe(packet)
            }
            sampledPackets.removeAll(keepingCapacity: false)
        }

        while true {
            let maybePacket: UnsafeMutablePointer<AVPacket>?
            do {
                maybePacket = try demuxer.readPacket()
            } catch {
                break
            }
            guard let packet = maybePacket else { break }  // EOF

            if packet.pointee.stream_index == videoIdx {
                packetsProcessed += 1
                if streamFraming == nil {
                    sampledPackets.append(packet)
                    if sampledPackets.count >= framingSampleLimit {
                        resolveAndProcessSample()
                    }
                } else {
                    processVideoPacket(packet, preferred: streamFraming!)
                    av_packet_unref(packet)
                    av_packet_free_safe(packet)
                }
            } else {
                av_packet_unref(packet)
                av_packet_free_safe(packet)
            }
        }

        // Forward-only URLs are supported: sampled packets remain owned in memory until framing
        // is resolved, so no seek/reset is needed and no sampled video packet is lost.
        resolveAndProcessSample()

        return DoviConvertProbeResult(
            packetsProcessed: packetsProcessed,
            conversions: conversions,
            failures: failures,
            outputPath: outputPath,
            videoStreamFound: true,
            enhancementLayerType: elType
        )
    }
}
