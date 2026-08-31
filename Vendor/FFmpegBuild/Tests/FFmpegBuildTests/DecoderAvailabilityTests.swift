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

    /// The native `.wmv` chain is all-in or all-out (FFmpegBuild#3).
    ///
    /// A `.wmv` file needs the asf demuxer and a WMA decoder together. With the
    /// demuxer but without `wmav1`/`wmav2`, AetherEngine's `AudioCodecCompat` maps
    /// the unrecognised id to `.unsupported` and the session drops to video-only:
    /// the file plays silently, which reads as a playback bug, where today's
    /// `unsupportedCodec` is at least an honest failure. Enabling one of the three
    /// therefore means enabling all three plus the engine's audio-route entry, and
    /// this test is what refuses the half-set.
    ///
    /// Currently all three are out, and the field answer behind that is recorded in
    /// build.sh: the reporter's library carries WMV9 only inside Matroska and
    /// MPEG-TS, where the container's own demuxer supplies the stream.
    @Test("the native .wmv chain is whole or absent")
    func nativeWmvChainIsWholeOrAbsent() {
        let asf = av_find_input_format("asf") != nil
        let wmav1 = avcodec_find_decoder_by_name("wmav1") != nil
        let wmav2 = avcodec_find_decoder_by_name("wmav2") != nil
        #expect(
            asf == wmav1 && wmav1 == wmav2,
            "half a format chain fails silently: asf=\(asf), wmav1=\(wmav1), wmav2=\(wmav2)"
        )
    }
}
