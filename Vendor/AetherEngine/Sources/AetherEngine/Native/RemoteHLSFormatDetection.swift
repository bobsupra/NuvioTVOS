import CoreMedia
import CoreVideo

/// AetherEngine#168: dynamic-range classification for the `nativeRemoteHLS` bypass. That path hands the
/// m3u8 straight to AVPlayer and runs no libav probe, so `videoFormat` used to stay at its `.sdr` default
/// (the reporter saw `fmt=sdr` on an HDR10 4K50 stream). Instead of reopening the origin a second time
/// (a real cost against per-token IPTV origins), the dynamic range is read back from AVPlayer's already
/// parsed video-track `CMFormatDescription` at readyToPlay. This is the pure classifier feeding that read.
enum RemoteHLSFormatDetection {

    /// Dolby Vision video sample types. A DV track carries a PQ base transfer, so the subtype must be
    /// consulted before the transfer function or the badge would read HDR10.
    static let dvh1: FourCharCode = 0x64766831 // 'dvh1'
    static let dvhe: FourCharCode = 0x64766865 // 'dvhe'

    /// Map the color transfer function (and video sample type for DV) to a `VideoFormat`.
    /// `transferFunction` is the `kCMFormatDescriptionExtension_TransferFunction` value read as a String;
    /// nil / unrecognized values classify as `.sdr` so a missing or future signal never mislabels a source.
    /// HDR10+ cannot be distinguished from HDR10 without per-frame ST 2094-40 metadata, so PQ maps to
    /// `.hdr10` (the base badge); the per-frame refinement stays on the loopback path's SEI tap.
    static func videoFormat(transferFunction: String?, videoSubType: FourCharCode?) -> VideoFormat {
        if let videoSubType, videoSubType == dvh1 || videoSubType == dvhe {
            return .dolbyVision
        }
        guard let transferFunction else { return .sdr }
        if transferFunction == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String {
            return .hdr10
        }
        if transferFunction == kCVImageBufferTransferFunction_ITU_R_2100_HLG as String {
            return .hlg
        }
        return .sdr
    }

    /// Whether the nativeRemoteHLS bypass should program `preferredDisplayCriteria` for a detected format.
    /// Only an HDR range needs the panel switch that lets AVPlayer present HDR at all; SDR is presented in
    /// any panel mode, and a sole-writer host (`suppressDisplayCriteria`) is left untouched so the engine
    /// and the host never fight over the criteria. Pure so it is unit-testable.
    static func shouldApplyDisplayCriteria(format: VideoFormat, suppressDisplayCriteria: Bool) -> Bool {
        format != .sdr && !suppressDisplayCriteria
    }

    /// Video sample types the bypass can name, mapped to the libavcodec spelling the probe path publishes.
    /// Dolby Vision tags resolve to their base-layer codec ('dvh1'/'dvhe' are HEVC, 'dvav' is AVC): the DV
    /// signaling already reaches the host through `sourceVideoFormat`, so repeating it here would cost the
    /// codec row its actual answer.
    private static let codecNamesBySubType: [FourCharCode: String] = [
        0x68766331: "hevc",  // 'hvc1'
        0x68657631: "hevc",  // 'hev1'
        0x64766831: "hevc",  // 'dvh1'
        0x64766865: "hevc",  // 'dvhe'
        0x61766331: "h264",  // 'avc1'
        0x61766333: "h264",  // 'avc3'
        0x64766176: "h264",  // 'dvav'
        0x61763031: "av1",   // 'av01'
        0x76703039: "vp9",   // 'vp09'
        0x6D703476: "mpeg4", // 'mp4v'
    ]

    /// Codec name for a video sample type, in the same vocabulary `avcodec_get_name` gives the probe path,
    /// so one published field means one thing whichever path loaded the source. An unmapped type reports its
    /// FourCC: a codec we cannot name is still one the viewer is watching, and nil is reserved for "no video
    /// track at all". Pure so it is unit-testable.
    static func codecName(videoSubType: FourCharCode?) -> String? {
        guard let videoSubType else { return nil }
        if let known = codecNamesBySubType[videoSubType] { return known }
        let bytes = [
            UInt8((videoSubType >> 24) & 0xFF), UInt8((videoSubType >> 16) & 0xFF),
            UInt8((videoSubType >> 8) & 0xFF), UInt8(videoSubType & 0xFF),
        ]
        return String(bytes: bytes, encoding: .macOSRoman)
    }
}
