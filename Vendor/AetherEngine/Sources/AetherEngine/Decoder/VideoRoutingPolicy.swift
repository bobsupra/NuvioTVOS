import AetherLibavcodec
import AetherLibavutil

/// Pure codec-and-field-order routing decision extracted from AetherEngine.load's dispatch so it is
/// unit-testable. Native carries HEVC, H.264 and HW-decodable AV1; every other video codec is
/// software. The #107 rule sits on top: interlaced H.264 goes software too, so DeinterlaceFilter
/// (bwdif) can deinterlace it. tvOS AVPlayer does not deinterlace, so 1080i broadcast otherwise combs.
enum VideoRoutingPolicy {

    /// Field orders that indicate interlaced content warranting software deinterlacing.
    static let interlacedFieldOrders: Set<AVFieldOrder> = [
        AV_FIELD_TT, AV_FIELD_BB, AV_FIELD_TB, AV_FIELD_BT
    ]

    /// True when a video codec must use the software decode path (SoftwarePlaybackHost) instead of
    /// native AVPlayer. `av1Available` is `VTCapabilityProbe.av1Available` (HW AV1 decode support).
    /// #150: `spsIndicatesInterlaced` (SPS frame_mbs_only_flag == 0) breaks the tie when the demuxer's
    /// field_order probe stays UNKNOWN; a concrete PROGRESSIVE probe analyzed actual frames and wins.
    /// A false positive costs an unnecessary SW decode (deint=interlaced passes progressive frames
    /// through untouched), never a wrong deinterlace. #232 narrows that class: on a seekable VOD
    /// source the declaration is checked against decoded frames before it routes (see
    /// `InterlaceProbe` and `routesSoftwareForDeclaredInterlace`).
    ///
    /// FFmpegBuild#1: the native side is an allowlist, not a denylist. `HLSVideoEngine` refuses
    /// anything that is not HEVC / H.264 / HW-decodable AV1 (`unsupportedCodec`), so a codec that is
    /// merely absent from the software list did not fall back, it failed the load. That took every
    /// codec nobody had enumerated (qtrle, ProRes, MJPEG, Theora, the QuickTime long tail) to the one
    /// path that cannot play it, while the software path decodes them. Only `AV_CODEC_ID_NONE` stays
    /// native by default: an audio-only source probes as NONE and has no video route to get wrong.
    static func requiresSoftwarePath(
        codecID: AVCodecID,
        fieldOrder: AVFieldOrder,
        av1Available: Bool,
        spsIndicatesInterlaced: Bool = false,
        stereo3DType: AVStereo3DType? = nil
    ) -> Bool {
        switch codecID {
        case AV_CODEC_ID_NONE, AV_CODEC_ID_HEVC:
            return false
        case AV_CODEC_ID_AV1:
            return !av1Available
        case AV_CODEC_ID_H264:
            if routesSoftwareForMultiviewCarriage(codecID: codecID, stereo3DType: stereo3DType) {
                return true
            }
            return routesSoftwareForDeclaredInterlace(
                codecID: codecID, fieldOrder: fieldOrder,
                spsIndicatesInterlaced: spsIndicatesInterlaced)
        default:
            return true
        }
    }

    /// #435: H.264 that carries both stereo views inside one track, which is how a 3D Blu-ray MVC remux
    /// is muxed: Matroska StereoMode 13 / 14 (`block_lr` / `block_rl`, both eyes in one block), reported
    /// by libavformat as stream-level `AV_PKT_DATA_STEREO3D` of type `AV_STEREO3D_FRAMESEQUENCE`. The
    /// dependent view's slices reference a subset SPS the base decoder does not have, so a decoder that
    /// only knows plain H.264 has to skip them, and VideoToolbox gets no say in that: it is handed whole
    /// samples with both views' NALs inside and renders nothing (reported as black video with audio
    /// playing). libavcodec skips the extension NALs and decodes the base view, which is the left eye and
    /// exactly the 2D fallback every non-3D player shows, so the software path is the one that produces a
    /// picture. Same shape as the interlaced and High 4:2:2 rules: native on paper, no picture in practice.
    ///
    /// Only these two carriages qualify. The frame-packed modes (side by side, top / bottom, checkerboard,
    /// row or column interleaved, anaglyph) are single self-contained pictures that decode natively and
    /// keep the native route; the host, not the engine, decides whether to crop an eye out of them.
    /// HEVC is excluded on purpose: MV-HEVC is Apple's own spatial-video format, and the native path
    /// plays its base layer.
    static func routesSoftwareForMultiviewCarriage(
        codecID: AVCodecID,
        stereo3DType: AVStereo3DType?
    ) -> Bool {
        guard codecID == AV_CODEC_ID_H264 else { return false }
        return stereo3DType == AV_STEREO3D_FRAMESEQUENCE
    }

    /// #232: true when the declared-interlace rule, and only that rule, is what sends this stream to
    /// software. That is the single routing decision `InterlaceProbe` is allowed to overrule, so the
    /// load path asks this before paying for a decode sample: a codec that is software-bound anyway
    /// (MPEG-2, VC-1, AV1 without HW) must not trigger a probe whose answer changes nothing.
    static func routesSoftwareForDeclaredInterlace(
        codecID: AVCodecID,
        fieldOrder: AVFieldOrder,
        spsIndicatesInterlaced: Bool
    ) -> Bool {
        guard codecID == AV_CODEC_ID_H264 else { return false }
        if interlacedFieldOrders.contains(fieldOrder) { return true }
        return fieldOrder == AV_FIELD_UNKNOWN && spsIndicatesInterlaced
    }

    /// #150: pure extradata classifier feeding `spsIndicatesInterlaced`. Accepts Annex-B (MPEG-TS) and
    /// avcC (MP4/MKV) extradata; anything unparseable classifies as not-interlaced so a missing or
    /// malformed config never forces the software path.
    static func spsIndicatesInterlaced(extradata: [UInt8]) -> Bool {
        guard let sps = H264SPS.spsNAL(fromExtradata: extradata) else { return false }
        return H264SPS.frameMbsOnly(fromNAL: sps) == false
    }

    /// Second-stage gate (#2): a codec that passed `requiresSoftwarePath` as native (H.264 / HEVC) but whose
    /// specific format VideoToolbox cannot HARDWARE-decode must still fall back to software, or the native
    /// AVPlayer path reaches readyToPlay and then renders nothing (H.264 High 4:2:2/4:4:4/High-10, HEVC Rext
    /// on Intel Macs / older Apple TV). Pure so it is unit-testable; the impure VT probe
    /// (`VTCapabilityProbe.canHardwareDecode`) is injected as the `canHardwareDecode` closure and only runs
    /// when the gate actually consults it. Only H.264 / HEVC consult this gate; AV1 / VP9 / etc. already
    /// have their own routing above and must not be reclassified here.
    ///
    /// #176: HEVC DV Profile 5 bypasses the gate entirely. The probe builds a plain-HEVC format description
    /// from the raw hvcC, which is not what the native path plays (dvh1 + dvcC, decoded by Apple's DV
    /// decoder), so a probe rejection there is not evidence the dvh1 route fails. And P5 has no compatible
    /// base layer: libavcodec decodes its IPT-PQ-c2 signal as YCbCr (green/purple cast), so the software
    /// path is never a correct fallback for it. P7 / P8.x keep the gate; their base layer is standard
    /// Main10 that the software path decodes with correct color.
    static func forcesSoftwareForUndecodableFormat(
        codecID: AVCodecID,
        dvProfile: Int?,
        canHardwareDecode: () -> Bool
    ) -> Bool {
        switch codecID {
        case AV_CODEC_ID_HEVC where dvProfile == 5:
            return false
        case AV_CODEC_ID_H264, AV_CODEC_ID_HEVC:
            return !canHardwareDecode()
        default:
            return false
        }
    }

    /// #176 follow-up: DV variants whose only signal is IPT-PQ-c2 (no compatible base layer) cannot be
    /// color-correctly decoded by the software path: libavcodec / dav1d hand the IPT signal on as YCbCr,
    /// which renders with a green/purple cast. That is HEVC P5 and AV1 P10.0 (compat 0). P7 / P8.x /
    /// P10.1 / P10.2 / P10.4 base layers are self-contained HDR10 / SDR / HLG and stay software-eligible.
    /// Consulted after the final routing decision; a true here fails the load instead of playing wrong color
    /// (AV1 P10.0 without HW AV1 has no native fallback, HEVC P5 reaches software only off forward-only
    /// sources the native path cannot serve).
    static func softwarePathCannotRepresent(
        codecID: AVCodecID,
        dvProfile: Int?,
        dvBlCompatID: Int?
    ) -> Bool {
        switch codecID {
        case AV_CODEC_ID_HEVC:
            return dvProfile == 5
        case AV_CODEC_ID_AV1:
            return dvProfile == 10 && dvBlCompatID == 0
        default:
            return false
        }
    }
}
