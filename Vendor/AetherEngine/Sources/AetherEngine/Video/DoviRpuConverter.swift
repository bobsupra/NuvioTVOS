import Foundation
import AetherLibavcodec
import AetherLibavutil
import Dovi

/// In-place DV P7 -> P8.1 rewrite: drops unspec63 EL NALs, rewrites unspec62 RPU via libdovi mode 2. The packet's NAL framing is preserved; libdovi handles emulation-prevention bytes internally.
public enum DoviRpuConverter {

    private static let nalTypeRPU: UInt8 = 62   // unspec62: Dolby Vision RPU
    private static let nalTypeEL: UInt8  = 63   // unspec63: enhancement layer
    /// Return the number of bytes used by the packet's output delimiter. Annex-B accepts either
    /// three- or four-byte start codes; use the four-byte form consistently when rebuilding.
    private static func outputDelimiterSize(_ framing: VideoNALFraming) -> Int? {
        switch framing {
        case .annexB: return 4
        case .lengthPrefixed(let size): return (1...4).contains(size) ? size : nil
        }
    }

    private static func writeLength(_ length: Int, to dst: UnsafeMutablePointer<UInt8>, width: Int) {
        for i in 0..<width {
            let shift = (width - i - 1) * 8
            dst[i] = UInt8((length >> shift) & 0xFF)
        }
    }

    /// Returns `false` when a libdovi conversion fails (or on an internal allocation failure).
    /// On a libdovi failure the offending RPU (and EL) are dropped so the frame degrades to the
    /// clean HDR10 base, rather than shipping a P7 RPU inside a container already declared 8.1
    /// (mixed-profile hazard, #135). Packets with no RPU/EL are left untouched and return `true`.
    ///
    /// `framing` must be the framing of THIS packet, and the rewritten packet is emitted in the same
    /// one: the mp4 muxer decides whether to convert samples from the extradata, so a packet that
    /// changes framing under it is a second defect (#365). An Annex-B packet walked as length-
    /// prefixed reads `00 00 01 40` as a 320-byte NAL and finds no RPU at all, which is how a P7
    /// source shipped its RPU and EL untouched inside a container already rewritten to 8.1.
    public static func convertPacketToProfile81(
        _ packet: UnsafeMutablePointer<AVPacket>,
        framing: VideoNALFraming = .lengthPrefixed(size: 4)
    ) -> Bool {
        guard let data = packet.pointee.data, packet.pointee.size > 0 else { return true }
        guard let delimiterSize = Self.outputDelimiterSize(framing) else { return false }
        let size = Int(packet.pointee.size)

        var outputNALs: [[UInt8]] = []
        var converted = false
        var droppedEL = false
        var degraded = false

        A53SEIParser.forEachNAL(data, size, framing) { nal, len in
            // HEVC NAL type: bits 1..6 of byte 0.
            let nalType = (nal[0] >> 1) & 0x3F

            switch nalType {
            case nalTypeRPU:
                // Any libdovi failure drops the RPU (degraded) instead of muxing a stale P7 RPU
                // inside a container already declared 8.1 (mixed-profile hazard, #135).
                guard let rpu = dovi_parse_unspec62_nalu(nal, len) else {
                    degraded = true
                    return
                }
                let rc = dovi_convert_rpu_with_mode(rpu, 2)
                if rc != 0 {
                    dovi_rpu_free(rpu)
                    degraded = true
                    return
                }
                guard let out = dovi_write_unspec62_nalu(rpu) else {
                    dovi_rpu_free(rpu)
                    degraded = true
                    return
                }
                let outLen = out.pointee.len
                guard let outData = out.pointee.data, outLen > 0 else {
                    dovi_data_free(out)
                    dovi_rpu_free(rpu)
                    degraded = true
                    return
                }
                outputNALs.append([UInt8](UnsafeBufferPointer(start: outData, count: outLen)))
                dovi_data_free(out)
                dovi_rpu_free(rpu)
                converted = true

            case nalTypeEL:
                droppedEL = true

            default:
                outputNALs.append([UInt8](UnsafeBufferPointer(start: nal, count: len)))
            }
        }

        if !converted && !droppedEL && !degraded {
            return true
        }

        // A length-prefixed sample cannot represent a NAL larger than its declared prefix. A
        // converted RPU can grow, so drop only that RPU and degrade to the clean base-layer
        // packet; retaining it would put P7 metadata into a P8.1-signalled track. A malformed
        // oversized non-RPU NAL is left untouched and reported as unsupported.
        if case .lengthPrefixed(let width) = framing, width < 4 {
            let maximum = (1 << (width * 8)) - 1
            for nal in outputNALs where nal.count > maximum {
                guard nal.count >= 2, ((nal[0] >> 1) & 0x3F) == nalTypeRPU else { return false }
                degraded = true
            }
            outputNALs.removeAll { nal in
                nal.count > maximum && nal.count >= 2 && ((nal[0] >> 1) & 0x3F) == nalTypeRPU
            }
        }

        var total = 0
        for nal in outputNALs {
            total += delimiterSize + nal.count
        }
        // Degenerate: all NALs were RPU/EL. Leave the packet untouched rather than emit a zero-length video packet.
        guard total > 0 else { return true }

        let pad = Int(AV_INPUT_BUFFER_PADDING_SIZE)
        guard let newRef = av_buffer_alloc(total + pad) else {
            return false
        }
        guard let dst = newRef.pointee.data else {
            var ref: UnsafeMutablePointer<AVBufferRef>? = newRef
            av_buffer_unref(&ref)
            return false
        }

        let emitsStartCodes = framing == .annexB
        var w = 0
        for nal in outputNALs {
            let n = nal.count
            if emitsStartCodes {
                dst[w + 0] = 0; dst[w + 1] = 0; dst[w + 2] = 0; dst[w + 3] = 1
            } else {
                Self.writeLength(n, to: dst + w, width: delimiterSize)
            }
            w += delimiterSize
            nal.withUnsafeBufferPointer { src in
                if let base = src.baseAddress, n > 0 {
                    memcpy(dst + w, base, n)
                }
            }
            w += n
        }
        memset(dst + total, 0, pad)   // decoders read past size
        av_buffer_unref(&packet.pointee.buf)
        packet.pointee.buf = newRef
        packet.pointee.data = newRef.pointee.data
        packet.pointee.size = Int32(total)
        // A dropped-RPU degrade still produces a valid HDR10 packet, but reports failure so callers
        // can log it and the probe can flag the source for dovi_tool inspection.
        return !degraded
    }

    /// Enhancement-layer type ("FEL" or "MEL") of the first unspec62 RPU in a P7 packet, or nil if
    /// there is no RPU, the RPU is unparseable, or the source is not profile 7. One-shot diagnostic:
    /// a FEL source loses highlight/detail refinement in the P8.1 conversion (the EL is discarded),
    /// so callers can explain why a FEL disc looks flatter than on a native P7 player.
    public static func enhancementLayerType(
        _ packet: UnsafePointer<AVPacket>,
        framing: VideoNALFraming = .lengthPrefixed(size: 4)
    ) -> String? {
        guard let data = packet.pointee.data, packet.pointee.size > 0 else { return nil }
        let size = Int(packet.pointee.size)

        var result: String?
        A53SEIParser.forEachNAL(data, size, framing) { nal, len in
            guard result == nil, (nal[0] >> 1) & 0x3F == nalTypeRPU else { return }
            guard let rpu = dovi_parse_unspec62_nalu(nal, len) else { return }
            defer { dovi_rpu_free(rpu) }
            guard let hdr = dovi_rpu_get_header(rpu) else { return }
            defer { dovi_rpu_free_header(hdr) }
            guard let el = hdr.pointee.el_type else { return }
            result = String(cString: el)
        }
        return result
    }
}
