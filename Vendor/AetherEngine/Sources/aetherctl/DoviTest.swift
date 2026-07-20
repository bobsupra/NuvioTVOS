import Foundation
import AetherEngine

// MARK: - dovitest

/// Validate DoviRpuConverter.convertPacketToProfile81 against dovi_tool ground truth. Walks the HEVC stream, converts DV P7 -> P8.1, writes Annex-B to /tmp/aetherctl-dovitest.hevc.
func runDoviTest(url: URL) -> Int32 {
    let outputPath = "/tmp/aetherctl-dovitest.hevc"
    print("aetherctl dovitest: \(url.absoluteString)")
    print("output: \(outputPath)")
    print("")

    let result: DoviConvertProbeResult
    do {
        result = try AetherEngine.doviConvertProbe(url: url, outputPath: outputPath)
    } catch {
        print("ERROR: \(error)")
        return 1
    }

    guard result.videoStreamFound else {
        print("VERDICT: dovitest FAIL: no video stream in source.")
        return 2
    }

    print("=== DOVI CONVERT RESULT ===")
    print("Packets processed:    \(result.packetsProcessed)")
    print("Conversions:          \(result.conversions)")
    print("Failures:             \(result.failures)")
    print("Enhancement layer:    \(result.enhancementLayerType ?? "n/a (not profile 7)")")
    print("Output (Annex-B):     \(result.outputPath)")
    print("===========================")
    print("")

    if result.failures > 0 {
        print("VERDICT: dovitest had \(result.failures) converter failure(s).")
        print("         Validate the surviving RPUs against dovi_tool, then debug:")
        print("           dovi_tool extract-rpu -i \(outputPath) -o /tmp/host.rpu")
        print("           dovi_tool info -i /tmp/host.rpu -f 0")
        return 3
    }

    print("VERDICT: converted \(result.conversions) packet(s) to Profile 8.1.")
    print("         Validate against dovi_tool ground truth:")
    print("           dovi_tool extract-rpu -i \(outputPath) -o /tmp/host.rpu")
    print("           dovi_tool info -i /tmp/host.rpu -f 0 | grep -iE 'dovi_profile|disable_residual|rpu_data_crc32'")
    return 0
}
