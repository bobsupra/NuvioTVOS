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

    /// Walk every HEVC video packet, run `convertPacketToProfile81`, and write Annex-B output (AVCC length prefix replaced by `00 00 00 01`) for validation with `dovi_tool extract-rpu`. False returns are counted as failures but still emitted.
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

        let startCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]

        // MP4 hvcC keeps VPS/SPS/PPS out-of-band; emit them once as Annex-B so dovi_tool's parser can walk the stream.
        if let cp = stream.pointee.codecpar,
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
                if elType == nil {
                    elType = DoviRpuConverter.enhancementLayerType(packet)
                }
                if DoviRpuConverter.convertPacketToProfile81(packet) {
                    conversions += 1
                } else {
                    failures += 1
                }
                if let data = packet.pointee.data, packet.pointee.size > 4 {
                    let size = Int(packet.pointee.size)
                    var off = 0
                    while off + 4 <= size {
                        var len = 0
                        for i in 0..<4 { len = (len << 8) | Int(data[off + i]) }
                        let nalStart = off + 4
                        if len == 0 || nalStart + len > size { break }
                        handle.write(Data(startCode))
                        handle.write(Data(bytes: data + nalStart, count: len))
                        off = nalStart + len
                    }
                }
            }

            av_packet_unref(packet)
            av_packet_free_safe(packet)
        }

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
