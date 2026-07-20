import Foundation
import AetherEngine

// MARK: - customio

/// IOReader over a local file for testing the custom-source load path. `forwardOnly` refuses SEEK_SET/CUR/END (AVSEEK_SIZE still answers). `inMemory` buffers the whole file.
final class FileHandleIOReader: IOReader, @unchecked Sendable {
    private let path: String
    private let data: Data?
    private let handle: FileHandle?
    private let totalSize: Int64
    private var position: Int64 = 0
    private let forwardOnly: Bool
    private let lock = NSLock()

    /// Counts cancel() calls to verify dynamic dispatch (cancel() is a protocol requirement, not extension-only).
    nonisolated(unsafe) static var cancelCount = 0

    init(path: String, inMemory: Bool, forwardOnly: Bool) throws {
        self.path = path
        self.forwardOnly = forwardOnly
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        self.totalSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        if inMemory {
            self.data = try Data(contentsOf: URL(fileURLWithPath: path))
            self.handle = nil
        } else {
            guard let h = FileHandle(forReadingAtPath: path) else {
                throw NSError(domain: "aetherctl", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "cannot open \(path)"])
            }
            self.data = nil
            self.handle = h
        }
    }

    func cancel() {
        FileHandleIOReader.cancelCount += 1
    }

    func makeIndependentReader() -> IOReader? {
        // Forward-only sources cannot provide a second cursor (concurrent features seek the clone).
        if forwardOnly { return nil }
        return try? FileHandleIOReader(path: path, inMemory: false, forwardOnly: false)
    }

    func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
        guard let buffer = buffer, size > 0 else { return -1 }
        lock.lock(); defer { lock.unlock() }
        let want = Int(size)
        guard position >= 0 else { return -1 }
        let chunk: Data
        if let data = data {
            let start = Int(position)
            if start >= data.count { return 0 } // EOF
            let end = min(start + want, data.count)
            chunk = data.subdata(in: start..<end)
        } else if let handle = handle {
            handle.seek(toFileOffset: UInt64(position))
            chunk = handle.readData(ofLength: want)
            if chunk.isEmpty { return 0 } // EOF
        } else {
            return -1
        }
        chunk.copyBytes(to: buffer, count: chunk.count)
        position += Int64(chunk.count)
        return Int32(chunk.count)
    }

    /// AVSEEK_SIZE queries total file size rather than repositioning.
    private static let avSeekSize: Int32 = 0x10000

    func seek(offset: Int64, whence: Int32) -> Int64 {
        lock.lock(); defer { lock.unlock() }
        if whence == Self.avSeekSize { return totalSize }
        if forwardOnly { return -1 }
        switch whence {
        case 0: position = max(0, offset)              // SEEK_SET
        case 1: position = max(0, position + offset)   // SEEK_CUR
        case 2: position = max(0, totalSize + offset)  // SEEK_END
        default: return -1
        }
        return position
    }

    func close() {
        try? handle?.close()
    }
}

/// Load media through load(source:) with a custom IOReader and print engine state once a second. Tests both native (seekable) and software (seekable or forward-only) paths.
func runCustomIO(path: String, inMemory: Bool, forwardOnly: Bool, audioOnly: Bool, reload: Bool, switchAudio: Bool, selectSubs: Bool, extract: Bool) -> Int32 {
    EngineLog.handler = { print($0) }
    var modeDesc: String
    switch (inMemory, forwardOnly) {
    case (true, true):   modeDesc = "in-memory + forward-only"
    case (true, false):  modeDesc = "in-memory"
    case (false, true):  modeDesc = "forward-only streaming file"
    case (false, false): modeDesc = "seekable file"
    }
    if audioOnly { modeDesc += " + audio-only" }
    print("aetherctl customio: \(path) (\(modeDesc))")
    let box = UncheckedBox<Int32?>(nil)
    Task { @MainActor in
        box.value = await customIOSmokeTest(path: path, inMemory: inMemory, forwardOnly: forwardOnly, audioOnly: audioOnly, reload: reload, switchAudio: switchAudio, selectSubs: selectSubs, extract: extract)
        CFRunLoopStop(CFRunLoopGetMain())
    }
    CFRunLoopRun()
    return box.value ?? 1
}

@MainActor
private func customIOSmokeTest(path: String, inMemory: Bool, forwardOnly: Bool, audioOnly: Bool, reload: Bool, switchAudio: Bool, selectSubs: Bool, extract: Bool) async -> Int32 {
    let reader: FileHandleIOReader
    do {
        reader = try FileHandleIOReader(path: path, inMemory: inMemory, forwardOnly: forwardOnly)
    } catch {
        print("VERDICT: custom source failed: reader init error: \(error.localizedDescription)")
        return 1
    }

    let engine: AetherEngine
    do {
        engine = try AetherEngine()
    } catch {
        print("VERDICT: custom source failed: engine init error: \(error.localizedDescription)")
        return 1
    }

    var options = LoadOptions()
    options.suppressDisplayCriteria = true
    options.audioOnly = audioOnly

    do {
        try await engine.load(source: .custom(reader), options: options)
    } catch {
        print("VERDICT: custom source failed: load error: \(error.localizedDescription)")
        engine.stop()
        return 1
    }

    // Capture state immediately: a short file may reach .idle before the first poll tick.
    let postLoadState = engine.state
    let postLoadTime = engine.currentTime
    print(String(format: "  post-load state=%@ t=%.2fs dur=%.2fs",
                 "\(postLoadState)", postLoadTime, engine.duration))
    if case .playing = postLoadState {
        let verdict = String(format: "VERDICT: custom source playing. currentTime=%.2fs", postLoadTime)
        print(verdict)
    } else if case .error(let msg) = postLoadState {
        print("VERDICT: custom source failed: \(msg)")
        engine.stop()
        return 1
    } else {
        let maxTicks = 8 // poll up to 8s for .playing
        var reached = false
        for _ in 0..<maxTicks {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let t = engine.currentTime
            let st = engine.state
            print(String(format: "  state=%@ t=%.2fs", "\(st)", t))
            switch st {
            case .playing:
                let verdict = String(format: "VERDICT: custom source playing. currentTime=%.2fs", t)
                print(verdict)
                reached = true
            case .error(let msg):
                print("VERDICT: custom source failed: \(msg)")
                engine.stop()
                return 1
            default:
                break
            }
            if reached { break }
        }
        if !reached {
            let finalTime = engine.currentTime
            let finalState = engine.state
            print("VERDICT: custom source timed out after \(maxTicks)s (state=\(finalState), t=\(String(format: "%.2f", finalTime))s)")
            engine.stop()
            return 1
        }
    }

    if reload {
        do { try await engine.reloadAtCurrentPosition() } catch {
            print("VERDICT: reload threw: \(error.localizedDescription)"); engine.stop(); return 5
        }
        try? await Task.sleep(nanoseconds: 600_000_000)
        if case .playing = engine.state {
            print("VERDICT: reload OK, still playing")
        } else {
            print("VERDICT: reload left state \(engine.state)"); engine.stop(); return 5
        }
    }
    if switchAudio {
        let current = engine.activeAudioTrackIndex
        guard let target = engine.audioTracks.map({ $0.id }).first(where: { $0 != current }) else {
            print("VERDICT: switch-audio: no second audio track to switch to (tracks=\(engine.audioTracks.map { $0.id }), active=\(String(describing: current)))")
            engine.stop(); return 6
        }
        engine.selectAudioTrack(index: target)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        if case .playing = engine.state {
            print("VERDICT: audio switch OK to id=\(target), still playing (was \(String(describing: current)))")
        } else {
            print("VERDICT: audio switch left state \(engine.state)"); engine.stop(); return 6
        }
    }
    if selectSubs {
        guard let subID = engine.subtitleTracks.first?.id else {
            print("VERDICT: select-subs: no subtitle tracks in source"); engine.stop(); return 7
        }
        engine.selectSubtitleTrack(index: subID)
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        let cueCount = engine.subtitleCues.count
        print("VERDICT: subtitle select id=\(subID), cues=\(cueCount) active=\(engine.isSubtitleActive)")
        if cueCount == 0 { print("VERDICT: select-subs FAILED: no cues produced"); engine.stop(); return 7 }
    }
    if extract {
        guard let fx = engine.makeFrameExtractor() else {
            print("VERDICT: makeFrameExtractor returned nil"); engine.stop(); return 8
        }
        if let image = await fx.thumbnail(at: 1.0, maxWidth: 320) {
            print("VERDICT: extract OK, image \(image.width)x\(image.height)")
        } else {
            print("VERDICT: extract returned nil image"); await fx.shutdown(); engine.stop(); return 8
        }
        await fx.shutdown()
    }
    engine.stop()
    // Wait for the native-path demux teardown (detached Task: Demuxer.close -> markClosed -> reader.cancel) before sampling the counter.
    try? await Task.sleep(nanoseconds: 3_500_000_000)
    print("cancel() override invocations: \(FileHandleIOReader.cancelCount)")
    return 0
}
