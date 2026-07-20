import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AetherEngine

// MARK: - extract

/// Bridge an async call to the synchronous CLI via semaphore.
private func runBlocking<T: Sendable>(_ work: @escaping @Sendable () async -> T) -> T {
    let semaphore = DispatchSemaphore(value: 0)
    let box = UncheckedBox<T?>(nil)
    Task {
        box.value = await work()
        semaphore.signal()
    }
    semaphore.wait()
    return box.value!
}

private func writePNG(_ image: CGImage, to path: String) -> Bool {
    let url = URL(fileURLWithPath: path)
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else { return false }
    CGImageDestinationAddImage(dest, image, nil)
    return CGImageDestinationFinalize(dest)
}

func runExtract(url: URL, at seconds: Double, mode: FrameMode, loops: Int, maxWidth: Int) -> Int32 {
    EngineLog.handler = { print($0) }
    print("aetherctl extract: \(url.absoluteString) at=\(seconds)s mode=\(mode) loops=\(loops)")
    print("")

    let extractor = FrameExtractor(url: url, httpHeaders: [:])

    var produced = 0
    let start = Date()
    let effectiveLoops = max(1, loops)
    for i in 0..<effectiveLoops {
        // 8 distinct 1s buckets defeat cache short-circuiting (snapshot cache holds only 2 entries).
        let pos = seconds + Double(i % 8) * 1.0
        let image: CGImage? = runBlocking {
            switch mode {
            case .thumbnail: return await extractor.thumbnail(at: pos, maxWidth: maxWidth)
            case .snapshot:  return await extractor.snapshot(at: pos, maxSize: nil)
            }
        }
        if let image {
            produced += 1
            if i == 0 {
                let out = "/tmp/aetherctl-extract-\(mode).png"
                if writePNG(image, to: out) {
                    print("Wrote \(image.width)x\(image.height) -> \(out)")
                } else {
                    print("ERROR: could not write \(out)")
                }
            }
        } else {
            print("Frame \(i) [\(mode)] at \(pos)s: (nil)")
        }
    }
    let elapsed = Date().timeIntervalSince(start)

    // Deterministic teardown so `leaks --atExit` sees a fully released context.
    runBlocking { await extractor.shutdown() }

    print("")
    print("=== EXTRACT RESULT ===")
    print("Frames produced:  \(produced)/\(effectiveLoops)")
    print("Elapsed:          \(String(format: "%.2f", elapsed))s")
    print("Avg per frame:    \(String(format: "%.1f", elapsed / Double(effectiveLoops) * 1000))ms")
    print("======================")
    return produced > 0 ? 0 : 1
}
