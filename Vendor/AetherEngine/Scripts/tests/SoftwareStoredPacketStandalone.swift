import Foundation
import AetherLibavcodec
import AetherLibavutil

/// Same tracked double-pointer adapter used by SoftwarePlaybackHost, without its UI/runtime graph.
func av_packet_free_safe(_ packet: UnsafeMutablePointer<AVPacket>) {
    var pointer: UnsafeMutablePointer<AVPacket>? = packet
    trackedPacketFree(&pointer)
}

@main
struct SoftwareStoredPacketTests {
    enum TestError: Error { case allocationFailed }

    static func main() throws {
        precondition(PacketBalanceTracker.alive == 0)
        let allocationsBefore = PacketBalanceTracker.totalAllocs
        for iteration in 0..<32 {
            try roundTrip(
                bytes: Data((0..<256).map(UInt8.init)), pts: 1234567 + Int64(iteration),
                dts: 1233566, duration: 1001, position: 9_876_543_210,
                stream: 3, flags: AV_PKT_FLAG_KEY | AV_PKT_FLAG_CORRUPT | AV_PKT_FLAG_DISCARD,
                numerator: 1, denominator: 30000
            )
            try roundTrip(
                bytes: Data(), pts: Int64.min, dts: Int64.min, duration: 0, position: -1,
                stream: 5, flags: 0, numerator: 0, denominator: 1
            )
            try roundTrip(
                bytes: Data([0x00, 0xff, 0x80, 0x01]), pts: -1001, dts: -3003,
                duration: 1001, position: 0, stream: 0, flags: AV_PKT_FLAG_DISPOSABLE,
                numerator: 1001, denominator: 30000
            )
            try roundTrip(
                bytes: Data([0x7f]), pts: Int64.min, dts: Int64.max,
                duration: Int64.max, position: Int64.max, stream: Int32.max,
                flags: Int32.max, numerator: Int32.max, denominator: Int32.max
            )
        }
        precondition(PacketBalanceTracker.alive == 0)
        precondition(PacketBalanceTracker.totalAllocs - allocationsBefore == 256)
        var empty: UnsafeMutablePointer<AVPacket>? = nil
        trackedPacketFree(&empty)
        precondition(PacketBalanceTracker.alive == 0)
        print("PASS: 128 AVPacket/binary-envelope roundtrips; payload, PTS/DTS including NOPTS, duration/position/flags/time_base, distinct side data including empty bytes; tracked allocations=256, alive=0")
    }

    static func roundTrip(
        bytes: Data, pts: Int64, dts: Int64, duration: Int64, position: Int64,
        stream: Int32, flags: Int32, numerator: Int32, denominator: Int32
    ) throws {
        let aliveBefore = PacketBalanceTracker.alive
        guard let source = trackedPacketAlloc() else { throw TestError.allocationFailed }
        do {
            defer { av_packet_free_safe(source) }
            guard av_new_packet(source, Int32(bytes.count)) >= 0 else { throw TestError.allocationFailed }
            if !bytes.isEmpty { bytes.copyBytes(to: source.pointee.data, count: bytes.count) }
            source.pointee.pts = pts
            source.pointee.dts = dts
            source.pointee.duration = duration
            source.pointee.pos = position
            source.pointee.stream_index = stream
            source.pointee.flags = flags
            source.pointee.time_base = AVRational(num: numerator, den: denominator)

            let sideData: [(AVPacketSideDataType, Data)] = [
                (AV_PKT_DATA_SKIP_SAMPLES, Data([0x00, 0x04, 0, 0, 0x00, 0x08, 0, 0, 0, 0])),
                (AV_PKT_DATA_WEBVTT_IDENTIFIER, Data("cue-42".utf8)),
                (AV_PKT_DATA_WEBVTT_SETTINGS, Data("align:start position:10%".utf8)),
                (AV_PKT_DATA_NEW_EXTRADATA, Data()),
            ]
            for (type, data) in sideData {
                guard let target = av_packet_new_side_data(source, type, data.count) else {
                    throw TestError.allocationFailed
                }
                if !data.isEmpty { data.copyBytes(to: target, count: data.count) }
            }

            let stored = try SoftwareStoredPacket(copying: source)
            let expected = SoftwareStoredPacket(
                pts: pts, dts: dts, duration: duration, position: position,
                streamIndex: stream, flags: flags, timeBaseNumerator: numerator,
                timeBaseDenominator: denominator, bytes: bytes,
                sideData: sideData.map { .init(type: $0.0.rawValue, bytes: $0.1) }
            )
            precondition(stored == expected)
            let encoded = try stored.encoded()
            precondition(encoded.starts(with: Data("bplist00".utf8)))
            let decoded = try SoftwareStoredPacket.decode(encoded)
            precondition(decoded == expected)
            let restored = try decoded.makeAVPacket()
            defer { av_packet_free_safe(restored) }
            let copiedBack = try SoftwareStoredPacket(copying: restored)
            precondition(copiedBack == expected)
            precondition(restored.pointee.side_data_elems == Int32(sideData.count))
            precondition(restored.pointee.size == Int32(bytes.count))
            precondition(PacketBalanceTracker.alive == aliveBefore + 2)
        }
        precondition(PacketBalanceTracker.alive == aliveBefore)
    }
}
