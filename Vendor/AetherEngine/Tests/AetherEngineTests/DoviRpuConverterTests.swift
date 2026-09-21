import Testing
import AetherLibavcodec
@testable import AetherEngine

/// Deterministic NAL-walk checks for the DV P7 -> P8.1 converter (#132/#135).
/// Successful real-RPU conversion and the FEL/MEL string value are validated against
/// dovi_tool ground truth via `aetherctl dovitest` and on device; these guard the
/// pure byte-walk branches (degrade-on-failure, EL drop, no-op) from regressing.
struct DoviRpuConverterTests {

    /// 2-byte HEVC NAL header (type in bits 1..6 of byte 0, layer 0, temporal_id_plus1 = 1) + payload.
    private func hevcNAL(type: UInt8, payload: [UInt8]) -> [UInt8] {
        [UInt8(type << 1), 0x01] + payload
    }

    /// Pack NALs into an AVCC (4-byte BE length prefix) AVPacket, the framing the MKV/MP4 demuxer guarantees.
    private func avccPacket(_ nals: [[UInt8]]) -> UnsafeMutablePointer<AVPacket> {
        var bytes: [UInt8] = []
        for nal in nals {
            let n = nal.count
            bytes.append(UInt8((n >> 24) & 0xFF))
            bytes.append(UInt8((n >> 16) & 0xFF))
            bytes.append(UInt8((n >> 8) & 0xFF))
            bytes.append(UInt8(n & 0xFF))
            bytes.append(contentsOf: nal)
        }
        let pkt = av_packet_alloc()!
        _ = av_new_packet(pkt, Int32(bytes.count))
        bytes.withUnsafeBytes { src in
            _ = memcpy(pkt.pointee.data, src.baseAddress, bytes.count)
        }
        return pkt
    }

    /// The HEVC NAL types present in a packet, in order.
    private func nalTypes(_ pkt: UnsafeMutablePointer<AVPacket>) -> [UInt8] {
        guard let data = pkt.pointee.data else { return [] }
        let size = Int(pkt.pointee.size)
        var out: [UInt8] = []
        var off = 0
        while off + 4 <= size {
            var len = 0
            for i in 0..<4 { len = (len << 8) | Int(data[off + i]) }
            let start = off + 4
            if len == 0 || start + len > size { break }
            out.append((data[start] >> 1) & 0x3F)
            off = start + len
        }
        return out
    }

    private func free(_ pkt: UnsafeMutablePointer<AVPacket>) {
        var p: UnsafeMutablePointer<AVPacket>? = pkt
        av_packet_free(&p)
    }

    // MARK: - #135 point 3: conversion-failure posture

    @Test("Unconvertible RPU degrades to clean HDR10: RPU and EL dropped, base layer kept")
    func degradesOnUnconvertibleRPU() {
        let bl = hevcNAL(type: 1, payload: [0xAA, 0xBB])   // TRAIL_R base-layer VCL
        let rpu = hevcNAL(type: 62, payload: [0x00])       // malformed unspec62, libdovi rejects
        let el = hevcNAL(type: 63, payload: [0xCC])        // unspec63 enhancement layer
        let pkt = avccPacket([bl, rpu, el])
        defer { free(pkt) }

        // A libdovi failure reports false...
        #expect(DoviRpuConverter.convertPacketToProfile81(pkt) == false)
        // ...and drops the RPU (62) and EL (63): no stale P7 metadata rides inside an 8.1 container.
        #expect(nalTypes(pkt) == [1])
    }

    @Test("A non-DV packet is left untouched")
    func leavesNonDVUntouched() {
        let bl = hevcNAL(type: 1, payload: [0xAA, 0xBB])
        let pkt = avccPacket([bl])
        defer { free(pkt) }

        // A non-DV packet is not a conversion failure...
        #expect(DoviRpuConverter.convertPacketToProfile81(pkt) == true)
        #expect(nalTypes(pkt) == [1])
    }

    @Test("Enhancement layer is dropped even when there is no RPU to convert")
    func dropsEnhancementLayer() {
        let bl = hevcNAL(type: 1, payload: [0xAA, 0xBB])
        let el = hevcNAL(type: 63, payload: [0xCC])
        let pkt = avccPacket([bl, el])
        defer { free(pkt) }

        #expect(DoviRpuConverter.convertPacketToProfile81(pkt) == true)
        #expect(nalTypes(pkt) == [1])   // EL (63) stripped, base layer kept
    }

    // MARK: - #135 point 2: FEL vs MEL diagnostics

    @Test("enhancementLayerType returns nil when no RPU NAL is present")
    func elTypeNilWithoutRPU() {
        let bl = hevcNAL(type: 1, payload: [0xAA, 0xBB])
        let pkt = avccPacket([bl])
        defer { free(pkt) }
        #expect(DoviRpuConverter.enhancementLayerType(pkt) == nil)
    }

    @Test("enhancementLayerType returns nil for an unparseable RPU")
    func elTypeNilForMalformedRPU() {
        let pkt = avccPacket([hevcNAL(type: 1, payload: [0xAA]), hevcNAL(type: 62, payload: [0x00])])
        defer { free(pkt) }
        #expect(DoviRpuConverter.enhancementLayerType(pkt) == nil)
    }

    // MARK: - #365: framing is given, not assumed

    /// Pack NALs Annex B, the framing a Matroska remux with Annex-B CodecPrivate delivers.
    private func annexBPacket(_ nals: [[UInt8]]) -> UnsafeMutablePointer<AVPacket> {
        var bytes: [UInt8] = []
        for nal in nals {
            bytes += [0x00, 0x00, 0x00, 0x01]
            bytes += nal
        }
        let pkt = av_packet_alloc()!
        _ = av_new_packet(pkt, Int32(bytes.count))
        bytes.withUnsafeBytes { src in
            _ = memcpy(pkt.pointee.data, src.baseAddress, bytes.count)
        }
        return pkt
    }

    private func annexBNALTypes(_ pkt: UnsafeMutablePointer<AVPacket>) -> [UInt8] {
        guard let data = pkt.pointee.data else { return [] }
        var out: [UInt8] = []
        A53SEIParser.forEachNAL(data, Int(pkt.pointee.size), .annexB) { nal, _ in
            out.append((nal[0] >> 1) & 0x3F)
        }
        return out
    }

    /// Walked as length-prefixed, an Annex-B packet reads `00 00 00 01` as a 1-byte NAL and finds
    /// nothing to convert, so the RPU and EL of a P7 source rode untouched into a container the
    /// muxer had already rewritten to 8.1. The converter has to be told the framing.
    @Test("An Annex-B packet walked with the wrong framing keeps its EL, walked with the right one loses it")
    func annexBPacketNeedsItsFraming() {
        let bl = hevcNAL(type: 1, payload: [0xAA, 0xBB])
        let el = hevcNAL(type: 63, payload: [0xCC])

        let wrong = annexBPacket([bl, el])
        defer { free(wrong) }
        #expect(DoviRpuConverter.convertPacketToProfile81(wrong) == true)
        #expect(annexBNALTypes(wrong) == [1, 63])   // untouched: the EL survived

        let right = annexBPacket([bl, el])
        defer { free(right) }
        #expect(DoviRpuConverter.convertPacketToProfile81(right, framing: .annexB) == true)
        #expect(annexBNALTypes(right) == [1])
    }

    @Test("A rewritten Annex-B packet stays Annex B")
    func annexBPacketKeepsItsFraming() {
        let pkt = annexBPacket([hevcNAL(type: 1, payload: [0xAA, 0xBB]),
                                hevcNAL(type: 62, payload: [0x00]),
                                hevcNAL(type: 63, payload: [0xCC])])
        defer { free(pkt) }
        #expect(DoviRpuConverter.convertPacketToProfile81(pkt, framing: .annexB) == false)
        #expect(annexBNALTypes(pkt) == [1])
        // Emitting length prefixes here would break the muxer's own Annex-B assumption downstream.
        let head = [UInt8](UnsafeBufferPointer(start: pkt.pointee.data, count: 4))
        #expect(head == [0x00, 0x00, 0x00, 0x01])
    }

    @Test("A length prefix size the sample entry cannot declare leaves the packet alone")
    func refusesUnsupportedLengthSize() {
        let pkt = avccPacket([hevcNAL(type: 1, payload: [0xAA]), hevcNAL(type: 63, payload: [0xCC])])
        defer { free(pkt) }
        #expect(DoviRpuConverter.convertPacketToProfile81(pkt, framing: .lengthPrefixed(size: 2)) == true)
        #expect(nalTypes(pkt) == [1, 63])   // untouched rather than rewritten into a framing nobody declared
    }

    @Test("enhancementLayerType walks Annex-B packets when given the framing")
    func elTypeWalksAnnexB() {
        let pkt = annexBPacket([hevcNAL(type: 1, payload: [0xAA]), hevcNAL(type: 62, payload: [0x00])])
        defer { free(pkt) }
        // A malformed RPU still returns nil, but it now REACHES the RPU: with the wrong framing the
        // walk never sees NAL 62 at all, which is the failure this guards.
        #expect(DoviRpuConverter.enhancementLayerType(pkt, framing: .annexB) == nil)
        #expect(annexBNALTypes(pkt) == [1, 62])
    }
}
