import Testing
import Foundation
@testable import AetherEngine

// MARK: - Fixture

/// Real E-AC-3 JOC media, local-only: no JOC bitstream can be synthesized (FFmpeg's E-AC-3 encoder does
/// not write the flag) and none can be committed. Drop Dolby's own Online Delivery Kit test signal at
/// `Fixtures/user/ddp-joc.mp4` to run these:
///
///     curl -o Fixtures/user/ddp-joc.mp4 \
///       https://ott.dolby.com/OnDelKits/DDP/Dolby_Digital_Plus_Online_Delivery_Kit_v1.4.1/Test_Signals/muxed_streams/MP4/Example/ChID_voices_1920x1080p_25fps_h265_6ch_640kbps_ddp_joc.mp4
///
/// Without it the suite skips, the same rule the restart-witness clips follow.
private func jocFixtureURL() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/user/ddp-joc.mp4")
}

private func jocFixtureExists() -> Bool {
    FileManager.default.fileExists(atPath: jocFixtureURL().path)
}

/// The same JOC audio remuxed so it starts 70 s into the container, which is what a feature-length remux
/// with a coarse interleave looks like from the head. Regenerate from the kit signal above with:
///
///     ffmpeg -i ddp-joc.mp4 -itsoffset 70 -i ddp-joc.mp4 -map 0:v -map 1:a -c copy ddp-joc-lateaudio.mkv
private func lateAudioFixtureURL() -> URL {
    jocFixtureURL().deletingLastPathComponent().appendingPathComponent("ddp-joc-lateaudio.mkv")
}

private func lateAudioFixtureExists() -> Bool {
    FileManager.default.fileExists(atPath: lateAudioFixtureURL().path)
}

/// The positive half of the Atmos story, which no synthetic fixture can reach: a genuinely JOC track has
/// to come back confirmed, through the same open profile and the same bounded pass the session uses.
@Suite("Atmos confirmation against real E-AC-3 JOC media")
struct AtmosConfirmationJOCTests {

    @Test("a genuine JOC track is confirmed through the session's open profile",
          .enabled(if: jocFixtureExists(), "drop Dolby's DDP JOC test signal at Fixtures/user/ddp-joc.mp4"))
    func realJOCIsConfirmed() throws {
        let demuxer = Demuxer()
        defer { demuxer.close() }
        #expect(AetherEngine.openAtmosConfirmationDemuxer(
            demuxer, url: jocFixtureURL(), reader: nil, formatHint: nil, headers: [:],
            callerProbesize: nil, callerMaxAnalyzeDuration: nil))

        let targetIndex = demuxer.audioStreamIndex
        #expect(targetIndex >= 0)

        let outcome = AetherEngine.detectAtmos(
            demuxer: demuxer, targetIndex: targetIndex, options: AtmosDetectionOptions())
        #expect(outcome.stopReason == .frameDecoded)
        #expect(outcome.decodedProfile == AtmosDetectionOutcome.eac3JOCProfile)
        #expect(outcome.confirmedAtmos)
        // The whole point of the caps: a real JOC track resolves early, not at the ceiling. Dolby's kit
        // signal confirms on its first audio packet; the bound leaves room for a coarser interleave.
        #expect(outcome.packetsRead <= 4)
    }

    @Test("probeDetectingAtmos reports the track as Atmos end to end",
          .enabled(if: jocFixtureExists(), "drop Dolby's DDP JOC test signal at Fixtures/user/ddp-joc.mp4"))
    func probeDetectingAtmosConfirmsRealJOC() throws {
        let probe = try AetherEngine.probeDetectingAtmos(url: jocFixtureURL())
        let track = try #require(probe.audioTracks.first)
        #expect(track.codec == "eac3")
        #expect(track.isAtmos)
    }

    // MARK: - Audio away from the head, the case the feature actually exists for
    //
    // With the audio at the head, `avformat_find_stream_info` decodes a frame on its own and the base
    // probe is already right. Push the audio 70 s in and it stops reaching one, which is where an
    // authoritative pass earns its keep. It is also where the pass used to fail: find_stream_info leaves
    // its own packets queued, libavformat hands those back regardless of AVDISCARD_ALL, and the
    // foreign-packet fuse burned through them before a single audio byte arrived.

    @Test("the base probe cannot resolve JOC once the audio is away from the head",
          .enabled(if: lateAudioFixtureExists(), "see lateAudioFixtureURL for the ffmpeg line"))
    func baseProbeMissesLateAudioJOC() throws {
        let probe = try AetherEngine.probe(url: lateAudioFixtureURL())
        let track = try #require(probe.audioTracks.first)
        #expect(track.codec == "eac3")
        #expect(track.isAtmos == false, "if this starts passing, find_stream_info reached the audio after all")
    }

    @Test("probeDetectingAtmos still confirms JOC when the audio is 70 s into the container",
          .enabled(if: lateAudioFixtureExists(), "see lateAudioFixtureURL for the ffmpeg line"))
    func lateAudioJOCIsStillConfirmed() throws {
        let probe = try AetherEngine.probeDetectingAtmos(url: lateAudioFixtureURL())
        let track = try #require(probe.audioTracks.first)
        #expect(track.isAtmos)
    }

    @Test("the confirmation candidate list picks the JOC track off a real probe",
          .enabled(if: jocFixtureExists(), "drop Dolby's DDP JOC test signal at Fixtures/user/ddp-joc.mp4"))
    func candidateSelectionMatchesRealMedia() throws {
        let probe = try AetherEngine.probe(url: jocFixtureURL())
        let track = try #require(probe.audioTracks.first)
        // Whether the base probe already guessed right depends on whether find_stream_info happened to
        // decode a frame, which is exactly the coin flip this feature removes. Either way the session
        // must end up with the flag: already set, or set by a pass that lists the track as a candidate.
        if track.isAtmos {
            #expect(AetherEngine.atmosConfirmationCandidates(in: probe.audioTracks).isEmpty)
        } else {
            #expect(AetherEngine.atmosConfirmationCandidates(in: probe.audioTracks) == [Int32(track.id)])
        }
    }
}
