import AVFAudio
import XCTest
import AetherEngine
@testable import NuvioTV

final class PlaybackAudioTapBrokerTests: XCTestCase {
    private func buffer(at sourceTime: Double) -> AudioTapBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
        pcm.frameLength = 480
        return AudioTapBuffer(buffer: pcm, sourceTime: sourceTime)
    }

    /// Collects what a subscriber received, ending its stream first.
    @MainActor
    private func received(_ broker: PlaybackAudioTapBroker, id: UUID, stream: AsyncStream<AudioTapBuffer>) async -> [Double] {
        broker.unsubscribe(id: id)
        var times: [Double] = []
        for await buffer in stream { times.append(buffer.sourceTime) }
        return times
    }

    @MainActor
    func testABufferFromAReplacedConsumerDoesNotReachCurrentSubscribers() async {
        let broker = PlaybackAudioTapBroker(engine: nil)
        let oldGeneration = broker.consumerGeneration

        // The tap is replaced (as updateEngine does): the previous consumer's generation is stale.
        broker.teardown()
        let (id, stream) = broker.subscribe()
        XCTAssertNotEqual(broker.consumerGeneration, oldGeneration)

        // A buffer the old consumer had in flight arrives now, then one from the current consumer.
        broker.broadcast(buffer: buffer(at: 120), generation: oldGeneration)
        broker.broadcast(buffer: buffer(at: 5), generation: broker.consumerGeneration)

        let times = await received(broker, id: id, stream: stream)
        XCTAssertEqual(times, [5])
    }

    @MainActor
    func testBuffersFromTheCurrentConsumerReachEverySubscriber() async {
        let broker = PlaybackAudioTapBroker(engine: nil)
        let first = broker.subscribe()
        let second = broker.subscribe()
        let generation = broker.consumerGeneration
        broker.broadcast(buffer: buffer(at: 1), generation: generation)
        broker.broadcast(buffer: buffer(at: 2), generation: generation)

        let firstTimes = await received(broker, id: first.id, stream: first.stream)
        let secondTimes = await received(broker, id: second.id, stream: second.stream)
        XCTAssertEqual(firstTimes, [1, 2])
        XCTAssertEqual(secondTimes, [1, 2])
    }
}
