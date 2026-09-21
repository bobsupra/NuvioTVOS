import Foundation
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil

/// #407: a Matroska track written as `V_MS/VFW/FOURCC` carries no presentation timestamps at all.
/// `matroskadec` puts the block timecode on `pkt->dts` and leaves `pkt->pts` unset for such a track
/// (`if (track->ms_compat) pkt->dts = timecode; else pkt->pts = timecode;`), and that is the carriage
/// every VC-1 remux uses, because VC-1 has no native Matroska mapping.
///
/// The engine opens every source with `fflags=+genpts`, so libavformat fills the gap it finds. Its
/// reconstruction takes a following packet's DTS as this packet's PTS, which assumes decode order and
/// presentation order are the same sequence. On a stream with B pictures they are not, and what comes
/// out is a uniform `pts = dts + one frame` ladder: decode-order timestamps, monotonic and perfectly
/// even.
///
/// Nothing downstream survives that. libavcodec hands its pictures out in presentation order but each
/// one carries the timestamp of the packet it was decoded from, so a B picture wears the following P
/// picture's time and the P wears the B's. `SampleBufferRenderer` then sorts its reorder buffer by PTS
/// and puts the pictures back into decode order. Motion steps forward, back, forward, back for the
/// length of the title, at an even frame spacing, with nothing to count: no drop, no late frame, no
/// corrupted frame. Every instrument reads healthy and the pictures are in the wrong order.
///
/// Measured on `samples.ffmpeg.org/V-codecs/WVC1/Test_1440x576_WVC1_6Mbps.wmv` remuxed with a plain
/// `ffmpeg -c copy`, decoded ladder against picture type:
///
///     with +genpts    0.040 I   0.120 B   0.080 P   0.200 B   0.160 P     <- every B/P pair swapped
///     without         0.040 I   0.080 B   0.120 P   0.160 B   0.200 P
///
/// So the repair is to stop supplying the invented axis and let the decoder's own reorder own it.
/// Clearing PTS leaves `best_effort_timestamp` to place each picture, which is the second ladder.
///
/// The gate is an equivalence, not a guess. `matroskadec` sets `ms_compat` and `par->codec_tag` in one
/// block, both read out of the same VFW header, and no natively mapped Matroska track carries a codec
/// tag (measured: `WVC1` = 0x31435657 on the VFW track, 0 on H.264 and VP9 in the same container). On a
/// Matroska input `codec_tag != 0` is therefore exactly the carriage that withholds PTS, and any PTS
/// present on such a track was necessarily invented by `+genpts`. `video_delay > 0` narrows that to the
/// streams where inventing it can transpose anything at all.
///
/// **AVI joins the gate (measured).** The exclusion above was for want of a sample; here is one.
/// A 2000s XviD rip (`mpeg4`, Advanced Simple Profile, tag `XVID`, 720x304, `video_delay = 1`,
/// packed B-frames) reaches `SoftwareVideoDecoder` with the same transposition, and `aetherctl
/// swdecode` reports it in the same words:
///
///     0.042  0.083  0.167  0.125  0.209  0.292  0.250  0.334  0.417  0.375
///     Steps backwards: 12 of 37
///
/// AVI needs no `ms_compat` equivalence to establish the same fact, because `avidec` has no other
/// mode: the container has no presentation timestamps at all, every track carries a FourCC, and the
/// demuxer puts the frame index on `pkt->dts` (it never assigns `pkt->pts` anywhere). So on an AVI
/// input any PTS present was necessarily invented by `+genpts`, which makes `codec_tag != 0` a
/// tautology there rather than a signal, and `video_delay > 0` carries the whole gate.
///
/// **What decides whether the invented axis transposes is the PACKED bitstream, and an AVI without
/// one is already correct today.** Two files of the same shape (`mpeg4`, tag `XVID`,
/// `video_delay = 1`, progressive, evenly spaced), through `aetherctl swdecode` before this repair:
///
///     packed B-frames (FATE mpeg4/packed_bframes.avi, looped x25)   64 backwards steps of 239
///     plain coding-order chunks (ffmpeg -c:v mpeg4 -bf 2)            0 backwards steps of 14
///
/// `+genpts` writes a coding-order axis in both, but on a well-formed AVI that axis is the
/// presentation ladder shifted by exactly one frame, uniformly, so no pair changes places:
///
///     pkt   0      1      2      3      4      5        (dts = the AVI frame index)
///     dts   0.000  0.042  0.083  0.125  0.167  0.208
///     pts   0.042  0.167  0.083  0.125  0.292  0.208    <- each picture's own slot, plus one
///
/// A packed stream breaks that correspondence. Its N-VOP placeholder chunks (7 bytes, no picture)
/// hold a slot in the packet ladder while the picture they stand for rides inside the PREVIOUS
/// chunk, so packets and pictures stop matching one to one and the shift stops being uniform.
/// Hence the repair rather than libavcodec's `mpeg4_unpack_bframes` suggestion: clearing the axis
/// covers every container that withholds PTS, where the bitstream filter would cover one codec.
///
/// Arming on every AVI with a reorder delay, packed or not, costs nothing: on the files that are
/// already correct the cleared axis reproduces the same ladder frame for frame (measured on both
/// `mpeg4` and `mpeg2video` in AVI with B-frames, identical before and after).
///
/// One deliberate exclusion remains:
///
/// - **H.264 / HEVC / AV1 keep their PTS**, VFW-carried or not. Those are the codecs
///   `VideoRoutingPolicy` can route natively, which is the one path where packets reach the fMP4
///   muxer, and that muxer refuses a packet with no timestamp outright. A wrongly ordered picture is
///   a bad picture; a refused packet is no playback at all. Such a file is pathological in the first
///   place, and #409 already covers the reordering defect on the native path.
enum VFWDecodeOrderPTSRepair {

    /// The three facts about a video stream that decide the repair. Values only, so the decision is
    /// testable without FFmpeg.
    struct StreamShape: Equatable, Sendable {
        /// `AVCodecParameters.codec_tag`. Nonzero on a Matroska track exactly when it is VFW-carried.
        var codecTag: UInt32
        /// `AVCodecParameters.video_delay`: how many pictures the bitstream reorders by.
        var videoDelay: Int32
        /// `AVCodecParameters.codec_id`, to hold the natively routable codecs out (see above).
        var codecID: AVCodecID
    }

    /// Codecs `VideoRoutingPolicy` can keep on the native path, whose packets can therefore reach the
    /// fMP4 muxer. AV1 is here even though it routes by HW availability: the muxer is the risk, and it
    /// is reachable for AV1 on a device with a hardware decoder.
    static let nativelyRoutableCodecs: Set<AVCodecID> = [
        AV_CODEC_ID_H264, AV_CODEC_ID_HEVC, AV_CODEC_ID_AV1,
    ]

    /// Whether `+genpts` is inventing a decode-order axis for this stream, so its PTS has to go.
    static func suppressesGeneratedPTS(formatName: String, shape: StreamShape) -> Bool {
        guard containerWithholdsPTS(formatName) else { return false }
        // No reorder delay means decode order IS presentation order: the invented axis is the right
        // one, and clearing it would only cost. True for both containers.
        guard shape.videoDelay > 0 else { return false }
        // Matroska carries a codec tag only on the VFW-carried tracks that withhold PTS; a natively
        // mapped track gets real timestamps and must keep them. AVI has no such split (every track
        // is FourCC-carried and none carries PTS), so there the tag says nothing.
        if isMatroska(formatName), shape.codecTag == 0 { return false }
        return !nativelyRoutableCodecs.contains(shape.codecID)
    }

    /// Containers that supply no presentation timestamps, so anything on `pkt->pts` came from
    /// `+genpts` and describes decode order.
    static func containerWithholdsPTS(_ formatName: String) -> Bool {
        isMatroska(formatName) || isAVI(formatName)
    }

    /// `avidec` registers under the bare name, but match it the same way as Matroska so a
    /// comma-joined alias cannot slip past.
    static func isAVI(_ formatName: String) -> Bool {
        formatName.split(separator: ",").contains { $0 == "avi" }
    }

    /// libavformat registers both Matroska flavours under one comma-joined demuxer name
    /// (`matroska,webm`), so the name is matched element by element rather than whole.
    static func isMatroska(_ formatName: String) -> Bool {
        formatName.split(separator: ",").contains { $0 == "matroska" || $0 == "webm" }
    }
}
