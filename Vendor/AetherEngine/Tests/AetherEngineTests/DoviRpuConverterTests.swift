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

    private func avPacket(_ bytes: [UInt8]) -> UnsafeMutablePointer<AVPacket> {
        let pkt = av_packet_alloc()!
        _ = av_new_packet(pkt, Int32(bytes.count))
        bytes.withUnsafeBytes { src in
            _ = memcpy(pkt.pointee.data, src.baseAddress, bytes.count)
        }
        return pkt
    }

    /// Pack NALs into a length-prefixed AVPacket with the sample entry's declared prefix width.
    private func lengthPrefixedPacket(_ nals: [[UInt8]], size: Int = 4) -> UnsafeMutablePointer<AVPacket> {
        var bytes: [UInt8] = []
        for nal in nals {
            let n = nal.count
            for i in 0..<size {
                let shift = (size - i - 1) * 8
                bytes.append(UInt8((n >> shift) & 0xFF))
            }
            bytes.append(contentsOf: nal)
        }
        return avPacket(bytes)
    }

    /// The HEVC NAL types present in a packet, in order.
    private func nalTypes(_ pkt: UnsafeMutablePointer<AVPacket>, framing: VideoNALFraming = .lengthPrefixed(size: 4)) -> [UInt8] {
        guard let data = pkt.pointee.data else { return [] }
        let size = Int(pkt.pointee.size)
        var out: [UInt8] = []
        A53SEIParser.forEachNAL(data, size, framing) { nal, _ in
            out.append((nal[0] >> 1) & 0x3F)
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
        let pkt = lengthPrefixedPacket([bl, rpu, el])
        defer { free(pkt) }

        // A libdovi failure reports false...
        #expect(DoviRpuConverter.convertPacketToProfile81(pkt) == false)
        // ...and drops the RPU (62) and EL (63): no stale P7 metadata rides inside an 8.1 container.
        #expect(nalTypes(pkt) == [1])
    }

    @Test("A non-DV packet is left untouched")
    func leavesNonDVUntouched() {
        let bl = hevcNAL(type: 1, payload: [0xAA, 0xBB])
        let pkt = lengthPrefixedPacket([bl])
        defer { free(pkt) }

        // A non-DV packet is not a conversion failure...
        #expect(DoviRpuConverter.convertPacketToProfile81(pkt) == true)
        #expect(nalTypes(pkt) == [1])
    }

    @Test("Enhancement layer is dropped even when there is no RPU to convert")
    func dropsEnhancementLayer() {
        let bl = hevcNAL(type: 1, payload: [0xAA, 0xBB])
        let el = hevcNAL(type: 63, payload: [0xCC])
        let pkt = lengthPrefixedPacket([bl, el])
        defer { free(pkt) }

        #expect(DoviRpuConverter.convertPacketToProfile81(pkt) == true)
        #expect(nalTypes(pkt) == [1])   // EL (63) stripped, base layer kept
    }

    // MARK: - #135 point 2: FEL vs MEL diagnostics

    @Test("enhancementLayerType returns nil when no RPU NAL is present")
    func elTypeNilWithoutRPU() {
        let bl = hevcNAL(type: 1, payload: [0xAA, 0xBB])
        let pkt = lengthPrefixedPacket([bl])
        defer { free(pkt) }
        #expect(DoviRpuConverter.enhancementLayerType(pkt) == nil)
    }

    @Test("enhancementLayerType returns nil for an unparseable RPU")
    func elTypeNilForMalformedRPU() {
        let pkt = lengthPrefixedPacket([hevcNAL(type: 1, payload: [0xAA]), hevcNAL(type: 62, payload: [0x00])])
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

    @Test("A two-byte length prefix is preserved while rewriting")
    func preservesTwoByteLengthSize() {
        let pkt = lengthPrefixedPacket([hevcNAL(type: 1, payload: [0xAA]), hevcNAL(type: 63, payload: [0xCC])], size: 2)
        defer { free(pkt) }
        #expect(DoviRpuConverter.convertPacketToProfile81(pkt, framing: .lengthPrefixed(size: 2)) == true)
        #expect(nalTypes(pkt, framing: .lengthPrefixed(size: 2)) == [1])
        #expect(pkt.pointee.data![0] == 0 && pkt.pointee.data![1] == 3)
    }

    @Test("A one-byte length prefix is preserved while rewriting")
    func preservesOneByteLengthSize() {
        let pkt = lengthPrefixedPacket([hevcNAL(type: 1, payload: [0xAA]), hevcNAL(type: 63, payload: [0xCC])], size: 1)
        defer { free(pkt) }
        #expect(DoviRpuConverter.convertPacketToProfile81(pkt, framing: .lengthPrefixed(size: 1)) == true)
        #expect(nalTypes(pkt, framing: .lengthPrefixed(size: 1)) == [1])
        #expect(pkt.pointee.data![0] == 3)
    }

    @Test("Packet framing falls back when Annex-B extradata accompanies length-prefixed data")
    func detectsPacketFramingRatherThanTrustingExtradata() {
        let extradata: [UInt8] = [0x00, 0x00, 0x01, 0x40, 0x01]
        let packet = lengthPrefixedPacket([hevcNAL(type: 1, payload: [0xAA, 0xBB])])
        defer { free(packet) }

        let configured: VideoNALFraming = extradata.withUnsafeBufferPointer {
            A53SEIParser.nalFraming(codec: .hevc, extradata: $0.baseAddress, size: $0.count)
        }
        #expect(configured == .annexB)
        let detected: VideoNALFraming? = packet.pointee.data.flatMap {
            A53SEIParser.detectNALFraming(
                $0, Int(packet.pointee.size), preferred: configured)
        }
        #expect(detected == .lengthPrefixed(size: 4))
    }

    @Test("A 0x00000103 length prefix is not mistaken for Annex-B")
    func detectsLengthPrefixWithStartCodeLookingBytes() {
        // 2-byte HEVC header + 257-byte payload = 259 bytes = 0x00000103.
        let packet = lengthPrefixedPacket(
            [hevcNAL(type: 1, payload: Array(repeating: 0xAA, count: 257))])
        defer { free(packet) }
        guard let data = packet.pointee.data else {
            Issue.record("packet allocation returned no data")
            return
        }
        #expect(A53SEIParser.detectNALFraming(
            data, Int(packet.pointee.size), preferred: .annexB
        ) == .lengthPrefixed(size: 4))
    }

    @Test("Length-prefixed stream resolution ignores an ambiguous packet")
    func resolvesLengthPrefixedStreamFromConclusiveEvidence() {
        let ambiguous = lengthPrefixedPacket(
            [hevcNAL(type: 1, payload: Array(repeating: 0xAA, count: 257))])
        let conclusive = lengthPrefixedPacket(
            [hevcNAL(type: 1, payload: Array(repeating: 0xBB, count: 510))])
        defer { free(ambiguous); free(conclusive) }

        let evidence = [ambiguous, conclusive].compactMap { packet -> [VideoNALFraming]? in
            guard let data = packet.pointee.data else { return nil }
            return A53SEIParser.allValidNALFramings(data, Int(packet.pointee.size))
        }
        #expect(evidence[0].contains(.annexB))
        #expect(evidence[0].contains(.lengthPrefixed(size: 4)))
        #expect(evidence[1] == [.lengthPrefixed(size: 4)])
        #expect(A53SEIParser.resolveNALFraming(samples: evidence, configured: .annexB)
                == .lengthPrefixed(size: 4))
    }

    @Test("Annex-B stream resolution ignores a packet that synthetically closes as length-prefixed")
    func resolvesAnnexBStreamFromConclusiveEvidence() {
        // Start code + NAL bytes arranged so the first start code is also a valid 3-byte
        // length-prefixed walk: length 1, then length 3, then exactly three bytes.
        let ambiguousBytes: [UInt8] = [0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x03, 0x40, 0x01, 0xAA]
        let ambiguous = avPacket(ambiguousBytes)
        let conclusive = annexBPacket([
            hevcNAL(type: 1, payload: [0xAA]),
            hevcNAL(type: 1, payload: [0xBB])
        ])
        defer { free(ambiguous); free(conclusive) }

        let evidence = [ambiguous, conclusive].compactMap { packet -> [VideoNALFraming]? in
            guard let data = packet.pointee.data else { return nil }
            return A53SEIParser.allValidNALFramings(data, Int(packet.pointee.size))
        }
        #expect(evidence[0].contains(.annexB))
        #expect(evidence[0].contains(.lengthPrefixed(size: 3)))
        #expect(evidence[1] == [.annexB])
        #expect(A53SEIParser.resolveNALFraming(
            samples: evidence, configured: .lengthPrefixed(size: 3)) == .annexB)
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
