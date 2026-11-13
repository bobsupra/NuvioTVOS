import Foundation
import AVFAudio
import AetherEngine

/// Shared, reference-counted broker for AetherEngine's decoded PCM audio tap.
///
/// Ensures multiple host features (Scene music recognition, speech transcription, audio probes)
/// can consume decoded playback audio concurrently without interfering with each other's lifecycle.
@MainActor
final class PlaybackAudioTapBroker {
    private weak var engine: AetherEngine?
    private var subscribers: [UUID: AsyncStream<AudioTapBuffer>.Continuation] = [:]
    private var consumerTask: Task<Void, Never>?
    /// Identifies the current consumer task. `installAudioTap()` finishes the previous tap's
    /// stream, so a replaced consumer still reaches its end handler; it must not tear down
    /// or reinstall the tap that replaced it.
    private var consumerGeneration: UInt64 = 0
    private var isReconnecting = false
    
    init(engine: AetherEngine?) {
        self.engine = engine
    }
    
    func updateEngine(_ engine: AetherEngine?) {
        guard self.engine !== engine else { return }
        print("[AudioTapBroker] updateEngine: \(engine != nil ? "present" : "nil") (subscribers: \(subscribers.count))")
        teardownEngineTap()
        self.engine = engine
        if !subscribers.isEmpty {
            ensureEngineTapActive()
        }
    }
    
    var hasActiveSubscribers: Bool {
        !subscribers.isEmpty
    }
    
    var hasDeliverySource: Bool {
        engine?.audioTapHasDeliverySource ?? false
    }
    
    /// Adds a subscriber and returns an AsyncStream of AudioTapBuffers with source PTS timestamps.
    func subscribe() -> (id: UUID, stream: AsyncStream<AudioTapBuffer>) {
        let id = UUID()
        print("[AudioTapBroker] New subscriber \(id) added (total: \(subscribers.count + 1))")
        let (stream, continuation) = AsyncStream.makeStream(of: AudioTapBuffer.self, bufferingPolicy: .bufferingNewest(50))
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.unsubscribe(id: id)
            }
        }
        ensureEngineTapActive()
        return (id, stream)
    }
    
    /// Unsubscribes a subscriber. If no subscribers remain, tears down the engine tap.
    func unsubscribe(id: UUID) {
        guard let continuation = subscribers.removeValue(forKey: id) else { return }
        print("[AudioTapBroker] Unsubscribed \(id) (remaining: \(subscribers.count))")
        continuation.finish()
        if subscribers.isEmpty {
            teardownEngineTap()
        }
    }
    
    /// Teardown all subscribers and release the engine tap.
    func teardown() {
        print("[AudioTapBroker] Teardown all subscribers")
        for (_, continuation) in subscribers {
            continuation.finish()
        }
        subscribers.removeAll()
        teardownEngineTap()
    }
    
    private func ensureEngineTapActive() {
        guard let engine, consumerTask == nil else {
            if engine == nil {
                print("[AudioTapBroker] ensureEngineTapActive: engine is nil")
            }
            return
        }
        
        let engineStream = engine.installAudioTap()
        guard engine.audioTapHasDeliverySource else {
            print("[AudioTapBroker] ⚠️ engine.installAudioTap: audioTapHasDeliverySource is false (no active audio pipeline)")
            return
        }
        print("[AudioTapBroker] ✅ Installed audio tap on AetherEngine (live delivery source: true)")
        
        consumerGeneration &+= 1
        let generation = consumerGeneration
        consumerTask = Task.detached(priority: .userInitiated) { [weak self, engineStream] in
            var bufferCount = 0
            for await buffer in engineStream {
                guard !Task.isCancelled else { break }
                bufferCount += 1
                #if DEBUG
                if bufferCount == 1 || bufferCount % 30 == 0 {
                    print("[AudioTapBroker] Yielded buffer #\(bufferCount): pts=\(String(format: "%.2f", buffer.sourceTime))s, frames=\(buffer.buffer.frameLength), discontinuity=\(buffer.discontinuity)")
                }
                #endif
                await self?.broadcast(buffer: buffer)
            }
            print("[AudioTapBroker] Engine tap stream ended after \(bufferCount) buffer(s)")
            await self?.handleEngineStreamEnded(generation: generation)
        }
    }
    
    private func teardownEngineTap() {
        print("[AudioTapBroker] Teardown engine tap")
        consumerGeneration &+= 1
        consumerTask?.cancel()
        consumerTask = nil
        engine?.removeAudioTap()
    }
    
    private func broadcast(buffer: AudioTapBuffer) {
        for continuation in subscribers.values {
            continuation.yield(buffer)
        }
    }
    
    private func handleEngineStreamEnded(generation: UInt64) {
        // A torn-down or replaced consumer: the current tap, if any, is not this one's.
        guard generation == consumerGeneration else { return }
        consumerTask = nil
        // If subscribers are still active, attempt to re-install if the engine has a new session
        guard !subscribers.isEmpty, let engine, engine.audioTapHasDeliverySource else {
            print("[AudioTapBroker] Stream ended and no live delivery source to re-install")
            return
        }
        print("[AudioTapBroker] Stream ended, re-ensuring active tap for remaining subscribers...")
        ensureEngineTapActive()
    }
}
