import AVFoundation
import Testing
@testable import AetherEngine

/// AE#436: `AVPlayer.play()` is rate 1.0 by definition, so a resume used to drop the speed the host
/// had set, and a client could not hold it from outside: the engine re-issues play() from the
/// readyToPlay re-assert after an item swap, from interruption and background resume, from the #287
/// premature-end recovery, and AVKit and the remote command centre call it straight on the player.
/// The rate a resume comes back at is `AVPlayer.defaultRate` (the platform's own answer, "the rate at
/// which to start playback when play is called"), so recording it there covers every one of those
/// paths without anyone writing rate inside a resume window. The software hosts already resumed at
/// their remembered rate; what they lacked was a way for the engine to seed it across a rebuild.
@Suite("AE#436: the speed survives the transport's own resume")
@MainActor
struct Issue436ResumeRateTests {

    /// Records what the engine asks a transport to do, without an AVPlayer or a session behind it.
    private final class StubTransport: TransportControllable {
        var played = 0
        var paused = 0
        var rates: [Float] = []
        var resumeRates: [Float] = []
        var volume: Float = 1.0
        func play() { played += 1 }
        func pause() { paused += 1 }
        func setRate(_ rate: Float) { rates.append(rate) }
        func setResumeRate(_ rate: Float) { resumeRates.append(rate) }
    }

    // MARK: - The native paths, where the platform holds the memory

    @Test("a speed set on the video host is what a later play() starts at")
    func nativeVideoHostRemembersTheSpeed() {
        let host = NativeAVPlayerHost()
        host.setRate(1.5)
        #expect(host.avPlayer.defaultRate == 1.5)

        // A pause is not a speed: the resume rate must survive it, or the resume is 1.0 again.
        host.pause()
        #expect(host.avPlayer.defaultRate == 1.5)
    }

    @Test("setRate(0) is a pause and does not become the rate a resume returns to")
    func zeroIsNotASpeed() {
        let host = NativeAVPlayerHost()
        host.setRate(1.5)
        host.setRate(0)
        #expect(host.avPlayer.defaultRate == 1.5)
        #expect(!host.transportIntentIsPlaying)

        let audio = AudioAVPlayerHost()
        audio.setRate(1.25)
        audio.setRate(0)
        #expect(audio.avPlayer.defaultRate == 1.25)
    }

    @Test("seeding the resume rate never asserts play")
    func seedingDoesNotStartPlayback() {
        let host = NativeAVPlayerHost()
        host.setResumeRate(2.0)
        #expect(host.avPlayer.defaultRate == 2.0)
        #expect(host.avPlayer.rate == 0)
        #expect(!host.transportIntentIsPlaying)

        let audio = AudioAVPlayerHost()
        audio.setResumeRate(2.0)
        #expect(audio.avPlayer.defaultRate == 2.0)
        #expect(audio.avPlayer.rate == 0)
    }

    @Test("a zero seed is ignored: it would make the next play() a no-op")
    func zeroSeedIsIgnored() {
        let host = NativeAVPlayerHost()
        host.setRate(1.75)
        host.setResumeRate(0)
        #expect(host.avPlayer.defaultRate == 1.75)
    }

    // MARK: - The engine's memory, which carries it across a rebuild

    @Test("the engine remembers the clamped speed, and never remembers a pause as one")
    func engineRemembersTheRequestedSpeed() throws {
        let engine = try AetherEngine()
        engine.setRate(1.5)
        #expect(engine.desiredRate == 1.5)

        // Above the cap the host gets the clamped rate, so that is what a resume owes it too.
        engine.setRate(5.0)
        #expect(engine.desiredRate == engine.maxSupportedRate)

        engine.setRate(0)
        #expect(engine.desiredRate == engine.maxSupportedRate)
    }

    @Test("a rebuilt host is seeded, not played, and re-clamped to its own ceiling")
    func rebuiltHostIsSeeded() throws {
        let engine = try AetherEngine()
        let stub = StubTransport()

        engine.desiredRate = 3.0
        engine.applyDesiredRate(to: stub)
        // 3.0 is the audio-only ceiling; an idle engine reports the video one, and the seed follows it.
        #expect(stub.resumeRates == [engine.maxSupportedRate])
        #expect(stub.played == 0 && stub.rates.isEmpty,
                "seeding a rebuilt host must not assert play or re-rate it")

        // A new item seeds 1.0 rather than seeding nothing: both AVPlayer hosts are reused across
        // loads and carry their resume rate on the player, so "no speed set" has to be written.
        engine.desiredRate = nil
        engine.applyDesiredRate(to: stub)
        #expect(stub.resumeRates.last == 1.0)
    }

    @Test("a reused host does not carry the previous item's speed into the next one")
    func reusedHostIsResetForANewItem() throws {
        let engine = try AetherEngine()
        let host = NativeAVPlayerHost()
        host.setRate(1.5)
        #expect(host.avPlayer.defaultRate == 1.5)

        // What `load` does for a source that is not the one the speed was set on.
        engine.desiredRate = nil
        engine.applyDesiredRate(to: host)
        #expect(host.avPlayer.defaultRate == 1.0)
    }

    // MARK: - What the memory belongs to

    @Test("a speed belongs to the item it was set on")
    func rateBelongsToTheItem() {
        let playing = URL(string: "https://origin.example/movie.mkv")!
        let other = URL(string: "https://origin.example/next-episode.mkv")!

        // The rebuilds a session makes on its own reopen the same source: reload at position,
        // audio-track switch, AirPlay LAN swap, background return.
        #expect(AetherEngine.rateSurvivesLoad(of: .url(playing), loadedURL: playing))
        // A different item starts at 1.0, so a host whose speed control resets per item cannot end up
        // showing 1.0 over a session still running at 1.5.
        #expect(!AetherEngine.rateSurvivesLoad(of: .url(other), loadedURL: playing))
        // Nothing loaded is a fresh session either way.
        #expect(!AetherEngine.rateSurvivesLoad(of: .url(playing), loadedURL: nil))
    }
}
