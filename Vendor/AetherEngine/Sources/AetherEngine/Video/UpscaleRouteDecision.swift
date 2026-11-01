import CoreGraphics
import AetherLibavutil

/// Coded picture size plus sample aspect ratio, the geometry the upscale decision works from.
struct SourceGeometry: Equatable {
    var width: Int
    var height: Int
    var sarNum: Int
    var sarDen: Int

    /// A SAR of 0/0 or 0/x counts as 1:1.
    var effectiveSAR: (num: Int, den: Int) {
        sarNum > 0 && sarDen > 0 ? (sarNum, sarDen) : (1, 1)
    }
}

/// What the upscale stage does for one source: an optional ML pass (coded size times `mlScale`), then
/// MetalFX up to the target, which is the display aspect fitted into the display box.
struct UpscalePlan: Equatable, Sendable {
    var sourceWidth: Int
    var sourceHeight: Int
    /// nil = MetalFX only.
    var mlScale: Float?
    /// Equal to the source size when `mlScale` is nil.
    var mlOutputWidth: Int
    var mlOutputHeight: Int
    var targetWidth: Int
    var targetHeight: Int
    var displayWidth: Int
    var displayHeight: Int

    var needsMetalFX: Bool { mlOutputWidth != targetWidth || mlOutputHeight != targetHeight }
}

/// Whether a load takes the low-resolution upscale route, and if not, why. Pure so every exit is
/// unit-testable; the load asks it once and logs `logLine`.
enum UpscaleRouteDecision: Equatable {

    case taken(UpscalePlan)
    case notTaken(Reason)

    /// Every reason the route is not taken, in the order the checks run.
    enum Reason: Equatable {
        case preferenceOff
        case unsupportedOS
        case metalFXUnsupported
        case hdrOrDolbyVision
        case notEightBit420
        case geometryUnknown
        case notBelow1080p
        case displayNotLarger
        case airPlayVideoReceiver
        case demuxedAudioLive
    }

    static func decide(
        preference: Bool, osSupportsStage: Bool, metalFXSupported: Bool,
        source: SourceGeometry, isSDR: Bool, isDolbyVision: Bool, isEightBit420: Bool,
        display: CGSize, airPlayVideoReceiver: Bool, demuxedAudioLive: Bool,
        mlScaleFactors: (Int, Int) -> [Float]
    ) -> UpscaleRouteDecision {
        guard preference else { return .notTaken(.preferenceOff) }
        guard osSupportsStage else { return .notTaken(.unsupportedOS) }
        guard metalFXSupported else { return .notTaken(.metalFXUnsupported) }
        guard isSDR, !isDolbyVision else { return .notTaken(.hdrOrDolbyVision) }
        guard isEightBit420 else { return .notTaken(.notEightBit420) }
        guard source.width > 0, source.height > 0 else { return .notTaken(.geometryUnknown) }
        guard source.width < 1920, source.height < 1080 else { return .notTaken(.notBelow1080p) }
        guard let plan = makePlan(source: source, display: display, mlScaleFactors: mlScaleFactors),
              plan.targetWidth > source.width || plan.targetHeight > source.height
        else { return .notTaken(.displayNotLarger) }
        guard !airPlayVideoReceiver else { return .notTaken(.airPlayVideoReceiver) }
        guard !demuxedAudioLive else { return .notTaken(.demuxedAudioLive) }
        return .taken(plan)
    }

    /// The plan for `source` on `display`, or nil when either size is not positive. Also used to rebuild
    /// the plan when the decoded size changes mid-stream.
    static func makePlan(
        source: SourceGeometry, display: CGSize, mlScaleFactors: (Int, Int) -> [Float]
    ) -> UpscalePlan? {
        let displayW = Int(display.width.rounded(.down))
        let displayH = Int(display.height.rounded(.down))
        guard source.width > 0, source.height > 0, displayW > 0, displayH > 0 else { return nil }

        let sar = source.effectiveSAR
        let aspect = Double(source.width * sar.num) / Double(source.height * sar.den)
        var targetW = displayW
        var targetH = Int((Double(displayW) / aspect).rounded(.down))
        if targetH > displayH {
            targetH = displayH
            targetW = Int((Double(displayH) * aspect).rounded(.down))
        }
        targetW = even(min(targetW, displayW))
        targetH = even(min(targetH, displayH))
        guard targetW > 0, targetH > 0 else { return nil }

        var mlScale: Float?
        var mlW = source.width
        var mlH = source.height
        for factor in mlScaleFactors(source.width, source.height).sorted(by: >) where factor > 1 {
            let w = even(Int((Float(source.width) * factor).rounded(.down)))
            let h = even(Int((Float(source.height) * factor).rounded(.down)))
            if w <= targetW, h <= targetH {
                mlScale = factor
                mlW = w
                mlH = h
                break
            }
        }
        return UpscalePlan(
            sourceWidth: source.width, sourceHeight: source.height, mlScale: mlScale,
            mlOutputWidth: mlW, mlOutputHeight: mlH, targetWidth: targetW, targetHeight: targetH,
            displayWidth: displayW, displayHeight: displayH)
    }

    private static func even(_ value: Int) -> Int { value & ~1 }

    /// Only PQ and HLG count as HDR here; an unspecified or unknown transfer is treated as SDR.
    static func isSDR(colorTransfer: AVColorTransferCharacteristic) -> Bool {
        colorTransfer != AVCOL_TRC_SMPTE2084 && colorTransfer != AVCOL_TRC_ARIB_STD_B67
    }

    /// The stage takes 8-bit 4:2:0 decoder output only. A known pixel format decides; without one the raw
    /// sample depth does, and an unknown depth counts as not 8-bit.
    static func isEightBit420(pixelFormat: Int32, bitsPerRawSample: Int32) -> Bool {
        let format = AVPixelFormat(rawValue: pixelFormat)
        guard format != AV_PIX_FMT_NONE, let desc = av_pix_fmt_desc_get(format) else {
            return (1...8).contains(bitsPerRawSample)
        }
        let d = desc.pointee
        let excluded = UInt64(AV_PIX_FMT_FLAG_RGB) | UInt64(AV_PIX_FMT_FLAG_HWACCEL) | UInt64(AV_PIX_FMT_FLAG_PAL)
        return d.nb_components >= 3 && d.comp.0.depth == 8 && d.log2_chroma_w == 1 && d.log2_chroma_h == 1
            && d.flags & excluded == 0
    }

    /// What an in-session rebuild hands the next software host, and the status it republishes before that
    /// host's first frame. The option turned off builds no stage and publishes nothing; a stage that
    /// disabled itself stays off for the session and keeps its disabled status.
    static func forRebuild(
        sessionPlan: UpscalePlan?, optionOn: Bool, disabled: UpscaleStatus?
    ) -> (plan: UpscalePlan?, status: UpscaleStatus?) {
        guard optionOn, let sessionPlan else { return (nil, nil) }
        if let disabled { return (nil, disabled) }
        return (sessionPlan, nil)
    }

    var plan: UpscalePlan? {
        if case let .taken(plan) = self { return plan }
        return nil
    }

    /// The one diagnostic line for a load, or nil when the preference is off.
    var logLine: String? {
        switch self {
        case .notTaken(.preferenceOff):
            return nil
        case let .taken(plan):
            let ml = plan.mlScale.map {
                "ML \(String(format: "%g", $0))x to \(plan.mlOutputWidth)x\(plan.mlOutputHeight)"
            }
            let stages = [ml, plan.needsMetalFX ? "MetalFX" : nil].compactMap { $0 }.joined(separator: ", then ")
            return "[Upscale] taken: \(plan.sourceWidth)x\(plan.sourceHeight) -> "
                + "\(plan.targetWidth)x\(plan.targetHeight) (\(stages))"
        case let .notTaken(reason):
            return "[Upscale] not taken (\(reason.text))"
        }
    }
}

extension UpscaleRouteDecision.Reason {
    var text: String {
        switch self {
        case .preferenceOff: return "upscalesLowResolutionVideo is off"
        case .unsupportedOS: return "needs OS 26"
        case .metalFXUnsupported: return "MetalFX spatial scaling unsupported on this device"
        case .hdrOrDolbyVision: return "HDR or Dolby Vision source"
        case .notEightBit420: return "source is not 8-bit 4:2:0"
        case .geometryUnknown: return "source size unknown"
        case .notBelow1080p: return "source is not below 1080p"
        case .displayNotLarger: return "display is not larger than the source"
        case .airPlayVideoReceiver: return "AirPlay video receiver"
        case .demuxedAudioLive: return "live stream with demuxed audio"
        }
    }
}
