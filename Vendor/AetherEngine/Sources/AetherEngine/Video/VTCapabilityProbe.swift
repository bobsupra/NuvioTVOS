import Foundation
import VideoToolbox
import CoreMedia
import AetherLibavcodec
import AetherLibavutil

/// Cached VTIsHardwareDecodeSupported probe after VTRegisterSupplementalVideoDecoderIfAvailable. Cached on first access; registration is idempotent.
enum VTCapabilityProbe {

    /// A value snapshot of the codec fields needed by the VideoToolbox probe.
    ///
    /// `AetherEngine` is main-actor isolated, but creating a throwaway
    /// `VTDecompressionSession` can enter the system decoder service and block
    /// for hundreds of milliseconds on a cold 4K device. Copy the small C
    /// record before hopping off the actor so the expensive probe never needs
    /// to capture an `AVCodecParameters` pointer across the concurrency hop.
    struct HardwareDecodeSnapshot: Sendable {
        let codecIDRawValue: Int32
        let width: Int32
        let height: Int32
        let extradata: [UInt8]
    }

    /// True only when AVPlayer's HLS-fMP4 pipeline can HW-decode AV1. Apple's dav1d (macOS 14+/iOS 17+) is reachable via direct file playback but NOT via AVPlayer HLS in practice (verified 2026-05-14 on M1 macOS 26.4): VTIsHardwareDecodeSupported returns false, AVURLAsset.isPlayable returns false. False routes to SoftwarePlaybackHost/dav1d.
    static let av1Available: Bool = {
        if #available(tvOS 26.2, iOS 26.2, macOS 16.0, visionOS 26.2, *) {
            VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_AV1)
        }
        let supported = VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
        EngineLog.emit("[VTProbe] codec=av01 hwSupported=\(supported)", category: .engine)
        return supported
    }()

    /// What the per-format hardware probe could establish. The two consumers read an unclassifiable
    /// format in OPPOSITE directions, which is why this is three-valued rather than a Bool:
    /// - the routing gate (`canHardwareDecode`) keeps the native path, because AVPlayer's decoder reads
    ///   in-band parameter sets and Annex-B carriage that the probe cannot see from the config record;
    /// - `SoftwarePlaybackHost` must pick libavcodec, because `HardwareVideoDecoder` builds its format
    ///   description from the hvcC alone, so every unclassifiable class is one it can never open
    ///   (AE#461: a decode-path correction onto software failed `sessionCreationFailed(-4)` there).
    enum HardwareDecodeVerdict: Equatable {
        /// A hardware session was built from this exact config record.
        case supported
        /// The config record was complete and VideoToolbox refused a hardware session for it.
        case unsupported
        /// Nothing in the config record to judge (no extradata, Annex-B extradata, in-band parameter
        /// sets, format-description build failure).
        case unclassifiable(reason: String)

        /// Routing gate: only a proven refusal leaves the native path, so a probe gap never forces software.
        var keepsNativeRoute: Bool { self != .unsupported }

        /// Software host: only a proven hardware session may be served by `HardwareVideoDecoder`, which has
        /// no software fallback.
        var opensHardwareDecoder: Bool { self == .supported }
    }

    /// True when VideoToolbox can build a HARDWARE-accelerated decompression session for this exact
    /// H.264 / HEVC format (profile + chroma + bit depth encoded in the avcC / hvcC config). AV1's coarse
    /// `av1Available` gate has no per-format analogue because H.264 / HEVC decodability is profile-specific:
    /// AVPlayer accepts the HLS CODECS string for H.264 High 4:2:2 / 4:4:4 / High-10 and HEVC Rext, but the
    /// underlying VT decoder only exists on some silicon (Apple Silicon: yes; Intel Macs / older Apple TV: no
    /// HW decoder), so the item reaches readyToPlay then renders nothing (issue #2, DrHurt Intel Mac mini).
    /// Callers route `false` to the SoftwarePlaybackHost (libavcodec), which decodes these profiles fine.
    ///
    /// Returns `true` (keep the native path) whenever the format can't be classified, so a probe gap never
    /// wrongly forces the software path. Not the question `SoftwarePlaybackHost` asks, see
    /// `HardwareDecodeVerdict`.
    static func canHardwareDecode(codecpar: UnsafePointer<AVCodecParameters>) -> Bool {
        canHardwareDecode(snapshot: snapshot(codecpar: codecpar))
    }

    /// Main-actor-safe input for callers that perform the actual probe from a
    /// detached task.
    static func snapshot(codecpar: UnsafePointer<AVCodecParameters>) -> HardwareDecodeSnapshot {
        let extraSize = max(0, Int(codecpar.pointee.extradata_size))
        let extra: [UInt8]
        if extraSize > 0, let extradata = codecpar.pointee.extradata {
            extra = Array(UnsafeBufferPointer(start: extradata, count: extraSize))
        } else {
            extra = []
        }
        return HardwareDecodeSnapshot(
            codecIDRawValue: Int32(codecpar.pointee.codec_id.rawValue),
            width: codecpar.pointee.width,
            height: codecpar.pointee.height,
            extradata: extra
        )
    }

    static func canHardwareDecode(snapshot: HardwareDecodeSnapshot) -> Bool {
        hardwareDecodeVerdict(snapshot: snapshot).keepsNativeRoute
    }

    /// The throwaway session is invalidated immediately; the whole probe costs well under a millisecond and
    /// runs once per consult.
    static func hardwareDecodeVerdict(codecpar: UnsafePointer<AVCodecParameters>) -> HardwareDecodeVerdict {
        hardwareDecodeVerdict(snapshot: snapshot(codecpar: codecpar))
    }

    static func hardwareDecodeVerdict(snapshot: HardwareDecodeSnapshot) -> HardwareDecodeVerdict {
        let codecIDRawValue = snapshot.codecIDRawValue
        let vtCodecType: CMVideoCodecType
        let atomKey: String
        switch codecIDRawValue {
        case Int32(AV_CODEC_ID_H264.rawValue): vtCodecType = kCMVideoCodecType_H264; atomKey = "avcC"
        case Int32(AV_CODEC_ID_HEVC.rawValue): vtCodecType = kCMVideoCodecType_HEVC; atomKey = "hvcC"
        default: return .unclassifiable(reason: "codec outside the H.264 / HEVC gate")
        }

        func unclassifiable(_ reason: String) -> HardwareDecodeVerdict {
            EngineLog.emit(
                "[VTProbe] hardwareDecodeVerdict codec=\(codecIDRawValue) "
                + "\(snapshot.width)x\(snapshot.height) -> unclassifiable (\(reason))",
                category: .engine
            )
            return .unclassifiable(reason: reason)
        }

        guard !snapshot.extradata.isEmpty else {
            return unclassifiable("no extradata")
        }
        // avcC / hvcC config records start with a configurationVersion byte (0x01). Annex-B extradata starts
        // with a 0x00 00 (00) 01 start code and can't seed the atom-based format description.
        if snapshot.extradata[0] == 0x00 { return unclassifiable("Annex-B extradata") }

        let configBytes = snapshot.extradata
        // In-band parameter sets (`hev1` / `avc1` with an empty config record, what
        // `MP4Box ...:xps_inband` and the common Dolby-Vision MP4 recipes write): the record parses, so
        // CMVideoFormatDescriptionCreate succeeds, but VideoToolbox has no SPS to configure a decoder and
        // fails the session with -4. That says nothing about hardware support (AetherPlayer#2).
        guard configRecordCarriesParameterSets(configBytes, codecIDRawValue: codecIDRawValue) else {
            return unclassifiable("in-band parameter sets")
        }

        let configData = Data(configBytes)
        var formatDescription: CMVideoFormatDescription?
        let atoms: NSDictionary = [atomKey: configData]
        let extensions: NSDictionary = [
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: atoms,
        ]
        let fdStatus = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: vtCodecType,
            width: snapshot.width,
            height: snapshot.height,
            extensions: extensions,
            formatDescriptionOut: &formatDescription
        )
        guard fdStatus == noErr, let formatDesc = formatDescription else {
            return unclassifiable("format description failed, status=\(fdStatus)")
        }

        // Require hardware, matching HardwareVideoDecoder's session spec: a format VT can only software-decode
        // is exactly what we want to hand to libavcodec instead (predictable path, no black screen).
        let decoderSpec: NSDictionary = [
            kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true,
        ]
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDesc,
            decoderSpecification: decoderSpec,
            imageBufferAttributes: nil,  // don't constrain output; probe decodability, not pixel conversion
            outputCallback: nil,
            decompressionSessionOut: &session
        )
        if let session { VTDecompressionSessionInvalidate(session) }
        let ok = status == noErr && session != nil
        EngineLog.emit(
            "[VTProbe] canHardwareDecode codec=\(codecIDRawValue) "
            + "\(snapshot.width)x\(snapshot.height) -> \(ok) (status=\(status))",
            category: .engine
        )
        return ok ? .supported : .unsupported
    }

    /// True when the avcC / hvcC config record actually carries out-of-band parameter sets, i.e. enough
    /// for VideoToolbox to build a decoder from the record alone. `false` means "not classifiable from the
    /// record" (in-band xPS, or a record truncated before the count), never "unsupported".
    /// hvcC: `numOfArrays` is the 23rd byte. avcC: `numOfSequenceParameterSets` is the low 5 bits of the
    /// 6th. Other codecs never reach this gate.
    static func configRecordCarriesParameterSets(_ record: [UInt8], codecID: AVCodecID) -> Bool {
        configRecordCarriesParameterSets(record, codecIDRawValue: Int32(codecID.rawValue))
    }

    private static func configRecordCarriesParameterSets(_ record: [UInt8], codecIDRawValue: Int32) -> Bool {
        switch codecIDRawValue {
        case Int32(AV_CODEC_ID_HEVC.rawValue):
            guard record.count >= 23 else { return false }
            return record[22] > 0
        case Int32(AV_CODEC_ID_H264.rawValue):
            guard record.count >= 6 else { return false }
            return (record[5] & 0x1F) > 0
        default:
            return true
        }
    }

}
