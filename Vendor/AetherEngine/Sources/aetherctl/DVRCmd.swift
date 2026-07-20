import Foundation
import AetherEngine

// MARK: - dvr matrix harness

/// Run the DVR matrix on one playback path (native or SW). Returns 0 if all hard invariants pass.
@MainActor
private func dvrMatrixRun(
    label: String,
    url: URL,
    seconds playSeconds: Double,
    dvrWindow: Double
) async -> Int32 {
    print("")
    print("=== DVR MATRIX: \(label) path ===")
    print("  dvrWindow=\(dvrWindow)s  playSeconds=\(playSeconds)s")

    let engine: AetherEngine
    do {
        engine = try AetherEngine()
    } catch {
        print("VERDICT: dvr \(label) FAIL: engine init error: \(error.localizedDescription)")
        return 1
    }
    defer { engine.stop() }

    var options = LoadOptions(isLive: true)
    options.suppressDisplayCriteria = true
    options.dvrWindowSeconds = dvrWindow

    do {
        try await engine.load(url: url, options: options)
    } catch {
        print("VERDICT: dvr \(label) FAIL: load error: \(error.localizedDescription)")
        return 1
    }

    print(String(format: "  post-load state=%@ isLive=%@ t=%.2fs",
                 "\(engine.state)", "\(engine.isLive)", engine.currentTime))

    let sampleInterval = 12 // sample every ~12s; inject rewind+return at two-thirds of the run
    let totalTicks = max(sampleInterval * 2 + sampleInterval, Int(playSeconds))
    let rewindTick = (totalTicks * 2) / 3
    let rewindOffset = 20.0   // seconds to rewind behind live edge

    var rewindDone = false
    var rewindEdgeBefore: Double = 0
    var seekTargetTime: Double = 0
    var postSeekTimeSamples: [Double] = []
    var postReturnEdgeSamples: [Double] = []; var postReturnBehindSamples: [Double] = []
    var atEdgeAfterReturn: Bool = false
    var seekToEdgeDone = false

    // Disk byte samples for plateau check.
    var diskSamples: [Int64] = []
    // Playback continuity tracking.
    var anyStall = false
    var prevTime = engine.currentTime

    print("  SAMPLE_HEADER: tick  state  t  edge  behind  atEdge  diskMB")

    for tick in 1...totalTicks {
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        let ct = engine.currentTime
        let edge = engine.liveEdgeTime
        let behind = engine.behindLiveSeconds
        let atEdge = engine.isAtLiveEdge
        let stateNow = engine.state
        let disk = engine.segmentCacheDiskBytes ?? 0
        diskSamples.append(disk)

        // Stall: time staying put is the failure (fixture runs faster than 1x so forward jumps are normal).
        if case .playing = stateNow {
            if ct <= prevTime && tick > 5 {
                anyStall = true
                print(String(format: "  WARNING: time did not advance tick=%d ct=%.2f", tick, ct))
            }
        } else {
            anyStall = true
            print(String(format: "  WARNING: state not .playing at tick=%d state=%@", tick, "\(stateNow)"))
        }
        prevTime = ct

        if tick % sampleInterval == 0 || tick == rewindTick || tick == totalTicks {
            print(String(format: "  SAMPLE: tick=%d state=%@ t=%.2f edge=%.2f behind=%.2f atEdge=%@ disk=%.2fMB",
                         tick, "\(stateNow)", ct, edge, behind, "\(atEdge)",
                         Double(disk) / 1_048_576.0))
        }

        if tick == rewindTick && !rewindDone {
            rewindEdgeBefore = engine.liveEdgeTime
            seekTargetTime = rewindEdgeBefore - rewindOffset
            print(String(format: "  REWIND: seeking to %.2f (edge=%.2f minus %.0fs)",
                         seekTargetTime, rewindEdgeBefore, rewindOffset))
            await engine.seek(to: seekTargetTime)
            rewindDone = true

            for si in 0..<5 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let pt = engine.currentTime
                let pb = engine.behindLiveSeconds
                postSeekTimeSamples.append(pt)
                print(String(format: "    post-seek +%ds t=%.2f behind=%.2f", si+1, pt, pb))
                prevTime = pt // reset stall-check baseline after seek
            }

            // Now return to live edge.
            print("  RETURN: seeking to live edge")
            await engine.seekToLiveEdge()
            seekToEdgeDone = true

            for ri in 0..<5 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let pt = engine.currentTime
                let pb = engine.behindLiveSeconds
                let ae = engine.isAtLiveEdge
                let re = engine.liveEdgeTime
                postReturnEdgeSamples.append(re)
                postReturnBehindSamples.append(pb)
                if ae { atEdgeAfterReturn = true }
                print(String(format: "    post-return +%ds t=%.2f edge=%.2f behind=%.2f atEdge=%@",
                             ri+1, pt, re, pb, "\(ae)"))
                prevTime = pt
            }
        }
    }

    let finalState = engine.state
    let finalTime = engine.currentTime
    let finalEdge = engine.liveEdgeTime
    let finalRange = engine.seekableLiveRange
    let finalBehind = engine.behindLiveSeconds

    print("")
    print("=== HARD INVARIANT CHECKS (\(label)) ===")

    let check1 = !anyStall
    print("  [1] Sustained .playing with advancing time: \(check1 ? "PASS" : "FAIL")")

    let check2 = finalRange != nil && (finalRange!.upperBound - finalRange!.lowerBound) > 0
    let rangeStr = finalRange.map { String(format: "%.2f...%.2f", $0.lowerBound, $0.upperBound) } ?? "nil"
    print("  [2] seekableLiveRange non-nil and advancing: \(check2 ? "PASS" : "FAIL")  (\(rangeStr))")

    // Check 3: after rewind, playhead moved back vs. the pre-rewind edge.
    var check3 = false
    var check3detail = "no rewind performed"
    if rewindDone, let firstPostSeek = postSeekTimeSamples.first {
        let movedBack = firstPostSeek < rewindEdgeBefore
        let landedNearTarget = abs(firstPostSeek - seekTargetTime) <= dvrWindow // generous: keyframe granularity 1-5s
        check3 = movedBack && landedNearTarget
        check3detail = String(format: "edgeBefore=%.2f target=%.2f landed=%.2f movedBack=%@ landedNear=%@",
                              rewindEdgeBefore, seekTargetTime, firstPostSeek,
                              "\(movedBack)", "\(landedNearTarget)")
    }
    print("  [3] After rewind, playhead moved back to near target: \(check3 ? "PASS" : "FAIL")  (\(check3detail))")

    // Check 4: after seekToLiveEdge, isAtLiveEdge or behindLiveSeconds < 10s (boolean may not flip instantly on the synthetic fixture).
    var check4 = false
    var check4detail = "no seekToLiveEdge performed"
    if seekToEdgeDone {
        let minBehindAfterReturn = postReturnBehindSamples.min() ?? finalBehind
        let behindDropped = minBehindAfterReturn < 10.0
        check4 = atEdgeAfterReturn || behindDropped
        check4detail = String(format: "atEdge=%@ minBehind=%.2f behindDropped=%@",
                              "\(atEdgeAfterReturn)", minBehindAfterReturn, "\(behindDropped)")
    }
    print("  [4] After seekToLiveEdge, isAtLiveEdge or behind < 10s: \(check4 ? "PASS" : "FAIL")  (\(check4detail))")

    // Check 5: disk bytes plateau (last-third max not much larger than first-third max).
    var check5 = true
    var check5detail = "no samples"
    if diskSamples.count >= 3 {
        let firstThird = diskSamples.prefix(diskSamples.count / 3)
        let lastThird  = diskSamples.suffix(diskSamples.count / 3)
        let firstMax = firstThird.max() ?? 0
        let lastMax  = lastThird.max()  ?? 0
        let growthMB = Double(max(0, lastMax - firstMax)) / 1_048_576.0
        check5 = growthMB < 100.0 // 100 MB tolerance for first-segment warm-up spike
        check5detail = String(format: "firstMax=%.2fMB lastMax=%.2fMB growth=%.2fMB",
                              Double(firstMax) / 1_048_576.0,
                              Double(lastMax)  / 1_048_576.0,
                              growthMB)
    }
    print("  [5] Disk bytes not unbounded (plateau): \(check5 ? "PASS" : "FAIL")  (\(check5detail))")

    print("")
    print("=== INFO (device-verify) metrics (\(label)) ===")

    // RSS slope is unreliable off-device on macOS.
    let phys = physFootprintBytes()
    let res  = residentBytes()
    print(String(format: "  INFO (device-verify): phys_footprint=%.1fMB  resident=%.1fMB",
                 phys >= 0 ? Double(phys) / 1_048_576.0 : -1,
                 res  >= 0 ? Double(res)  / 1_048_576.0 : -1))
    print("  INFO (device-verify): macOS phys_footprint ~7-8GB VM does NOT map to tvOS jetsam; verify on device.")

    if !postSeekTimeSamples.isEmpty {
        let minBehind = postReturnBehindSamples.min().map { String(format: "%.2f", $0) } ?? "n/a"
        print("  INFO (device-verify): behindLiveSeconds post-seek min=\(minBehind)s (unreliable on synthetic fixture; verify on device.)")
    }

    let hardPassed = check1 && check2 && check3 && check4 && check5
    print("")
    print("=== SUMMARY (\(label)) ===")
    print(String(format: "  finalState=%@  t=%.2fs  edge=%.2fs  behind=%.2fs  range=%@",
                 "\(finalState)", finalTime, finalEdge, finalBehind, rangeStr))
    if hardPassed {
        print("VERDICT: dvr \(label) OK")
    } else {
        var failed: [String] = []
        if !check1 { failed.append("[1] sustained play") }
        if !check2 { failed.append("[2] seekableLiveRange") }
        if !check3 { failed.append("[3] rewind landed near target") }
        if !check4 { failed.append("[4] seekToLiveEdge") }
        if !check5 { failed.append("[5] disk plateau") }
        print("VERDICT: dvr \(label) FAIL -- failed hard checks: \(failed.joined(separator: ", "))")
    }
    return hardPassed ? 0 : 1
}

func runDVR(path: String, seconds: Double, dvrWindow: Double) -> Int32 {
    EngineLog.handler = { print($0) }

    let nativeSeed = "Fixtures/user/h264-ts-sample.ts"
    let swSeed     = "Fixtures/user/h264-aac-ts-sample.ts"
    let fm = FileManager.default

    print("aetherctl dvr: path=\(path) seconds=\(seconds) dvrWindow=\(dvrWindow)s")

    let runNative = path == "native" || path == "both"
    var runSW     = path == "sw"     || path == "both"

    if runSW && !fm.fileExists(atPath: swSeed) {
        let genCmd = "ffmpeg -i \(nativeSeed) -f lavfi -t 5 "
            + "-i \"sine=frequency=440:sample_rate=48000\" "
            + "-map 0:v:0 -map 1:a:0 -c:v copy -c:a aac -b:a 96k "
            + "-muxrate 2M -f mpegts \(swSeed) -y"
        if path == "sw" {
            print("SW leg skipped: no a/v seed at \(swSeed); generate with:")
            print("  \(genCmd)")
            return 1
        } else { // both
            print("SW leg skipped: no a/v seed at \(swSeed); generate with:")
            print("  \(genCmd)")
            runSW = false
        }
    }

    var overallRC: Int32 = 0

    if runNative {
        guard fm.fileExists(atPath: nativeSeed) else {
            print("ERROR: native seed not found at \(nativeSeed)")
            return 1
        }

        let fixture: LiveFixture
        do {
            fixture = try LiveFixture(seedPath: nativeSeed)
        } catch {
            print("ERROR: LiveFixture (native) init: \(error)")
            return 1
        }
        let liveURL: URL
        do {
            liveURL = try fixture.start()
        } catch {
            print("ERROR: LiveFixture (native) start: \(error)")
            return 1
        }
        print("[native] live URL: \(liveURL.absoluteString)")

        let box = UncheckedBox<Int32?>(nil)
        Task { @MainActor in
            box.value = await dvrMatrixRun(
                label: "native",
                url: liveURL,
                seconds: seconds,
                dvrWindow: dvrWindow
            )
            CFRunLoopStop(CFRunLoopGetMain())
        }
        CFRunLoopRun()
        fixture.stop()
        if (box.value ?? 1) != 0 { overallRC = 1 }
    }

    if runSW {
        AetherEngine.setForceSoftwarePathForTesting(true)
        defer { AetherEngine.setForceSoftwarePathForTesting(false) }

        let fixture: LiveFixture
        do {
            fixture = try LiveFixture(seedPath: swSeed)
        } catch {
            print("ERROR: LiveFixture (sw) init: \(error)")
            return 1
        }
        let liveURL: URL
        do {
            liveURL = try fixture.start()
        } catch {
            print("ERROR: LiveFixture (sw) start: \(error)")
            return 1
        }
        print("[sw] live URL: \(liveURL.absoluteString)")

        let box = UncheckedBox<Int32?>(nil)
        Task { @MainActor in
            box.value = await dvrMatrixRun(
                label: "sw",
                url: liveURL,
                seconds: seconds,
                dvrWindow: dvrWindow
            )
            CFRunLoopStop(CFRunLoopGetMain())
        }
        CFRunLoopRun()
        fixture.stop()
        if (box.value ?? 1) != 0 { overallRC = 1 }
    }

    return overallRC
}
