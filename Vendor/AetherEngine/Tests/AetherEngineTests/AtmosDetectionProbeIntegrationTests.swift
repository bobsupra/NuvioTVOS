import Testing
import Foundation
import AetherLibavformat
import AetherLibavcodec
@testable import AetherEngine

/// Fixture-backed tests for the bounded EAC3/JOC decode-detection path (`AetherEngine.detectAtmos` /
/// `AetherEngine.probeDetectingAtmos`). All media below is synthesized locally (silent, sub-2KB) via the
/// `ffmpeg` CLI -- none of it is Dolby Atmos/JOC content (no such fixture is created or embedded, per the
/// task's copyrighted-media constraint). The genuinely-Atmos (`profile == 30`) case is instead covered by
/// `AtmosDetectionOptionsTests.confirmedAtmosTrueOnJOCProfile`, a pure test over a synthesized
/// `AtmosDetectionOutcome` -- this is the "test seam around the bounded decode/profile result" the task calls
/// for in lieu of a real JOC bitstream.
@Suite("AtmosDetectionProbe: bounded decode against synthesized fixtures")
struct AtmosDetectionProbeIntegrationTests {

    // MARK: - Fixtures (synthetic silence, non-Atmos, ffmpeg-generated)

    /// 0.1s stereo silence, EAC3 @ 64kbps, plain (non-JOC) -- `ffprobe` reports `profile=unknown` pre-decode,
    /// matching the exact ambiguity this feature exists to resolve. Internal rather than private because
    /// `AtmosConfirmationTests` opens the same bytes from a file URL to exercise the session pass's open profile.
    static let eac3PlainBase64 = """
    AAAAIGZ0eXBpc29tAAACAGlzb21kYnkxaXNvMm1wNDEAAAKwbW9vdgAAAGxtdmhkAAAAAAAAAAAA
    AAAAAAAD6AAAAF8AAQAAAQAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAA
    AABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAAdp0cmFrAAAAXHRraGQAAAADAAAA
    AAAAAAAAAAABAAAAAAAAAF8AAAAAAAAAAAAAAAEBAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAA
    AAAAAAAAAABAAAAAAAAAAAAAAAAAAAAkZWR0cwAAABxlbHN0AAAAAAAAAAEAAABeAAABAAABAAAA
    AAFSbWRpYQAAACBtZGhkAAAAAAAAAAAAAAAAAAC7gAAAEsBVxAAAAAAALWhkbHIAAAAAAAAAAHNv
    dW4AAAAAAAAAAAAAAABTb3VuZEhhbmRsZXIAAAAA/W1pbmYAAAAQc21oZAAAAAAAAAAAAAAAJGRp
    bmYAAAAcZHJlZgAAAAAAAAABAAAADHVybCAAAAABAAAAwXN0YmwAAABVc3RzZAAAAAAAAAABAAAA
    RWVjLTMAAAAAAAAAAQAAAAAAAAAAAAIAEAAAAAC7gAAAAAAADWRlYzMCACAEAAAAABRidHJ0AAAA
    AAABQAAAAUAAAAAAIHN0dHMAAAAAAAAAAgAAAAMAAAYAAAAAAQAAAMAAAAAcc3RzYwAAAAAAAAAB
    AAAAAQAAAAQAAAABAAAAFHN0c3oAAAAAAAABAAAAAAQAAAAUc3RjbwAAAAAAAAABAAAC4AAAAGJ1
    ZHRhAAAAWm1ldGEAAAAAAAAAIWhkbHIAAAAAAAAAAG1kaXJhcHBsAAAAAAAAAAAAAAAALWlsc3QA
    AAAlqXRvbwAAAB1kYXRhAAAAAQAAAABMYXZmNjIuMTIuMTAyAAAACGZyZWUAAAQIbWRhdAt3AH80
    h8AAIAAAAEGAAAQEBAEBAQGPnz58+fPnz58+ff86vnz58+fPnz58f86vnz58+fPnz58AAAAAA3z5
    8+bbbbbbx48ePAAAAA3z58ybbbbbbx48ePAAAAAAb58+fNttttt48ePHgAAAAb58+ZNttttt48eP
    HgAAAAAN8+fPm222228ePHjwAAAAN8+fMm222228ePHjwAAAAAG+fPnzbbbbbePHjx4AAAAG+fPm
    TbbbbbePHjx4AAAAADfPnz5tttttvHjx48AAAADfPnzJtttttvHjx48AAAAABvnz58222223jx48
    eAAAABvnz5k222223jx48eAAAAAAzg4LdwB/NIfAACAAAABBgAAEBAQBAQEBj58+fPnz58+fPn3/
    Or58+fPnz58+fH/Or58+fPnz58+fAAAAAAN8+fPm222228ePHjwAAAAN8+fMm222228ePHjwAAAA
    AG+fPnzbbbbbePHjx4AAAAG+fPmTbbbbbePHjx4AAAAADfPnz5tttttvHjx48AAAADfPnzJttttt
    vHjx48AAAAABvnz58222223jx48eAAAABvnz5k222223jx48eAAAAAA3z58+bbbbbbx48ePAAAAA
    3z58ybbbbbbx48ePAAAAAAb58+fNttttt48ePHgAAAAb58+ZNttttt48ePHgAAAAAM4OC3cAfzSH
    wAAgAAAAQYAABAQEAQEBAY+fPnz58+fPnz59/zq+fPnz58+fPnx/zq+fPnz58+fPnwAAAAADfPnz
    5tttttvHjx48AAAADfPnzJtttttvHjx48AAAAABvnz58222223jx48eAAAABvnz5k222223jx48e
    AAAAAA3z58+bbbbbbx48ePAAAAA3z58ybbbbbbx48ePAAAAAAb58+fNttttt48ePHgAAAAb58+ZN
    ttttt48ePHgAAAAAN8+fPm222228ePHjwAAAAN8+fMm222228ePHjwAAAAAG+fPnzbbbbbePHjx4
    AAAAG+fPmTbbbbbePHjx4AAAAADODgt3AH80h8AAIAAAAEGAAAQEBAEBAQGPnz58+fPnz58+ff86
    vnz58+fPnz58f86vnz58+fPnz58AAAAAA3z58+bbbbbbx48ePAAAAA3z58ybbbbbbx48ePAAAAAA
    b58+fNttttt48ePHgAAAAb58+ZNttttt48ePHgAAAAAN8+fPm222228ePHjwAAAAN8+fMm222228
    ePHjwAAAAAG+fPnzbbbbbePHjx4AAAAG+fPmTbbbbbePHjx4AAAAADfPnz5tttttvHjx48AAAADf
    PnzJtttttvHjx48AAAAABvnz58222223jx48eAAAABvnz5k222223jx48eAAAAAAzg4=
    """

    /// 0.5s stereo silence, AAC @ 96kbps -- exercises the `.notEAC3` skip path (no decoder is ever opened).
    /// Internal so `Issue222EAC3MoovPrimeTests` can mux the same bytes as a codecpar-derived sample entry.
    static let aacBase64 = """
    AAAAHGZ0eXBpc29tAAACAGlzb21pc28ybXA0MQAAA3Ntb292AAAAbG12aGQAAAAAAAAAAAAAAAAA
    AAPoAAAB9AABAAABAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAEAA
    AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAAACnXRyYWsAAABcdGtoZAAAAAMAAAAAAAAA
    AAAAAAEAAAAAAAAB9AAAAAAAAAAAAAAAAQEAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAA
    AAAAAEAAAAAAAAAAAAAAAAAAACRlZHRzAAAAHGVsc3QAAAAAAAAAAQAAAfQAAAQAAAEAAAAAAhVt
    ZGlhAAAAIG1kaGQAAAAAAAAAAAAAAAAAALuAAABhwFXEAAAAAAAtaGRscgAAAAAAAAAAc291bgAA
    AAAAAAAAAAAAAFNvdW5kSGFuZGxlcgAAAAHAbWluZgAAABBzbWhkAAAAAAAAAAAAAAAkZGluZgAA
    ABxkcmVmAAAAAAAAAAEAAAAMdXJsIAAAAAEAAAGEc3RibAAAAH5zdHNkAAAAAAAAAAEAAABubXA0
    YQAAAAAAAAABAAAAAAAAAAAAAgAQAAAAALuAAAAAAAA2ZXNkcwAAAAADgICAJQABAASAgIAXQBUA
    AAAAAXcAAAAKAgWAgIAFEZBW5QAGgICAAQIAAAAUYnRydAAAAAAAAXcAAAAKAgAAACBzdHRzAAAA
    AAAAAAIAAAAYAAAEAAAAAAEAAAHAAAAAHHN0c2MAAAAAAAAAAQAAAAEAAAAZAAAAAQAAAHhzdHN6
    AAAAAAAAAAAAAAAZAAAAFwAAAAYAAAAGAAAABgAAAAYAAAAGAAAABgAAAAYAAAAGAAAABgAAAAYA
    AAAGAAAABgAAAAYAAAAGAAAABgAAAAYAAAAGAAAABgAAAAYAAAAGAAAABgAAAAYAAAAGAAAABgAA
    ABRzdGNvAAAAAAAAAAEAAAOfAAAAGnNncGQBAAAAcm9sbAAAAAIAAAAB//8AAAAcc2JncAAAAABy
    b2xsAAAAAQAAABkAAAABAAAAYnVkdGEAAABabWV0YQAAAAAAAAAhaGRscgAAAAAAAAAAbWRpcmFw
    cGwAAAAAAAAAAAAAAAAtaWxzdAAAACWpdG9vAAAAHWRhdGEAAAABAAAAAExhdmY2Mi4xMi4xMDIA
    AAAIZnJlZQAAAK9tZGF03gIATGF2YzYyLjI4LjEwMgBCIAjBGDghEARgjBwhEARgjBwhEARgjBwh
    EARgjBwhEARgjBwhEARgjBwhEARgjBwhEARgjBwhEARgjBwhEARgjBwhEARgjBwhEARgjBwhEARg
    jBwhEARgjBwhEARgjBwhEARgjBwhEARgjBwhEARgjBwhEARgjBwhEARgjBwhEARgjBwhEARgjBwh
    EARgjBwhEARgjBw=
    """

    /// 0.1s of black video, H.264 16x16, no audio stream at all -- exercises `.noAudioTrack`.
    /// Internal so `Issue222EAC3MoovPrimeTests` can use it as the video track of a muxer under test.
    static let videoOnlyBase64 = """
    AAAAIGZ0eXBpc29tAAACAGlzb21pc28yYXZjMW1wNDEAAANdbW9vdgAAAGxtdmhkAAAAAAAAAAAA
    AAAAAAAD6AAAAHgAAQAAAQAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAA
    AABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAAod0cmFrAAAAXHRraGQAAAADAAAA
    AAAAAAAAAAABAAAAAAAAAHgAAAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAA
    AAAAAAAAAABAAAAAABAAAAAQAAAAAAAkZWR0cwAAABxlbHN0AAAAAAAAAAEAAAB4AAAEAAABAAAA
    AAH/bWRpYQAAACBtZGhkAAAAAAAAAAAAAAAAAAAyAAAACABVxAAAAAAALWhkbHIAAAAAAAAAAHZp
    ZGUAAAAAAAAAAAAAAABWaWRlb0hhbmRsZXIAAAABqm1pbmYAAAAUdm1oZAAAAAEAAAAAAAAAAAAA
    ACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAAAQAAAWpzdGJsAAAAvnN0c2QAAAAAAAAA
    AQAAAK5hdmMxAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAABAAEABIAAAASAAAAAAAAAABFUxhdmM2
    Mi4yOC4xMDIgbGlieDI2NAAAAAAAAAAAAAAAGP//AAAANGF2Y0MBZAAK/+EAF2dkAAqs2V7ARAAA
    AwAEAAADAMg8SJZYAQAGaOvjyyLA/fj4AAAAABBwYXNwAAAAAQAAAAEAAAAUYnRydAAAAAAAAL7i
    AAAAAAAAABhzdHRzAAAAAAAAAAEAAAADAAACAAAAABRzdHNzAAAAAAAAAAEAAAABAAAAKGN0dHMA
    AAAAAAAAAwAAAAEAAAQAAAAAAQAABgAAAAABAAACAAAAABxzdHNjAAAAAAAAAAEAAAABAAAAAwAA
    AAEAAAAgc3RzegAAAAAAAAAAAAAAAwAAAsUAAAAMAAAADAAAABRzdGNvAAAAAAAAAAEAAAONAAAA
    YnVkdGEAAABabWV0YQAAAAAAAAAhaGRscgAAAAAAAAAAbWRpcmFwcGwAAAAAAAAAAAAAAAAtaWxz
    dAAAACWpdG9vAAAAHWRhdGEAAAABAAAAAExhdmY2Mi4xMi4xMDIAAAAIZnJlZQAAAuVtZGF0AAAC
    rgYF//+q3EXpvebZSLeWLNgg2SPu73gyNjQgLSBjb3JlIDE2NSByMzIyMiBiMzU2MDVhIC0gSC4y
    NjQvTVBFRy00IEFWQyBjb2RlYyAtIENvcHlsZWZ0IDIwMDMtMjAyNSAtIGh0dHA6Ly93d3cudmlk
    ZW9sYW4ub3JnL3gyNjQuaHRtbCAtIG9wdGlvbnM6IGNhYmFjPTEgcmVmPTMgZGVibG9jaz0xOjA6
    MCBhbmFseXNlPTB4MzoweDExMyBtZT1oZXggc3VibWU9NyBwc3k9MSBwc3lfcmQ9MS4wMDowLjAw
    IG1peGVkX3JlZj0xIG1lX3JhbmdlPTE2IGNocm9tYV9tZT0xIHRyZWxsaXM9MSA4eDhkY3Q9MSBj
    cW09MCBkZWFkem9uZT0yMSwxMSBmYXN0X3Bza2lwPTEgY2hyb21hX3FwX29mZnNldD0tMiB0aHJl
    YWRzPTEgbG9va2FoZWFkX3RocmVhZHM9MSBzbGljZWRfdGhyZWFkcz0wIG5yPTAgZGVjaW1hdGU9
    MSBpbnRlcmxhY2VkPTAgYmx1cmF5X2NvbXBhdD0wIGNvbnN0cmFpbmVkX2ludHJhPTAgYmZyYW1l
    cz0zIGJfcHlyYW1pZD0yIGJfYWRhcHQ9MSBiX2JpYXM9MCBkaXJlY3Q9MSB3ZWlnaHRiPTEgb3Bl
    bl9nb3A9MCB3ZWlnaHRwPTIga2V5aW50PTI1MCBrZXlpbnRfbWluPTI1IHNjZW5lY3V0PTQwIGlu
    dHJhX3JlZnJlc2g9MCByY19sb29rYWhlYWQ9NDAgcmM9Y3JmIG1idHJlZT0xIGNyZj0yMy4wIHFj
    b21wPTAuNjAgcXBtaW49MCBxcG1heD02OSBxcHN0ZXA9NCBpcF9yYXRpbz0xLjQwIGFxPTE6MS4w
    MACAAAAAD2WIhAAz//727L4FNhTIwQAAAAhBmiJsQr/+wAAAAAgBnkF5Cv/EgQ==
    """

    private static func data(_ base64: String) -> Data {
        guard let d = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else {
            Issue.record("failed to decode embedded base64 fixture")
            return Data()
        }
        return d
    }

    // MARK: - detectAtmos internal seam, exercised end-to-end against real (non-Atmos) media

    @Test("plain EAC3 decodes a frame but is never confirmed Atmos (profile != 30)")
    func plainEAC3DecodesButIsNotAtmos() throws {
        let demuxer = Demuxer()
        defer { demuxer.close() }
        try demuxer.open(reader: DataIOReader(data: Self.data(Self.eac3PlainBase64)), formatHint: "mp4")

        let targetIndex = AetherEngine.atmosDecodeTargetIndex(
            options: AtmosDetectionOptions(), defaultAudioStreamIndex: demuxer.audioStreamIndex)
        #expect(targetIndex >= 0, "fixture has an audio stream")

        let outcome = AetherEngine.detectAtmos(demuxer: demuxer, targetIndex: targetIndex, options: AtmosDetectionOptions())
        #expect(outcome.stopReason == .frameDecoded)
        #expect(outcome.decodedProfile != 30)
        #expect(outcome.confirmedAtmos == false)
    }

    @Test("the scan keeps decoding past a non-JOC first frame instead of answering off packet one")
    func scanContinuesPastFirstDecodedFrame() throws {
        let demuxer = Demuxer()
        defer { demuxer.close() }
        try demuxer.open(reader: DataIOReader(data: Self.data(Self.eac3PlainBase64)), formatHint: "mp4")

        let targetIndex = AetherEngine.atmosDecodeTargetIndex(
            options: AtmosDetectionOptions(), defaultAudioStreamIndex: demuxer.audioStreamIndex)
        let outcome = AetherEngine.detectAtmos(demuxer: demuxer, targetIndex: targetIndex, options: AtmosDetectionOptions())

        // avctx->profile is assigned per frame and reset to UNKNOWN whenever the JOC flag is absent, so a
        // first-frame-only read would make the answer depend on packet one being representative.
        #expect(outcome.packetsRead > 1, "the scan must not stop at the first decoded frame")
        // Running out of source after real decodes is still a real observation, not a give-up.
        #expect(outcome.stopReason == .frameDecoded)
        #expect(outcome.confirmedAtmos == false)
    }

    @Test("a byte cap reached after real decodes still reports the observation, not the cap")
    func capAfterDecodeReportsFrameDecoded() throws {
        let demuxer = Demuxer()
        defer { demuxer.close() }
        try demuxer.open(reader: DataIOReader(data: Self.data(Self.eac3PlainBase64)), formatHint: "mp4")

        let options = AtmosDetectionOptions(maxBytes: 1)
        let targetIndex = AetherEngine.atmosDecodeTargetIndex(options: options, defaultAudioStreamIndex: demuxer.audioStreamIndex)
        let outcome = AetherEngine.detectAtmos(demuxer: demuxer, targetIndex: targetIndex, options: options)

        #expect(outcome.packetsRead == 1)
        #expect(outcome.stopReason == .frameDecoded)
        #expect(outcome.decodedProfile != nil)
        #expect(outcome.confirmedAtmos == false)
    }

    @Test("AAC audio never opens an EAC3 decoder (.notEAC3), never confirmed Atmos")
    func aacIsSkippedAsNotEAC3() throws {
        let demuxer = Demuxer()
        defer { demuxer.close() }
        try demuxer.open(reader: DataIOReader(data: Self.data(Self.aacBase64)), formatHint: "mp4")

        let targetIndex = AetherEngine.atmosDecodeTargetIndex(
            options: AtmosDetectionOptions(), defaultAudioStreamIndex: demuxer.audioStreamIndex)
        #expect(targetIndex >= 0, "fixture has an audio stream")

        let outcome = AetherEngine.detectAtmos(demuxer: demuxer, targetIndex: targetIndex, options: AtmosDetectionOptions())
        #expect(outcome.stopReason == .notEAC3)
        #expect(outcome.packetsRead == 0, "no packets are read once the codec is known not to be EAC3")
        #expect(outcome.confirmedAtmos == false)
    }

    @Test("a video-only source (no audio stream) reports .noAudioTrack, never confirmed Atmos")
    func videoOnlySourceReportsNoAudioTrack() throws {
        let demuxer = Demuxer()
        defer { demuxer.close() }
        try demuxer.open(reader: DataIOReader(data: Self.data(Self.videoOnlyBase64)), formatHint: "mp4")
        #expect(demuxer.audioStreamIndex == -1, "fixture has no audio stream")

        let targetIndex = AetherEngine.atmosDecodeTargetIndex(
            options: AtmosDetectionOptions(), defaultAudioStreamIndex: demuxer.audioStreamIndex)
        let outcome = AetherEngine.detectAtmos(demuxer: demuxer, targetIndex: targetIndex, options: AtmosDetectionOptions())
        #expect(outcome.stopReason == .noAudioTrack)
        #expect(outcome.confirmedAtmos == false)
    }

    @Test("an out-of-range explicit targetTrackID reports .noAudioTrack rather than crashing")
    func outOfRangeExplicitTargetIsTolerated() throws {
        let demuxer = Demuxer()
        defer { demuxer.close() }
        try demuxer.open(reader: DataIOReader(data: Self.data(Self.eac3PlainBase64)), formatHint: "mp4")

        let outcome = AetherEngine.detectAtmos(
            demuxer: demuxer, targetIndex: 99, options: AtmosDetectionOptions(targetTrackID: 99))
        #expect(outcome.stopReason == .noAudioTrack)
        #expect(outcome.confirmedAtmos == false)
    }

    @Test("a packet cap of 0 stops before any packet is read, never confirmed Atmos")
    func zeroPacketCapStopsImmediately() throws {
        let demuxer = Demuxer()
        defer { demuxer.close() }
        try demuxer.open(reader: DataIOReader(data: Self.data(Self.eac3PlainBase64)), formatHint: "mp4")

        let options = AtmosDetectionOptions(maxPackets: 0)
        let targetIndex = AetherEngine.atmosDecodeTargetIndex(options: options, defaultAudioStreamIndex: demuxer.audioStreamIndex)
        let outcome = AetherEngine.detectAtmos(demuxer: demuxer, targetIndex: targetIndex, options: options)
        #expect(outcome.stopReason == .packetCap)
        #expect(outcome.packetsRead == 0)
        #expect(outcome.confirmedAtmos == false)
    }

    // MARK: - Public API: probeDetectingAtmos wiring + default-probe compatibility

    @Test("probeDetectingAtmos(source:) on plain EAC3 matches probe(source:) exactly (isAtmos stays false)")
    func probeDetectingAtmosMatchesBaseProbeWhenNotConfirmed() throws {
        let bytes = Self.data(Self.eac3PlainBase64)

        let base = try AetherEngine.probe(source: .custom(DataIOReader(data: bytes), formatHint: "mp4"))
        let enriched = try AetherEngine.probeDetectingAtmos(source: .custom(DataIOReader(data: bytes), formatHint: "mp4"))

        #expect(base.audioTracks.count == enriched.audioTracks.count)
        #expect(base.audioTracks.map(\.isAtmos) == enriched.audioTracks.map(\.isAtmos))
        #expect(enriched.audioTracks.allSatisfy { $0.isAtmos == false })
        #expect(base.videoCodecID == enriched.videoCodecID)
        #expect(base.durationSeconds == enriched.durationSeconds)
    }

    @Test("probeDetectingAtmos(source:) on AAC-only media matches probe(source:) exactly")
    func probeDetectingAtmosMatchesBaseProbeForNonEAC3() throws {
        let bytes = Self.data(Self.aacBase64)

        let base = try AetherEngine.probe(source: .custom(DataIOReader(data: bytes), formatHint: "mp4"))
        let enriched = try AetherEngine.probeDetectingAtmos(source: .custom(DataIOReader(data: bytes), formatHint: "mp4"))

        #expect(base.audioTracks.map(\.codec) == enriched.audioTracks.map(\.codec))
        #expect(enriched.audioTracks.allSatisfy { $0.isAtmos == false })
    }

    @Test("probeDetectingAtmos(source:) on a video-only source does not throw and leaves audioTracks empty")
    func probeDetectingAtmosToleratesNoAudioTrack() throws {
        let bytes = Self.data(Self.videoOnlyBase64)
        let enriched = try AetherEngine.probeDetectingAtmos(source: .custom(DataIOReader(data: bytes), formatHint: "mp4"))
        #expect(enriched.audioTracks.isEmpty)
    }

    @Test("a malformed (non-media) source throws identically from probe(source:) and probeDetectingAtmos(source:)")
    func malformedSourceThrowsLikeBaseProbe() {
        let garbage = Data((0..<256).map { UInt8($0 % 256) })

        var baseThrew = false
        var enrichedThrew = false
        do { _ = try AetherEngine.probe(source: .custom(DataIOReader(data: garbage), formatHint: nil)) }
        catch { baseThrew = true }
        do { _ = try AetherEngine.probeDetectingAtmos(source: .custom(DataIOReader(data: garbage), formatHint: nil)) }
        catch { enrichedThrew = true }

        #expect(baseThrew == true)
        #expect(enrichedThrew == true)
    }

    @Test("probeDetectingAtmos(source:) never opens a decoder budget beyond what atmosDetection specifies (0-packet cap is honored end-to-end)")
    func probeDetectingAtmosHonorsExplicitZeroPacketCap() throws {
        let bytes = Self.data(Self.eac3PlainBase64)
        let enriched = try AetherEngine.probeDetectingAtmos(
            source: .custom(DataIOReader(data: bytes), formatHint: "mp4"),
            atmosDetection: AtmosDetectionOptions(maxPackets: 0)
        )
        // A 0-packet cap can never decode a frame, so isAtmos must stay exactly as the base probe left it (false).
        #expect(enriched.audioTracks.allSatisfy { $0.isAtmos == false })
    }
}
