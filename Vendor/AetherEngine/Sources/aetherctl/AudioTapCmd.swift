import Foundation
import AetherEngine

// MARK: - audiotap (#95): decode the loopback audio track to a WAV, print continuity stats.

func runAudioTap(url: URL, duration: Double, outPath: String, remote: Bool = false) -> Int32 {
    EngineLog.handler = { print($0) }
    let mode = remote ? "remote-HLS" : "loopback"
    print("aetherctl audiotap (\(mode)): \(url.absoluteString) duration=\(duration)s out=\(outPath)")
    do {
        let report = remote
            ? try AudioTapProbe.runRemote(url: url, durationSeconds: duration, outPath: outPath)
            : try AudioTapProbe.run(url: url, durationSeconds: duration, outPath: outPath)
        print(report)
        return 0
    } catch {
        print("ERROR: \(error)")
        return 1
    }
}
