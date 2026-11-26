import Foundation
import Testing
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil

/// Proves the mpegts muxer writes the Dolby Vision descriptors (build.sh
/// `patch_ffmpeg_mpegts_dovi_descriptor`), so a Dolby Vision stream copied into a transport
/// stream keeps its configuration record.
///
/// The demuxer reads the DOVI video stream descriptor (0xb0) into AV_PKT_DATA_DOVI_CONF, but
/// stock mpegtsenc never writes it. AetherEngine's live recordings stream-copy into MPEG-TS,
/// so every RPU reached the file and the record did not: played back, Profile 8.1 came out as
/// HDR10, Profile 8.4 as HLG and Profile 5 as HDR10 with the wrong colours.
///
/// Each case muxes a few HEVC access units with a record through the shipped mpegts muxer and
/// opens the file the way a player does. The payload is an access unit delimiter only: the
/// descriptors live in the PMT, which the muxer builds from the stream parameters alone.
struct MPEGTSDolbyVisionDescriptorTests {

    struct Record: Equatable, CustomStringConvertible {
        var profile: UInt8
        var level: UInt8
        var rpu: UInt8 = 1
        var el: UInt8 = 0
        var bl: UInt8 = 1
        var compatibility: UInt8
        var compression: UInt8 = 0

        var description: String {
            "profile \(profile) level \(level) rpu \(rpu) el \(el) bl \(bl) "
                + "compatibility \(compatibility) compression \(compression)"
        }
    }

    private static let accessUnitDelimiter: [UInt8] = [0x00, 0x00, 0x00, 0x01, 0x46, 0x01, 0x50]
    private static let doviRegistration: [UInt8] = [0x05, 0x04, 0x44, 0x4f, 0x56, 0x49]

    /// Muxes an HEVC stream with `record` (or none) into a transport stream at `path`.
    private static func mux(record: Record?, to path: String) -> Bool {
        var ctxOut: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_alloc_output_context2(&ctxOut, nil, "mpegts", path) == 0,
              let ctx = ctxOut else { return false }
        defer { avformat_free_context(ctx) }
        guard let stream = avformat_new_stream(ctx, nil) else { return false }
        let par = stream.pointee.codecpar!
        par.pointee.codec_type = AVMEDIA_TYPE_VIDEO
        par.pointee.codec_id = AV_CODEC_ID_HEVC
        par.pointee.width = 3840
        par.pointee.height = 2160
        stream.pointee.time_base = AVRational(num: 1, den: 90_000)

        if let record {
            var size = 0
            guard let dovi = av_dovi_alloc(&size) else { return false }
            dovi.pointee.dv_version_major = 1
            dovi.pointee.dv_version_minor = 0
            dovi.pointee.dv_profile = record.profile
            dovi.pointee.dv_level = record.level
            dovi.pointee.rpu_present_flag = record.rpu
            dovi.pointee.el_present_flag = record.el
            dovi.pointee.bl_present_flag = record.bl
            dovi.pointee.dv_bl_signal_compatibility_id = record.compatibility
            dovi.pointee.dv_md_compression = record.compression
            guard av_packet_side_data_add(&par.pointee.coded_side_data, &par.pointee.nb_coded_side_data,
                                          AV_PKT_DATA_DOVI_CONF, dovi, size, 0) != nil else {
                av_free(dovi)
                return false
            }
        }

        guard avio_open(&ctx.pointee.pb, path, AVIO_FLAG_WRITE) >= 0 else { return false }
        defer { avio_closep(&ctx.pointee.pb) }
        guard avformat_write_header(ctx, nil) >= 0 else { return false }

        var pkt = av_packet_alloc()
        defer { av_packet_free(&pkt) }
        guard let packet = pkt else { return false }
        for index in 0..<10 {
            guard av_new_packet(packet, Int32(accessUnitDelimiter.count)) >= 0 else { return false }
            accessUnitDelimiter.withUnsafeBytes {
                _ = memcpy(packet.pointee.data, $0.baseAddress!, accessUnitDelimiter.count)
            }
            packet.pointee.stream_index = 0
            packet.pointee.pts = Int64(index) * 3_600
            packet.pointee.dts = packet.pointee.pts
            packet.pointee.duration = 3_600
            if index == 0 { packet.pointee.flags |= AV_PKT_FLAG_KEY }
            guard av_interleaved_write_frame(ctx, packet) >= 0 else { return false }
        }
        return av_write_trailer(ctx) >= 0
    }

    /// The record a player reads back from the file (nil when the stream has none) and the
    /// stream's codec tag.
    private static func readBack(path: String) -> (record: Record?, codecTag: UInt32)? {
        var ctxIn: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_open_input(&ctxIn, path, nil, nil) == 0, let ctx = ctxIn else { return nil }
        defer { avformat_close_input(&ctxIn) }
        guard ctx.pointee.nb_streams == 1,
              let par = ctx.pointee.streams[0]?.pointee.codecpar,
              par.pointee.codec_id == AV_CODEC_ID_HEVC else { return nil }
        let codecTag = par.pointee.codec_tag
        guard let side = av_packet_side_data_get(par.pointee.coded_side_data, par.pointee.nb_coded_side_data,
                                                 AV_PKT_DATA_DOVI_CONF) else { return (nil, codecTag) }
        let dovi = UnsafeRawPointer(side.pointee.data!).assumingMemoryBound(
            to: AVDOVIDecoderConfigurationRecord.self).pointee
        return (Record(profile: dovi.dv_profile, level: dovi.dv_level, rpu: dovi.rpu_present_flag,
                       el: dovi.el_present_flag, bl: dovi.bl_present_flag,
                       compatibility: dovi.dv_bl_signal_compatibility_id,
                       compression: dovi.dv_md_compression), codecTag)
    }

    private struct RoundTrip {
        let record: Record?
        let codecTag: UInt32
        let hasDoviRegistration: Bool
    }

    /// 'HEVC' as the little-endian FourCC the demuxer stores in codec_tag.
    private static let hevcTag: UInt32 = 0x4356_4548

    private static func roundTrip(_ record: Record?) throws -> RoundTrip? {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("mpegts-dovi-\(UUID().uuidString).ts").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        guard mux(record: record, to: path), let read = readBack(path: path) else { return nil }
        let bytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
        let registered = bytes.indices.dropLast(doviRegistration.count).contains {
            bytes[$0..<($0 + doviRegistration.count)].elementsEqual(doviRegistration)
        }
        return RoundTrip(record: read.record, codecTag: read.codecTag, hasDoviRegistration: registered)
    }

    @Test("a Dolby Vision record survives the mpegts muxer", arguments: [
        Record(profile: 8, level: 6, compatibility: 1),
        Record(profile: 8, level: 6, compatibility: 4),
        Record(profile: 8, level: 9, compatibility: 2),
        Record(profile: 5, level: 6, compatibility: 0),
        Record(profile: 7, level: 6, el: 1, compatibility: 6),
        Record(profile: 8, level: 13, compatibility: 1, compression: 1),
    ])
    func recordRoundTrips(_ record: Record) throws {
        let result = try #require(try Self.roundTrip(record))
        // Stock FFmpeg reads back no record: the PMT carries only the 'HEVC' registration.
        #expect(result.record == record)
        // Dolby's TS spec asks for the 'DOVI' registration only with compatibility ID 0
        // (section 7.1.2), and the demuxer reads the 0xb0 descriptor without it.
        #expect(result.hasDoviRegistration == (record.compatibility == 0))
        // The demuxer keeps the last registration as codec_tag, so 'DOVI' has to come first
        // or a stream copy to AVI loses its FourCC.
        #expect(result.codecTag == Self.hevcTag)
    }

    @Test("a stream without a record gets no Dolby Vision descriptor")
    func noRecordNoDescriptor() throws {
        let result = try #require(try Self.roundTrip(nil))
        #expect(result.record == nil)
        #expect(!result.hasDoviRegistration)
    }

    @Test("a base layer without its RPU gets no descriptor")
    func baseLayerWithoutRPUIsLeftAlone() throws {
        // What dovi_split=mode=bl leaves of a Profile 7 stream: plain HEVC, not Dolby Vision.
        let result = try #require(try Self.roundTrip(
            Record(profile: 7, level: 6, rpu: 0, el: 0, compatibility: 6)))
        #expect(result.record == nil)
        #expect(!result.hasDoviRegistration)
    }

    @Test("an enhancement layer without its base layer gets no descriptor")
    func enhancementLayerOnlyIsLeftAlone() throws {
        let result = try #require(try Self.roundTrip(
            Record(profile: 7, level: 6, el: 1, bl: 0, compatibility: 0)))
        #expect(result.record == nil)
        #expect(!result.hasDoviRegistration)
    }
}
