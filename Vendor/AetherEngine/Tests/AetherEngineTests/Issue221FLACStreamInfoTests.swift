import Testing
import Foundation
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// AE#221: a FLAC source whose `STREAMINFO` declares `min_blocksize = 0` produced an HLS asset AVFoundation
/// refused to open (`CoreMediaErrorDomain -12848` surfacing as `AVFoundationErrorDomain -11829 "Cannot Open"`),
/// so playback died on the first segment while the same file played fine in QuickTime.
///
/// `min_blocksize = 0` violates the FLAC spec (the field must be >= 16) but occurs in the wild: MKV -> MP4
/// remuxes carry the source `CodecPrivate` verbatim, and encoders that never rewrite `STREAMINFO` after a
/// streaming pass leave the field zeroed. libavcodec's decoder ignores it; CoreMedia validates it and rejects
/// the entire audio sample description. Because stream-copy hands the source extradata straight to movenc,
/// which serialises it into `dfLa` byte for byte, the defect propagated into every segment of the session.
///
/// Bisected against the reporter's asset: patching `min_blocksize` alone (0 -> max_blocksize) makes it play;
/// patching the equally-wrong `total_samples` alone does not. Hence the fix clamps that one field and leaves
/// every other `STREAMINFO` byte, md5 and `total_samples` included, untouched.
///
/// Media is a synthesized 0.25 s stereo FLAC-in-MP4 (valid STREAMINFO, min = max = 4608), degraded per test.
@Suite("AE#221: FLAC dfLa STREAMINFO sanitising")
struct Issue221FLACStreamInfoTests {

    // MARK: - Fixture plumbing

    /// Byte offset of the 34-byte STREAMINFO payload inside `data`: past `dfLa`, its version+flags word,
    /// and the metadata-block header.
    private static func streamInfoOffset(in data: Data) -> Int? {
        guard let r = data.range(of: Data("dfLa".utf8)) else { return nil }
        return r.upperBound + 4 + 4
    }

    private static func blockSizes(in data: Data) -> (min: UInt16, max: UInt16)? {
        guard let off = streamInfoOffset(in: data), off + 4 <= data.count else { return nil }
        let b = [UInt8](data[off..<(off + 4)])
        return (UInt16(b[0]) << 8 | UInt16(b[1]), UInt16(b[2]) << 8 | UInt16(b[3]))
    }

    /// The fixture with its STREAMINFO block sizes overwritten, i.e. the shape a bad remux ships.
    private static func fixture(minBlockSize: UInt16? = nil, maxBlockSize: UInt16? = nil) -> Data {
        var data = data(flacBase64)
        guard let off = streamInfoOffset(in: data) else { return data }
        if let minBlockSize {
            data[off] = UInt8(minBlockSize >> 8)
            data[off + 1] = UInt8(minBlockSize & 0xFF)
        }
        if let maxBlockSize {
            data[off + 2] = UInt8(maxBlockSize >> 8)
            data[off + 3] = UInt8(maxBlockSize & 0xFF)
        }
        return data
    }

    private static func data(_ base64: String) -> Data {
        guard let d = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else {
            Issue.record("failed to decode embedded base64 fixture")
            return Data()
        }
        return d
    }

    /// Opens `data` and hands the audio codecpar to `body`; the demuxer outlives the call.
    private static func withAudioCodecpar(
        _ data: Data,
        _ body: (UnsafePointer<AVCodecParameters>) throws -> Void
    ) throws {
        let demuxer = Demuxer()
        defer { demuxer.close() }
        try demuxer.open(reader: DataIOReader(data: data), formatHint: "mp4")
        guard let stream = demuxer.stream(at: demuxer.audioStreamIndex) else {
            Issue.record("fixture must expose an audio stream")
            return
        }
        try body(UnsafePointer(stream.pointee.codecpar))
    }

    /// A hand-built FLAC codecpar carrying `streamInfo` verbatim. Needed where libavformat refuses to open
    /// the media at all (a STREAMINFO with both blocksizes zeroed fails its probe), so the sanitiser's own
    /// guards stay reachable from a test.
    private static func withSynthesizedFLACCodecpar(
        streamInfo: [UInt8],
        _ body: (UnsafePointer<AVCodecParameters>) -> Void
    ) {
        guard let codecpar = avcodec_parameters_alloc() else {
            Issue.record("avcodec_parameters_alloc failed")
            return
        }
        defer {
            var p: UnsafeMutablePointer<AVCodecParameters>? = codecpar
            avcodec_parameters_free(&p)
        }
        codecpar.pointee.codec_type = AVMEDIA_TYPE_AUDIO
        codecpar.pointee.codec_id = AV_CODEC_ID_FLAC
        let total = streamInfo.count + Int(AV_INPUT_BUFFER_PADDING_SIZE)
        guard let buf = av_malloc(total)?.assumingMemoryBound(to: UInt8.self) else {
            Issue.record("av_malloc failed")
            return
        }
        streamInfo.withUnsafeBufferPointer { src in
            if let base = src.baseAddress { memcpy(buf, base, streamInfo.count) }
        }
        memset(buf + streamInfo.count, 0, Int(AV_INPUT_BUFFER_PADDING_SIZE))
        codecpar.pointee.extradata = buf
        codecpar.pointee.extradata_size = Int32(streamInfo.count)
        body(UnsafePointer(codecpar))
    }

    /// The fixture's STREAMINFO payload with both blocksize fields overwritten.
    private static func streamInfoBytes(minBlockSize: UInt16, maxBlockSize: UInt16) -> [UInt8] {
        let data = fixture(minBlockSize: minBlockSize, maxBlockSize: maxBlockSize)
        guard let off = streamInfoOffset(in: data), off + 34 <= data.count else { return [] }
        return [UInt8](data[off..<(off + 34)])
    }

    // MARK: - The defect: an illegal min_blocksize reaches dfLa verbatim

    @Test("min_blocksize = 0 is clamped up to max_blocksize")
    func zeroMinBlockSizeIsClamped() throws {
        try Self.withAudioCodecpar(Self.fixture(minBlockSize: 0)) { codecpar in
            guard let fixed = MP4SegmentMuxer.sanitizedFLACExtradata(codecpar) else {
                Issue.record("an illegal min_blocksize must be repaired")
                return
            }
            #expect(UInt16(fixed[0]) << 8 | UInt16(fixed[1]) == 4608,
                    "min_blocksize takes the only blocksize the container attests to")
            #expect(UInt16(fixed[2]) << 8 | UInt16(fixed[3]) == 4608, "max_blocksize is not touched")
        }
    }

    @Test("only the two min_blocksize bytes change; md5 and total_samples survive")
    func sanitiserIsSurgical() throws {
        let broken = Self.fixture(minBlockSize: 0)
        try Self.withAudioCodecpar(broken) { codecpar in
            guard let fixed = MP4SegmentMuxer.sanitizedFLACExtradata(codecpar) else {
                Issue.record("an illegal min_blocksize must be repaired")
                return
            }
            let original = [UInt8](UnsafeBufferPointer(
                start: codecpar.pointee.extradata,
                count: Int(codecpar.pointee.extradata_size)
            ))
            #expect(fixed.count == original.count, "sanitising must not resize STREAMINFO")
            #expect(Array(fixed.dropFirst(2)) == Array(original.dropFirst(2)),
                    "every byte past min_blocksize, md5 and total_samples included, is left alone")
        }
    }

    @Test("a spec-legal STREAMINFO is left alone")
    func validStreamInfoIsUntouched() throws {
        try Self.withAudioCodecpar(Self.fixture()) { codecpar in
            #expect(MP4SegmentMuxer.sanitizedFLACExtradata(codecpar) == nil,
                    "min = max = 4608 is legal; rewriting it would be gratuitous")
        }
    }

    @Test("min_blocksize below the spec floor of 16 is repaired too", arguments: [UInt16(1), UInt16(15)])
    func subSpecFloorMinBlockSizeIsRepaired(_ minBlockSize: UInt16) throws {
        try Self.withAudioCodecpar(Self.fixture(minBlockSize: minBlockSize)) { codecpar in
            #expect(MP4SegmentMuxer.sanitizedFLACExtradata(codecpar) != nil,
                    "the spec floor is 16, not 1")
        }
    }

    @Test("an equally broken max_blocksize leaves nothing to clamp to")
    func unrepairableWhenMaxBlockSizeIsAlsoIllegal() {
        Self.withSynthesizedFLACCodecpar(
            streamInfo: Self.streamInfoBytes(minBlockSize: 0, maxBlockSize: 0)
        ) { codecpar in
            #expect(MP4SegmentMuxer.sanitizedFLACExtradata(codecpar) == nil,
                    "inventing a blocksize the container never attested to is a guess, not a repair")
        }
    }

    @Test("extradata too short to be a STREAMINFO is not touched")
    func truncatedExtradataIsIgnored() {
        Self.withSynthesizedFLACCodecpar(
            streamInfo: Array(Self.streamInfoBytes(minBlockSize: 0, maxBlockSize: 4608).prefix(33))
        ) { codecpar in
            #expect(MP4SegmentMuxer.sanitizedFLACExtradata(codecpar) == nil,
                    "a short buffer is not a STREAMINFO to reason about")
        }
    }

    @Test("non-FLAC audio is never rewritten")
    func nonFLACIsIgnored() throws {
        try Self.withAudioCodecpar(Self.data(Self.aacBase64)) { codecpar in
            #expect(MP4SegmentMuxer.sanitizedFLACExtradata(codecpar) == nil,
                    "the sanitiser is keyed on codec id; AAC extradata is not STREAMINFO")
        }
    }

    // MARK: - End to end: what the muxer actually serialises into dfLa

    @Test("the muxer writes a legal dfLa for a source whose STREAMINFO is degenerate")
    func muxerWritesLegalDfla() throws {
        let rig = try Rig()
        try rig.open(audio: Self.fixture(minBlockSize: 0))
        let muxer = try rig.makeMuxer()
        try rig.writeAllVideoPackets(into: muxer)
        guard case .completed = muxer.cutFragmentForNextSegment(1) else {
            Issue.record("FLAC needs no parsed packet for its sample entry, so the first cut completes")
            return
        }
        guard let initBytes = rig.initBytes, let sizes = Self.blockSizes(in: initBytes) else {
            Issue.record("init.mp4 must carry a dfLa box")
            return
        }
        #expect(sizes.min == 4608, "the illegal 0 must not reach the segment CoreMedia validates")
        #expect(sizes.max == 4608)
    }

    @Test("a healthy source still round-trips its STREAMINFO unchanged")
    func healthySourceRoundTrips() throws {
        let rig = try Rig()
        try rig.open(audio: Self.fixture())
        let muxer = try rig.makeMuxer()
        try rig.writeAllVideoPackets(into: muxer)
        _ = muxer.cutFragmentForNextSegment(1)
        guard let initBytes = rig.initBytes, let sizes = Self.blockSizes(in: initBytes) else {
            Issue.record("init.mp4 must carry a dfLa box")
            return
        }
        #expect(sizes.min == 4608)
        #expect(sizes.max == 4608)
    }

    // MARK: - Harness

    /// One muxer under test plus the demuxers whose codecpar it points at (they must outlive it).
    private final class Rig {
        let videoDemuxer = Demuxer()
        let audioDemuxer = Demuxer()
        let sessionDir: URL
        var initBytes: Data?
        var muxer: MP4SegmentMuxer?

        init() throws {
            sessionDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("ae221-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        }

        deinit {
            muxer = nil
            videoDemuxer.close()
            audioDemuxer.close()
            try? FileManager.default.removeItem(at: sessionDir)
        }

        func open(audio: Data) throws {
            try videoDemuxer.open(
                reader: DataIOReader(data: Issue221FLACStreamInfoTests.data(
                    AtmosDetectionProbeIntegrationTests.videoOnlyBase64)),
                formatHint: "mp4"
            )
            try audioDemuxer.open(reader: DataIOReader(data: audio), formatHint: "mp4")
        }

        func makeMuxer() throws -> MP4SegmentMuxer {
            guard let vStream = videoDemuxer.stream(at: videoDemuxer.videoStreamIndex),
                  let aStream = audioDemuxer.stream(at: audioDemuxer.audioStreamIndex) else {
                throw RigError.missingStream
            }
            let m = try MP4SegmentMuxer(
                initialSegmentIndex: 0,
                sessionDir: sessionDir,
                video: MP4SegmentMuxer.VideoConfig(
                    codecpar: UnsafePointer(vStream.pointee.codecpar),
                    timeBase: vStream.pointee.time_base,
                    codecTagOverride: nil
                ),
                audio: MP4SegmentMuxer.AudioConfig(
                    codecpar: UnsafePointer(aStream.pointee.codecpar),
                    timeBase: aStream.pointee.time_base
                ),
                onInitCaptured: { [self] bytes in self.initBytes = bytes }
            )
            muxer = m
            return m
        }

        @discardableResult
        func writeAllVideoPackets(into muxer: MP4SegmentMuxer) throws -> Int {
            guard let vStream = videoDemuxer.stream(at: videoDemuxer.videoStreamIndex) else { return 0 }
            let sourceTb = vStream.pointee.time_base
            var written = 0
            while let pkt = try videoDemuxer.readPacket() {
                var p: UnsafeMutablePointer<AVPacket>? = pkt
                defer { trackedPacketFree(&p) }
                guard pkt.pointee.stream_index == videoDemuxer.videoStreamIndex else { continue }
                pkt.pointee.stream_index = muxer.videoOutputStreamIndex
                av_packet_rescale_ts(pkt, sourceTb, muxer.muxerVideoTimeBase)
                _ = muxer.writePacket(pkt)
                written += 1
            }
            return written
        }

        enum RigError: Error { case missingStream }
    }

    private static let aacBase64 = AtmosDetectionProbeIntegrationTests.aacBase64

    /// 0.25 s stereo 48 kHz FLAC in MP4, encoded by libavcodec: STREAMINFO min = max = 4608, i.e. valid.
    private static let flacBase64 = """
    AAAAHGZ0eXBpc29tAAACAGlzb21pc28ybXA0MQAAAAhmcmVlAAANVW1kYXT/+FqIADdOAAAApgFM
    AfIClQM2A9UEcOak0hlIACu4h58+kx98RXSAEOc4eQzMkmYcmEpIcw8kzSSbCS5yyZpk/JPSaGTM
    mTMnOSSZmHJMyZkmckpOTMwyyH0kpLJTOSmSzA+ZJPJNMk5hOZCTyZhOZOTyTyFPPhPZJpkynnzJ
    NknKHmEpknJJpJMySZJskJTmcnmQynk880mZ5h5M5OYSkh5JkklJmkDOQ5PJOckPJnJZJyfIWeZJ
    Z5JyTzPJM5kkzIcmZDPJkzCXJkyUmTJSTTM+ZScsOkyknmQ+QlwkyYTmQzkknkkOQpzOczkyfmZS
    eZzPMnhyczKYTSSQ8OE4Zk4ZwmRJJnyTyGeTLJm5JzLJnJyTyTQyTJJZJCeQzmGSZJM8hPJhSTLD
    PJ8h8z55CdhkzJyTNMMk5JkmQ5mSZSTmTkyw6SefhzIYmTSck8mTpJzJwnk5JNCZJnhMk8nkmZJ5
    kz5mk5mmSc5lhJznDnOHkMzJJmHJhKSHMPJM0kmwkucsmaZPyT0mhkzJkzJzkkmZhyTMmZJnJKTk
    zMMsh9JKSyUzkpkswPmSTyTTJOYTmQk8mYTmTk8k8hTz4T2SaZMp58yTZJyh5hKZJySaSTMkmSbJ
    CU5nJ5kMp5PPNJmeYeTOTmEpIeSZJJSZpAzkOTyTnJDyZyWScnyFnmSWeSck8zyTOZJMyHJmQzyZ
    MwlyZMlJkyUk0zPmUnLDpMpJ5kPkJcJMmE5kM5JJ5JDkKcznM5Mn5mUnmczzJ4cnMymE0kkPDhOG
    ZOGcJkSSZ8k8hnkyyZuScyyZyck8k0MkySWSQnkM5hkmSTPITyYUkywzyfIfM+eQnYZMyckzTDJO
    SZJkOZkmUk5k5MsOknn4cyGJk0nJPJk6ScycJ5OSTQmSZ4TJPJ5JmSeZM+ZpOZpknOZYSc5w5zh5
    DMySZhyYSkhzDyTNJJsJLnLJmmT8k9JoZMyZMyc5JJmYckzJmSZySk5MzDLIfSSkslM5KZLMD5kk
    8k0yTmE5kJPJmE5k5PJPIU8+E9kmmTKefMk2ScoeYSmSckmkkzJJkmyQlOZyeZDKeTzzSZnmHkzk
    5hKSHkmSSUmaQM5Dk8k5yQ8mclknJ8hZ5klnknJPM8kzmSTMhyZkM8mTMJcmTJSZMlJNMz5lJyw6
    TKSeZD5CXCTJhOZDOSSeSQ5CnM5zOTJ+ZlJ5nM8yeHJzMphNJJDw4ThmThnCZEkmfJPIZ5Msmbkn
    MsmcnJPJNDJMklkkJ5DOYZJkkzyE8mFJMsM8nyHzPnkJ2GTMnJM0wyTkmSZDmZJlJOZOTLDpJ5+H
    MhiZNJyTyZOknMnCeTkk0JkmeEyTyeSZknmTPmaTmaZJzmWEnOcOc4eQzMkmYcmEpIcw8kzSSbCS
    5yyZpk/JPSaGTMmTMnOSSZmHJMyZkmckpOTMwyyH0kpLJTOSmSzA+ZJPJNMk5hOZCTyZhOZOTyTy
    FPPhPZJpkynnzJNknKHmEpknJJpJMySZJskJTmcnmQynk880mZ5h5M5OYSkh5JkklJmkDOQ5PJOc
    kPJnJZJyfIWeZJZ5JyTzPJM5kkzIcmZDPJkzCXJkyUmTJSTTM+ZScsOkyknmQ+QlwkyYTmQzkknk
    kOQpzOczkyfmZSeZzPMnhyczKYTSSQ8OE4Zk4ZwmRJJnyTyGeTLJm5JzLJnJyTyTQyTJJZJCeQzm
    GSZJM8hPJhSTLDPJ8h8z55CdhkzJyTNMMk4AAAAiyv/4WogBME4LSgtQC0wLPgsnCwcK3Qqp5qVO
    GG3+D7hvo76dP5YFMoAEPmSZSTmTkyw8kmTnDkkNMmk5JmTJ0JOZOHycyaTJKeTJPJ5JmSeZM5mc
    mTNMk4cywk5zhznDyZnMzDkwlM5h5Jmkk2EnJk5M0yc5J6TQyZkyZk5ySSmYczyZznJKTkzMM5D6
    SUnJSTkpJLMD5kk8k0zOZPkM2TMJzJyeSeQp58J8kmmTKeTzJJZJyh5hKZJySaSTyTkmyQlOZyeZ
    DKZkPJk0kmeYeTOTmEpJ85MlJ6QzkOTzOckLkzkpJOTOQ54ZJzyTknmeSZzJmZOcyGeSkzCXJkyU
    mTJSTmZMzKTlhmTKSeZD5CXJzk5kM5MnkkOQpzOczkyfhmUmZJzJkyeHJzMpk0kkPDk4eTh8JkSS
    Z8k8hmZM5JNMhOZZM5OSeSaGSZJLJJ8hnMMk5JnwnkwpJlhnk+Q+SeTyE7DJmTkmaYZmknOQ+ZJl
    JOZOTLDySZOcOSQ0yaTkmZMnQk5k4fJzJpMkp5Mk8nkmZJ5kzmZyZM0yThzLCTnOHOcPJmczMOTC
    UzmHkmaSTYScmTkzTJzknpNDJmTJmTnJJKZhzPJnOckpOTMwzkPpJSclJOSkkswPmSTyTTM5k+Qz
    ZMwnMnJ5J5CnnwnySaZMp5PMklknKHmEpknJJpJPJOSbJCU5nJ5kMpmQ8mTSSZ5h5M5OYSknzkyU
    npDOQ5PM5yQuTOSkk5M5DnhknPJOSeZ5JnMmZk5zIZ5KTMJcmTJSZMlJOZkzMpOWGZMpJ5kPkJcn
    OTmQzkyeSQ5CnM5zOTJ+GZSZknMmTJ4cnMymTSSQ8OTh5OHwmRJJnyTyGZkzkk0yE5lkzk5J5JoZ
    JkksknyGcwyTkmfCeTCkmWGeT5D5J5PITsMmZOSZphmaSc5D5kmUk5k5MsPJJk5w5JDTJpOSZkyd
    CTmTh8nMmkySnkyTyeSZknmTOZnJkzTJOHMsJOc4c5w8mZzMw5MJTOYeSZpJNhJyZOTNMnOSek0M
    mZMmZOckkpmHM8mc5ySk5MzDOQ+klJyUk5KSSzA+ZJPJNMzmT5DNkzCcycnknkKefCfJJpkynk8y
    SWScoeYSmSckmkk8k5JskJTmcnmQymZDyZNJJnmHkzk5hKSfOTJSekM5Dk8znJC5M5KSTkzkOeGS
    c8k5J5nkmcyZmTnMhnkpMwlyZMlJkyUk5mTMyk5YZkyknmQ+Qlyc5OZDOTJ5JDkKcznM5Mn4ZlJm
    ScyZMnhyczKZNJJDw5OHk4fCZEkmfJPIZmTOSTTITmWTOTknkmhkmSSySfIZzDJOSZ8J5MKSZYZ5
    PkPknk8hOwyZk5JmmGZpJzkPmSZSTmTkyw8kmTnDkkNMmk5JmTJ0JOZOHycyaTJKeTJPJ5JmSeZM
    5mcmTNMk4cywk5zhznDyZnMzDkwlM5h5Jmkk2EnJk5M0yc5J6TQyZkyZk5ySSmYczyZznJKTkzMM
    5D6SUnJSTkpJLMD5kk8k0zOZPkM2TMJzJyeSeQp58J8kmmTKeTzJJZJyh5hKZJySaSTyTkmyQlOZ
    yeZDKZkPJk0kmeYeTOTmEpJ85MlJ6QzkOTzOckLkzkpJOTOQ54ZJzyTknmeSZzJmZOcyGeSkzCXJ
    kyUmTJSTmZMzKTlhmTKSeZD5CXJzk5kM5MnkkOQpzOczkyfhmUmZJzJkyeHJzMpk0kkPDk4eTh8J
    kQAAAABzlP/4eogCCt+xTgFrAMUAHv94/tH+Lf2J/OfmrZIJzeHHqsgALzz/3UMsgBJJ5CmZMsmc
    yTklJM5OTmZoZmSaTJ5JTmFJySZ8JyTCkmFIU8mZIXJmZPITsMmZOSZphknCcnIfMkyhJZzkykPC
    eTkw5JDQycnJMzk6EnDJw+TmeEySnnJPJ5mZnhkzmZyZDOGScOZYScOcOcyHkplJmYclCUwsw8Mz
    SSbCSyZLJnMnOSZwmhnMmTDJzmSUzCzPJTJzklIcnmFMkPKElJZKSclJJEmB8pJ8k0MzmE5kzyeH
    mTk5MzIUzPIc5J4ZMocnzJJZPKHlDQyTmdCTmZyTZISnM5PMhlPJZOTSSZ5hcJkycw0ksk5OUnpC
    nJyeZk5IXJTkpJOTMks8MkyeSckzMzJKcyZmTmmSnkpMwlyUmSkyZpJwzDmZScLDKEyklMyHyEuE
    5wnMmcmTzJZCmTOcpyZM8MyhMyThnJk8NJyTKGdJMLhwnDycPgciSTDySeQpmTLJnMk5JSTOTk5m
    aGZkmkyeSU5hSckmfCckwpJhSFPJmSFyZmTyE7DJmTkmaYZJwnJyHzJMoSWc5MpDwnk5MOSQ0MnJ
    yTM5OhJwycPk5nhMkp5yTyeZmZ4ZM5mcmQzhknDmWEnDnDnMh5KZSZmHJQlMLMPDM0kmwksmSyZz
    JzkmcJoZzJkwyc5klMwszyUyc5JSHJ5hTJDyhJSWSknJSSRJgfKSfJNDM5hOZM8nh5k5OTMyFMzy
    HOSeGTKHJ8ySWTyh5Q0Mk5nQk5mck2SEpzOTzIZTyWTk0kmeYXCZMnMNJLJOTlJ6QpycnmZOSFyU
    5KSTkzJLPDJMnknJMzMySnMmZk5pkp5KTMJclJkpMmaScMw5mUnCwyhMpJTMh8hLhOcJzJnJk8yW
    QpkznKcmTPDMoTMk4ZyZPDSckyhnSTC4cJw8nD4HIkkw8knkKZkyyZzJOSUkzk5OZmhmZJpMnklO
    YUnJJnwnJMKSYUhTyZkhcmZk8hOwyZk5JmmGScJych8yTKElnOTKQ8J5OTDkkNDJyckzOToScMnD
    5OZ4TJKeck8nmZmeGTOZnJkM4ZJw5lhIAAAAE0UAAALhbW9vdgAAAGxtdmhkAAAAAAAAAAAAAAAA
    AAAD6AAAAPoAAQAAAQAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABA
    AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAAgt0cmFrAAAAXHRraGQAAAADAAAAAAAA
    AAAAAAABAAAAAAAAAPoAAAAAAAAAAAAAAAEBAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAA
    AAAAAABAAAAAAAAAAAAAAAAAAAAkZWR0cwAAABxlbHN0AAAAAAAAAAEAAAD6AAAAAAABAAAAAAGD
    bWRpYQAAACBtZGhkAAAAAAAAAAAAAAAAAAC7gAAALuBVxAAAAAAALWhkbHIAAAAAAAAAAHNvdW4A
    AAAAAAAAAAAAAABTb3VuZEhhbmRsZXIAAAABLm1pbmYAAAAQc21oZAAAAAAAAAAAAAAAJGRpbmYA
    AAAcZHJlZgAAAAAAAAABAAAADHVybCAAAAABAAAA8nN0YmwAAAB6c3RzZAAAAAAAAAABAAAAamZM
    YUMAAAAAAAAAAQAAAAAAAAAAAAIAEAAAAAC7gAAAAAAAMmRmTGEAAAAAgAAAIhIAEgAAAzQABRIL
    uALwAAAu4DIS0+HCo78CcE4F0KYNwaQAAAAUYnRydAAAAAAAAfQAAAGpoAAAACBzdHRzAAAAAAAA
    AAIAAAACAAASAAAAAAEAAArgAAAAHHN0c2MAAAAAAAAAAQAAAAEAAAADAAAAAQAAACBzdHN6AAAA
    AAAAAAAAAAADAAAFEgAABQcAAAM0AAAAFHN0Y28AAAAAAAAAAQAAACwAAABidWR0YQAAAFptZXRh
    AAAAAAAAACFoZGxyAAAAAAAAAABtZGlyYXBwbAAAAAAAAAAAAAAAAC1pbHN0AAAAJal0b28AAAAd
    ZGF0YQAAAAEAAAAATGF2ZjYyLjEyLjEwMQ==
    """
}
