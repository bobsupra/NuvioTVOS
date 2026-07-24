import Foundation

/// The real playback ceiling for the Apple TV model this process is running
/// on, used to keep `SmartPlaybackSelector` (see `DetailsScreen.swift`) from
/// auto-picking — or even offering — a source the hardware cannot actually
/// decode.
///
/// ## Why this exists
///
/// Apple TV HD (`AppleTV5,3`, A8 SoC, 2015) has no hardware HEVC decoder at
/// all — Apple's HEVC media engine shipped starting with A9 — and its video
/// output is capped at 1080p SDR. When it's handed a 4K and/or Dolby
/// Vision/HDR source, AetherEngine falls back to software-decoding it, which
/// saturates the CPU. Verified on physical Apple TV HD hardware: this
/// produces visibly choppy video *and* completely silent audio (the audio
/// decode thread starves rather than the video merely dropping frames), for
/// the entire runtime of playback — not an intermittent glitch.
///
/// Every other current Apple TV model (`AppleTV6,2`/`11,1`/`14,1`, the three
/// Apple TV 4K generations) has hardware HEVC and Dolby Vision/HDR support
/// and keeps an unrestricted ceiling here — this type changes nothing on
/// those devices.
///
/// ## Extending this for another product/device family
///
/// This is intentionally a plain data table keyed by `hw.machine`
/// (`"AppleTV5,3"`, not the marketing name), not per-device `#if` branches:
/// adding support for a new box, or reusing this pattern for a different
/// product line's hardware tiers, is a matter of adding one more table entry
/// with that model's real decode ceiling — everything else (identifier
/// lookup, the `isPlayable` gate, the unrestricted-by-default fallback for
/// hardware this table doesn't recognize yet) stays the same.
struct AppleTVCapability: Equatable {
    let maxResolution: Int
    let supportsHDR: Bool
    let supportsDolbyVision: Bool
    let supportsHEVCHardwareDecode: Bool
    let supportsAV1HardwareDecode: Bool

    /// No known Apple TV hardware has an AV1 decode block yet, hence `false`
    /// on every entry below — kept as an explicit field (rather than baked
    /// into `isPlayable`) so a future model can simply flip it to `true`.
    private static let unrestricted = AppleTVCapability(
        maxResolution: 2160,
        supportsHDR: true,
        supportsDolbyVision: true,
        supportsHEVCHardwareDecode: true,
        supportsAV1HardwareDecode: false
    )

    /// Keyed by `hw.machine` identifier, not marketing name. Source: Apple's
    /// published SoC media-engine specs per generation.
    private static let table: [String: AppleTVCapability] = [
        // Apple TV HD / A1625 (2015, A8). 1080p SDR ceiling; no HEVC hw decode.
        "AppleTV5,3": AppleTVCapability(
            maxResolution: 1080,
            supportsHDR: false,
            supportsDolbyVision: false,
            supportsHEVCHardwareDecode: false,
            supportsAV1HardwareDecode: false
        ),
        "AppleTV6,2": unrestricted,   // Apple TV 4K, 1st gen (2017, A10X).
        "AppleTV11,1": unrestricted,  // Apple TV 4K, 2nd gen (2021, A12).
        "AppleTV14,1": unrestricted,  // Apple TV 4K, 3rd gen (2022, A15).
    ]

    /// The capability profile for the device this process is running on.
    /// Hardware this table doesn't recognize yet (including the Simulator,
    /// whose `hw.machine` is the host Mac's architecture string) resolves to
    /// `unrestricted` — this table should only ever narrow behavior for
    /// models it has explicit, verified data for, never restrict a device by
    /// default.
    static let current: AppleTVCapability = table[hardwareIdentifier()] ?? unrestricted

    /// Whether a stream carrying these tags is expected to actually play on
    /// this device, rather than software-decode-thrash into choppy video
    /// and/or silent audio.
    func isPlayable(tags: StreamQualityTags) -> Bool {
        if tags.resolution > 0, tags.resolution > maxResolution { return false }
        if tags.isDolbyVision, !supportsDolbyVision { return false }
        if tags.isHDR, !supportsHDR { return false }
        return true
    }

    static func hardwareIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }
}
