import Foundation
import AetherEngine

// MARK: - bgaudio

#if DEBUG

/// Drive a software-path source through the full engine, then toggle the SW-path background-audio-only flag
/// (the macOS stand-in for the iOS background lifecycle) and verify audio keeps advancing while video is
/// dropped, then resumes on foreground return. Exercises the real runDemuxLoop background branch headless.
func runBackgroundAudio(url: URL, fgSeconds: Double, bgSeconds: Double) -> Int32 {
    print("aetherctl bgaudio: \(url.absoluteString) (fg=\(fgSeconds)s bg=\(bgSeconds)s)")
    // Must use CFRunLoopRun, not a blocking semaphore: AetherEngine is @MainActor, so parking the main thread
    // would deadlock the executor. The run loop also lets the host's time timer + Combine sinks fire.
    let box = UncheckedBox<Int32?>(nil)
    Task { @MainActor in
        box.value = await backgroundAudioTest(url: url, fgSeconds: fgSeconds, bgSeconds: bgSeconds)
        CFRunLoopStop(CFRunLoopGetMain())
    }
    CFRunLoopRun()
    return box.value ?? 1
}

@MainActor
private func backgroundAudioTest(url: URL, fgSeconds: Double, bgSeconds: Double) async -> Int32 {
    let engine: AetherEngine
    do {
        engine = try AetherEngine()
    } catch {
        print("engine init failed: \(error.localizedDescription)")
        return 1
    }
    do {
        try await engine.load(url: url)
    } catch {
        print("load failed: \(error.localizedDescription)")
        return 1
    }
    let backend = engine.playbackBackend
    print("backend=\(backend.rawValue) duration=\(String(format: "%.1f", engine.duration))s")
    guard backend == .software else {
        print("FAIL: expected backend .software, got \(backend.rawValue) (source did not route to the SW path)")
        return 1
    }
    engine.play()

    func vframes() -> Int { engine.softwareVideoFramesEnqueuedForTesting ?? 0 }
    func sample(_ phase: String) {
        let fp = physFootprintBytes()
        print(String(format: "  [%@] clock=%.2fs vframes=%d footprint=%.1fMB",
                     phase, engine.currentTime, vframes(), Double(fp) / 1_048_576))
    }
    func tickFor(_ seconds: Double, phase: String) async {
        let ticks = max(1, Int(seconds * 2))
        for _ in 0..<ticks {
            try? await Task.sleep(nanoseconds: 500_000_000)
            sample(phase)
        }
    }

    // Phase 1: foreground baseline (video gate active).
    print("--- foreground (video-gated) ---")
    await tickFor(fgSeconds, phase: "FG")
    let clockBeforeBg = engine.currentTime
    let vfBeforeBg = vframes()
    let fpBeforeBg = physFootprintBytes()

    // Phase 2: background-audio-only (video dropped, pace on audio renderer).
    print("--- background-audio-only (video dropped, pace on audio) ---")
    engine.setSoftwareBackgroundAudioOnlyForTesting(true)
    await tickFor(bgSeconds, phase: "BG")
    let clockAfterBg = engine.currentTime
    let vfAfterBg = vframes()
    let fpAfterBg = physFootprintBytes()

    // Phase 3: foreground again (video resumes at next keyframe).
    print("--- foreground again (video resumes) ---")
    engine.setSoftwareBackgroundAudioOnlyForTesting(false)
    await tickFor(fgSeconds, phase: "FG2")
    let vfAfterFg2 = vframes()

    engine.stop()

    let bgClockDelta = clockAfterBg - clockBeforeBg
    let bgVideoDelta = vfAfterBg - vfBeforeBg
    let bgFootprintDeltaMB = Double(fpAfterBg - fpBeforeBg) / 1_048_576
    let fg2VideoDelta = vfAfterFg2 - vfAfterBg

    print("")
    print("=== BACKGROUND AUDIO PROBE RESULT ===")
    print(String(format: "Background clock advance:    %.2fs over %.1fs wall (expect ~wall, audio alive)", bgClockDelta, bgSeconds))
    print("Background video frames:     +\(bgVideoDelta) (expect ~0, video dropped)")
    print(String(format: "Background footprint delta:  %+.1fMB (expect small, audio-paced not unbounded)", bgFootprintDeltaMB))
    print("Foreground-2 video frames:   +\(fg2VideoDelta) (expect > 0, video resumed)")
    print("=====================================")

    var ok = true
    if bgClockDelta < bgSeconds * 0.5 {
        print("FAIL: audio clock did not advance during background (\(String(format: "%.2f", bgClockDelta))s); the loop starved audio")
        ok = false
    }
    if bgVideoDelta > 2 {
        print("WARN: video frames advanced during background (+\(bgVideoDelta)); video should be dropped")
    }
    if fg2VideoDelta <= 0 {
        print("WARN: video did not resume after foreground return (+\(fg2VideoDelta))")
    }
    if ok {
        print("OK: background-audio-only kept audio advancing while video was dropped, and video resumed on return.")
        return 0
    }
    return 1
}

#else

// The bgaudio harness drives the DEBUG-only engine test hooks
// (setSoftwareBackgroundAudioOnlyForTesting / softwareVideoFramesEnqueuedForTesting),
// which are compiled out of Release, so the harness itself is DEBUG-only. Keep a
// stub so `main.swift`'s unconditional dispatch still links in Release builds.
func runBackgroundAudio(url: URL, fgSeconds: Double, bgSeconds: Double) -> Int32 {
    print("aetherctl bgaudio is a DEBUG-only harness (it needs engine test hooks that are compiled out of Release).")
    print("Rebuild in debug to use it: swift build --product aetherctl")
    return 2
}

#endif
