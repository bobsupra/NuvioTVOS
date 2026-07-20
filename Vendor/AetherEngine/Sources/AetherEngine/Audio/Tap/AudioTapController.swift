import Foundation
import AVFAudio

/// #95: lifecycle owner for one audio tap. Owns the AsyncStream continuation and (on the native
/// path) the LoopbackAudioReader. One per engine; re-install replaces it. MainActor like the
/// engine itself; the yield closure it vends is Sendable and safe from any thread.
@MainActor
final class AudioTapController {

    /// Registration hook the caller uses to hand back a stop closure for whatever it started.
    typealias StartReader = (_ onStop: (@escaping () -> Void) -> Void) -> Void

    private var continuation: AsyncStream<AudioTapBuffer>.Continuation?
    private var filter: AudioTapMonotonicFilter?
    private var stopReader: (() -> Void)?
    private var torndown = false

    /// Build the stream and let the caller start its delivery source. `startReader` runs
    /// synchronously; it registers a stop closure via its callback.
    func makeStream(startReader: StartReader) -> AsyncStream<AudioTapBuffer> {
        let (stream, cont) = AsyncStream.makeStream(of: AudioTapBuffer.self,
                                                    bufferingPolicy: .bufferingNewest(64))
        continuation = cont
        filter = AudioTapMonotonicFilter(downstream: { buf in _ = cont.yield(buf) })
        startReader { [weak self] stop in self?.stopReader = stop }
        cont.onTermination = { _ in
            // Consumer cancelled (broke the for-await loop): tear down from the MainActor.
            Task { @MainActor [weak self] in self?.teardown() }
        }
        return stream
    }

    /// Thread-safe delivery closure for the reader / SW sink. Nil once torn down.
    func makeYield() -> (@Sendable (AudioTapBuffer) -> Void)? {
        guard !torndown, let filter else { return nil }
        return { buf in filter.accept(buf) }
    }

    /// True when startReader registered a running delivery source. False means nothing will
    /// ever yield (no session, no audio track): the caller finishes the stream immediately.
    var hasDeliverySource: Bool { stopReader != nil }

    func teardown() {
        guard !torndown else { return }
        torndown = true
        stopReader?()
        stopReader = nil
        continuation?.finish()
        continuation = nil
        filter = nil
    }
}
