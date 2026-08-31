import Foundation
import CoreVideo
import AVFoundation
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil

extension AetherEngine {

    // MARK: - Probe

    /// One-shot container + stream metadata read; no HLS server or decoders. Network sources pull a HEAD probe + small initial range (typically a few MB). File sources read directly via FFmpeg's file protocol.
    ///
    /// - Parameters:
    ///   - url: Media source (`file://`, `http://`, or `https://`).
    ///   - options: Forwarded for `httpHeaders` only; other flags ignored (no playback session).
    /// - Throws: Any error the demuxer raises during open / probe.
    public nonisolated static func probe(
        url: URL,
        options: LoadOptions = .init()
    ) throws -> SourceProbe {
        try probe(source: .url(url), options: options)
    }

    /// `probe(url:)` for a custom byte source (AetherEngine#27). Caller retains reader ownership; cursor is left at an unspecified position and `close()` is NOT called. Pass a fresh (or rewound) reader to `load(source:)` afterwards. `SourceProbe.url` is `aether-custom://source` for custom readers.
    public nonisolated static func probe(
        source: MediaSource,
        options: LoadOptions = .init()
    ) throws -> SourceProbe {
        let demuxer = Demuxer()
        let displayURL: URL
        switch source {
        case .url(let u):
            try demuxer.open(url: u, extraHeaders: options.httpHeaders)
            displayURL = u
        case .custom(let reader, let formatHint):
            try demuxer.open(reader: reader, formatHint: formatHint)
            displayURL = URL(string: "aether-custom://source")!
        }
        defer { demuxer.close() }
        return makeSourceProbe(demuxer: demuxer, displayURL: displayURL)
    }

    // MARK: - Bounded, opt-in Atmos/JOC detail probe

    /// `probe(url:)` plus a bounded, OPT-IN decode pass that authoritatively resolves E-AC-3 JOC (Dolby Atmos)
    /// on the default (or explicitly named) audio track.
    ///
    /// FFmpeg's E-AC-3 decoder only populates `AVCodecContext.profile == AV_PROFILE_EAC3_DDP_ATMOS` (30) AFTER
    /// decoding at least one audio frame. The lightweight `probe(url:)` / `probe(source:)` path never opens a
    /// decoder -- it only demuxes and runs `avformat_find_stream_info` -- so `TrackInfo.isAtmos` from those
    /// calls reflects only whatever `codecpar.profile` the container already carries pre-decode, which is
    /// unresolved for JOC in the common case. Call `probeDetectingAtmos` instead of `probe(url:)` ONLY when a
    /// host specifically needs an authoritative "Dolby Atmos" badge (e.g. a details screen): it is strictly
    /// more expensive than `probe(url:)` (it opens a real EAC3 decoder and decodes at least one frame) and
    /// MUST NOT be used on the playback-start critical path. `probe(url:)` / `probe(source:)` themselves are
    /// completely unmodified by this API and remain byte-for-byte the same lightweight demux-only probe --
    /// this is an additive, separate entry point, not a flag on the existing one.
    ///
    /// The decode pass is bounded by `atmosDetection` (packet-count / byte / wall-clock caps -- see
    /// `AtmosDetectionOptions`): it stops at the first successfully decoded audio frame, or at whichever cap
    /// is hit first. There is no video decode, no HLS server, and no playback session. The demuxer, decoder
    /// context, packet, and frame are all closed / freed before returning on every path, including error
    /// paths. A malformed / no-audio / non-EAC3 source is tolerated: the decode pass simply degrades to "not
    /// authoritatively Atmos" (the base probe's `TrackInfo.isAtmos`, which a pre-existing container-declared
    /// profile 30 can still leave `true` -- this API only ever ADDS confirmation, never removes a pre-decode
    /// signal) instead of throwing or hanging.
    ///
    /// - Parameters:
    ///   - url: Media source, forwarded verbatim to `probe(url:)`.
    ///   - options: Forwarded verbatim to `probe(url:)` (`httpHeaders` only; other flags ignored, same as `probe(url:)`).
    ///   - atmosDetection: Bounds + optional explicit track override for the decode pass. Defaults resolve the
    ///     demuxer's own default audio track (`Demuxer.audioStreamIndex`) and cap the decode attempt at 64
    ///     packets / 8 MiB / 2 s wall clock (soft -- see `AtmosDetectionOptions` doc for the same
    ///     AVIO-blocking caveat `Demuxer.seekBounded` already documents: a single blocking `av_read_frame()`
    ///     on a stalled remote socket can still run past the wall-clock budget before the next check fires).
    /// - Throws: Any error the demuxer raises during open / probe -- identical to `probe(url:)`. Decode-side
    ///   failures (bad EAC3 extradata, no decoder built, a malformed frame, EOF before any frame decodes) are
    ///   NEVER thrown; they only affect whether Atmos gets confirmed.
    public nonisolated static func probeDetectingAtmos(
        url: URL,
        options: LoadOptions = .init(),
        atmosDetection: AtmosDetectionOptions = .init()
    ) throws -> SourceProbe {
        try probeDetectingAtmos(source: .url(url), options: options, atmosDetection: atmosDetection)
    }

    /// `probeDetectingAtmos(url:)` for a custom byte source. Same reader-ownership contract as `probe(source:)`:
    /// the caller retains ownership, the cursor is left at an unspecified position, and `close()` is NOT called.
    public nonisolated static func probeDetectingAtmos(
        source: MediaSource,
        options: LoadOptions = .init(),
        atmosDetection: AtmosDetectionOptions = .init()
    ) throws -> SourceProbe {
        let demuxer = Demuxer()
        let displayURL: URL
        switch source {
        case .url(let u):
            try demuxer.open(url: u, extraHeaders: options.httpHeaders)
            displayURL = u
        case .custom(let reader, let formatHint):
            try demuxer.open(reader: reader, formatHint: formatHint)
            displayURL = URL(string: "aether-custom://source")!
        }
        defer { demuxer.close() }

        let base = makeSourceProbe(demuxer: demuxer, displayURL: displayURL)
        // Flush what `avformat_find_stream_info` left queued before the decode pass starts. Those packets
        // were read before `detectAtmos` sets AVDISCARD_ALL, so libavformat hands them back regardless of
        // the hint: on a source whose audio does not sit at the head, the pass burns its whole foreign-packet
        // fuse on that queue and reports "not Atmos" for genuinely Atmos media without ever reading a byte
        // of audio. Seeking to the start discards the queue so the discard takes effect from the first read.
        // A source that cannot seek is no worse off than before.
        demuxer.seekBounded(to: 0, timeout: Self.atmosProbeFlushSeekTimeout)
        let targetIndex = Self.atmosDecodeTargetIndex(
            options: atmosDetection, defaultAudioStreamIndex: demuxer.audioStreamIndex)
        let outcome = Self.detectAtmos(demuxer: demuxer, targetIndex: targetIndex, options: atmosDetection)
        guard outcome.confirmedAtmos else { return base }
        return Self.enrichAtmos(base: base, confirmedTrackID: Int(targetIndex))
    }

    /// Flip `isAtmos` to `true` on exactly the one confirmed audio track, leaving everything else identical.
    ///
    /// Mutates copies rather than rebuilding the structs field by field: both memberwise inits carry defaulted
    /// parameters, so a hand-copy silently drops any field added later and the compiler stays quiet about it.
    nonisolated static func enrichAtmos(base: SourceProbe, confirmedTrackID: Int) -> SourceProbe {
        // Additive only: a track already marked isAtmos by the base probe is left as it is; this only ever
        // sets true, never clears a pre-decode signal.
        var probe = base
        probe.audioTracks = base.audioTracks.map { track in
            guard track.id == confirmedTrackID else { return track }
            var confirmed = track
            confirmed.isAtmos = true
            return confirmed
        }
        return probe
    }

    /// Assemble a `SourceProbe` from an open demuxer. Shared by static probe entry points and `load(source:)`'s internal probe stage so all report identical metadata.
    nonisolated static func makeSourceProbe(
        demuxer: Demuxer,
        displayURL: URL
    ) -> SourceProbe {
        var detectedFormat: VideoFormat = .sdr
        var detectedRate: Double? = nil
        var detectedCodecID: AVCodecID = AV_CODEC_ID_NONE
        var width: Int32 = 0
        var height: Int32 = 0
        var dvProfileNum: Int? = nil
        let videoIdx = demuxer.videoStreamIndex
        if videoIdx >= 0, let stream = demuxer.stream(at: videoIdx) {
            detectedFormat = Self.detectVideoFormat(stream: stream)
            detectedRate = Self.detectFrameRate(stream: stream)
            detectedCodecID = stream.pointee.codecpar.pointee.codec_id
            width = stream.pointee.codecpar.pointee.width
            height = stream.pointee.codecpar.pointee.height
            dvProfileNum = Self.dvProfile(stream: stream)
        }
        let codecName: String? = {
            guard detectedCodecID != AV_CODEC_ID_NONE,
                  let cstr = avcodec_get_name(detectedCodecID) else { return nil }
            return String(cString: cstr)
        }()
        let snappedRate = detectedRate.flatMap { FrameRateSnap.snap($0) }
        let duration = demuxer.duration
        // Heuristic only: duration absent + network scheme. aether-custom:// never matches. Hosts decide the final LoadOptions.isLive.
        let liveSchemes: Set<String> = ["http", "https", "udp", "rtp", "rtsp"]
        let isLive = duration <= 0
            && liveSchemes.contains(displayURL.scheme?.lowercased() ?? "")

        return SourceProbe(
            url: displayURL,
            durationSeconds: duration,
            videoFormat: detectedFormat,
            videoCodecID: Int32(bitPattern: detectedCodecID.rawValue),
            videoCodecName: codecName,
            videoWidth: width,
            videoHeight: height,
            videoFrameRate: snappedRate,
            isDolbyVision: detectedFormat == .dolbyVision,
            dvProfile: dvProfileNum,
            audioTracks: demuxer.audioTrackInfos(),
            subtitleTracks: demuxer.subtitleTrackInfos(),
            metadata: demuxer.mediaMetadata(),
            isLive: isLive
        )
    }

    // MARK: - SW-decoder repro probe

    /// SW-decode repro for `aetherctl swdecode` (MPEG-4 Part 2, MPEG-2, VC-1, AV1 without HW). No render target. Discriminates: `openSucceeded == false` (missing libavcodec decoder / bad extradata), `framesDecoded == 0` (pixel-format conversion failure / all non-IDR), `framesDecoded > 0` (SW path healthy; downstream issue if real playback still hangs).
    public nonisolated static func swDecodeProbe(
        url: URL,
        maxPackets: Int = 100,
        options: LoadOptions = .init()
    ) throws -> SoftwareDecodeProbeResult {
        let demuxer = Demuxer()
        try demuxer.open(url: url, extraHeaders: options.httpHeaders)
        defer { demuxer.close() }
        return try swDecodeProbeRun(demuxer: demuxer, maxPackets: maxPackets)
    }

    /// SW-decode an in-memory media blob (e.g. an HLS `init.mp4` + one fMP4 segment concatenation) with a
    /// fresh decoder and no render target. Used by `aetherctl segverify` to test whether one segment is
    /// independently decodable: `framesDecoded == 0` means the blob carries no usable IRAP to start from
    /// (the #92 open-GOP defect, where the segment's IRAP landed in the previous segment).
    public nonisolated static func swDecodeProbe(
        data: Data,
        formatHint: String? = "mp4",
        maxPackets: Int = 200,
        options: LoadOptions = .init()
    ) throws -> SoftwareDecodeProbeResult {
        let demuxer = Demuxer()
        try demuxer.open(reader: DataIOReader(data: data), formatHint: formatHint)
        defer { demuxer.close() }
        return try swDecodeProbeRun(demuxer: demuxer, maxPackets: maxPackets)
    }

    private nonisolated static func swDecodeProbeRun(
        demuxer: Demuxer,
        maxPackets: Int
    ) throws -> SoftwareDecodeProbeResult {
        let videoIdx = demuxer.videoStreamIndex
        guard videoIdx >= 0, let stream = demuxer.stream(at: videoIdx) else {
            throw AetherEngineError.noVideoStream
        }

        let codecID = stream.pointee.codecpar.pointee.codec_id
        let codecName: String = {
            guard let cstr = avcodec_get_name(codecID) else { return "unknown" }
            return String(cString: cstr)
        }()
        let width = stream.pointee.codecpar.pointee.width
        let height = stream.pointee.codecpar.pointee.height

        let decoder = SoftwareVideoDecoder()
        // Probe decodes a handful of frames and throws them away: no Metal pipeline for that.
        decoder.deinterlaceConfig = DeinterlaceConfig(mode: .software)
        // Class for captured-by-reference mutable accumulators; the onFrame closure fires SYNCHRONOUSLY on this same
        // thread inside avcodec_send_packet / receive_frame (the probe drives decode inline, no demux thread). The
        // DecodedFrameHandler is @Sendable for the off-actor playback path, so this single-threaded capture is an
        // honest @unchecked Sendable exception.
        final class Accum: @unchecked Sendable {
            var framesDecoded = 0
            var firstFramePixelFormat: String?
            var firstFrameWidth: Int = 0
            var firstFrameHeight: Int = 0
        }
        let accum = Accum()

        do {
            try decoder.open(stream: stream) { pixelBuffer, _, _ in
                accum.framesDecoded += 1
                if accum.firstFramePixelFormat == nil {
                    let pfType = CVPixelBufferGetPixelFormatType(pixelBuffer)
                    let bytes: [UInt8] = [
                        UInt8((pfType >> 24) & 0xff),
                        UInt8((pfType >> 16) & 0xff),
                        UInt8((pfType >> 8) & 0xff),
                        UInt8(pfType & 0xff),
                    ]
                    let printable = bytes.map { ($0 >= 0x20 && $0 < 0x7f) ? $0 : 0x2e }
                    let fourCC = String(bytes: printable, encoding: .ascii) ?? "????"
                    accum.firstFramePixelFormat = "\(fourCC) (0x\(String(pfType, radix: 16)))"
                    accum.firstFrameWidth = CVPixelBufferGetWidth(pixelBuffer)
                    accum.firstFrameHeight = CVPixelBufferGetHeight(pixelBuffer)
                }
            }
        } catch {
            return SoftwareDecodeProbeResult(
                codecName: codecName,
                codecID: Int32(bitPattern: codecID.rawValue),
                width: width,
                height: height,
                openSucceeded: false,
                openError: "\(error)",
                packetsRead: 0,
                packetsFedToDecoder: 0,
                framesDecoded: 0,
                firstFramePixelFormat: nil,
                firstFrameWidth: 0,
                firstFrameHeight: 0,
                firstError: "decoder open failed: \(error)"
            )
        }
        defer { decoder.close() }

        var packetsRead = 0
        var packetsFedToDecoder = 0
        var firstError: String?

        while packetsRead < maxPackets, accum.framesDecoded < maxPackets {
            do {
                guard let packet = try demuxer.readPacket() else {
                    break  // EOF
                }
                packetsRead += 1
                if packet.pointee.stream_index == videoIdx {
                    packetsFedToDecoder += 1
                    decoder.decode(packet: packet)
                }
                av_packet_unref(packet)
                av_packet_free_safe(packet)
            } catch {
                if firstError == nil {
                    firstError = "\(error)"
                }
                break
            }
        }
        decoder.flush()

        return SoftwareDecodeProbeResult(
            codecName: codecName,
            codecID: Int32(bitPattern: codecID.rawValue),
            width: width,
            height: height,
            openSucceeded: true,
            openError: nil,
            packetsRead: packetsRead,
            packetsFedToDecoder: packetsFedToDecoder,
            framesDecoded: accum.framesDecoded,
            firstFramePixelFormat: accum.firstFramePixelFormat,
            firstFrameWidth: accum.firstFrameWidth,
            firstFrameHeight: accum.firstFrameHeight,
            firstError: firstError
        )
    }

    /// Pure, nonisolated, and unit-testable: audio-only path when the host requested it OR a *successful* probe
    /// genuinely found no video stream.
    ///
    /// A failed probe (`probeOpened == false`) must NOT route here. probeOpened false means we never looked, not
    /// that there is no video; conflating the two silently degrades a real video file to the audio-only backend
    /// when the open-time probe loses to a transient origin 429 (#78). On probe failure the caller falls through
    /// to the native path so HLSVideoEngine reopens and discovers the stream (it demonstrably can).
    nonisolated static func shouldUseAudioOnlyPath(audioOnlyRequested: Bool, probeOpened: Bool, hasVideoStream: Bool) -> Bool {
        if audioOnlyRequested { return true }
        return probeOpened && !hasVideoStream
    }

    /// What load() does about the previous session's display criteria once routing is known.
    ///
    /// The load seam preserves the criteria through stopInternal (a nil write bounces the panel through
    /// SDR before apply() re-negotiates the same mode, #128). That moves the cleanup decision here:
    enum LoadDisplayCriteriaAction {
        /// Engine-writer video path: apply() overwrites the preserved criteria in place, single handshake.
        case applyFresh
        /// No engine apply() this session (audio-only, or an AVKit-sole-writer host): clear a criteria a
        /// previous session left applied, so it can't keep the panel in DV/HDR under music playback or
        /// fight AVKit's own write. `DisplayCriteriaController.reset()` stays didApply-gated, so this is
        /// a no-op for hosts that never route criteria through the engine.
        case clearStale
    }

    nonisolated static func loadDisplayCriteriaAction(suppressDisplayCriteria: Bool, audioOnlyPath: Bool) -> LoadDisplayCriteriaAction {
        (suppressDisplayCriteria || audioOnlyPath) ? .clearStale : .applyFresh
    }

    /// #274: how long the post-load play-gate blind-polls for a panel switch to start.
    ///
    /// The gate exists for one case: a sole-writer host (`suppressDisplayCriteria`) whose criteria write
    /// lands during the load, from AVKit's auto path reading dvcC off the live AVPlayerItem. DV P5 has no
    /// HDR10 base layer, so its first frame must not hit a panel that is still SDR, and 1000 ms is the
    /// budget that made that land (5d60dbb2). Every other session paid the same 1000 ms for a switch that
    /// could not arrive, which is dead startup time, not safety:
    ///
    /// - Engine-writer sessions wrote their criteria synchronously *before* `loadNative`. Whatever switch
    ///   that write triggers has started long before the gate runs (and `.willSwitch` already settled it in
    ///   the pre-flight), so a second full blind poll buys nothing.
    /// - SDR content reaches no dynamic-range switch at all. The only write anyone can still make is
    ///   rate-only, and the engine already declines to gate its own rate-only writes (`apply()` returns
    ///   `.applied` with no pre-flight wait) because those switches are sub-second.
    ///
    /// `formatKnown` is false when the open-time probe failed: the real range is then unknown and a DV write
    /// may still be inbound, so a suppressed host keeps the full budget.
    nonisolated static func playGateGrace(
        criteriaUnchanged: Bool,
        engineIsCriteriaWriter: Bool,
        formatKnown: Bool,
        effectiveFormat: VideoFormat
    ) -> DisplayCriteriaController.StartGrace {
        // #133: the criteria were already active, nothing was written, nothing can settle.
        if criteriaUnchanged { return .skip }
        if engineIsCriteriaWriter { return .brief }
        guard formatKnown else { return .full }
        return effectiveFormat == .sdr ? .brief : .full
    }

    /// Whitelist (not blacklist) of AVPlayer-native audio codecs: AAC, MP3, MP2, ALAC, AC-3/E-AC-3, LPCM, FLAC (native since iOS/tvOS 11). Anything else falls back to `AudioPlaybackHost` (FFmpeg).
    nonisolated static func avPlayerCanDecodeAudio(_ codecID: AVCodecID) -> Bool {
        switch codecID {
        case AV_CODEC_ID_AAC,
             AV_CODEC_ID_MP3,
             AV_CODEC_ID_MP2,
             AV_CODEC_ID_MP1,
             AV_CODEC_ID_ALAC,
             AV_CODEC_ID_FLAC,
             AV_CODEC_ID_AC3,
             AV_CODEC_ID_EAC3,
             AV_CODEC_ID_PCM_S16LE,
             AV_CODEC_ID_PCM_S16BE,
             AV_CODEC_ID_PCM_S24LE,
             AV_CODEC_ID_PCM_S24BE,
             AV_CODEC_ID_PCM_F32LE:
            return true
        default:
            return false
        }
    }

    // MARK: - Audio track selection (#72)

    /// Resolve the audio stream index selected by an explicit host `override` or, failing that, the
    /// ordered `preferredLanguages` policy. Returns nil when neither applies, so the caller keeps the
    /// container / session default pick (i.e. an empty preference list with no override is a no-op,
    /// behaviourally identical to before #72). Pure and nonisolated so a host can avoid a separate
    /// audio pre-probe or a post-load `selectAudioTrack` reload (#72).
    nonisolated static func selectAudioIndex(
        tracks: [TrackInfo],
        override: Int32?,
        preferredLanguages: [String]
    ) -> Int32? {
        // Explicit host override wins, but only when it names a real audio track (else fall through).
        if let override, tracks.contains(where: { $0.id == Int(override) }) {
            return override
        }
        // Each preference is scanned across all tracks in order, so an earlier preference on a later
        // track still beats a later preference on an earlier track.
        for preferred in preferredLanguages {
            if let match = tracks.first(where: { languageMatches($0.language, preferred) }) {
                return Int32(match.id)
            }
        }
        return nil
    }

    /// Resolve the subtitle track to auto-activate from `LoadOptions.preferredSubtitleLanguages`: within the
    /// first preference (scanned in order) that has any language match, the best-ranked track by
    /// `subtitlePickRank`; else nil. Preference order dominates rank, so an earlier preference always beats a
    /// later one. Unlike audio there is no explicit index override and no default fallback: nil means "keep
    /// subtitles off" (the default). Pure and nonisolated; the engine calls this at the end of a successful
    /// load and, on a hit, activates the track via the host-overlay path so a host without container metadata
    /// of its own need not language-match and rank `subtitleTracks` itself (#73).
    nonisolated static func selectSubtitleIndex(
        tracks: [TrackInfo],
        preferredLanguages: [String]
    ) -> Int32? {
        for preferred in preferredLanguages {
            let matches = tracks.filter { languageMatches($0.language, preferred) }
            // min(by:) is stable, so equal-rank ties keep container order.
            if let best = matches.min(by: { subtitlePickRank($0) < subtitlePickRank($1) }) {
                return Int32(best.id)
            }
        }
        return nil
    }

    /// Lower rank wins. The descriptor axis (full > SDH > forced > commentary, from container dispositions)
    /// dominates; text-vs-bitmap is a tiebreaker (text preferred, since host styling only applies to text
    /// cues). Sourced from `TrackInfo` disposition flags rather than title strings, so it is locale-robust.
    /// Used by `selectSubtitleIndex` and exposed so a host can rank `subtitleTracks` the same way (#73).
    nonisolated static func subtitlePickRank(_ track: TrackInfo) -> Int {
        let descriptorRank: Int
        if track.isCommentary {
            descriptorRank = 3
        } else if track.isForced {
            descriptorRank = 2
        } else if track.isHearingImpaired {
            descriptorRank = 1
        } else {
            descriptorRank = 0
        }
        return descriptorRank * 2 + (isBitmapSubtitleCodec(track.codec) ? 1 : 0)
    }

    /// True when the codec is a bitmap (image) subtitle. `TrackInfo.codec` is the libavcodec DECODER name
    /// (pgssub / dvdsub / dvbsub / xsub), not the descriptor name (hdmv_pgs_subtitle / dvb_subtitle / ...);
    /// matched case-insensitively by substring so either form is tolerated. Bitmap subs cannot mux into
    /// mov_text, so the native-subtitle rendition (#55) excludes them and only the host overlay renders them.
    nonisolated static func isBitmapSubtitleCodec(_ codec: String) -> Bool {
        let c = codec.lowercased()
        return ["pgs", "hdmv", "dvb_sub", "dvbsub", "dvd_sub", "dvdsub", "vobsub", "xsub"]
            .contains(where: { c.contains($0) })
    }

    /// True when the codec is DVB Teletext, the only subtitle codec whose decode depends on a page
    /// number (`txt_page`, see `EmbeddedSubtitleDecoder.decoderOptions`). Both spellings the track
    /// list can carry are covered: the libzvbi DECODER name (`libzvbi_teletextdec`) when FFmpeg was
    /// built with it, and the descriptor name (`dvb_teletext`) when it was not. Matched by substring
    /// for the same reason `isBitmapSubtitleCodec` is (#364).
    nonisolated static func isTeletextSubtitleCodec(_ codec: String) -> Bool {
        codec.lowercased().contains("teletext")
    }

    /// True when the codec is an in-band CEA-608/708 caption track (`eia_608` / QuickTime `c608`). These
    /// have no FFmpeg decoder, so they bypass the side-demuxer `EmbeddedSubtitleDecoder` and are served by
    /// the producer CC tap, which parses their `cc_data` directly. (#77)
    nonisolated static func isEmbeddedClosedCaptionCodec(_ codec: String) -> Bool {
        let c = codec.lowercased()
        return c == "eia_608" || c == "eia_708" || c == "cea708" || c == "cea_708"
    }

    /// Case-insensitive language match across ISO 639-1 / 639-2 (B and T) / English name, e.g.
    /// `"en" == "eng" == "english"`, `"de" == "deu" == "ger"`. Empty / nil track language never matches.
    /// Shared by audio (#72) and subtitle (#73) language selection. Pure and unit-tested.
    nonisolated static func languageMatches(_ trackLanguage: String?, _ preferred: String) -> Bool {
        guard let track = trackLanguage?.lowercased().trimmingCharacters(in: .whitespaces),
              !track.isEmpty else { return false }
        let want = preferred.lowercased().trimmingCharacters(in: .whitespaces)
        guard !want.isEmpty else { return false }
        if track == want { return true }
        return languageSynonyms.contains { $0.contains(track) && $0.contains(want) }
    }

    /// ISO 639-1 / 639-2/T / 639-2/B equivalence classes (plus common English names); anything outside
    /// falls back to strict equality. Mirrors the host-side table so engine-resolved selection matches
    /// what hosts computed before #72.
    nonisolated static let languageSynonyms: [Set<String>] = [
        ["de", "deu", "ger", "german"], ["en", "eng", "english"], ["fr", "fra", "fre", "french"],
        ["es", "spa", "spanish"], ["it", "ita", "italian"], ["ja", "jpn", "japanese"],
        ["ko", "kor", "korean"], ["zh", "zho", "chi", "chinese"], ["pt", "por", "portuguese"],
        ["ru", "rus", "russian"], ["nl", "nld", "dut", "dutch"], ["sv", "swe", "swedish"],
        ["da", "dan", "danish"], ["no", "nor", "norwegian"], ["nb", "nob"], ["nn", "nno"],
        ["fi", "fin", "finnish"], ["pl", "pol", "polish"], ["cs", "ces", "cze", "czech"],
        ["hu", "hun", "hungarian"], ["tr", "tur", "turkish"], ["el", "ell", "gre", "greek"],
        ["ar", "ara", "arabic"], ["he", "heb", "hebrew"], ["hi", "hin", "hindi"],
        ["id", "ind", "indonesian"], ["th", "tha", "thai"], ["vi", "vie", "vietnamese"],
        ["uk", "ukr", "ukrainian"], ["ro", "ron", "rum", "romanian"], ["sk", "slk", "slo", "slovak"],
        ["hr", "hrv", "croatian"], ["bg", "bul", "bulgarian"], ["sr", "srp", "serbian"],
        ["pt-br", "por"], ["pt-pt", "por"],
    ]

    // MARK: - Decoder identity helpers

    /// User-facing label for the active video decoder. nil when no video track (AV_CODEC_ID_NONE). Native = VideoToolbox HW; SW = dav1d (AV1) or libavcodec (VP9, MPEG-2, VC-1).
    static func videoDecoderLabel(codecID: AVCodecID, isSoftware: Bool) -> String? {
        guard codecID != AV_CODEC_ID_NONE else { return nil }
        let name: String = {
            guard let cstr = avcodec_get_name(codecID) else { return "video" }
            return String(cString: cstr).uppercased()
        }()
        if isSoftware {
            switch codecID {
            case AV_CODEC_ID_AV1: return "dav1d \(name) (SW)"
            default:              return "libavcodec \(name) (SW)"
            }
        }
        return "VideoToolbox \(name) (HW)"
    }

    /// User-facing label for the active audio decoder on the SW path (libavcodec -> CoreAudio). nil when no audio track.
    static func softwareAudioDecoderLabel(
        audioTracks: [TrackInfo],
        activeIndex: Int32
    ) -> String? {
        guard activeIndex >= 0,
              let track = audioTracks.first(where: { $0.id == Int(activeIndex) }) else {
            return nil
        }
        return "libavcodec \(track.codec.uppercased()) → CoreAudio"
    }

    // MARK: - Format / frame-rate probing

    nonisolated static func detectVideoFormat(stream: UnsafeMutablePointer<AVStream>) -> VideoFormat {
        let codecpar = stream.pointee.codecpar.pointee
        // dvcC/dvvC side-data is the authoritative DV marker, independent of color_trc. Branching on color_trc first mis-classifies HLG-base P8.4 (reported as HLG) and unspecified-trc P5 (reported as SDR) -- both emit hvc1 instead of dvh1, so the panel never enters DV (DrHurt#4 2026-05-26: only P8.1 produced dolbyvision pre-fix).
        if Self.streamHasDV(stream: stream) {
            return .dolbyVision
        }
        let transfer = codecpar.color_trc
        if transfer == AVCOL_TRC_SMPTE2084 { return .hdr10 }
        if transfer == AVCOL_TRC_ARIB_STD_B67 { return .hlg }
        return .sdr
    }

    /// Clamp source format to what the panel can present. On non-DV panels, publishes the HDR10/HLG base layer format (hvc1 path); SDR-base DV (P8.2) collapses to .sdr (HLSVideoEngine refuses to serve it).
    static func effectiveVideoFormat(
        detected: VideoFormat,
        stream: UnsafeMutablePointer<AVStream>
    ) -> VideoFormat {
        guard detected == .dolbyVision else { return detected }
        let caps = displayCapabilities
        if caps.supportsDolbyVision { return .dolbyVision }
        let trc = stream.pointee.codecpar.pointee.color_trc
        if trc == AVCOL_TRC_ARIB_STD_B67 {
            return caps.supportsHLG ? .hlg : .sdr
        }
        // SMPTE2084 base (P5/P7/P8.1) or unspecified trc (P5 with empty VUI): AVPlayer tonemaps via dvh1 on non-DV panel.
        // tvOS 26 can report eligibleForHDRPlayback while availableHDRModes omits HDR10. For a non-DV
        // display, an HDR-eligible PQ DV base has only one valid downgrade target: HDR10/PQ. Treat the
        // generic HDR eligibility as the HDR10 fallback so the criteria handshake is not downgraded to SDR.
        let canPresentHDR10Base = caps.supportsHDR10 || (caps.supportsHDR && !caps.supportsDolbyVision)
        return canPresentHDR10Base ? .hdr10 : .sdr
    }

    private nonisolated static func streamHasDV(stream: UnsafeMutablePointer<AVStream>) -> Bool {
        let nb = Int(stream.pointee.codecpar.pointee.nb_coded_side_data)
        guard nb > 0, let sideData = stream.pointee.codecpar.pointee.coded_side_data else {
            return false
        }
        for i in 0..<nb {
            if sideData[i].type == AV_PKT_DATA_DOVI_CONF {
                return true
            }
        }
        return false
    }

    /// Dolby Vision profile number (5, 7, 8, 10) from the dvcC/dvvC configuration record; nil when the stream carries no DV side-data. Same record `CodecRoutePolicy` reads for routing.
    nonisolated static func dvProfile(stream: UnsafeMutablePointer<AVStream>) -> Int? {
        dvConfig(stream: stream)?.profile
    }

    /// Profile + base-layer signal compatibility ID from the dvcC/dvvC record (compat 0 = IPT-only, no
    /// compatible base layer). nil when the stream carries no DV side-data.
    nonisolated static func dvConfig(stream: UnsafeMutablePointer<AVStream>) -> (profile: Int, blCompatID: Int)? {
        let nb = Int(stream.pointee.codecpar.pointee.nb_coded_side_data)
        guard nb > 0, let sideData = stream.pointee.codecpar.pointee.coded_side_data else {
            return nil
        }
        for i in 0..<nb {
            let item = sideData[i]
            guard item.type == AV_PKT_DATA_DOVI_CONF, let raw = item.data, item.size >= 8 else { continue }
            let record = raw.withMemoryRebound(to: AVDOVIDecoderConfigurationRecord.self, capacity: 1) { $0.pointee }
            return (Int(record.dv_profile), Int(record.dv_bl_signal_compatibility_id))
        }
        return nil
    }

    /// Container-declared stereo layout from stream-level `AV_PKT_DATA_STEREO3D` side data; nil when the
    /// stream declares none. Matroska StereoMode is the source in practice (`stereo_mode` in the stream
    /// metadata is the same value spelled as a string). Read for routing: `AV_STEREO3D_FRAMESEQUENCE` on
    /// H.264 means both views ride in one track (#435).
    nonisolated static func stereo3DType(stream: UnsafeMutablePointer<AVStream>) -> AVStereo3DType? {
        let nb = Int(stream.pointee.codecpar.pointee.nb_coded_side_data)
        guard nb > 0, let sideData = stream.pointee.codecpar.pointee.coded_side_data else { return nil }
        for i in 0..<nb {
            let item = sideData[i]
            guard item.type == AV_PKT_DATA_STEREO3D, let raw = item.data,
                  item.size >= MemoryLayout<AVStereo3D>.size else { continue }
            return raw.withMemoryRebound(to: AVStereo3D.self, capacity: 1) { $0.pointee.type }
        }
        return nil
    }

    nonisolated static func detectFrameRate(stream: UnsafeMutablePointer<AVStream>) -> Double? {
        let avg = stream.pointee.avg_frame_rate
        if avg.den > 0 && avg.num > 0 {
            return Double(avg.num) / Double(avg.den)
        }
        let r = stream.pointee.r_frame_rate
        if r.den > 0 && r.num > 0 {
            return Double(r.num) / Double(r.den)
        }
        return nil
    }
}
