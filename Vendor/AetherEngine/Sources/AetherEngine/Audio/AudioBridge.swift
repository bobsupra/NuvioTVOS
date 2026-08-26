import Foundation
import AetherLibavcodec
import AetherLibavutil
import AetherLibswresample

/// Transcoding bridge for the HLS-fMP4 pipeline's audio sidecar. Decodes a source stream (TrueHD, DTS, DTS-HD MA,
/// Vorbis, PCM, MP2) to PCM, resamples, re-encodes in one of two modes, emits packets HLSSegmentProducer writes
/// alongside video in the same fMP4 fragments.
///
/// Motivation: AVPlayer's fMP4 path decodes AAC/AC3/EAC3 (incl. Atmos JOC)/FLAC/ALAC/MP3/Opus directly, but FFmpeg's
/// mp4 muxer can't always stream-copy EAC3 from MKV (the dec3 box needs pre-parsed extradata MKV CodecPrivate often
/// lacks -> avformat_write_header -22 EINVAL); TrueHD/DTS aren't legal in fMP4 per ISOBMFF+HLS spec. FLAC and EAC3
/// are legal and decode everywhere on Apple devices, so reroute through one.
///
/// Atmos object metadata survives neither mode (TrueHD-MAT objects interleaved in the source, FFmpeg's EAC3 encoder
/// produces no JOC, FLAC has no object channel concept). EAC3+JOC sources stay lossless via the stream-copy path
/// that bypasses this bridge; only non-stream-copyable sources enter here.
///
/// Encoder choice. Public so LoadOptions / the host pass it through; default `.surroundCompat` (soundbar /
/// LPCM-stereo-only install base is the consumer majority).
///   - `.surroundCompat`: EAC3 128 kbps/channel (256 stereo, 768 5.1), AVPlayer -> HDMI bitstream tunnel. Lossy,
///     caps at 5.1 (7.1 loses SL/SR), but surround works on essentially every AVR + soundbar including LPCM-stereo-
///     only routes (Sonos Arc, Samsung HW-Q, Bose) where FLAC falls down.
///   - `.lossless`: FLAC up to 7.1, AVPlayer -> LPCM HDMI route. Needs a multichannel-LPCM sink (Denon/Marantz/NAD);
///     a stereo-LPCM route downmixes to stereo.
public enum AudioBridgeMode: String, Sendable, CaseIterable {
    case surroundCompat
    case lossless
}

final class AudioBridge: @unchecked Sendable {

    // MARK: - Mode

    typealias Mode = AudioBridgeMode

    // MARK: - Encoder shape

    /// The encoder a mode opens for a given source. `.lossless` is FLAC unconditionally;
    /// `.surroundCompat` is EAC3 only where there is surround to carry.
    ///
    /// A mode is not an encoder. `.surroundCompat` exists so that multichannel survives a route that
    /// cannot take multichannel LPCM, and on a source of two channels or fewer it has nothing to carry:
    /// its EAC3 output is then lossy where the FLAC the same build already ships is lossless, and it is
    /// a Dolby bitstream on every route that can only pass one through rather than decode it. AE#395 is
    /// what that costs in the field: on an AirPlay 2 optical adapter the stream-copied AC3 5.1 of one
    /// MPEG-TS program played and the bridged EAC3 stereo from the same program was silent, so which
    /// track `av_find_best_stream` happened to pick decided whether the viewer heard anything.
    ///
    /// The input is the SOURCE's channel count, never the current output route. Route-dependent bridging
    /// was measured wrong in #34 (AVPlayer downmixes EAC3+JOC natively over A2DP) and removed; this is a
    /// static property of the source, so a route change cannot make it disagree with itself mid-session.
    static func bridgeEncoder(for mode: Mode, sourceChannels: Int32) -> AVCodecID {
        switch mode {
        case .lossless:       return AV_CODEC_ID_FLAC
        case .surroundCompat: return sourceChannels > 2 ? AV_CODEC_ID_EAC3 : AV_CODEC_ID_FLAC
        }
    }

    /// The other encoder a build can carry, for the #165 cascade when the resolved one is absent.
    static func alternateEncoder(to missing: AVCodecID) -> AVCodecID {
        missing == AV_CODEC_ID_EAC3 ? AV_CODEC_ID_FLAC : AV_CODEC_ID_EAC3
    }

    /// Channel ceiling per bridge encoder. EAC3 sits at 6 because FFmpeg's encoder caps there until the
    /// dependent-substream patch lands upstream (a 7.1 source is folded to 5.1); FLAC carries 7.1 whole,
    /// and 8 is also Apple's HDMI LPCM ceiling.
    ///
    /// Pure and named rather than inline, because docs/formats.md quotes both numbers and
    /// `DocumentedConstantsTests` pins them: a cap that moves without the sentence moving with it
    /// is a doc that lies in a paragraph that still reads perfectly.
    static func maxEncodedChannels(for encoder: AVCodecID) -> Int32 {
        encoder == AV_CODEC_ID_EAC3 ? 6 : 8
    }

    /// EAC3 scales at 128 kbps per resolved channel (Dolby's transparent reference profile): 256
    /// kbps stereo, 768 kbps 5.1, and 1024 kbps if the cap above ever reaches 8. FLAC is VBR, so
    /// its rate is 0 (unlimited) rather than a number.
    static func encoderBitRate(for encoder: AVCodecID, channels: Int32) -> Int64 {
        encoder == AV_CODEC_ID_EAC3 ? Int64(channels) * 128_000 : 0
    }

    // MARK: - Errors

    enum AudioBridgeError: Error, CustomStringConvertible, LocalizedError {
        case decoderNotFound(codecID: UInt32)
        case decoderAllocFailed
        case decoderParametersFailed(code: Int32)
        case decoderOpenFailed(code: Int32)
        case encoderNotFound(codecID: AVCodecID)
        case encoderAllocFailed
        case encoderOpenFailed(code: Int32)
        case codecparAllocFailed
        case resamplerAllocFailed(code: Int32)
        case resamplerInitFailed(code: Int32)
        case sendPacketFailed(code: Int32)
        case sendFrameFailed(code: Int32)

        var description: String {
            switch self {
            case .decoderNotFound(let id):       return "AudioBridge: no FFmpeg decoder for source codec id \(id)"
            case .decoderAllocFailed:            return "AudioBridge: avcodec_alloc_context3 (decoder) failed"
            case .decoderParametersFailed(let c): return "AudioBridge: avcodec_parameters_to_context returned \(c)"
            case .decoderOpenFailed(let c):      return "AudioBridge: source decoder open failed (\(c))"
            case .encoderNotFound(let id):
                let name = avcodec_get_name(id).map { String(cString: $0) } ?? "id \(id.rawValue)"
                return "AudioBridge: bridge encoder \(name) not registered (FFmpeg build missing --enable-encoder=\(name)?)"
            case .encoderAllocFailed:            return "AudioBridge: avcodec_alloc_context3 (encoder) failed"
            case .encoderOpenFailed(let c):      return "AudioBridge: encoder open failed (\(c))"
            case .codecparAllocFailed:           return "AudioBridge: avcodec_parameters_alloc failed"
            case .resamplerAllocFailed(let c):   return "AudioBridge: swr_alloc_set_opts2 returned \(c)"
            case .resamplerInitFailed(let c):    return "AudioBridge: swr_init returned \(c)"
            case .sendPacketFailed(let c):       return "AudioBridge: avcodec_send_packet (decoder) returned \(c)"
            case .sendFrameFailed(let c):        return "AudioBridge: avcodec_send_frame (encoder) returned \(c)"
            }
        }

        var errorDescription: String? { description }
    }

    // MARK: - State

    private var decoderCtx: UnsafeMutablePointer<AVCodecContext>?
    private var encoderCtx: UnsafeMutablePointer<AVCodecContext>?
    private var swrCtx: OpaquePointer?
    /// The (sample_fmt, sample_rate, ch_layout) the swr context's INPUT side is currently configured for.
    /// Seeded at init from the decoder, then re-derived from each decoded frame in resampleAndPushIntoFIFO:
    /// libswresample reads raw extended_data per its configured input format, so the config MUST match the
    /// frame the decoder actually produced. The init seed is only a guess - dca/mlp leave sample_fmt
    /// unresolved at open unless avformat_find_stream_info pre-decoded a probe frame, and a bailed probe
    /// (live MPEG-TS) leaves it AV_SAMPLE_FMT_NONE -> the FLTP fallback. Reconfiguring from the frame keeps
    /// every codec/container correct (no S32P-XLL-misread-as-FLTP noise). swrInLayout is owned: uninit it
    /// before overwrite and in cleanup.
    private var swrInFmt: AVSampleFormat = AV_SAMPLE_FMT_NONE
    private var swrInRate: Int32 = 0
    private var swrInLayout = AVChannelLayout()
    /// FIFO buffering resampled PCM until >= encoderCtx.frame_size samples. FLAC's wrapper has
    /// AV_CODEC_CAP_SMALL_LAST_FRAME but not VARIABLE_FRAME_SIZE, so non-final frames must hit frame_size exactly
    /// (~4608 @48kHz); EAC3 decodes 1536 samples/packet, so without the FIFO we'd hit -22 EINVAL on the first send.
    private var fifo: OpaquePointer?

    /// Serializes the public mutators (feed/flush/startSegment/noteTimelineJump/close) against each
    /// other. On a producer restart whose old pump did not exit within the 5s budget (slow/remote
    /// source), the abandoned pump can still be inside feed() while the restart thread calls
    /// startSegment() on this otherwise lock-free bridge; concurrent libswresample/libavcodec calls on
    /// the same contexts are a data race. Uncontended in the normal single-pump case. Mirrors
    /// AudioDecoder.stateLock. Diagnostic reads (fifoSampleCount/liveBytes) stay lock-free; the engine
    /// lifecycle (restartLock ref-handoff + waitForFinish-gated cleanup) forecloses their races.
    private let opLock = NSLock()

    /// PCM intermediate format end-to-end (resampler -> FIFO -> encoder). S16 for lossy sources (EAC3/AC3);
    /// S32 @ bits_per_raw_sample=24 for lossless sources (TrueHD, DTS-HD MA, FLAC, ALAC, raw 24/32-bit PCM) so
    /// FLAC output stays bit-perfect (S16 would dither away the bottom 8 bits, audible in quiet passages).
    private var pcmSampleFmt: AVSampleFormat = AV_SAMPLE_FMT_FLTP
    private var pcmBytesPerSample: Int32 = 4
    private var pcmBitsPerRawSample: Int32 = 32

    /// The encoder this bridge actually opened, resolved from the mode AND the source's channel count.
    /// The route reads it for the master playlist's CODECS attribute and the pipeline label, and
    /// `rebuildEncoderAfterEOFDrain` reopens exactly this one: re-deriving from the mode a second time
    /// would name EAC3 for a stereo source the bridge encoded as FLAC. Assigned once during init, before
    /// the encoder context exists.
    private(set) var outputCodecID: AVCodecID = AV_CODEC_ID_NONE

    /// AVCodecParameters for the encoder output stream; caller hands to HLSSegmentProducer.AudioConfig.codecpar.
    /// Owned by the bridge, freed in close().
    private(set) var encoderCodecpar: UnsafeMutablePointer<AVCodecParameters>?

    /// Output stream time base (1 / sample_rate). Caller passes as StreamConfig.timeBase.
    private(set) var encoderTimeBase: AVRational = AVRational(num: 1, den: 1)

    private let srcTimeBase: AVRational
    private let mode: Mode
    private var resampledFrame: UnsafeMutablePointer<AVFrame>?

    /// Encoder PTS counter in encoder time base, incremented by nb_samples/frame. FLAC demands monotonically
    /// increasing PTS in 1/sample_rate units.
    private var nextEncoderPTS: Int64 = 0

    /// Consumed on the next decoded frame: rebases nextEncoderPTS off that frame's packet source-TB pts so the
    /// audio PTS tracks the source. Without it the counter drifts vs video across fragments because the FIFO
    /// retains a partial frame at each segment boundary. Armed at INIT (not just by startSegment): the packets
    /// reaching feed() are already gate-shifted onto the output timeline, so the first session must track them
    /// too. Before #99 only producer restarts armed it; an ANCHORED initial load (resume into the file) then
    /// emitted audio from 0 while video carried the anchor's source PTS, every fragment held tracks the whole
    /// resume offset apart, and AVPlayer silently discarded everything (loadedTimeRanges never populated).
    private var rebaseFromNextSourcePTS: Bool = true

    /// Latched by flush(): avcodec_send_frame(enc, nil) leaves the encoder in a terminal draining state that
    /// avcodec_flush_buffers cannot clear (ac3/flac lack AV_CODEC_CAP_ENCODER_FLUSH). startSegment() rebuilds
    /// the encoder context when this is set, so a producer restart into a finished session (seek after EOF)
    /// gets a working bridge again (#99 failure mode B: it otherwise emitted zero packets forever and the
    /// restarted muxer died on the unparsed dec3 box, "Cannot write moov atom before EAC3 packets parsed").
    private var drainedAtEOF = false

    private static let avNoPTS: Int64 = -0x7FFFFFFFFFFFFFFF - 1

    // MARK: - Lifecycle

    /// Opens source decoder + bridge encoder (eagerly, so encoderCodecpar is ready for muxer init). The encoder
    /// comes from `bridgeEncoder(for:sourceChannels:)`, so it is settled only after the decoder is open and the
    /// source's channel count is resolved: EAC3 128 kbps/ch, max 6 ch, FLTP for a surround source in
    /// `.surroundCompat`, FLAC max 8 ch, S16 (lossy src) or S32@24 (lossless src) otherwise. `forcedEncoder`
    /// overrides that resolution and exists for the route's #165 cascade, which retries the other encoder when
    /// the resolved one is absent from the build. Incomplete source codecpar (TrueHD sometimes reports
    /// sample_rate=0 pre-frame) falls back to 48 kHz stereo, which the resampler reconfigures on the first
    /// decoded frame if it differs.
    init(
        srcCodecpar: UnsafeMutablePointer<AVCodecParameters>,
        srcTimeBase: AVRational,
        mode: Mode = .surroundCompat,
        forcedEncoder: AVCodecID? = nil
    ) throws {
        self.srcTimeBase = srcTimeBase
        self.mode = mode

        // 1. Source decoder
        let srcCodecID = srcCodecpar.pointee.codec_id

        // PCM intermediate format follows the ENCODER (resolved below, after the channel count): EAC3 needs
        // FLTP; FLAC takes S16 (lossy src) or S32@24 (lossless src).
        let isLosslessSource: Bool
        switch srcCodecID {
        case AV_CODEC_ID_TRUEHD,
             AV_CODEC_ID_MLP,
             AV_CODEC_ID_DTS,
             AV_CODEC_ID_FLAC,
             AV_CODEC_ID_ALAC,
             AV_CODEC_ID_PCM_S24LE,
             AV_CODEC_ID_PCM_S24BE,
             AV_CODEC_ID_PCM_S32LE,
             AV_CODEC_ID_PCM_S32BE:
            isLosslessSource = true
        default:
            isLosslessSource = false
        }
        guard let srcCodec = avcodec_find_decoder(srcCodecID) else {
            throw AudioBridgeError.decoderNotFound(codecID: srcCodecID.rawValue)
        }
        guard let dec = avcodec_alloc_context3(srcCodec) else {
            throw AudioBridgeError.decoderAllocFailed
        }
        decoderCtx = dec
        let copyRet = avcodec_parameters_to_context(dec, srcCodecpar)
        guard copyRet >= 0 else {
            cleanup()
            throw AudioBridgeError.decoderParametersFailed(code: copyRet)
        }
        // DTS-HD MA / HRA carry a lossless XLL extension on top of the mandatory DTS core. Decode the FULL
        // stream: for DTS-HD MA the dca decoder reconstructs the lossless XLL (S32P), which .lossless mode
        // re-encodes bit-perfectly to FLAC; .surroundCompat re-encodes lossy EAC3 either way. An earlier #64
        // fix routed DTS through the dca_core bitstream filter to strip every packet to its lossy core, but
        // that (a) discarded lossless XLL for streams that decode fine (#66) and (b) on a stripped standalone
        // core the decoder takes the FLOAT path (FLTP), mismatching the S32P input swr is seeded with from the
        // probe -> garbled audio. The full path is correct; the only genuine failures are XLL frames that
        // residual-code channels without a usable core ("Residual encoded channels are present without core",
        // EINVAL -22), which feed() skips per-packet instead of failing the whole feed (#64).
        let openRet = avcodec_open2(dec, srcCodec, nil)
        guard openRet >= 0 else {
            cleanup()
            throw AudioBridgeError.decoderOpenFailed(code: openRet)
        }

        // 2. Source shape. The encoder cannot be chosen before this: `.surroundCompat` resolves to EAC3 only
        // for a source that HAS surround to carry, and the channel count is not final until the decoder is open.
        let sampleRate: Int32 = srcCodecpar.pointee.sample_rate > 0
            ? srcCodecpar.pointee.sample_rate
            : 48000

        // Channel count in order: (1) srcCodecpar.ch_layout (demuxer from container header, most sources);
        // (2) dec.ch_layout after avcodec_open2 (some codecs propagate a default at init); (3) stereo fallback
        // with a loud log. Matroska doesn't reliably populate Channels for TrueHD/MLP (layout is in the bitstream,
        // container header optional); when both come back 0 the bridge defaults stereo and downmixes the real
        // 5.1/7.1, which the WARNING logs as a repro (proper fix: peek the first packet before opening the encoder).
        let containerChannels = srcCodecpar.pointee.ch_layout.nb_channels
        let decoderChannels = dec.pointee.ch_layout.nb_channels
        let resolvedChannels: Int32
        let resolvedSource: String
        if containerChannels > 0 && containerChannels <= 8 {
            resolvedChannels = containerChannels
            resolvedSource = "container"
        } else if decoderChannels > 0 && decoderChannels <= 8 {
            resolvedChannels = decoderChannels
            resolvedSource = "decoder"
        } else {
            resolvedChannels = 2
            resolvedSource = "fallback (stereo)"
            EngineLog.emit(
                "[AudioBridge] WARNING: source channel layout unresolved at bridge init "
                + "(container=\(containerChannels), decoder=\(decoderChannels)); "
                + "defaulting to stereo. Surround / Atmos sources will be downmixed. "
                + "Codec: \(srcCodecID.rawValue). Need to peek first packet to fix.",
                category: .session
            )
        }
        // 3. Bridge encoder, resolved from the mode AND the source: EAC3 128 kbps/ch max 6 for surround in
        // `.surroundCompat`, FLAC VBR max 8 otherwise. bit_rate is set below once the channel count is capped
        // (EAC3 scales 128 kbps x nChannels per DrHurt on AetherEngine#4: 256 stereo, 768 5.1, and scales
        // further if the cap is bumped per Nomis101's PR 21668). FLAC = 0 (VBR).
        let encoderCodecID = forcedEncoder
            ?? Self.bridgeEncoder(for: mode, sourceChannels: resolvedChannels)
        outputCodecID = encoderCodecID
        if encoderCodecID == AV_CODEC_ID_EAC3 {
            pcmSampleFmt = AV_SAMPLE_FMT_FLTP
            pcmBytesPerSample = 4
            pcmBitsPerRawSample = 32
        } else if isLosslessSource {
            pcmSampleFmt = AV_SAMPLE_FMT_S32
            pcmBytesPerSample = 4
            pcmBitsPerRawSample = 24
        } else {
            pcmSampleFmt = AV_SAMPLE_FMT_S16
            pcmBytesPerSample = 2
            pcmBitsPerRawSample = 16
        }
        guard let encCodec = avcodec_find_encoder(encoderCodecID) else {
            cleanup()
            throw AudioBridgeError.encoderNotFound(codecID: encoderCodecID)
        }
        guard let enc = avcodec_alloc_context3(encCodec) else {
            cleanup()
            throw AudioBridgeError.encoderAllocFailed
        }
        encoderCtx = enc

        // Cap to encoder max (EAC3 5.1, FLAC 7.1). Above-cap downmix happens automatically inside swr_convert
        // when source layout exceeds the encoder's; the resampler picks Apple-compatible ordering.
        let nChannels: Int32 = min(resolvedChannels, Self.maxEncodedChannels(for: encoderCodecID))
        let encoderName = avcodec_get_name(encoderCodecID).map { String(cString: $0) } ?? "?"
        let logBitRate: String = encoderCodecID == AV_CODEC_ID_EAC3
            ? "\(Int64(nChannels) * 128) kbps"
            : "VBR"
        EngineLog.emit(
            "[AudioBridge] init: mode=\(mode.rawValue) encoder=\(encoderName)"
            + (forcedEncoder != nil ? " (forced)" : "")
            + " srcCodec=\(srcCodecID.rawValue) sampleRate=\(sampleRate) "
            + "sourceChannels=\(resolvedChannels) "
            + "encoderChannels=\(nChannels) bitRate=\(logBitRate) "
            + "(source=\(resolvedSource), container=\(containerChannels), decoder=\(decoderChannels))",
            category: .session
        )

        enc.pointee.sample_rate = sampleRate
        enc.pointee.sample_fmt = pcmSampleFmt
        enc.pointee.bits_per_raw_sample = pcmBitsPerRawSample
        // EAC3 per-channel bitrate 128 kbps (Dolby reference transparent profile); FLAC stays 0 = unlimited VBR.
        let resolvedBitRate = Self.encoderBitRate(for: encoderCodecID, channels: nChannels)
        enc.pointee.bit_rate = resolvedBitRate
        enc.pointee.time_base = AVRational(num: 1, den: sampleRate)
        var encLayout = AVChannelLayout()
        av_channel_layout_default(&encLayout, nChannels)
        let layoutCopyRet = av_channel_layout_copy(&enc.pointee.ch_layout, &encLayout)
        if layoutCopyRet < 0 {
            cleanup()
            throw AudioBridgeError.encoderOpenFailed(code: layoutCopyRet)
        }
        let encOpenRet = avcodec_open2(enc, encCodec, nil)
        guard encOpenRet >= 0 else {
            cleanup()
            throw AudioBridgeError.encoderOpenFailed(code: encOpenRet)
        }
        encoderTimeBase = AVRational(num: 1, den: sampleRate)

        // 4. Codecpar describing the encoder output for the muxer.
        guard let cp = avcodec_parameters_alloc() else {
            cleanup()
            throw AudioBridgeError.codecparAllocFailed
        }
        encoderCodecpar = cp
        let fillRet = avcodec_parameters_from_context(cp, enc)
        if fillRet < 0 {
            cleanup()
            throw AudioBridgeError.encoderOpenFailed(code: fillRet)
        }

        // 5. Resampler input format: seed from the decoder ctx if avformat_find_stream_info already resolved it
        //    (most VOD sources - the probe decoded a frame and wrote the real sample_fmt back into codecpar),
        //    else fall back to FLTP + codecpar rate for codecs that defer until the first frame (TrueHD) or a
        //    bailed probe. This is only a seed: resampleAndPushIntoFIFO re-derives the input config from each
        //    decoded frame, so a wrong seed self-corrects on the first frame.
        let inFmtRaw = dec.pointee.sample_fmt.rawValue
        let inFmt = inFmtRaw >= 0 ? dec.pointee.sample_fmt : AV_SAMPLE_FMT_FLTP
        let inRate = dec.pointee.sample_rate > 0 ? dec.pointee.sample_rate : sampleRate
        var inLayout = AVChannelLayout()
        if dec.pointee.ch_layout.nb_channels > 0 {
            av_channel_layout_copy(&inLayout, &dec.pointee.ch_layout)
        } else {
            av_channel_layout_default(&inLayout, nChannels)
        }
        // copy() allocates a channel map for custom-order layouts; uninit the stack struct or that map leaks per session.
        defer { av_channel_layout_uninit(&inLayout) }

        // Remember the input config so resampleAndPushIntoFIFO knows when a decoded frame diverges from it.
        swrInFmt = inFmt
        swrInRate = inRate
        av_channel_layout_copy(&swrInLayout, &inLayout)

        let swrRet = swr_alloc_set_opts2(
            &swrCtx,
            &enc.pointee.ch_layout,
            pcmSampleFmt,
            sampleRate,
            &inLayout,
            inFmt,
            inRate,
            0,
            nil
        )
        guard swrRet >= 0, swrCtx != nil else {
            cleanup()
            throw AudioBridgeError.resamplerAllocFailed(code: swrRet)
        }
        let initRet = swr_init(swrCtx)
        guard initRet >= 0 else {
            cleanup()
            throw AudioBridgeError.resamplerInitFailed(code: initRet)
        }

        // 6. Audio FIFO: ~1s of PCM (FFmpeg grows on demand), chunks resampler output into encoder-sized frames.
        guard let fifoPtr = av_audio_fifo_alloc(
            pcmSampleFmt,
            nChannels,
            sampleRate
        ) else {
            cleanup()
            throw AudioBridgeError.encoderAllocFailed
        }
        fifo = fifoPtr
    }

    deinit {
        cleanup()
    }

    func close() {
        opLock.lock()
        defer { opLock.unlock() }
        cleanup()
    }

    /// FIFO depth in samples/channel, for the engine memory probe. Steady-state below frame_size (~4608 @48kHz);
    /// a growing value means the encoder isn't keeping up with the resampler.
    var fifoSampleCount: Int {
        guard let f = fifo else { return 0 }
        return Int(av_audio_fifo_size(f))
    }

    /// Cumulative bytes of encoded audio the bridge has emitted this session (sum of every output packet's size).
    /// Monotonic across producer restarts and encoder rebuilds; the telemetry sampler diffs it into a live output
    /// bitrate (FLAC is lossless VBR, so a measured rate is the only honest reading). Written only under `opLock`
    /// on the pump thread; read lock-free for diagnostics, mirroring `liveBytes`.
    private(set) var outputBytesLifetime: Int64 = 0

    /// AE#396: what the bridge has actually done with what it was handed.
    ///
    /// Every step between a source packet and an encoded frame can fail per packet, and each of those
    /// arms ends in a `return` or in a loop that stops on a negative code: a packet the decoder
    /// rejects, a decoder that answers nothing, a resample that converts to zero samples, an encoder
    /// that keeps its output. Per packet that is the right behaviour, one bad frame must not end a
    /// session. In aggregate it is the worst failure this class has, because a bridge that emits
    /// NOTHING for a whole first segment surfaces as movenc's -22: the mp4 muxer is asked for an
    /// AC-3/E-AC-3 sample entry it can only build from a packet that was never written, the cut
    /// fails, the revive re-reads the same bytes twice more, and the session ends on "Source audio
    /// cannot be muxed". Neither that sentence nor any line before it mentions audio decoding, so the
    /// only subsystem that is definitely innocent is the one everybody reads about.
    ///
    /// These counters exist to name the arm. Written under `opLock` on the pump thread, read
    /// lock-free for diagnostics, exactly like `outputBytesLifetime`.
    struct FeedStats: Sendable, Equatable {
        var packetsFed = 0
        /// Source packets `avcodec_send_packet` rejected and `feed` skipped (`invalidData`, `einval`).
        var packetsRejected = 0
        var framesDecoded = 0
        /// `avcodec_receive_frame` answers that were neither a frame nor EAGAIN/EOF.
        var decodeErrors = 0
        var lastDecodeErrorCode: Int32 = 0
        /// Decoded frames that never reached the FIFO: no samples, a null plane, or a resample that
        /// produced nothing.
        var framesDroppedBeforeFIFO = 0
        var samplesEnqueued: Int64 = 0
        var packetsEmitted = 0
        /// `avcodec_receive_packet` answers that were neither a packet nor EAGAIN/EOF.
        var encodeErrors = 0
        var lastEncodeErrorCode: Int32 = 0

        /// Fed real source, answered with nothing at all.
        var isSilent: Bool { packetsFed > 0 && packetsEmitted == 0 }

        /// The DECODER is the arm that failed, which no rebuild can change: a producer restart opens a
        /// fresh encoder (#99 failure mode B) but hands the same decoder the same bytes. That is the
        /// line between a muxer revive that can heal and three attempts that read identically.
        var decodedNothing: Bool { packetsFed > 0 && framesDecoded == 0 }

        var summary: String {
            var parts = ["fed=\(packetsFed)", "decoded=\(framesDecoded)",
                         "enqueued=\(samplesEnqueued)", "emitted=\(packetsEmitted)"]
            if packetsRejected > 0 { parts.append("rejected=\(packetsRejected)") }
            if framesDroppedBeforeFIFO > 0 {
                parts.append("droppedBeforeFIFO=\(framesDroppedBeforeFIFO)")
            }
            if decodeErrors > 0 {
                parts.append("decodeErrors=\(decodeErrors)")
                parts.append("lastDecodeError=\(FFmpegErr.text(for: lastDecodeErrorCode))")
            } else if packetsRejected > 0, lastDecodeErrorCode != 0 {
                parts.append("lastDecodeError=\(FFmpegErr.text(for: lastDecodeErrorCode))")
            }
            if encodeErrors > 0 {
                parts.append("encodeErrors=\(encodeErrors)")
                parts.append("lastEncodeError=\(FFmpegErr.text(for: lastEncodeErrorCode))")
            }
            return parts.joined(separator: " ")
        }
    }

    private var stats = FeedStats()

    /// Snapshot for the producer and the engine. The pump thread is the only writer, and both readers
    /// run on it (the deferred-cut log site and the pump-finished handler).
    var feedStats: FeedStats { stats }

    /// One-shot: a bridge that stays silent for an hour costs one line, not one per packet.
    private var silentFeedReported = false

    /// Enough source that no start-up latency explains the silence. The largest encoder frame the
    /// bridge builds is 1536 samples (E-AC-3) and the smallest source packet it is fed is 512 (DTS),
    /// so three packets is the honest worst case before the first output and 64 is two orders past it.
    private static let silentFeedPacketThreshold = 64

    /// Snapshot of bytes live in the bridge's growable buffers, for the engine memory probe. Both fields grow on
    /// the FFmpeg side (FIFO reallocs upward, swr delay buffer reallocates on rate/layout shift), so a
    /// monotonically rising value points here vs the segment muxer or HLS server. Costs: two C calls, no allocations.
    struct LiveBytes {
        /// Samples currently in the FIFO (per channel).
        let fifoSamples: Int
        /// FIFO bytes in interleaved PCM (samples * channels * bytesPerSample).
        let fifoBytes: Int
        /// Samples the resampler is buffering internally, in encoder sample-rate units.
        let swrDelaySamples: Int
        /// Approx swr delay-buffer bytes (swrDelaySamples * channels * bytesPerSample); fine proxy for a growth trend.
        let swrDelayBytes: Int

        var totalBytes: Int { fifoBytes + swrDelayBytes }
    }

    var liveBytes: LiveBytes {
        let fifoSamples: Int
        if let f = fifo {
            fifoSamples = Int(av_audio_fifo_size(f))
        } else {
            fifoSamples = 0
        }

        let channels: Int
        let bytesPerSample: Int = Int(pcmBytesPerSample)
        if let enc = encoderCtx {
            channels = Int(enc.pointee.ch_layout.nb_channels)
        } else {
            channels = 0
        }

        let fifoBytes = fifoSamples * channels * bytesPerSample

        let swrDelaySamples: Int
        if let swr = swrCtx, let enc = encoderCtx {
            swrDelaySamples = Int(swr_get_delay(swr, Int64(enc.pointee.sample_rate)))
        } else {
            swrDelaySamples = 0
        }
        let swrDelayBytes = swrDelaySamples * channels * bytesPerSample

        return LiveBytes(
            fifoSamples: fifoSamples,
            fifoBytes: fifoBytes,
            swrDelaySamples: swrDelaySamples,
            swrDelayBytes: swrDelayBytes
        )
    }

    /// Mark a producer restart boundary: drain the FIFO (drops the buffered partial frame, max ~96 ms @48kHz) and
    /// rebase encoder PTS off the next decoded frame's pts. Caller is HLSVideoEngine.performRestart, before the
    /// new pump starts, so A/V timestamps stay aligned across producer generations.
    func startSegment() {
        opLock.lock()
        defer { opLock.unlock() }
        // A prior pump reached EOF and flush() drained the encoder into its terminal state; rebuild it
        // before this restart feeds new frames (#99 failure mode B).
        if drainedAtEOF {
            rebuildEncoderAfterEOFDrain()
            drainedAtEOF = false
        }
        if let f = fifo {
            av_audio_fifo_reset(f)
        }
        // Drop decoder reference frames + resampler delay buffer too: after a backward scrub they hold pre-restart
        // samples that would bleed a few ms of old-position audio into the new position (and a stale decoder frame
        // could surface as garbage on the rebased timeline). swr_init on a configured context re-inits in place,
        // clearing fractional-delay state.
        if let dec = decoderCtx {
            avcodec_flush_buffers(dec)
        }
        if let swr = swrCtx {
            _ = swr_init(swr)
        }
        rebaseFromNextSourcePTS = true
    }

    /// Drain everything buffered at source EOF: remaining decoder frames, FIFO leftover (< one encoder frame),
    /// encoder internal delay. Without this the final ~100-200 ms of every VOD title were dropped (feed's FIFO
    /// drain only emits FULL frames and nothing sent the encoder its EOF frame). Returns the tail packets; caller
    /// writes them via the same muxer path. Call once at pump EOF before muxer finalize. Not meaningful for live.
    /// Latches `drainedAtEOF`: the encoder is unusable afterwards until startSegment() rebuilds it, and a second
    /// flush is a no-op.
    func flush() -> [UnsafeMutablePointer<AVPacket>] {
        opLock.lock()
        defer { opLock.unlock() }
        guard !drainedAtEOF else { return [] }
        guard let dec = decoderCtx, let enc = encoderCtx,
              let swr = swrCtx, let fifoPtr = fifo else { return [] }
        drainedAtEOF = true
        var results: [UnsafeMutablePointer<AVPacket>] = []

        // 1. Drain the decoder's internal delay.
        _ = avcodec_send_packet(dec, nil)
        var srcFrame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        defer { av_frame_free(&srcFrame) }
        if let sf = srcFrame {
            while avcodec_receive_frame(dec, sf) >= 0 {
                try? resampleAndPushIntoFIFO(srcFrame: sf, enc: enc, swr: swr, fifo: fifoPtr)
            }
        }

        // 2. Encode the FIFO remainder, including the final partial
        //    frame (requireFull: false pads/short-frames it).
        try? drainFIFOIntoEncoder(enc: enc, fifo: fifoPtr, requireFull: false, results: &results)

        // 3. Flush the encoder's internal delay.
        _ = avcodec_send_frame(enc, nil)
        while true {
            guard let outPkt = trackedPacketAlloc() else { break }
            let recvRet = avcodec_receive_packet(enc, outPkt)
            guard recvRet >= 0 else {
                var p: UnsafeMutablePointer<AVPacket>? = outPkt
                trackedPacketFree(&p)
                break
            }
            outputBytesLifetime += Int64(outPkt.pointee.size)
            results.append(outPkt)
        }
        if !results.isEmpty {
            EngineLog.emit(
                "[AudioBridge] EOF flush emitted \(results.count) tail packet(s)",
                category: .session
            )
        }
        return results
    }

    /// Live program-boundary correction. The free-running nextEncoderPTS counter collapses any audio splice gap
    /// sample-continuously while video keeps the rebase-preserved gap. Producer calls this with the residual
    /// (audio gap minus video gap, seconds): positive deltas advance the PTS (AVPlayer renders silence), negative
    /// (splice overlap) are clamped, the counter never rewinds. Called on the pump thread (same as feed). FIFO
    /// leftover (< one frame) is stamped post-jump; that error is one-shot, bounded by one frame (~32 ms).
    func noteTimelineJump(deltaSeconds: Double) {
        opLock.lock()
        defer { opLock.unlock() }
        guard deltaSeconds > 0, encoderTimeBase.den > 0 else { return }
        let samples = Int64((deltaSeconds * Double(encoderTimeBase.den)).rounded())
        nextEncoderPTS += samples
        EngineLog.emit(
            "[AudioBridge] live timeline jump: +\(String(format: "%.3f", deltaSeconds))s "
            + "(\(samples) samples) at encoder pts \(nextEncoderPTS)",
            category: .session
        )
    }

    /// Replace the EOF-drained encoder with a freshly opened one of identical configuration. The muxer holds
    /// the `encoderCodecpar` POINTER from session setup, so the codecpar is refreshed in place, never
    /// reallocated. On any failure the old context stays; the next feed() then throws loudly instead of
    /// silently emitting nothing. Runs under opLock (callers hold it).
    private func rebuildEncoderAfterEOFDrain() {
        guard let oldEnc = encoderCtx else { return }
        let encoderCodecID: AVCodecID = outputCodecID
        guard let encCodec = avcodec_find_encoder(encoderCodecID),
              let enc = avcodec_alloc_context3(encCodec) else {
            EngineLog.emit(
                "[AudioBridge] WARNING: encoder rebuild after EOF drain failed (alloc); "
                + "subsequent feeds will fail",
                category: .session
            )
            return
        }
        enc.pointee.sample_rate = oldEnc.pointee.sample_rate
        enc.pointee.sample_fmt = pcmSampleFmt
        enc.pointee.bits_per_raw_sample = pcmBitsPerRawSample
        enc.pointee.bit_rate = oldEnc.pointee.bit_rate
        enc.pointee.time_base = oldEnc.pointee.time_base
        let layoutRet = av_channel_layout_copy(&enc.pointee.ch_layout, &oldEnc.pointee.ch_layout)
        guard layoutRet >= 0, avcodec_open2(enc, encCodec, nil) >= 0 else {
            var tmp: UnsafeMutablePointer<AVCodecContext>? = enc
            avcodec_free_context(&tmp)
            EngineLog.emit(
                "[AudioBridge] WARNING: encoder rebuild after EOF drain failed (open); "
                + "subsequent feeds will fail",
                category: .session
            )
            return
        }
        avcodec_free_context(&encoderCtx)
        encoderCtx = enc
        if let cp = encoderCodecpar {
            _ = avcodec_parameters_from_context(cp, enc)
        }
        EngineLog.emit(
            "[AudioBridge] encoder rebuilt after EOF drain (producer restart into a finished session)",
            category: .session
        )
    }

    private func cleanup() {
        if decoderCtx != nil {
            avcodec_free_context(&decoderCtx)
        }
        if encoderCtx != nil {
            avcodec_free_context(&encoderCtx)
        }
        if swrCtx != nil {
            swr_free(&swrCtx)
        }
        // Releases the channel map allocated by av_channel_layout_copy; idempotent when already empty.
        av_channel_layout_uninit(&swrInLayout)
        if encoderCodecpar != nil {
            avcodec_parameters_free(&encoderCodecpar)
        }
        if resampledFrame != nil {
            av_frame_free(&resampledFrame)
        }
        if let f = fifo {
            av_audio_fifo_free(f)
            fifo = nil
        }
    }

    // MARK: - Feed

    /// Decode one source packet, resample, buffer, encode. Returns 0+ encoded packets, ownership transferred to
    /// the caller (must av_packet_free after muxing). PTS is in encoderTimeBase units; the muxer rescales during writePacket.
    func feed(packet: UnsafePointer<AVPacket>) throws -> [UnsafeMutablePointer<AVPacket>] {
        opLock.lock()
        defer { opLock.unlock() }
        guard let dec = decoderCtx,
              let enc = encoderCtx,
              let swr = swrCtx,
              let fifoPtr = fifo else {
            return []
        }

        stats.packetsFed += 1

        var results: [UnsafeMutablePointer<AVPacket>] = []

        // Capture packet.pts for the encoder-PTS rebase, NOT the decoded frame's pts. Issue #7: for codecs with
        // decoder priming (Opus preskip ~312 samples @48kHz, AAC delay), libavcodec's discard-samples path trims
        // the first frame AND advances frame.pts by the same amount; rebasing off that would forward-shift FLAC
        // by preskip-count, opening the audio gate ahead of video and stalling AVPlayer in waitingToPlay.
        // packet.pts is the source position of the encoded packet (preskip + content), so it keeps FLAC aligned
        // with source-PTS=packet.pts like the video segments regardless of auto-trim.
        let packetPts = packet.pointee.pts

        var srcFrame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        defer { av_frame_free(&srcFrame) }
        guard let sf = srcFrame else { return results }

        // Drain every decodable frame into the FIFO. The PTS rebase fires on the first frame after a segment
        // boundary so FLAC timestamps track the source rather than drifting on FIFO leftover (uses packetPts, not sf.pts).
        func receiveDecodedFrames() throws {
            while true {
                // AE#396: the loop used to be `while avcodec_receive_frame(...) >= 0`, which reads
                // "drain what is there" and behaves as "drop the reason there is nothing". A decoder
                // that rejects every frame of a stream is then indistinguishable from one that has
                // simply caught up, for the whole session.
                let receiveRet = avcodec_receive_frame(dec, sf)
                if receiveRet < 0 {
                    if receiveRet != FFmpegErr.eagain, receiveRet != FFmpegErr.eof {
                        stats.decodeErrors += 1
                        stats.lastDecodeErrorCode = receiveRet
                    }
                    break
                }
                stats.framesDecoded += 1
                if rebaseFromNextSourcePTS, packetPts != Self.avNoPTS {
                    nextEncoderPTS = av_rescale_q(packetPts, srcTimeBase, encoderTimeBase)
                    rebaseFromNextSourcePTS = false
                }
                try resampleAndPushIntoFIFO(srcFrame: sf, enc: enc, swr: swr, fifo: fifoPtr)
            }
        }

        // Push one source packet into the decoder and drain its frames.
        func decodeOnePacket(_ pkt: UnsafePointer<AVPacket>) throws {
            var sendRet = avcodec_send_packet(dec, pkt)
            if sendRet == FFmpegErr.eagain {
                // EAGAIN = decoder output queue full (multi-frame packets, e.g. TrueHD bursts): drain, then retry.
                try receiveDecodedFrames()
                sendRet = avcodec_send_packet(dec, pkt)
            }
            if sendRet == FFmpegErr.invalidData || sendRet == FFmpegErr.einval {
                stats.packetsRejected += 1
                stats.lastDecodeErrorCode = sendRet
                // Skippable single-packet rejections, decoder stays usable for the next packet:
                //   invalidData = corrupt source packet (glitchy live MPEG-TS, broken mp2 header);
                //   einval (-22) = a DTS-HD MA XLL frame that residual-codes channels without a usable core
                //   ("Residual encoded channels are present without core"; #64). Skip rather than throw:
                //   per-packet throwing floods the caller hundreds/sec on a bad feed, and dropping the rare
                //   bad frame keeps the rest playing.
                return
            }
            // EOF is NOT exempt: a draining decoder here means feed-after-flush without startSegment
            // (#99); swallowing it produced zero output with zero diagnostics.
            if sendRet < 0 {
                throw AudioBridgeError.sendPacketFailed(code: sendRet)
            }
            try receiveDecodedFrames()
        }

        try decodeOnePacket(packet)

        // Drain the FIFO into encoder-frame-size chunks, each fed as one AVFrame.
        // The helper may append encoded packets before throwing; feed propagates the error (the
        // caller logs and continues, holding no reference), so free the partial results here or
        // they leak. flush() intentionally keeps its partial results via try?, so this cleanup
        // lives in feed(), not in the shared helper.
        do {
            try drainFIFOIntoEncoder(enc: enc, fifo: fifoPtr, requireFull: true, results: &results)
        } catch {
            for p in results {
                var pp: UnsafeMutablePointer<AVPacket>? = p
                trackedPacketFree(&pp)
            }
            throw error
        }

        noteSilentFeedIfNeeded()
        return results
    }

    /// AE#396: say it once, the moment enough source has gone in for the silence to be structural
    /// rather than start-up latency. Without this the only downstream evidence is movenc's -22 on a
    /// moov it cannot build, which names the muxer and the source and never the bridge. `EngineLog`
    /// has no error level, so the `ERROR:` prefix carries it, as in the #165 cascade line.
    private func noteSilentFeedIfNeeded() {
        guard !silentFeedReported,
              stats.isSilent,
              stats.packetsFed >= Self.silentFeedPacketThreshold else { return }
        silentFeedReported = true
        EngineLog.emit(
            "[AudioBridge] ERROR: AE#396 the bridge has produced no encoded audio at all "
            + "(mode=\(mode.rawValue)): \(stats.summary). The mp4 muxer can only build an "
            + "AC-3/E-AC-3 sample entry from a packet that was written, so this session will fail "
            + "its first segment cut unless output starts.",
            category: .session
        )
    }

    /// Align swr's INPUT side to the frame the decoder actually produced. libswresample reads `extended_data`
    /// planes strictly per its configured input format, so if the decoder emits a different (sample_fmt,
    /// sample_rate, ch_layout) than swr was set up for, the bytes are misread: lossless DTS-HD MA decodes to
    /// S32P, but the init seed can be FLTP (codec sample_fmt unresolved at avcodec_open2, or a bailed live
    /// probe), and reading S32 integers as FLTP floats is noise. Re-derive the input from the frame, keeping
    /// the output side pinned to the encoder, exactly as AudioDecoder configures its resampler from the frame.
    /// No-op in the common case where find_stream_info already resolved the format (frame == seed), so working
    /// paths are untouched; only a wrong seed or a genuine mid-stream format change rebuilds. swr_alloc_set_opts2
    /// reuses the context pointer on success and frees it on failure (the caller re-binds swrCtx); swr_init drops
    /// the sub-frame resampler delay, as startSegment already does. Runs under feed()'s opLock (never re-lock).
    private func reconfigureSwrInputIfNeeded(
        forFrame sf: UnsafeMutablePointer<AVFrame>,
        enc: UnsafeMutablePointer<AVCodecContext>
    ) {
        let frameFmtRaw = sf.pointee.format
        let frameRate = sf.pointee.sample_rate
        guard frameFmtRaw >= 0, frameRate > 0, sf.pointee.ch_layout.nb_channels > 0 else { return }
        let matchesCurrent = frameFmtRaw == swrInFmt.rawValue
            && frameRate == swrInRate
            && av_channel_layout_compare(&swrInLayout, &sf.pointee.ch_layout) == 0
        guard !matchesCurrent else { return }

        let frameFmt = AVSampleFormat(rawValue: frameFmtRaw)
        let setRet = swr_alloc_set_opts2(
            &swrCtx,
            &enc.pointee.ch_layout,
            pcmSampleFmt,
            enc.pointee.sample_rate,
            &sf.pointee.ch_layout,
            frameFmt,
            frameRate,
            0,
            nil
        )
        guard setRet >= 0, swrCtx != nil, swr_init(swrCtx) >= 0 else { return }

        av_channel_layout_uninit(&swrInLayout)
        av_channel_layout_copy(&swrInLayout, &sf.pointee.ch_layout)
        swrInFmt = frameFmt
        swrInRate = frameRate

        // .lossless pins the encoder + swr OUTPUT to the codecpar rate/layout at init (the muxer header is
        // already written from it, so it cannot change now). If the decoded frame differs, swr must resample
        // or rematrix and the FLAC is no longer bit-perfect. Surface it loudly; a deferred encoder open (open
        // the encoder from the first decoded frame) is the follow-up if this ever fires on real material.
        if mode == .lossless,
           frameRate != enc.pointee.sample_rate
            || av_channel_layout_compare(&sf.pointee.ch_layout, &enc.pointee.ch_layout) != 0 {
            EngineLog.emit(
                "[AudioBridge] WARNING: lossless not bit-perfect - decoded "
                + "\(frameRate)Hz/\(sf.pointee.ch_layout.nb_channels)ch differs from encoder "
                + "\(enc.pointee.sample_rate)Hz/\(enc.pointee.ch_layout.nb_channels)ch; swr will resample/downmix "
                + "(source codecpar under-described the stream, e.g. the probe reported the core rate/layout).",
                category: .session
            )
        }
    }

    /// Resample sf (decoded source frame) to encoder format and push into the FIFO (swr_convert may produce
    /// more/fewer samples; the FIFO smooths that). Buffer layout by pcmSampleFmt: interleaved (S16/S32, FLAC mode)
    /// is one contiguous buffer in out[0]; planar (FLTP, EAC3 mode) is N pointers, one per channel. Passing a
    /// single pointer for planar would have the encoder read garbage from N-1 unallocated slots (EXC_BAD_ACCESS in swr_convert).
    private func resampleAndPushIntoFIFO(
        srcFrame sf: UnsafeMutablePointer<AVFrame>,
        enc: UnsafeMutablePointer<AVCodecContext>,
        swr: OpaquePointer,
        fifo: OpaquePointer
    ) throws {
        // Corrupt source audio (glitchy live MPEG-TS, mp2 with missing frame headers) can decode to a frame with
        // nb_samples > 0 but a NULL channel pointer in extended_data; swr_convert then derefs NULL and crashes
        // EXC_BAD_ACCESS at 0x0. Skip such frames (the video path tolerates the same corruption).
        guard sf.pointee.nb_samples > 0,
              let ext = sf.pointee.extended_data,
              ext.pointee != nil else {
            stats.framesDroppedBeforeFIFO += 1
            return
        }

        // Align swr's INPUT to the frame the decoder actually produced before converting. No-op once the seed
        // matched (the usual case); only a wrong init seed or a genuine mid-stream format change rebuilds swr.
        reconfigureSwrInputIfNeeded(forFrame: sf, enc: enc)
        // The rebuild reuses the context pointer on success, but swr_alloc_set_opts2 frees it on a set-opts
        // failure (swr_free(ps) -> swrCtx == nil), which would dangle the caller's `swr`. Re-bind to the live one.
        guard let swr = swrCtx else {
            stats.framesDroppedBeforeFIFO += 1
            return
        }

        let outNbSamples = swr_get_out_samples(swr, sf.pointee.nb_samples)
        guard outNbSamples > 0 else {
            stats.framesDroppedBeforeFIFO += 1
            return
        }

        let nChannels = enc.pointee.ch_layout.nb_channels
        let isPlanar = av_sample_fmt_is_planar(pcmSampleFmt) != 0
        let bufferCount = isPlanar ? Int(nChannels) : 1
        let bytesPerBuffer = isPlanar
            ? Int(outNbSamples) * Int(pcmBytesPerSample)
            : Int(outNbSamples) * Int(nChannels) * Int(pcmBytesPerSample)

        // Allocate N (planar) or 1 (interleaved) buffer(s).
        var buffers: [UnsafeMutablePointer<UInt8>] = []
        buffers.reserveCapacity(bufferCount)
        for _ in 0..<bufferCount {
            buffers.append(UnsafeMutablePointer<UInt8>.allocate(capacity: bytesPerBuffer))
        }
        defer { for b in buffers { b.deallocate() } }

        // Pointer array for swr_convert + FIFO write: single element interleaved, one per channel planar.
        var outPtrs: [UnsafeMutablePointer<UInt8>?] = buffers.map { $0 }
        let producedSamples = outPtrs.withUnsafeMutableBufferPointer { outBuf in
            withUnsafeMutablePointer(to: &sf.pointee.extended_data) { srcPtr in
                let srcReadOnly = UnsafeRawPointer(srcPtr.pointee)
                    .assumingMemoryBound(to: UnsafePointer<UInt8>?.self)
                return swr_convert(
                    swr,
                    outBuf.baseAddress,
                    outNbSamples,
                    srcReadOnly,
                    sf.pointee.nb_samples
                )
            }
        }
        guard producedSamples > 0 else {
            stats.framesDroppedBeforeFIFO += 1
            return
        }

        // av_audio_fifo_write takes void **data; the same array works for both layouts (FIFO knows the format).
        let written = outPtrs.withUnsafeMutableBufferPointer { fifoBuf in
            fifoBuf.baseAddress!.withMemoryRebound(
                to: UnsafeMutableRawPointer?.self, capacity: bufferCount
            ) { rebound in
                av_audio_fifo_write(fifo, rebound, producedSamples)
            }
        }
        if written > 0 { stats.samplesEnqueued += Int64(written) }
    }

    /// Pull frame_size chunks from the FIFO and encode each. requireFull true stops below frame_size (streaming);
    /// false emits a final short frame for the leftover (flush).
    private func drainFIFOIntoEncoder(
        enc: UnsafeMutablePointer<AVCodecContext>,
        fifo: OpaquePointer,
        requireFull: Bool,
        results: inout [UnsafeMutablePointer<AVPacket>]
    ) throws {
        let frameSize = enc.pointee.frame_size > 0 ? enc.pointee.frame_size : 4096
        let nChannels = enc.pointee.ch_layout.nb_channels

        while true {
            let available = av_audio_fifo_size(fifo)
            let chunkSize: Int32
            if available >= frameSize {
                chunkSize = frameSize
            } else if !requireFull && available > 0 {
                chunkSize = available
            } else {
                break
            }

            // Pull chunkSize samples into a fresh AVFrame the encoder consumes.
            var outFrame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
            defer { av_frame_free(&outFrame) }
            guard let of = outFrame else { break }
            of.pointee.format = pcmSampleFmt.rawValue
            of.pointee.nb_samples = chunkSize
            of.pointee.sample_rate = enc.pointee.sample_rate
            av_channel_layout_copy(&of.pointee.ch_layout, &enc.pointee.ch_layout)
            let allocRet = av_frame_get_buffer(of, 0)
            if allocRet < 0 { break }

            // FIFO read into the frame's data planes: interleaved uses data[0], planar uses data[0..N-1]
            // (data[] suffices since EAC3 caps 6 / FLAC 8 ch, below the 8-plane extended_data threshold).
            // av_audio_fifo_read takes void **data and respects the FIFO's format to fan out or not.
            let isPlanar = av_sample_fmt_is_planar(pcmSampleFmt) != 0
            let planes = isPlanar ? Int(nChannels) : 1
            let readSamples = withUnsafeMutablePointer(to: &of.pointee.data) { dataPtr in
                dataPtr.withMemoryRebound(to: UnsafeMutableRawPointer?.self, capacity: planes) { rebound in
                    av_audio_fifo_read(fifo, rebound, chunkSize)
                }
            }
            if readSamples <= 0 { break }
            of.pointee.nb_samples = readSamples
            of.pointee.pts = nextEncoderPTS
            nextEncoderPTS += Int64(readSamples)

            // EOF is NOT exempt: a draining encoder here means the EOF-drain latch was bypassed (#99);
            // swallowing it starved the muxer of audio with zero diagnostics.
            let sendFrameRet = avcodec_send_frame(enc, of)
            if sendFrameRet < 0 {
                throw AudioBridgeError.sendFrameFailed(code: sendFrameRet)
            }

            // Drain the encoder for ready packets.
            while true {
                guard let outPkt = trackedPacketAlloc() else { break }
                let recvRet = avcodec_receive_packet(enc, outPkt)
                if recvRet == FFmpegErr.eagain || recvRet == FFmpegErr.eof {
                    var p: UnsafeMutablePointer<AVPacket>? = outPkt
                    trackedPacketFree(&p)
                    break
                }
                if recvRet < 0 {
                    stats.encodeErrors += 1
                    stats.lastEncodeErrorCode = recvRet
                    var p: UnsafeMutablePointer<AVPacket>? = outPkt
                    trackedPacketFree(&p)
                    break
                }
                outputBytesLifetime += Int64(outPkt.pointee.size)
                stats.packetsEmitted += 1
                results.append(outPkt)
            }
        }
    }
}

