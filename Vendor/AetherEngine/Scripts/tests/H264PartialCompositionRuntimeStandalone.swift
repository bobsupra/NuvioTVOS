import Foundation
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil

func av_packet_free_safe(_ packet: UnsafeMutablePointer<AVPacket>) {
    var owned: UnsafeMutablePointer<AVPacket>? = packet
    trackedPacketFree(&owned)
}

// Test-only snapshot: no dependency on the independent software packet-cache proposal.
struct TimestampPacketSnapshot: Codable, Sendable, Equatable {
    struct SideData: Codable, Sendable, Equatable {
        let type: UInt32
        let bytes: Data
    }
    let pts: Int64
    let dts: Int64
    let duration: Int64
    let position: Int64
    let streamIndex: Int32
    let flags: Int32
    let timeBaseNumerator: Int32
    let timeBaseDenominator: Int32
    let bytes: Data
    let sideData: [SideData]

}
extension TimestampPacketSnapshot {
    enum PacketError: Error { case invalidPacket, allocationFailed }

    init(copying packet: UnsafeMutablePointer<AVPacket>) throws {
        let p = packet.pointee
        guard p.size >= 0, p.side_data_elems >= 0,
              p.size == 0 || p.data != nil,
              p.side_data_elems == 0 || p.side_data != nil else { throw PacketError.invalidPacket }
        var sides: [SideData] = []
        for index in 0..<Int(p.side_data_elems) {
            let side = p.side_data[index]
            guard side.size == 0 || side.data != nil else { throw PacketError.invalidPacket }
            sides.append(SideData(type: side.type.rawValue,
                                  bytes: side.size == 0 ? Data() : Data(bytes: side.data, count: side.size)))
        }
        self.init(pts: p.pts, dts: p.dts, duration: p.duration, position: p.pos,
                  streamIndex: p.stream_index, flags: p.flags,
                  timeBaseNumerator: p.time_base.num, timeBaseDenominator: p.time_base.den,
                  bytes: p.size == 0 ? Data() : Data(bytes: p.data, count: Int(p.size)), sideData: sides)
    }

}

@main
struct H264PartialCompositionRuntimeTests {
    enum Failure: Error { case open, decoder, demux, decode, session, boundedRead }
    static func main() throws {
        guard CommandLine.arguments.count >= 2 else { throw Failure.open }
        av_log_set_level(AV_LOG_QUIET)
        var format: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_open_input(&format, CommandLine.arguments[1], nil, nil) >= 0, let format else { throw Failure.open }
        defer { var owned: UnsafeMutablePointer<AVFormatContext>? = format; avformat_close_input(&owned) }
        guard avformat_find_stream_info(format, nil) >= 0 else { throw Failure.open }
        let index = av_find_best_stream(format, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)
        guard index >= 0, let stream = format.pointee.streams[Int(index)],
              let par = stream.pointee.codecpar, par.pointee.codec_id == AV_CODEC_ID_H264 else { throw Failure.open }
        let name = format.pointee.iformat.flatMap { $0.pointee.name }.map(String.init(cString:)) ?? ""
        let matroska = name.contains("matroska")
        guard !matroska else { throw Failure.session }
        let ladderStart = avformat_index_get_entry(stream, 0)?.pointee.timestamp ?? Int64.min
        guard let session = H264CompositionOffsetRepairSession(containerFormatName: name, stream: stream, streamIndex: index, ladderStart: ladderStart)
        else { throw Failure.session }
        let raw = try decoder(par, timeBase: stream.pointee.time_base)
        let fixed = try decoder(par, timeBase: stream.pointee.time_base)
        defer {
            var a: UnsafeMutablePointer<AVCodecContext>? = raw; avcodec_free_context(&a)
            var b: UnsafeMutablePointer<AVCodecContext>? = fixed; avcodec_free_context(&b)
        }
        var inputs: [UInt: TimestampPacketSnapshot] = [:]
        let positions = CommandLine.arguments.dropFirst(2).compactMap(Double.init)
        for position in positions.isEmpty ? [0] : positions {
            if position >= 0 {
                let target = Int64(position / av_q2d(stream.pointee.time_base))
                guard av_seek_frame(format, index, target, AVSEEK_FLAG_BACKWARD) >= 0 else { throw Failure.demux }
            }
            session.noteSeek()
            avcodec_flush_buffers(raw); avcodec_flush_buffers(fixed)
            var rawPTS: [Int64] = [], fixedPTS: [Int64] = []
            var videoRead = 0, reads = 0, delivered = 0, stop = false, observedRepair = false
            func emit(_ packet: UnsafeMutablePointer<AVPacket>) throws {
                defer { var owned: UnsafeMutablePointer<AVPacket>? = packet; trackedPacketFree(&owned) }
                let expected = inputs.removeValue(forKey: UInt(bitPattern: packet))!
                let actual = try TimestampPacketSnapshot(copying: packet)
                // Exact packet payload/side-data/flags/duration/audio preservation, not just a
                // model calculation. Only the selected video PTS/DTS may differ.
                if packet.pointee.stream_index == index {
                    precondition(actual.bytes == expected.bytes && actual.sideData == expected.sideData)
                    precondition(actual.duration == expected.duration && actual.flags == expected.flags)
                    precondition(actual.position == expected.position && actual.streamIndex == expected.streamIndex)
                    precondition(actual.dts == expected.dts, "partial repair must preserve the published decode/index axis")
                    try decode(fixed, packet: packet, into: &fixedPTS)
                } else { precondition(actual == expected) }
                delivered += 1
            }
            while !stop {
                while let packet = session.dequeue() { try emit(packet) }
                guard reads < 40000, videoRead < 8000 else { throw Failure.boundedRead }
                guard let packet = trackedPacketAlloc() else { throw Failure.demux }
                let status = av_read_frame(format, packet)
                if status < 0 {
                    var owned: UnsafeMutablePointer<AVPacket>? = packet; trackedPacketFree(&owned)
                    guard status == -541478725 else { throw Failure.demux }
                    stop = true
                    break
                }
                reads += 1
                inputs[UInt(bitPattern: packet)] = try TimestampPacketSnapshot(copying: packet)
                if packet.pointee.stream_index == index {
                    let key = packet.pointee.flags & AV_PKT_FLAG_KEY != 0
                    stop = videoRead >= 1200 && key
                    videoRead += 1
                    try decode(raw, packet: packet, into: &rawPTS)
                }
                if !session.ingest(packet) { try emit(packet) }
                observedRepair = observedRepair || session.summary.contains("confirmed_partial_composition_offsets")
            }
            session.endOfStream()
            while let packet = session.dequeue() { try emit(packet) }
            try decode(raw, packet: nil, into: &rawPTS)
            try decode(fixed, packet: nil, into: &fixedPTS)
            precondition(inputs.isEmpty && PacketBalanceTracker.alive == 0)
            let rawRegressions = zip(rawPTS, rawPTS.dropFirst()).filter { $1 <= $0 }.count
            let fixedRegressions = zip(fixedPTS, fixedPTS.dropFirst()).filter { $1 <= $0 }.count
            let diagnostic = session.summary
            observedRepair = observedRepair || diagnostic.contains("confirmed_partial_composition_offsets")
            FileHandle.standardError.write(Data("MEASURE seek=\(position) raw=\(rawRegressions) fixed=\(fixedRegressions) offset=\(session.decodeTimestampOffset ?? 0) state=\(diagnostic) lead=\(0) shift=\(0)\n".utf8))
            precondition(rawPTS.count == fixedPTS.count && !fixedPTS.isEmpty)
            precondition(fixedRegressions == 0)
            if rawRegressions > 0 {
                precondition(observedRepair)
                precondition(session.decodeTimestampOffset == nil)
            } else { precondition(rawPTS == fixedPTS, "healthy head remains exactly unchanged") }
            print("PASS source_kind=\(matroska ? "matroska" : "mp4") seek=\(position) decoded=\(fixedPTS.count) original_regressions=\(rawRegressions) repaired_regressions=\(fixedRegressions) packets=\(delivered) reason=\(diagnostic) decode_offset=\(session.decodeTimestampOffset ?? 0) packet_balance=0")
        }
        if positions.count > 1 {
            try lifecycleChecks(session: session, format: format, stream: stream, index: index, position: positions[1])
        }
    }

    static func lifecycleChecks(session: H264CompositionOffsetRepairSession,
        format: UnsafeMutablePointer<AVFormatContext>, stream: UnsafeMutablePointer<AVStream>, index: Int32,
        position: Double) throws {
        func seek() throws {
            guard av_seek_frame(format, index, Int64(position / av_q2d(stream.pointee.time_base)), AVSEEK_FLAG_BACKWARD) >= 0 else { throw Failure.demux }
            session.noteSeek()
        }
        func read() throws {
            guard let packet = trackedPacketAlloc() else { throw Failure.demux }
            guard av_read_frame(format, packet) >= 0 else { av_packet_free_safe(packet); throw Failure.demux }
            if !session.ingest(packet) { av_packet_free_safe(packet) }
        }
        for goal in [3, 500] {
            try seek()
            for _ in 0..<goal { try read() }
            if let packet = session.dequeue() { av_packet_free_safe(packet) }
            session.noteSeek()
            precondition(session.dequeue() == nil && PacketBalanceTracker.alive == 0,
                "seek must release both pending input and partly drained output")
        }
        // A shape this policy cannot own costs the repair, never the session. After confirmation a
        // malformed timestamp hands every held packet back and the reads that follow keep coming.
        for malformed: (dts: Int64, pts: Int64) in [(Int64.min, Int64.min), (0, 0)] {
            try seek()
            var confirmed = false
            for _ in 0..<4000 {
                try read()
                if session.summary.contains("confirmed_partial_composition_offsets") { confirmed = true; break }
            }
            precondition(confirmed)
            guard let packet = trackedPacketAlloc() else { throw Failure.demux }
            packet.pointee.stream_index = index
            packet.pointee.dts = malformed.dts
            packet.pointee.pts = malformed.pts
            if !session.ingest(packet) { av_packet_free_safe(packet) }
            while let packet = session.dequeue() { av_packet_free_safe(packet) }
            precondition(PacketBalanceTracker.alive == 0, "a refusal still owns every packet it took")
            // A refused sequence streams through the session rather than out of its queue, so
            // count both ways a packet can come back.
            var delivered = 0
            for _ in 0..<400 {
                guard let next = trackedPacketAlloc() else { throw Failure.demux }
                guard av_read_frame(format, next) >= 0 else { av_packet_free_safe(next); break }
                if !session.ingest(next) { av_packet_free_safe(next); delivered += 1 }
                while let packet = session.dequeue() { av_packet_free_safe(packet); delivered += 1 }
            }
            precondition(delivered > 0, "a refused sequence still has to stream through")
            session.noteSeek()
            precondition(PacketBalanceTracker.alive == 0)
        }
        try seek()
        for _ in 0..<32 { try read() }
        // Interleaving, not reordering, is what can still make the wait large. The all-stream budget
        // is the ceiling on that, and crossing it ends the hold rather than the delivery.
        var heldForeign = 0
        for _ in 0..<(4 * H264PartialCompositionRepair.maximumHeldPackets) {
            guard let packet = trackedPacketAlloc() else { throw Failure.demux }
            packet.pointee.stream_index = index + 1
            if session.ingest(packet) { heldForeign += 1 } else { av_packet_free_safe(packet) }
        }
        precondition(heldForeign > 0 && heldForeign <= H264PartialCompositionRepair.maximumHeldPackets,
                     "the all-stream budget has to end the hold, held \(heldForeign)")
        while let packet = session.dequeue() { av_packet_free_safe(packet) }
        session.noteSeek()
        precondition(PacketBalanceTracker.alive == 0)
        print("PASS partial lifecycle: seek-pending, seek-ready-and-pending, confirmed-fails-open,"
            + " all-stream-budget held=\(heldForeign) packet_balance=0")
    }

    static func decoder(_ parameters: UnsafeMutablePointer<AVCodecParameters>, timeBase: AVRational) throws
        -> UnsafeMutablePointer<AVCodecContext> {
        guard let codec = avcodec_find_decoder(AV_CODEC_ID_H264), let context = avcodec_alloc_context3(codec) else { throw Failure.decoder }
        guard avcodec_parameters_to_context(context, parameters) >= 0 else { throw Failure.decoder }
        context.pointee.pkt_timebase = timeBase
        context.pointee.thread_count = 1
        guard avcodec_open2(context, codec, nil) >= 0 else { throw Failure.decoder }
        return context
    }

    static func decode(_ decoder: UnsafeMutablePointer<AVCodecContext>, packet: UnsafeMutablePointer<AVPacket>?, into pts: inout [Int64]) throws {
        guard avcodec_send_packet(decoder, packet) >= 0, let frame = av_frame_alloc() else { throw Failure.decode }
        defer { var owned: UnsafeMutablePointer<AVFrame>? = frame; av_frame_free(&owned) }
        while true {
            let status = avcodec_receive_frame(decoder, frame)
            if status == -35 || status == -541478725 { return }
            guard status >= 0 else { throw Failure.decode }
            pts.append(frame.pointee.pts)
            av_frame_unref(frame)
        }
    }
}
