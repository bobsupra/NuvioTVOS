import Foundation
import Testing
@testable import AetherEngine

@Suite("AE#472 play intent propagation", .serialized, .timeLimit(.minutes(3)))
@MainActor
struct Issue472PlayIntentTests {
    private static let fixture = Task { try await ItemSwapStillTests.fixtureURL() }

    @Test("software demuxer follows engine pause and resume intent")
    func softwareDemuxerTracksIntent() async throws {
        let fixture = try await Self.fixture.value
        let engine = try AetherEngine()
        defer { engine.stop() }

        // The fresh engine's mirror starts true; a paused mount must set the reader's intent before
        // the detached host load can observe it.
        var intentAtHostLoad: Bool?
        engine.softwareHostLoadedForTesting = { host in
            intentAtHostLoad = host.demuxerPlayIntentForTesting
        }
        var options = LoadOptions(autoplay: false, preferredDecodePath: .software)
        try await engine.load(url: fixture, options: options)

        #expect(intentAtHostLoad == false)
        let host = try #require(engine.softwareHost)
        #expect(host.demuxerPlayIntentForTesting == false)

        engine.play()
        #expect(host.demuxerPlayIntentForTesting == true)
        engine.pause()
        #expect(host.demuxerPlayIntentForTesting == false)

        // Rebuild autostart follows the requested load intent even after this engine was paused.
        intentAtHostLoad = nil
        options.autoplay = true
        try await engine.load(url: fixture, options: options)
        #expect(intentAtHostLoad == true)
    }

    @Test("a software rebuild uses the latest preserved transport intent")
    func softwareRebuildUsesPreservedIntent() async throws {
        let fixture = try await Self.fixture.value
        let engine = try AetherEngine()
        defer { engine.stop() }
        engine.sessionPreservingReloadInFlight = true
        engine.transportIntentUnderReconstruction = false
        defer { engine.sessionPreservingReloadInFlight = false }

        var intentAtHostLoad: Bool?
        engine.softwareHostLoadedForTesting = { host in
            intentAtHostLoad = host.demuxerPlayIntentForTesting
        }
        try await engine.loadSoftware(
            url: fixture,
            startPosition: nil,
            audioSourceStreamIndex: nil,
            preopenedDemuxer: nil,
            requiresDeinterlaceWarmup: false,
            autostarts: true,
            generation: engine.loadGeneration
        )

        #expect(intentAtHostLoad == false)
    }

    @Test("play intent notification waits for restart demuxer replacement")
    func notificationSynchronizesWithDemuxerReplacement() {
        let session = HLSVideoEngine(url: URL(fileURLWithPath: "/unused/ae472.mkv"), dvModeAvailable: false)
        let oldDemuxer = Demuxer()
        let freshDemuxer = Demuxer()
        let started = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)

        session.restartLock.lock()
        session.demuxer = oldDemuxer
        DispatchQueue.global().async {
            started.signal()
            session.notifyPlayIntentChanged()
            finished.signal()
        }
        #expect(started.wait(timeout: .now() + 1) == .success)
        session.demuxer = freshDemuxer
        #expect(finished.wait(timeout: .now() + 0.05) == .timedOut)
        session.restartLock.unlock()

        #expect(finished.wait(timeout: .now() + 1) == .success)
        #expect(session.demuxer === freshDemuxer)
    }
}
