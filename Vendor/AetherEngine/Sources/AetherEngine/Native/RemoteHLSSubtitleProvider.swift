import Foundation

/// #316: serves the sidecar renditions the remote-HLS subtitle proxy injects into the origin master.
///
/// It is an `HLSSegmentProvider` that owns no media at all. The A/V variants in the rewritten master
/// point straight at the origin, so AVPlayer never asks this server for a segment; only `/master.m3u8`
/// (verbatim, via `staticMasterPlaylistBody`), `/subs_{n}.m3u8` and `/subs_{n}_0.vtt` are ever fetched.
/// The single reported segment exists so `buildSubtitleMediaPlaylistText`'s whole-program shape can read
/// the program duration off the usual `segmentDuration(at:)` path (Sodalite#32) without a special case.
final class RemoteHLSSubtitleProvider: HLSSegmentProvider, @unchecked Sendable {

    /// One declared sidecar, tied back to the engine-side external track id it was registered under.
    struct Track: Sendable {
        let externalID: Int
        let source: ExternalSubtitleTrack
    }

    let tracks: [Track]
    let staticMasterPlaylistBody: String?

    /// Total program seconds, summed from the origin's own variant playlist. TARGETDURATION and the
    /// single EXTINF of every subtitle rendition are built from it.
    private let programDuration: Double
    private let stores: [NativeSubtitleCueStore]
    private let defaultHeaders: [String: String]
    /// Guards `fillTask` alone: the fill is started from the proxy's build (off the main actor) and
    /// cancelled from the engine's teardown (on it), so the handle is genuinely shared.
    private let fillLock = NSLock()
    private var fillTask: Task<Void, Never>?

    /// How long a `.vtt` fetch waits for its store to finish. AVPlayer fetches a whole-program VOD
    /// subtitle segment ONCE and never re-fetches it, so serving early means serving truncated for the
    /// rest of the session; the fill normally completes long before the rendition is ever selected.
    /// Mirrors the loopback path's budget.
    static let defaultVTTFillWaitSeconds: TimeInterval = 30
    private let vttFillWaitSeconds: TimeInterval

    init(tracks: [Track], masterBody: String, programDuration: Double,
         defaultHeaders: [String: String],
         vttFillWaitSeconds: TimeInterval = defaultVTTFillWaitSeconds) {
        self.tracks = tracks
        self.staticMasterPlaylistBody = masterBody
        self.programDuration = max(1, programDuration)
        self.defaultHeaders = defaultHeaders
        self.vttFillWaitSeconds = vttFillWaitSeconds
        self.stores = tracks.map { _ in NativeSubtitleCueStore() }
    }

    /// The renditions as the rewriter needs to declare them, in `subs_{ordinal}` order.
    static func renditions(for tracks: [Track]) -> [RemoteHLSMasterRewrite.Rendition] {
        tracks.enumerated().map { ordinal, track in
            RemoteHLSMasterRewrite.Rendition(
                ordinal: ordinal,
                name: track.source.makeTrackInfo(id: track.externalID, fallbackNumber: ordinal + 1).name,
                language: track.source.language,
                isForced: track.source.isForced,
                isSDH: track.source.isHearingImpaired)
        }
    }

    /// Decode every sidecar into its store up front, off the main actor. Same one-pass-per-container
    /// machinery the loopback path uses (#266), so a container holding several subtitle streams is read
    /// once and a single bad stream index cannot blank its siblings.
    func startFill() {
        cancelFill()
        let jobs = Self.fillJobs(tracks: tracks, stores: stores, defaultHeaders: defaultHeaders)
        guard !jobs.isEmpty else { return }
        let task = Task.detached(priority: .utility) { [jobs] in
            for job in jobs {
                if Task.isCancelled { return }
                await AetherEngine.runExternalSubtitleFill(job: job)
            }
        }
        fillLock.lock()
        fillTask = task
        fillLock.unlock()
    }

    func cancelFill() {
        fillLock.lock()
        let task = fillTask
        fillTask = nil
        fillLock.unlock()
        task?.cancel()
    }

    /// Wait for the started fill to finish. Nothing in the session waits for it, the `.vtt` handler
    /// polls the store instead; this exists so a test can assert on a finished store without racing
    /// the wall clock. `nativeSubtitleVTT`'s wait is a budget, and a budget loses under a saturated
    /// cooperative pool, where the detached decode does not get a thread at all.
    func awaitFill() async {
        await currentFillTask()?.value
    }

    /// Reading the handle stays synchronous: `NSLock` is unavailable from an async context.
    private func currentFillTask() -> Task<Void, Never>? {
        fillLock.lock()
        defer { fillLock.unlock() }
        return fillTask
    }

    /// One job per (url, headers) pair, in first-appearance order. Mirrors
    /// `AetherEngine.externalSubtitleFillJobs`, which keys off the loopback's rendition table.
    static func fillJobs(tracks: [Track],
                         stores: [NativeSubtitleCueStore],
                         defaultHeaders: [String: String]) -> [AetherEngine.ExternalSubtitleFillJob] {
        struct Key: Hashable {
            let url: URL
            let headers: [String: String]
        }
        var order: [Key] = []
        var targetsByKey: [Key: [AetherEngine.ExternalSubtitleFillJob.Target]] = [:]
        for (ordinal, track) in tracks.enumerated() where ordinal < stores.count {
            let key = Key(url: track.source.url, headers: track.source.httpHeaders ?? defaultHeaders)
            if targetsByKey[key] == nil { order.append(key) }
            targetsByKey[key, default: []].append(
                .init(streamIndex: track.source.sourceStreamIndex, store: stores[ordinal]))
        }
        return order.map {
            AetherEngine.ExternalSubtitleFillJob(url: $0.url, headers: $0.headers,
                                                 targets: targetsByKey[$0] ?? [])
        }
    }

    // MARK: - HLSSegmentProvider

    func initSegment() -> Data? { nil }
    func mediaSegment(at index: Int) -> Data? { nil }

    /// This provider owns no media, and says so: a `/seg{N}.mp4` that reaches this origin is answered 404
    /// rather than "not yet, retry", because it never will exist. The served master's only variants are
    /// the origin's own.
    var segmentCount: Int { 0 }

    /// The subtitle playlist builder derives the whole-program TARGETDURATION and EXTINF from one visible
    /// segment (Sodalite#32). Reporting it here, instead of through `segmentCount`, keeps the duration
    /// math working without also claiming a media segment exists.
    func notePlaylistBuild() -> (visibleCount: Int, firstVisible: Int, refreshCounter: Int,
                                 endlistAdded: Bool, discontinuitySequence: Int) {
        (visibleCount: 1, firstVisible: 0, refreshCounter: 0, endlistAdded: true, discontinuitySequence: 0)
    }

    func segmentDuration(at index: Int) -> Double { programDuration }
    var playlistType: HLSPlaylistType { .vod }
    var nativeSubtitleWholeProgram: Bool { true }

    /// Empty on purpose: `nativeSubtitleRenditions` only feeds the master BUILDER, and this provider
    /// serves a finished master instead. The EXT-X-MEDIA tags were written by `RemoteHLSMasterRewrite`.
    var nativeSubtitleRenditions: [(ordinal: Int, language: String?, name: String, isForced: Bool)] { [] }

    /// Whole-program WebVTT for one sidecar. Cue times are used verbatim: this bypass has no loopback
    /// producer and therefore no playlist shift, and the origin's VOD timeline starts at zero, so the
    /// sidecar's own absolute seconds already are the item axis.
    func nativeSubtitleVTT(ordinal: Int, segmentIndex: Int) -> String? {
        guard ordinal >= 0, ordinal < stores.count else { return nil }
        let store = stores[ordinal]
        let deadline = Date().addingTimeInterval(vttFillWaitSeconds)
        while !store.isFinished, Date() < deadline {
            usleep(100_000)
        }
        let cues = store.allCues()
        if !store.isFinished {
            EngineLog.emit(
                "[AetherEngine] #316: serving subtitle rendition ord=\(ordinal) before its decode finished "
                + "(\(cues.count) cue(s)); AVPlayer does not re-fetch a whole-program .vtt",
                category: .hlsServer)
        } else {
            EngineLog.emit(
                "[AetherEngine] #316: whole-program rendition ord=\(ordinal) cues=\(cues.count)",
                category: .hlsServer, level: .verbose)
        }
        return WebVTTBuilder.body(cues: cues)
    }
}
