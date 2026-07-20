import Foundation
import AetherLibavcodec
import AetherLibavutil
import Dovi

/// In-place DV P7 -> P8.1 rewrite: drops unspec63 EL NALs, rewrites unspec62 RPU via libdovi mode 2. AVCC layout (4-byte BE length prefix); libdovi handles emulation-prevention bytes internally.
public enum DoviRpuConverter {

    private static let nalTypeRPU: UInt8 = 62   // unspec62: Dolby Vision RPU
    private static let nalTypeEL: UInt8  = 63   // unspec63: enhancement layer
    private static let lengthPrefixSize = 4

    /// Returns `false` when a libdovi conversion fails (or on an internal allocation failure).
    /// On a libdovi failure the offending RPU (and EL) are dropped so the frame degrades to the
    /// clean HDR10 base, rather than shipping a P7 RPU inside a container already declared 8.1
    /// (mixed-profile hazard, #135). Packets with no RPU/EL are left untouched and return `true`.
    public static func convertPacketToProfile81(_ packet: UnsafeMutablePointer<AVPacket>) -> Bool {
        guard let data = packet.pointee.data, packet.pointee.size > 0 else { return true }
        guard packet.pointee.size > 4 else { return true }
        let size = Int(packet.pointee.size)

        var outputNALs: [[UInt8]] = []
        var converted = false
        var droppedEL = false
        var degraded = false

        var off = 0
        while off + lengthPrefixSize <= size {
            var len = 0
            for i in 0..<lengthPrefixSize {
                len = (len << 8) | Int(data[off + i])
            }
            let nalStart = off + lengthPrefixSize
            if len == 0 || nalStart + len > size { break }

            // HEVC NAL type: bits 1..6 of byte 0.
            let nalType = (data[nalStart] >> 1) & 0x3F

            switch nalType {
            case nalTypeRPU:
                // Any libdovi failure drops the RPU (degraded) instead of muxing a stale P7 RPU
                // inside a container already declared 8.1 (mixed-profile hazard, #135).
                guard let rpu = dovi_parse_unspec62_nalu(data + nalStart, len) else {
                    degraded = true
                    break
                }
                let rc = dovi_convert_rpu_with_mode(rpu, 2)
                if rc != 0 {
                    dovi_rpu_free(rpu)
                    degraded = true
                    break
                }
                guard let out = dovi_write_unspec62_nalu(rpu) else {
                    dovi_rpu_free(rpu)
                    degraded = true
                    break
                }
                let outLen = out.pointee.len
                guard let outData = out.pointee.data, outLen > 0 else {
                    dovi_data_free(out)
                    dovi_rpu_free(rpu)
                    degraded = true
                    break
                }
                outputNALs.append([UInt8](UnsafeBufferPointer(start: outData, count: outLen)))
                dovi_data_free(out)
                dovi_rpu_free(rpu)
                converted = true

            case nalTypeEL:
                droppedEL = true

            default:
                outputNALs.append([UInt8](UnsafeBufferPointer(start: data + nalStart, count: len)))
            }

            off = nalStart + len
        }

        if !converted && !droppedEL && !degraded {
            return true
        }

        var total = 0
        for nal in outputNALs {
            total += lengthPrefixSize + nal.count
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

        var w = 0
        for nal in outputNALs {
            let n = nal.count
            dst[w + 0] = UInt8((n >> 24) & 0xFF)
            dst[w + 1] = UInt8((n >> 16) & 0xFF)
            dst[w + 2] = UInt8((n >> 8) & 0xFF)
            dst[w + 3] = UInt8(n & 0xFF)
            w += lengthPrefixSize
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
    public static func enhancementLayerType(_ packet: UnsafePointer<AVPacket>) -> String? {
        guard let data = packet.pointee.data, packet.pointee.size > 4 else { return nil }
        let size = Int(packet.pointee.size)

        var off = 0
        while off + lengthPrefixSize <= size {
            var len = 0
            for i in 0..<lengthPrefixSize {
                len = (len << 8) | Int(data[off + i])
            }
            let nalStart = off + lengthPrefixSize
            if len == 0 || nalStart + len > size { break }

            if (data[nalStart] >> 1) & 0x3F == nalTypeRPU {
                guard let rpu = dovi_parse_unspec62_nalu(data + nalStart, len) else { return nil }
                defer { dovi_rpu_free(rpu) }
                guard let hdr = dovi_rpu_get_header(rpu) else { return nil }
                defer { dovi_rpu_free_header(hdr) }
                guard let el = hdr.pointee.el_type else { return nil }
                return String(cString: el)
            }

            off = nalStart + len
        }
        return nil
    }
}
