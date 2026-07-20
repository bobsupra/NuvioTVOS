import Foundation
import AetherEngine

// MARK: - swdecode

func runSWDecode(url: URL, maxPackets: Int) -> Int32 {
    EngineLog.handler = { print($0) }
    print("aetherctl swdecode: \(url.absoluteString) (maxPackets=\(maxPackets))")
    print("")

    let result: SoftwareDecodeProbeResult
    do {
        result = try AetherEngine.swDecodeProbe(url: url, maxPackets: maxPackets)
    } catch {
        print("ERROR: \(error)")
        return 1
    }

    print("")
    print("=== SW DECODER RESULT ===")
    print("Codec:                \(result.codecName) (id=\(result.codecID))")
    print("Source resolution:    \(result.width)x\(result.height)")
    print("Decoder open:         \(result.openSucceeded ? "OK" : "FAILED")")
    if let err = result.openError {
        print("Open error:           \(err)")
    }
    print("Packets read:         \(result.packetsRead)")
    print("Packets fed (video):  \(result.packetsFedToDecoder)")
    print("Frames decoded:       \(result.framesDecoded)")
    if let fmt = result.firstFramePixelFormat {
        print("First frame pixfmt:   \(fmt)")
        print("First frame size:     \(result.firstFrameWidth)x\(result.firstFrameHeight)")
    } else {
        print("First frame:          (none decoded)")
    }
    if let err = result.firstError {
        print("First demux error:    \(err)")
    }
    print("=========================")
    print("")

    // Verdict
    if !result.openSucceeded {
        print("VERDICT: decoder open failed (libavcodec rejected the stream).")
        print("         Check FFmpegBuild --enable-decoder=\(result.codecName) +")
        print("         codec-private extradata in the source.")
        return 2
    }
    if result.framesDecoded == 0 {
        print("VERDICT: decoder opened but produced no frames from \(result.packetsFedToDecoder) packets.")
        print("         Suggests pixel-format conversion failure or no key-frame")
        print("         in the first \(result.packetsFedToDecoder) packets. Bump --frames")
        print("         if the source has a long GOP.")
        return 3
    }
    print("VERDICT: SW decode end-to-end healthy. \(result.framesDecoded) frames")
    print("         produced into \(result.firstFramePixelFormat ?? "?") pixel buffers.")
    print("         If real playback still hangs, the failure is downstream")
    print("         (SoftwarePlaybackHost frame-enqueue, AVSampleBufferDisplayLayer")
    print("         attach, audio-clock sync).")
    return 0
}
