import Foundation
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil

extension HLSVideoEngine {

    /// Audio codec routing: stream-copy (fMP4-legal, preserves Atmos/DTS-HD) vs AudioBridge (decode->S16 PCM->FLAC for non-fMP4-legal codecs; TrueHD-MAT Atmos object metadata lost in PCM intermediate).
    enum AudioCodecCompat {
        case aac, ac3, eac3, flac, alac, mp3, opus
        case truehd, dts
        case vorbis, pcm, mp2
        /// LATM/LOAS-framed AAC (DVB-T2/IPTV, typically HE-AAC); no ADTS headers, no ASC in extradata, always bridges via aac_latm decoder.
        case aacLatm
        case unsupported

        static func from(_ codecID: AVCodecID) -> AudioCodecCompat {
            switch codecID {
            case AV_CODEC_ID_AAC:    return .aac
            case AV_CODEC_ID_AAC_LATM: return .aacLatm
            case AV_CODEC_ID_AC3:    return .ac3
            case AV_CODEC_ID_EAC3:   return .eac3
            case AV_CODEC_ID_FLAC:   return .flac
            case AV_CODEC_ID_ALAC:   return .alac
            case AV_CODEC_ID_MP3:    return .mp3
            case AV_CODEC_ID_OPUS:   return .opus
            case AV_CODEC_ID_TRUEHD: return .truehd
            case AV_CODEC_ID_DTS:    return .dts
            case AV_CODEC_ID_VORBIS: return .vorbis
            case AV_CODEC_ID_MP2:    return .mp2
            case AV_CODEC_ID_PCM_S16LE,
                 AV_CODEC_ID_PCM_S24LE,
                 AV_CODEC_ID_PCM_F32LE,
                 AV_CODEC_ID_PCM_S16BE,
                 AV_CODEC_ID_PCM_S32LE,
                 AV_CODEC_ID_PCM_U8:
                return .pcm
            default: return .unsupported
            }
        }

        /// CODECS attribute for the master playlist. Empty for bridged codecs (engine computes `fLaC` from the encoded stream).
        var hlsCodecsString: String {
            switch self {
            case .aac:    return "mp4a.40.2"
            case .ac3:    return "ac-3"
            case .eac3:   return "ec-3"
            case .flac:   return "fLaC"
            case .alac:   return "alac"
            case .mp3, .opus, .truehd, .dts, .vorbis, .pcm, .mp2, .aacLatm, .unsupported:
                // mp3: theoretically mp4a.40.34, but AVPlayer treats any mp4a as AAC and fails; bridge to FLAC.
                return ""
            }
        }

        /// Codecs that must go through AudioBridge. Opus is fMP4-spec-legal but AVPlayer rejects it in HLS-fMP4 in practice (only CAF/WebM paths work). MP3 writes `mp4a.40.34` but AVPlayer treats any mp4a as AAC, failing with -11829/-12848.
        var requiresBridge: Bool {
            switch self {
            case .opus, .mp3, .truehd, .dts, .vorbis, .pcm, .mp2, .aacLatm: return true
            default: return false
            }
        }
    }

    /// #165: ordered bridge-encoder cascade. The configured mode's encoder for this source is attempted
    /// first; if it is absent from the FFmpeg build (`AudioBridgeError.encoderNotFound`, which names the
    /// missing one), fall through to the other encoder rather than dropping to silent video-only. Both
    /// decode everywhere on Apple devices (EAC3 -> HDMI bitstream, FLAC -> LPCM), so either is a valid
    /// rescue; the only loss is the configured mode's channel/quality trade-off.
    ///
    /// AE#395 made this an ENCODER cascade rather than the mode cascade it started as. A mode no longer
    /// names an encoder on its own (`.surroundCompat` takes FLAC for a source with no surround to carry),
    /// so on a stereo source both modes resolve to the same encoder, and a mode list would have retried
    /// the absent one against itself and landed on exactly the silent video-only fallback #165 exists to
    /// prevent.
    static func bridgeEncoderCascade(firstAttempt: AVCodecID) -> [AVCodecID] {
        [firstAttempt, AudioBridge.alternateEncoder(to: firstAttempt)]
    }

    /// libavcodec's own name for a codec id ("eac3", "flac"), for log lines that used to print a bridge
    /// MODE and would now name the wrong thing.
    static func encoderLabel(_ id: AVCodecID) -> String {
        avcodec_get_name(id).map { String(cString: $0) } ?? "id \(id.rawValue)"
    }

    /// AE#396: "absent from this FFmpeg build" was true and useless, because the build that answered
    /// was a second FFmpeg the host had linked ahead of AetherEngine's. The sentence read as a claim
    /// about our build, so the reporter spent five fixtures and two devices before anyone looked at
    /// the link. Naming the libavcodec that actually answered makes it a question about the process.
    static func encoderAbsentMessage(missing: AVCodecID, cascadingTo: AVCodecID) -> String {
        "[HLSVideoEngine] \(encoderLabel(missing)) bridge encoder absent from "
        + "\(FFmpegRuntimeCheck.avcodecIdentity), cascading to \(encoderLabel(cascadingTo))"
    }

    /// Guards `audioSourceStreamIndexOverride` against stale picker selections from a previous title.
    static func isAudioStream(demuxer: Demuxer, index: Int32) -> Bool {
        guard index >= 0, let stream = demuxer.stream(at: index) else {
            return false
        }
        return stream.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_AUDIO
    }

    /// Audio routing cascade: stream-copy -> configured bridge mode -> alternate bridge mode (when the
    /// configured encoder is absent from the build, #165) -> video-only. Covers EAC3-from-MKV where codecpar
    /// lacks the `dec3` extradata the mp4 muxer needs to write the audio sample-entry.
    func buildProducerWithAudioCascade(
        preferBridge: Bool,
        streamCopyAudio: HLSSegmentProducer.AudioConfig?,
        sourceAudioStreamIndex: Int32,
        sourceAudioStream: UnsafeMutablePointer<AVStream>?,
        audioHLSCodecs: inout String?
    ) throws -> HLSSegmentProducer {
        // EAC3 profile=30 is the JOC marker; any stream-copy->FLAC fallback silently loses Atmos object metadata.
        let sourceIsAtmos: Bool = {
            guard let stream = sourceAudioStream else { return false }
            return stream.pointee.codecpar.pointee.codec_id == AV_CODEC_ID_EAC3
                && stream.pointee.codecpar.pointee.profile == 30
        }()

        let sourceCodecLabel: String = {  // falls back to "audio" for codecs with no libavcodec name entry
            if let stream = sourceAudioStream,
               let cstr = avcodec_get_name(stream.pointee.codecpar.pointee.codec_id) {
                return String(cString: cstr).uppercased()
            }
            return "audio"
        }()

        if !preferBridge, let cfg = streamCopyAudio, let vcfg = savedVideoConfig {
            // Pre-flight avformat_write_header: makeProducer is lazy (muxer alloc on first keep-packet), so a
            // failure there (EAC3-from-MKV, missing dec3 extradata, -22 "Cannot write moov atom before EAC3
            // packets parsed") would leave the producer stuck with the bridge fallback unreachable.
            let probeVideo = MP4SegmentMuxer.VideoConfig(
                codecpar: vcfg.codecpar,
                timeBase: vcfg.timeBase,
                codecTagOverride: vcfg.codecTagOverride,
                stripDolbyVisionMetadata: vcfg.stripDolbyVisionMetadata,
                colorOverride: vcfg.colorOverride,
                extradataOverride: vcfg.extradataOverride
            )
            let probeAudio = MP4SegmentMuxer.AudioConfig(
                codecpar: cfg.codecpar,
                timeBase: cfg.timeBase
            )
            let probeRet = MP4SegmentMuxer.probeWriteHeader(
                video: probeVideo,
                audio: probeAudio
            )
            if probeRet < 0 {
                if sourceIsAtmos {
                    EngineLog.emit(
                        "[HLSVideoEngine] WARNING: Atmos downgrade, EAC3+JOC stream-copy probe rejected by mp4 muxer (ret=\(probeRet)). "
                        + "Falling back to FLAC bridge: bed channels stay lossless, but object metadata is lost. "
                        + "Source: \(sourceAudioStream?.pointee.codecpar.pointee.profile.description ?? "?") profile, "
                        + "channels=\(sourceAudioStream?.pointee.codecpar.pointee.ch_layout.nb_channels ?? -1), "
                        + "codec_tag=\(MP4SegmentMuxer.fourCCDescription(sourceAudioStream?.pointee.codecpar.pointee.codec_tag ?? 0)). "
                        + "The source container's codec_tag is already sanitised for the mp4 muxer (AE#382), so the cause "
                        + "is elsewhere; the muxer's own error line above this one names it.",
                        category: .session
                    )
                } else {
                    EngineLog.emit(
                        "[HLSVideoEngine] audio stream-copy probe failed (ret=\(probeRet)), retrying with FLAC bridge",
                        category: .session
                    )
                }
            } else {
                self.savedAudioConfig = cfg
                do {
                    let prod = try makeProducer(baseIndex: initialProducerBaseIndex)
                    if sourceIsAtmos {
                        EngineLog.emit(
                            "[HLSVideoEngine] EAC3+JOC Atmos: stream-copy engaged; DD+/JOC bitstream "
                            + "preserved for the downstream renderer (HDMI passthrough / AirPods spatial; "
                            + "plain Bluetooth A2DP / LE downmixes natively)",
                            category: .session
                        )
                    }
                    self.audioPipelineDescription = sourceIsAtmos
                        ? "Stream-copy (EAC3+JOC Atmos)"
                        : "Stream-copy (\(sourceCodecLabel))"
                    return prod
                } catch {
                    EngineLog.emit(
                        "[HLSVideoEngine] makeProducer failed after stream-copy probe succeeded (\(error)), retrying with FLAC bridge",
                        category: .session
                    )
                }
            }
        } else if preferBridge && sourceIsAtmos {
            // EAC3+JOC always stream-copies; a pre-bridge decision is a codec-table bug.
            EngineLog.emit(
                "[HLSVideoEngine] WARNING: Atmos source pre-routed to FLAC bridge without stream-copy attempt, Atmos lost. Investigate the codec compatibility table.",
                category: .session
            )
        }

        if let audioStream = sourceAudioStream, sourceAudioStreamIndex >= 0 {
            // #165: cascade across bridge encoders. The encoder the configured mode resolves to for this
            // source can be absent from the FFmpeg build (custom builds without --enable-encoder=eac3);
            // AudioBridge.init then throws .encoderNotFound naming it. Rather than dropping to silent
            // video-only after one attempt, try the other encoder. Only encoder-absence cascades (retrying
            // a different encoder can help); every other init failure is source-specific and re-attempting
            // is pointless, so it stops immediately.
            let firstAttempt = AudioBridge.bridgeEncoder(
                for: audioBridgeMode,
                sourceChannels: audioStream.pointee.codecpar.pointee.ch_layout.nb_channels)
            let cascade = Self.bridgeEncoderCascade(firstAttempt: firstAttempt)
            attempts: for (attemptIndex, encoderAttempt) in cascade.enumerated() {
                let isLastAttempt = attemptIndex == cascade.count - 1
                let bridge: AudioBridge
                do {
                    bridge = try AudioBridge(
                        srcCodecpar: audioStream.pointee.codecpar,
                        srcTimeBase: audioStream.pointee.time_base,
                        mode: audioBridgeMode,
                        // The first attempt lets the bridge resolve, so a container that under-reports its
                        // channel count still gets the decoder-resolved answer; only the retry is forced.
                        forcedEncoder: attemptIndex == 0 ? nil : encoderAttempt
                    )
                } catch AudioBridge.AudioBridgeError.encoderNotFound(let missing) where !isLastAttempt {
                    EngineLog.emit(
                        Self.encoderAbsentMessage(
                            missing: missing,
                            cascadingTo: AudioBridge.alternateEncoder(to: missing)),
                        category: .session
                    )
                    continue attempts
                } catch {
                    EngineLog.emit(
                        "[HLSVideoEngine] ERROR: AudioBridge init failed (\(error)), no working bridge encoder, "
                        + "falling back to SILENT video-only",
                        category: .session
                    )
                    break attempts
                }

                guard let cp = bridge.encoderCodecpar else {
                    bridge.close()
                    break attempts
                }
                let cfg = HLSSegmentProducer.AudioConfig(
                    codecpar: cp,
                    timeBase: bridge.encoderTimeBase,
                    sourceStreamIndex: sourceAudioStreamIndex,
                    inputTimeBase: bridge.encoderTimeBase,
                    sourceTimeBase: audioStream.pointee.time_base,
                    bridge: bridge
                )
                self.savedAudioConfig = cfg
                self.audioBridge = bridge
                do {
                    let prod = try makeProducer(baseIndex: initialProducerBaseIndex)
                    // The label and the CODECS attribute come from the encoder the bridge ACTUALLY opened,
                    // not from the mode: `.surroundCompat` on a stereo source produces fLaC, and a master
                    // playlist that advertises ec-3 for a FLAC track is a load failure, not a cosmetic slip.
                    let isEAC3Out = bridge.outputCodecID == AV_CODEC_ID_EAC3
                    let hlsCodec = isEAC3Out ? "ec-3" : "fLaC"
                    let pipelineLabel = "\(sourceCodecLabel) → \(isEAC3Out ? "EAC3" : "FLAC") bridge"
                    audioHLSCodecs = hlsCodec
                    self.audioPipelineDescription = pipelineLabel
                    if attemptIndex > 0 {
                        EngineLog.emit(
                            "[HLSVideoEngine] audio bridge cascaded \(Self.encoderLabel(firstAttempt)) → "
                            + "\(Self.encoderLabel(bridge.outputCodecID)) (configured encoder absent); "
                            + pipelineLabel,
                            category: .session
                        )
                    }
                    return prod
                } catch {
                    EngineLog.emit(
                        "[HLSVideoEngine] \(Self.encoderLabel(bridge.outputCodecID)) bridge header write failed "
                        + "(\(error)), falling back to video-only",
                        category: .session
                    )
                    self.savedAudioConfig = nil
                    self.audioBridge = nil
                    bridge.close()
                    break attempts
                }
            }
        }

        // Video-only fallback: illegal for demuxed-audio sessions (silent playback); fail and let the host fall back to server-muxed.
        if sideAudioDemuxer != nil {
            throw HLSVideoEngineError.openFailed(
                reason: "demuxed-audio companion present but no audio pipeline could be built")
        }
        self.savedAudioConfig = nil
        self.audioBridge = nil
        audioHLSCodecs = nil
        self.audioPipelineDescription = nil
        return try makeProducer(baseIndex: initialProducerBaseIndex)
    }
}
