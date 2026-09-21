import Testing
import Foundation
import AetherLibavcodec
import AetherLibavformat

/// Proves the decoder and demuxer allowlists in `build.sh` describe what the
/// shipped binaries actually carry.
///
/// `--disable-decoders` plus an explicit allowlist is this package's entire codec
/// policy: a name that is not on the list is not in the binary, and AetherEngine's
/// software path then fails the load with `unsupportedCodec` (FFmpegBuild#1, #3).
/// Two ways that policy goes silently wrong, neither of which shows up in a build
/// log:
///
/// * The configure line gains a decoder and the xcframeworks are not rebuilt. The
///   source says the codec ships, the binary a consumer resolves says otherwise,
///   and the gap surfaces as a field report months later.
/// * The name configure accepts is not the name the component registers under
///   (`libzvbi_teletext` builds `libzvbi_teletextdec`, the `mpegps` demuxer
///   registers as `mpeg`). "It is on the list" and "a consumer can find it" are
///   then different statements.
struct DecoderAvailabilityTests {

    private static let buildScript: String = {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FFmpegBuildTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
        return (try? String(contentsOf: repoRoot.appendingPathComponent("build.sh"), encoding: .utf8)) ?? ""
    }()

    /// Configure component name -> the name the built component registers under.
    /// `avcodec_find_decoder_by_name` / `av_find_input_format` are what a consumer
    /// calls, so a mismatch here is the difference between a shipped decoder and an
    /// unreachable one. Formats whose registered name is a comma list (`mov`,
    /// `matroska`) need no entry: `av_find_input_format` matches per element.
    private static let registeredName: [String: String] = [
        // The MS-MPEG4 v3 decoder answers to the family name, which is why a load
        // of a DivX 3.11 file logs `codec=msmpeg4` and not `codec=msmpeg4v3`. Its
        // v1 and v2 siblings do register under their own names.
        "msmpeg4v3": "msmpeg4",
        "movtext": "mov_text",
        "libzvbi_teletext": "libzvbi_teletextdec",
        "mpegps": "mpeg",
    ]

    private static func enabled(_ component: String) -> [String] {
        buildScript
            .components(separatedBy: "--enable-\(component)=")
            .dropFirst()
            .map { String($0.prefix(while: { $0.isLowercase || $0.isNumber || $0 == "_" })) }
            .filter { !$0.isEmpty }
    }

    @Test("build.sh enables no decoder the shipped libavcodec is missing")
    func everyEnabledDecoderResolves() {
        let names = Self.enabled("decoder")
        #expect(names.count > 30, "parsed \(names.count) decoders out of build.sh, the allowlist is larger than that")
        for name in names {
            let registered = Self.registeredName[name] ?? name
            #expect(
                avcodec_find_decoder_by_name(registered) != nil,
                "build.sh enables \(name) but the shipped libavcodec does not resolve \(registered): either the xcframeworks are stale or the decoder registers under another name"
            )
        }
    }

    @Test("build.sh enables no demuxer the shipped libavformat is missing")
    func everyEnabledDemuxerResolves() {
        let names = Self.enabled("demuxer")
        #expect(names.count > 15, "parsed \(names.count) demuxers out of build.sh, the allowlist is larger than that")
        for name in names {
            let registered = Self.registeredName[name] ?? name
            #expect(
                av_find_input_format(registered) != nil,
                "build.sh enables the \(name) demuxer but the shipped libavformat does not resolve \(registered)"
            )
        }
    }

    /// The decoders that are here because someone reported them missing. The list
    /// above follows build.sh and so cannot catch a deliberate removal; these names
    /// were promised to a reporter against a green field cell, so they are asserted
    /// independently of what the configure line currently says.
    @Test("decoders added on a field report are still present")
    func reportedDecodersStayIn() {
        // FFmpegBuild#1: QuickTime RLE, the case that also moved the routing
        // default to software for everything the native path does not carry.
        #expect(avcodec_find_decoder_by_name("qtrle") != nil)
        // FFmpegBuild#3: the legacy Microsoft MPEG-4 family. msmpeg4v3 and wmv3
        // are both field-verified by the reporter, in AVI and in Matroska.
        for name in ["msmpeg4v1", "msmpeg4v2", "msmpeg4v3", "wmv1", "wmv2", "wmv3"] {
            let registered = Self.registeredName[name] ?? name
            #expect(avcodec_find_decoder_by_name(registered) != nil, "\(name) went missing")
        }
    }

    /// The native `.wmv` chain is all-in or all-out (FFmpegBuild#3), and since
    /// September 2026 it is in.
    ///
    /// Such a file needs three things at once: the asf demuxer to open it, a video
    /// decoder, and a decoder for whichever WMA flavour its audio track carries. With
    /// the demuxer but without that last one, AetherEngine's `AudioCodecCompat` maps
    /// the unrecognised id to `.unsupported` and the session drops to video-only, so
    /// the file plays silently, which reads as a playback bug where an honest
    /// `unsupportedCodec` would not. Every name missing below is one such file, which
    /// is why the whole family ships and why this test lists each one instead of
    /// trusting the configure line.
    @Test("the native .wmv chain is whole")
    func theNativeWmvChainIsWhole() {
        #expect(
            av_find_input_format("asf") != nil,
            "asf demuxer missing: a native .wmv cannot be opened at all"
        )
        for name in ["wmav1", "wmav2", "wmapro", "wmalossless", "wmavoice"] {
            #expect(
                avcodec_find_decoder_by_name(name) != nil,
                "\(name) missing: files carrying it would play with silent audio"
            )
        }
        // The video half belongs in the same statement, so a failure reads as one fact
        // about the format rather than sending the reader to another suite to find out
        // why sound alone was not enough. vc1 is what WVC1, the modern .wmv, carries.
        for name in ["wmv1", "wmv2", "wmv3", "vc1"] {
            #expect(avcodec_find_decoder_by_name(name) != nil, "\(name) missing")
        }
    }

    /// The native `.flv` chain, whole since 3.2.0, and whole for the same reason.
    ///
    /// The container is the part that was never missing: the `flv` demuxer has been on the list
    /// since the first build, so a Flash file from after 2008 (H.264 + AAC) always played and only
    /// the legacy tail was absent. Both halves of that tail are asserted here, video and audio,
    /// because they fail differently and only one of the two failures is honest: without a video
    /// decoder the load ends in `unsupportedCodec`, without an audio decoder AetherEngine maps the
    /// id to `.unsupported` and plays the file silently.
    ///
    /// Flash Screen Video is deliberately not in this list. It needs zlib, which
    /// `--disable-autodetect` switches off, so asking for it would only produce the silent
    /// no-op the dash demuxer once was.
    @Test("the native .flv chain is whole")
    func theNativeFlvChainIsWhole() {
        #expect(
            av_find_input_format("flv") != nil,
            "flv demuxer missing: no Flash file opens at all"
        )
        // Video. `flv` IS the FLV1 decoder: it registers under the family name, so this is the
        // spelling a consumer has to ask for, and `flv1` resolves to nothing.
        for name in ["flv", "vp6", "vp6a", "vp6f"] {
            #expect(avcodec_find_decoder_by_name(name) != nil, "\(name) missing: those files fail the load")
        }
        // Audio, every shape the container can carry, since each one left out is a silent film.
        for name in ["nellymoser", "adpcm_swf", "speex", "pcm_s16be", "pcm_u8", "pcm_alaw", "pcm_mulaw"] {
            #expect(
                avcodec_find_decoder_by_name(name) != nil,
                "\(name) missing: files carrying it would play with silent audio"
            )
        }
    }
}
