import Testing
import Foundation
@testable import AetherEngine

/// Unit tests for the `LoadOptions.confirmAtmos` session pass (#214 follow-up): which tracks earn a
/// bounded decode, and how a confirmation survives the republishes that rebuild `audioTracks` mid-session.
/// The decode itself is covered by `AtmosDetectionOptionsTests` / `AtmosDetectionProbeIntegrationTests`.
@Suite("Atmos confirmation: candidate selection and ledger application")
struct AtmosConfirmationTests {

    private func track(
        id: Int, codec: String = "eac3", isAtmos: Bool = false, isExternal: Bool = false
    ) -> TrackInfo {
        TrackInfo(
            id: id, name: "Track \(id)", codec: codec, language: "eng", channels: 6,
            bitrate: 768_000, isDefault: id == 0, isAtmos: isAtmos, isExternal: isExternal
        )
    }

    // MARK: - atmosConfirmationCandidates

    @Test("only E-AC-3 tracks are candidates")
    func onlyEAC3IsACandidate() {
        let tracks = [
            track(id: 1, codec: "eac3"), track(id: 2, codec: "ac3"), track(id: 3, codec: "aac"),
            track(id: 4, codec: "truehd"), track(id: 5, codec: "dts"),
        ]
        #expect(AetherEngine.atmosConfirmationCandidates(in: tracks) == [1])
    }

    @Test("a codec label from a container that upper-cases still matches")
    func codecMatchIsCaseInsensitive() {
        #expect(AetherEngine.atmosConfirmationCandidates(in: [track(id: 2, codec: "EAC3")]) == [2])
    }

    @Test("a track the base probe already marked Atmos is not re-scanned")
    func alreadyConfirmedIsSkipped() {
        let tracks = [track(id: 1, isAtmos: true), track(id: 2)]
        #expect(AetherEngine.atmosConfirmationCandidates(in: tracks) == [2])
    }

    @Test("host-registered external tracks are never candidates")
    func externalTracksAreSkipped() {
        // 100_000 == AetherEngine.externalSubtitleTrackIDBase, inlined because that constant is MainActor-isolated.
        let tracks = [track(id: 100_000, isExternal: true), track(id: 1)]
        #expect(AetherEngine.atmosConfirmationCandidates(in: tracks) == [1])
    }

    @Test("a source with no E-AC-3 at all yields no candidates, so no pass is armed")
    func noEAC3MeansNoWork() {
        #expect(AetherEngine.atmosConfirmationCandidates(in: [track(id: 1, codec: "aac")]).isEmpty)
        #expect(AetherEngine.atmosConfirmationCandidates(in: []).isEmpty)
    }

    @Test("every E-AC-3 track is scanned, not just the first, so the track menu stays consistent")
    func allEAC3TracksAreScanned() {
        let tracks = [track(id: 1), track(id: 2, codec: "ac3"), track(id: 3), track(id: 4)]
        #expect(AetherEngine.atmosConfirmationCandidates(in: tracks) == [1, 3, 4])
    }

    @Test("an id that is not a real AVStream index is dropped rather than trapping")
    func synthenticIdsAreDropped() {
        let tracks = [track(id: -1), track(id: Int(Int32.max) + 1), track(id: 2)]
        #expect(AetherEngine.atmosConfirmationCandidates(in: tracks) == [2])
    }

    // MARK: - applyingConfirmedAtmos (the ledger)

    @Test("the ledger flips exactly the confirmed streams on a republished list")
    func ledgerFlipsConfirmedStreams() {
        let republished = [track(id: 1), track(id: 2), track(id: 3)]
        let out = AetherEngine.applyingConfirmedAtmos(to: republished, confirmed: [1, 3])
        #expect(out.map(\.isAtmos) == [true, false, true])
    }

    @Test("an empty ledger leaves a republished list untouched")
    func emptyLedgerIsANoOp() {
        let republished = [track(id: 1), track(id: 2)]
        let out = AetherEngine.applyingConfirmedAtmos(to: republished, confirmed: [])
        #expect(out.allSatisfy { !$0.isAtmos })
    }

    @Test("a ledger entry for a stream the new list does not carry is ignored")
    func ledgerEntryForAbsentStreamIsIgnored() {
        let republished = [track(id: 4), track(id: 5)]
        let out = AetherEngine.applyingConfirmedAtmos(to: republished, confirmed: [1])
        #expect(out.allSatisfy { !$0.isAtmos })
    }

    @Test("the ledger never clears a flag the base probe set")
    func ledgerIsAdditiveOnly() {
        let republished = [track(id: 1, isAtmos: true), track(id: 2)]
        let out = AetherEngine.applyingConfirmedAtmos(to: republished, confirmed: [2])
        #expect(out.map(\.isAtmos) == [true, true])
    }

    @Test("everything except isAtmos survives the ledger pass")
    func ledgerPreservesEveryOtherField() {
        let before = track(id: 7, codec: "eac3")
        let after = AetherEngine.applyingConfirmedAtmos(to: [before], confirmed: [7])[0]
        #expect(after.isAtmos)
        #expect(after.id == before.id)
        #expect(after.name == before.name)
        #expect(after.codec == before.codec)
        #expect(after.language == before.language)
        #expect(after.channels == before.channels)
        #expect(after.bitrate == before.bitrate)
        #expect(after.isDefault == before.isDefault)
        #expect(after.isExternal == before.isExternal)
    }

    // MARK: - LoadOptions surface

    @Test("confirmAtmos is off by default, so no existing session changes shape")
    func confirmAtmosDefaultsOff() {
        #expect(LoadOptions().confirmAtmos == false)
        #expect(LoadOptions(confirmAtmos: true).confirmAtmos == true)
    }

    // MARK: - The session pass's open profile, against real media
    //
    // The pass opens with skipStreamInfo, betting that codec_id and codec_type come off the container
    // header alone. If that bet were wrong the decode would never start and the badge would never appear,
    // so it is worth exercising against a real E-AC-3 file rather than only in the abstract.

    /// Writes the shared plain-EAC3 fixture to a temp file so the URL branch of the open is the one under test.
    private func withEAC3FixtureURL(_ body: (URL) throws -> Void) throws {
        let bytes = try #require(
            Data(base64Encoded: AtmosDetectionProbeIntegrationTests.eac3PlainBase64,
                 options: .ignoreUnknownCharacters))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("atmos-confirmation-\(UUID().uuidString).mp4")
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }

    @Test("the confirmation open resolves the E-AC-3 stream without find_stream_info, and decodes it")
    func openProfileReachesTheDecoder() throws {
        try withEAC3FixtureURL { url in
            let demuxer = Demuxer()
            defer { demuxer.close() }
            #expect(AetherEngine.openAtmosConfirmationDemuxer(
                demuxer, url: url, reader: nil, formatHint: nil, headers: [:],
                callerProbesize: nil, callerMaxAnalyzeDuration: nil))

            let outcome = AetherEngine.detectAtmos(
                demuxer: demuxer, targetIndex: 0, options: AtmosDetectionOptions())
            // Reaching .frameDecoded proves the skipStreamInfo open still handed the decoder a usable
            // codec_id; a plain (non-JOC) track then correctly declines to confirm.
            #expect(outcome.stopReason == .frameDecoded)
            #expect(outcome.confirmedAtmos == false)
        }
    }

    @Test("an unopenable source is a silent false, never a throw into the host")
    func unopenableSourceIsSilent() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("atmos-confirmation-does-not-exist-\(UUID().uuidString).mkv")
        let demuxer = Demuxer()
        defer { demuxer.close() }
        #expect(AetherEngine.openAtmosConfirmationDemuxer(
            demuxer, url: missing, reader: nil, formatHint: nil, headers: [:],
            callerProbesize: nil, callerMaxAnalyzeDuration: nil) == false)
    }
}
