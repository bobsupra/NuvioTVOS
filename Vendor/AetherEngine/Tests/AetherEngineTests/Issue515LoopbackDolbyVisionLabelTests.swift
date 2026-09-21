import Foundation
import Testing
@testable import AetherEngine

/// AE#515 (split out of #493): the label a loopback session takes back from AVFoundation's own parse.
///
/// On macOS `AVPlayer.availableHDRModes` is `API_UNAVAILABLE`, so `supportsDolbyVision` is false on
/// every Mac unless the host asserts it, and `effectiveVideoFormat` clamps a Profile 5 PQ base to
/// `.hdr10`. Measured in #493 with the assertion off, on a 16" XDR: Profile 5 and Profile 8.1 both
/// strobe against Dolby's reference content, so the RPU reaches the pixels with no claim set anywhere
/// and the clamp was moving nothing but the label. The item's own sample entry is the evidence that
/// takes it back, and it is an upgrade rather than a mirror, because the same parse is right about the
/// item and wrong about the panel everywhere the platform can answer for itself.
struct Issue515LoopbackDolbyVisionLabelTests {

    private func upgrade(
        published: VideoFormat,
        source: VideoFormat = .dolbyVision,
        item: VideoFormat = .dolbyVision,
        perModeCapabilities: Bool = false
    ) -> VideoFormat? {
        AetherEngine.dolbyVisionLabelUpgrade(
            publishedFormat: published,
            sourceFormat: source,
            itemFormat: item,
            perModeCapabilitiesObservable: perModeCapabilities)
    }

    // MARK: - What it takes back

    @Test("AE#515: a clamped Dolby Vision label is upgraded from the item's dvh1 sample entry")
    func clampedDolbyVisionLabelIsUpgraded() {
        #expect(upgrade(published: .hdr10) == .dolbyVision)
    }

    @Test("AE#515: the upgrade lands once, so a label already reading Dolby Vision is not republished")
    func assertedSessionIsLeftAlone() {
        #expect(upgrade(published: .dolbyVision) == nil)
    }

    // MARK: - What the guard keeps out

    /// The clamp is right whenever the display cannot present HDR at all: macOS on an SDR monitor
    /// resolves the same source to `.sdr` through `supportsHDR10 == false`, and on tvOS a panel parked
    /// in SDR gets `.sdr` from `presentedVideoFormat`. Neither is a session whose label lost a Dolby
    /// Vision it was presenting.
    @Test("AE#515: an SDR label is the clamp being right, and stays")
    func sdrLabelStays() {
        #expect(upgrade(published: .sdr) == nil)
    }

    /// The case that rules out mirroring the `loadRemoteHLS` sink into `loadNative`. A Profile 5 master
    /// carries a `dvh1` sample entry on every panel, so an unguarded copy would relabel a tvOS session
    /// on a panel parked in SDR, or on an HDR10-only panel, as Dolby Vision. There the platform has a
    /// per-mode table and the label follows it.
    @Test("AE#515: a platform that can observe its display keeps its own answer")
    func perModeCapabilityPlatformKeepsItsAnswer() {
        #expect(upgrade(published: .hdr10, perModeCapabilities: true) == nil)
    }

    /// Profile 8.1 reports `hvc1` with the Dolby Vision configuration alongside it, and it composes on
    /// that display all the same. Nothing in the stack reports that, so `.hdr10` is the honest label and
    /// this rule does not guess past its evidence.
    @Test("AE#515: an hvc1 item leaves the label where the clamp put it")
    func hvc1ItemDoesNotUpgrade() {
        #expect(upgrade(published: .hdr10, item: .hdr10) == nil)
    }

    /// The engine's probe and AVFoundation's parse disagreeing is a packaging fault worth seeing in the
    /// log, not a label to publish: a source the probe did not call Dolby Vision has no RPU to compose.
    @Test("AE#515: a source the probe did not call Dolby Vision is not relabelled by the item alone")
    func itemParseAloneDoesNotRelabel() {
        #expect(upgrade(published: .hdr10, source: .hdr10) == nil)
    }

    /// Boundary, deliberately drawn where the measurement stops. A Profile 8.4 HLG base clamps to
    /// `.hlg`, and an HDR10+ payload can upgrade a Profile 8 base to `.hdr10Plus` before the item parse
    /// arrives. Neither was measured on a macOS display, and in practice the order settles it: this
    /// upgrade runs at `readyToPlay`, the T.35 one on the SEI tap during playback, and each blocks the
    /// other by its own guard.
    @Test("AE#515: only the PQ clamp is taken back, the HLG and HDR10+ labels are not")
    func onlyThePQClampIsTakenBack() {
        #expect(upgrade(published: .hlg) == nil)
        #expect(upgrade(published: .hdr10Plus) == nil)
    }
}
