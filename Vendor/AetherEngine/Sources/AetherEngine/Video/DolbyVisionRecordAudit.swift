import Foundation
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil
import Dovi

/// AE#532: what a Dolby Vision source's own RPU says about the profile its container claims.
///
/// A container record is a claim, and for one class of remux it is a false one: a Profile 5 record over
/// a bitstream whose VUI declares BT.2020 YCbCr with a PQ or HLG transfer. IPT-PQ-c2 has no VUI code
/// point, so a genuine Profile 5 leaves `matrix_coeffs` and `transfer_characteristics` unspecified, and
/// a record that fills them in contradicts itself. Served as the record asks, the decoder reads YCbCr as
/// IPT and the picture comes out green / violet (#4, #176).
///
/// The RPU settles which half is lying, without a heuristic: a Profile 5 RPU cannot carry a residual or
/// an NLQ, so an RPU that carries one was authored for a different profile. libdovi answers it in one
/// field, and the engine already parses RPUs on this path for the Profile 7 conversion.
public enum DolbyVisionRecordAudit {

    private static let nalTypeRPU: UInt8 = 62   // unspec62: Dolby Vision RPU

    /// The profile libdovi reads out of the first RPU in this packet, or nil when the packet carries no
    /// parseable one. Unparseable says nothing rather than guessing: the record stands.
    static func rpuProfile(
        _ packet: UnsafePointer<AVPacket>,
        framing: VideoNALFraming = .lengthPrefixed(size: 4)
    ) -> Int? {
        guard let data = packet.pointee.data, packet.pointee.size > 4 else { return nil }
        let size = Int(packet.pointee.size)

        var result: Int?
        A53SEIParser.forEachNAL(data, size, framing) { nal, len in
            guard result == nil, (nal[0] >> 1) & 0x3F == nalTypeRPU else { return }
            guard let rpu = dovi_parse_unspec62_nalu(nal, len) else { return }
            defer { dovi_rpu_free(rpu) }
            guard let hdr = dovi_rpu_get_header(rpu) else { return }
            defer { dovi_rpu_free_header(hdr) }
            result = Int(hdr.pointee.guessed_profile)
        }
        return result
    }

    /// Whether this source's container record contradicts its own bitstream, i.e. whether reading the
    /// RPU can tell us anything the record does not. Only a Profile 5 record over a VUI that declares a
    /// BT.2020 YCbCr base with a PQ or HLG transfer qualifies, which is what keeps the audit free for
    /// every other source: a genuine Profile 5 leaves the VUI unspecified and is never read.
    ///
    /// HEVC only. AV1 Profile 10.0 has the same contradiction available in principle, but its RPU rides
    /// in an ITU-T T.35 metadata OBU rather than an `unspec62` NAL, which this walk cannot reach.
    static func recordIsContradicted(
        codecID: AVCodecID,
        dvProfile: Int?,
        colorTransfer: AVColorTransferCharacteristic,
        colorMatrix: AVColorSpace
    ) -> Bool {
        guard codecID == AV_CODEC_ID_HEVC, dvProfile == 5 else { return false }
        return VideoRoutingPolicy.vuiDeclaresYCbCrHDRBase(
            colorTransfer: colorTransfer, colorMatrix: colorMatrix)
    }

    /// The profile the route should believe, or nil to leave the record standing.
    ///
    /// Only a contradiction is a correction: an RPU that agrees with the record, an RPU that could not be
    /// read, and a profile this engine has no route for all leave the record alone. 7 and 8 are the two
    /// answers worth acting on, and both already have a route, so the correction costs no new packaging:
    /// a 7 takes the Profile 7 branch (RPU conversion on a Dolby Vision display, the HDR10 base without
    /// one) and an 8 takes the Profile 8.1 branch, whose compatibility rewrite turns the record's
    /// compatibility 0 into the 1 it should have carried.
    static func correctedProfile(record: Int?, rpu: Int?) -> Int? {
        guard record == 5, let rpu, rpu != record else { return nil }
        return (rpu == 7 || rpu == 8) ? rpu : nil
    }

    /// How many video packets to walk before giving up. Every frame of a Dolby Vision source carries an
    /// RPU, so the answer is in the first one; the slack is for a container whose head is audio.
    private static let auditPacketBudget = 16

    /// Open the source a second time and read what its first RPU says. nil when the source cannot be
    /// opened, carries no video, or holds no parseable RPU in its first frames, which all mean the same
    /// thing to the caller: the record stands.
    ///
    /// A second open rather than a read from the session's own probe demuxer, because that demuxer is
    /// handed to the software path as it stands and packets taken out of it here would be packets that
    /// path never sees. The audit is gated on `recordIsContradicted`, so this cost is paid by the one
    /// class of source that is already broken without it, and by no other.
    static func rpuProfileOfSource(url: URL, extraHeaders: [String: String]) -> Int? {
        let demuxer = Demuxer()
        defer { demuxer.close() }
        do {
            try demuxer.open(
                url: url, extraHeaders: extraHeaders,
                profile: .dolbyVisionRecordAuditDemuxer(callerProbesize: nil, callerMaxAnalyzeDuration: nil))
        } catch {
            return nil
        }

        let videoIdx = demuxer.videoStreamIndex
        guard videoIdx >= 0, let stream = demuxer.stream(at: videoIdx) else { return nil }
        let codecpar = stream.pointee.codecpar
        let framing = A53SEIParser.nalFraming(
            codec: .hevc, extradata: codecpar?.pointee.extradata,
            size: Int(codecpar?.pointee.extradata_size ?? 0))

        var walked = 0
        while walked < auditPacketBudget {
            guard let packet = (try? demuxer.readPacket()) ?? nil else { return nil }
            defer {
                av_packet_unref(packet)
                av_packet_free_safe(packet)
            }
            guard packet.pointee.stream_index == videoIdx else { continue }
            walked += 1
            if let profile = rpuProfile(packet, framing: framing) { return profile }
        }
        return nil
    }

    /// The verdict for a source in one call, gate included: opens it, reads the record and the VUI, and
    /// walks packets only when the record is contradicted. nil means the record stands.
    ///
    /// For a caller that has no probe of its own, which is the CLI harness. A session gates on the record
    /// its own probe already read and calls `rpuProfileOfSource` directly, so it does not open the source
    /// a second time for a source there is nothing to audit.
    public static func rpuCorrection(url: URL, extraHeaders: [String: String] = [:]) -> Int? {
        let demuxer = Demuxer()
        do {
            // The full profile, not the audit one: the gate reads the DOVI record and the colour
            // description, and both arrive only with `find_stream_info`. Measured, not assumed: the same
            // fixture comes back with no record at all under `skipStreamInfo`, while the extradata the
            // packet walk needs for its framing survives it, which is why `rpuProfileOfSource` can stay
            // on the cheap open and this cannot.
            try demuxer.open(url: url, extraHeaders: extraHeaders, profile: .playback)
        } catch {
            demuxer.close()
            return nil
        }
        let videoIdx = demuxer.videoStreamIndex
        guard videoIdx >= 0, let stream = demuxer.stream(at: videoIdx),
              let codecpar = stream.pointee.codecpar else {
            demuxer.close()
            return nil
        }
        let record = AetherEngine.dvConfig(stream: stream)
        let contradicted = recordIsContradicted(
            codecID: codecpar.pointee.codec_id, dvProfile: record?.profile,
            colorTransfer: codecpar.pointee.color_trc, colorMatrix: codecpar.pointee.color_space)
        demuxer.close()
        guard contradicted else { return nil }
        return correctedProfile(record: record?.profile,
                                rpu: rpuProfileOfSource(url: url, extraHeaders: extraHeaders))
    }
}
