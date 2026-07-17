import Foundation
import Libavcodec
import Libavformat
import Libavutil

/// Copies Dolby Vision HEVC and compatible audio packets into a local fMP4
/// HLS playlist so AVPlayer receives the original DV bitstream and RPU data.
/// No video decoding or re-encoding happens here.
final class DolbyVisionRemuxer {
    var onReady: ((URL, Double) -> Void)?
    var onProgress: ((Double) -> Void)?
    var onFinished: (() -> Void)?
    var onIneligible: ((String) -> Void)?
    var onError: ((String) -> Void)?

    let directory: URL

    private let inputURLString: String
    private let startAtSeconds: Double
    private let preferredAudioLanguage: String

    init(input: String, startAt: Double, preferredAudioLanguage: String = "") {
        inputURLString = input
        startAtSeconds = max(startAt, 0)
        self.preferredAudioLanguage = preferredAudioLanguage
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dv-remux-\(UUID().uuidString)", isDirectory: true)
    }

    func start() {
        let thread = Thread { [self] in run() }
        thread.name = "DolbyVisionRemuxer"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    func cancel() {
        cancelled = true
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }

    @Locked private var cancelled = false
    private var readySignalled = false
    private var firstWrittenPTS: Double = .nan
    private var lastVideoPTS: Double = 0
    private var keyframes: [Double] = []
    private var segmentDurations: [Double] = []

    private var pendingBytes = Data()
    private var initPhase = true
    private var initData = Data()
    private var segmentData = Data()
    private var segmentOpen = false
    private var segmentIndex = 0

    private var playlistURL: URL {
        directory.appendingPathComponent("dolby-vision.m3u8")
    }

    private func run() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            report { self.onError?("Couldn't create the Dolby Vision segment directory") }
            return
        }

        var inputContext: UnsafeMutablePointer<AVFormatContext>?
        var outputContext: UnsafeMutablePointer<AVFormatContext>?
        var avioContext: UnsafeMutablePointer<AVIOContext>?
        defer {
            if let outputContext {
                outputContext.pointee.pb = nil
                avformat_free_context(outputContext)
            }
            if avioContext != nil {
                avio_context_free(&avioContext)
            }
            avformat_close_input(&inputContext)
        }

        inputContext = avformat_alloc_context()
        guard let allocatedInput = inputContext else {
            report { self.onError?("Couldn't allocate the input context") }
            return
        }

        var interrupt = AVIOInterruptCB()
        interrupt.opaque = Unmanaged.passUnretained(self).toOpaque()
        interrupt.callback = { opaque -> Int32 in
            guard let opaque else { return 0 }
            return Unmanaged<DolbyVisionRemuxer>.fromOpaque(opaque)
                .takeUnretainedValue().cancelled ? 1 : 0
        }
        allocatedInput.pointee.interrupt_callback = interrupt

        var openOptions: OpaquePointer?
        av_dict_set(&openOptions, "reconnect", "1", 0)
        av_dict_set(&openOptions, "reconnect_streamed", "1", 0)
        av_dict_set(&openOptions, "reconnect_delay_max", "5", 0)
        av_dict_set(&openOptions, "reconnect_on_network_error", "1", 0)
        av_dict_set(&openOptions, "rw_timeout", "20000000", 0)
        av_dict_set(&openOptions, "buffer_size", String(4 << 20), 0)
        var result = avformat_open_input(&inputContext, inputURLString, nil, &openOptions)
        av_dict_free(&openOptions)
        guard result == 0, inputContext != nil else {
            report { self.onError?("Couldn't open the source (\(result))") }
            return
        }

        result = avformat_find_stream_info(inputContext, nil)
        guard result >= 0 else {
            report { self.onError?("Couldn't probe the source (\(result))") }
            return
        }

        var videoIndex: Int32 = -1
        var audioIndex: Int32 = -1
        var dolbyVisionProfile: UInt8 = 0
        var bestAudioScore = -1

        let streamCount = Int(inputContext!.pointee.nb_streams)
        for index in 0..<streamCount {
            guard let stream = inputContext!.pointee.streams[index],
                  let parameters = stream.pointee.codecpar else { continue }

            let attachedPicture = (stream.pointee.disposition & AV_DISPOSITION_ATTACHED_PIC) != 0
            if parameters.pointee.codec_type == AVMEDIA_TYPE_VIDEO,
               !attachedPicture,
               videoIndex < 0,
               parameters.pointee.codec_id == AV_CODEC_ID_HEVC {
                if let sideData = av_packet_side_data_get(
                    parameters.pointee.coded_side_data,
                    parameters.pointee.nb_coded_side_data,
                    AV_PKT_DATA_DOVI_CONF
                ), sideData.pointee.size > 0, let bytes = sideData.pointee.data {
                    let record = bytes.withMemoryRebound(
                        to: AVDOVIDecoderConfigurationRecord.self,
                        capacity: 1
                    ) { $0.pointee }
                    dolbyVisionProfile = record.dv_profile
                    videoIndex = Int32(index)
                }
            } else if parameters.pointee.codec_type == AVMEDIA_TYPE_AUDIO {
                let codecScore: Int
                switch parameters.pointee.codec_id {
                case AV_CODEC_ID_EAC3: codecScore = 3
                case AV_CODEC_ID_AC3: codecScore = 2
                case AV_CODEC_ID_AAC: codecScore = 1
                default: codecScore = -1
                }
                guard codecScore > 0 else { continue }

                var languageBonus = 0
                if !preferredAudioLanguage.isEmpty,
                   let language = av_dict_get(stream.pointee.metadata, "language", nil, 0),
                   let value = language.pointee.value,
                   String(cString: value).hasPrefix(preferredAudioLanguage) {
                    languageBonus = 10
                }
                if codecScore + languageBonus > bestAudioScore {
                    bestAudioScore = codecScore + languageBonus
                    audioIndex = Int32(index)
                }
            }
        }

        guard videoIndex >= 0 else {
            report { self.onIneligible?("no Dolby Vision HEVC stream") }
            return
        }
        guard dolbyVisionProfile == 5 || dolbyVisionProfile == 8 else {
            report {
                self.onIneligible?(
                    "Dolby Vision profile \(dolbyVisionProfile) isn't supported by AVPlayer"
                )
            }
            return
        }
        guard audioIndex >= 0 else {
            report {
                self.onIneligible?("no E-AC3, AC3, or AAC audio track for native playback")
            }
            return
        }

        if startAtSeconds > 1 {
            let timestamp = Int64(startAtSeconds * 1_000_000)
            _ = av_seek_frame(inputContext, -1, timestamp, AVSEEK_FLAG_BACKWARD)
        }

        avformat_alloc_output_context2(&outputContext, nil, "mp4", nil)
        guard let outputContext else {
            report { self.onError?("The fragmented MP4 muxer isn't available") }
            return
        }
        outputContext.pointee.strict_std_compliance = FF_COMPLIANCE_EXPERIMENTAL
        outputContext.pointee.avoid_negative_ts = AVFMT_AVOID_NEG_TS_MAKE_ZERO

        let bufferSize: Int32 = 1 << 16
        guard let buffer = av_malloc(Int(bufferSize))?.assumingMemoryBound(to: UInt8.self) else {
            report { self.onError?("Couldn't allocate the remux buffer") }
            return
        }
        avioContext = avio_alloc_context(
            buffer,
            bufferSize,
            1,
            Unmanaged.passUnretained(self).toOpaque(),
            nil,
            { opaque, bytes, size -> Int32 in
                guard let opaque, let bytes, size > 0 else { return size }
                let remuxer = Unmanaged<DolbyVisionRemuxer>.fromOpaque(opaque)
                    .takeUnretainedValue()
                remuxer.consume(Data(bytes: bytes, count: Int(size)))
                return size
            },
            nil
        )
        guard let avioContext else {
            av_free(buffer)
            report { self.onError?("Couldn't create the remux output") }
            return
        }
        avioContext.pointee.seekable = 0
        outputContext.pointee.pb = avioContext

        guard let inputVideo = inputContext!.pointee.streams[Int(videoIndex)],
              let inputAudio = inputContext!.pointee.streams[Int(audioIndex)],
              let outputVideo = avformat_new_stream(outputContext, nil),
              let outputAudio = avformat_new_stream(outputContext, nil) else {
            report { self.onError?("Couldn't configure the remux streams") }
            return
        }

        avcodec_parameters_copy(outputVideo.pointee.codecpar, inputVideo.pointee.codecpar)
        avcodec_parameters_copy(outputAudio.pointee.codecpar, inputAudio.pointee.codecpar)
        outputAudio.pointee.codecpar.pointee.codec_tag = 0
        outputVideo.pointee.codecpar.pointee.codec_tag = dolbyVisionProfile == 5
            ? fourCC("d", "v", "h", "1")
            : fourCC("h", "v", "c", "1")

        // FFmpeg 8 stores global DV/HDR side data on AVCodecParameters;
        // avcodec_parameters_copy above carries it into movenc.

        var muxOptions: OpaquePointer?
        av_dict_set(
            &muxOptions,
            "movflags",
            "+frag_keyframe+empty_moov+default_base_moof",
            0
        )
        result = avformat_write_header(outputContext, &muxOptions)
        av_dict_free(&muxOptions)
        guard result >= 0 else {
            report { self.onError?("Couldn't write the remux header (\(result))") }
            return
        }

        guard let packet = av_packet_alloc() else {
            report { self.onError?("Couldn't allocate a media packet") }
            return
        }
        var packetToFree: UnsafeMutablePointer<AVPacket>? = packet
        defer { av_packet_free(&packetToFree) }

        let videoTimeBase = inputVideo.pointee.time_base
        let audioTimeBase = inputAudio.pointee.time_base
        var packetsSinceProgress = 0

        while !cancelled {
            let readResult = av_read_frame(inputContext, packet)
            if readResult < 0 {
                // AVERROR_EOF is a normal end. A network/I/O failure must not
                // turn a truncated remux into a seemingly complete VOD.
                let avErrorEOF: Int32 = -541_478_725
                if readResult != avErrorEOF {
                    report { self.onError?("The source stopped during remux (\(readResult))") }
                    return
                }
                break
            }
            defer { av_packet_unref(packet) }

            let inputIndex = packet.pointee.stream_index
            let isVideo = inputIndex == videoIndex
            let isAudio = inputIndex == audioIndex
            guard isVideo || isAudio else { continue }

            let timeBase = isVideo ? videoTimeBase : audioTimeBase
            if packet.pointee.pts != Int64.min {
                let ptsSeconds = Double(packet.pointee.pts) * av_q2d(timeBase)
                if firstWrittenPTS.isNaN { firstWrittenPTS = ptsSeconds }
                if isVideo {
                    lastVideoPTS = ptsSeconds
                    if (packet.pointee.flags & AV_PKT_FLAG_KEY) != 0 {
                        keyframes.append(ptsSeconds - firstWrittenPTS)
                    }
                }
            }

            let outputStream = isVideo ? outputVideo : outputAudio
            packet.pointee.stream_index = outputStream.pointee.index
            av_packet_rescale_ts(packet, timeBase, outputStream.pointee.time_base)
            packet.pointee.pos = -1

            result = av_interleaved_write_frame(outputContext, packet)
            if result < 0 {
                report { self.onError?("The remux stopped while writing (\(result))") }
                return
            }

            packetsSinceProgress += 1
            if packetsSinceProgress >= 100 {
                packetsSinceProgress = 0
                let written = max(
                    lastVideoPTS - (firstWrittenPTS.isNaN ? 0 : firstWrittenPTS),
                    0
                )
                report { self.onProgress?(written) }
            }
        }

        if cancelled { return }

        av_write_trailer(outputContext)
        finalizeOpenSegment()
        writePlaylist(ended: true)
        let written = max(
            lastVideoPTS - (firstWrittenPTS.isNaN ? 0 : firstWrittenPTS),
            0
        )
        signalReadyIfNeeded()
        report {
            self.onProgress?(written)
            self.onFinished?()
        }
    }

    private func consume(_ bytes: Data) {
        pendingBytes.append(bytes)
        while pendingBytes.count >= 8 {
            let declaredSize = pendingBytes.withUnsafeBytes { raw -> UInt64 in
                let size32 = UInt32(
                    bigEndian: raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
                )
                if size32 == 1, raw.count >= 16 {
                    return UInt64(
                        bigEndian: raw.loadUnaligned(fromByteOffset: 8, as: UInt64.self)
                    )
                }
                return UInt64(size32)
            }
            guard declaredSize >= 8, declaredSize < 1 << 32 else { return }
            let boxSize = Int(declaredSize)
            guard pendingBytes.count >= boxSize else { return }

            let box = pendingBytes.prefix(boxSize)
            let type = String(decoding: box.dropFirst(4).prefix(4), as: UTF8.self)
            pendingBytes.removeFirst(boxSize)
            dispatch(box: Data(box), type: type)
        }
    }

    private func dispatch(box: Data, type: String) {
        if initPhase {
            if type == "moof" {
                try? initData.write(to: directory.appendingPathComponent("init.mp4"))
                initPhase = false
                segmentData = box
                segmentOpen = true
            } else {
                initData.append(box)
            }
            return
        }

        if !segmentOpen {
            guard type == "moof" else { return }
            segmentData = box
            segmentOpen = true
            return
        }

        segmentData.append(box)
        if type == "mdat" { closeSegment() }
    }

    private func closeSegment() {
        let name = String(format: "segment-%05d.m4s", segmentIndex)
        try? segmentData.write(to: directory.appendingPathComponent(name))
        segmentData = Data()
        segmentOpen = false

        let duration: Double
        if segmentIndex + 1 < keyframes.count {
            duration = max(keyframes[segmentIndex + 1] - keyframes[segmentIndex], 0.04)
        } else {
            let base = keyframes.indices.contains(segmentIndex) ? keyframes[segmentIndex] : 0
            duration = max(
                lastVideoPTS - (firstWrittenPTS.isNaN ? 0 : firstWrittenPTS) - base + 0.04,
                0.04
            )
        }
        segmentDurations.append(duration)
        segmentIndex += 1

        writePlaylist(ended: false)
        if segmentIndex >= 3 { signalReadyIfNeeded() }
        let available = keyframes.indices.contains(segmentIndex)
            ? keyframes[segmentIndex]
            : max(lastVideoPTS - (firstWrittenPTS.isNaN ? 0 : firstWrittenPTS), 0)
        report { self.onProgress?(available) }
    }

    private func finalizeOpenSegment() {
        segmentData = Data()
        segmentOpen = false
    }

    private func writePlaylist(ended: Bool) {
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:\(Int((segmentDurations.max() ?? 6).rounded(.up)) + 1)",
            "#EXT-X-MEDIA-SEQUENCE:0",
            "#EXT-X-PLAYLIST-TYPE:\(ended ? "VOD" : "EVENT")",
            "#EXT-X-INDEPENDENT-SEGMENTS",
            "#EXT-X-MAP:URI=\"init.mp4\"",
        ]
        for (index, duration) in segmentDurations.enumerated() {
            lines.append(String(format: "#EXTINF:%.5f,", duration))
            lines.append(String(format: "segment-%05d.m4s", index))
        }
        if ended { lines.append("#EXT-X-ENDLIST") }

        let content = lines.joined(separator: "\n") + "\n"
        try? content.data(using: .utf8)?.write(to: playlistURL, options: .atomic)
    }

    private func signalReadyIfNeeded() {
        guard !readySignalled, segmentIndex > 0 else { return }
        readySignalled = true
        let actualStart = firstWrittenPTS.isNaN ? startAtSeconds : firstWrittenPTS
        report { self.onReady?(self.playlistURL, actualStart) }
    }

    private func report(_ block: @escaping () -> Void) {
        DispatchQueue.main.async { [self] in
            guard !cancelled else { return }
            _ = self
            block()
        }
    }

    private func fourCC(
        _ first: Character,
        _ second: Character,
        _ third: Character,
        _ fourth: Character
    ) -> UInt32 {
        UInt32(first.asciiValue!)
            | UInt32(second.asciiValue!) << 8
            | UInt32(third.asciiValue!) << 16
            | UInt32(fourth.asciiValue!) << 24
    }

}

@propertyWrapper
private final class Locked<Value> {
    private let lock = NSLock()
    private var value: Value

    init(wrappedValue: Value) {
        value = wrappedValue
    }

    var wrappedValue: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            value = newValue
        }
    }
}
