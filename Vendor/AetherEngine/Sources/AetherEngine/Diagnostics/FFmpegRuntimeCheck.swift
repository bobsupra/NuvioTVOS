import Foundation
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil
import AetherLibswresample

/// Witnesses which FFmpeg actually answers in this process.
///
/// AetherEngine calls `avcodec_*` / `avformat_*` as ordinary external symbols, so which binary
/// serves them is decided by the host's link, not by the package graph. A second FFmpeg in the
/// executable wins wherever it sorts first: a static archive pulled in with `-force_load` becomes a
/// definition in the binary itself and beats every dylib, and a dependency that re-exports the same
/// symbols (libVLC does) wins whenever the build system lists it ahead of a vendored framework.
/// The engine then executes against headers it was never compiled against.
///
/// AE#396 was exactly that, and cost its reporter five fixtures and two devices, because the only
/// trace was `flac bridge encoder absent from this FFmpeg build`: a sentence about the build that
/// answered, which read as a sentence about ours. Nothing here fixes a bad link (nothing in a
/// library can), it only makes the first minute say so.
enum FFmpegRuntimeCheck {

    /// One linked FFmpeg library: what the headers declared when this engine compiled, against what
    /// the loaded binary reports now.
    struct Library: Sendable, Equatable {
        let name: String
        /// `LIB<NAME>_VERSION_MAJOR` as seen by the compiler.
        let compiledMajor: UInt32
        /// `<name>_version()` from whichever binary served the call: major<<16 | minor<<8 | micro.
        let loadedVersion: UInt32

        var loadedMajor: UInt32 { loadedVersion >> 16 }
        var loadedVersionString: String {
            "\(loadedMajor).\((loadedVersion >> 8) & 0xFF).\(loadedVersion & 0xFF)"
        }
        /// Only the major is load-bearing: FFmpeg keeps ABI within a major and breaks it across one.
        var matches: Bool { loadedMajor == compiledMajor }
    }

    static var loadedLibraries: [Library] {
        [
            Library(name: "libavcodec",
                    compiledMajor: UInt32(LIBAVCODEC_VERSION_MAJOR),
                    loadedVersion: avcodec_version()),
            Library(name: "libavformat",
                    compiledMajor: UInt32(LIBAVFORMAT_VERSION_MAJOR),
                    loadedVersion: avformat_version()),
            Library(name: "libavutil",
                    compiledMajor: UInt32(LIBAVUTIL_VERSION_MAJOR),
                    loadedVersion: avutil_version()),
            Library(name: "libswresample",
                    compiledMajor: UInt32(LIBSWRESAMPLE_VERSION_MAJOR),
                    loadedVersion: swresample_version()),
        ]
    }

    /// The configure line of the libavcodec that answered. This is the value the encoder-cascade
    /// message is really about: whether `--enable-encoder=flac` is present decides that path.
    static var loadedConfiguration: String? {
        guard let raw = avcodec_configuration() else { return nil }
        return String(validatingCString: raw)
    }

    /// Compact identity for messages that describe the FFmpeg build's contents, so a claim about
    /// "this FFmpeg build" always says which one. Silent about the expected major while it matches.
    static func identity(of library: Library) -> String {
        library.matches
            ? "\(library.name) \(library.loadedVersionString)"
            : "\(library.name) \(library.loadedVersionString), NOT the \(library.compiledMajor).x this engine was built against"
    }

    static var avcodecIdentity: String {
        guard let avcodec = loadedLibraries.first(where: { $0.name == "libavcodec" }) else {
            return "libavcodec (version unavailable)"
        }
        return identity(of: avcodec)
    }

    /// nil while every major matches. Otherwise a line that has to survive being read by someone who
    /// believes the engine is at fault, so it names the mismatch, the cause, and the two commands
    /// that show it.
    static func mismatchReport(for libraries: [Library], configuration: String?) -> String? {
        let mismatched = libraries.filter { !$0.matches }
        guard !mismatched.isEmpty else { return nil }

        let list = mismatched
            .map { "\($0.name) compiled against \($0.compiledMajor).x, loaded \($0.loadedVersionString)" }
            .joined(separator: "; ")

        var text = "ERROR: AetherEngine is executing against a different FFmpeg than it was built against: "
            + "\(list). A second FFmpeg sorts ahead of AetherEngine's frameworks in this executable's link "
            + "(a static archive force-loaded into the binary, or another dependency exporting the same "
            + "symbols, libVLC among them). `nm -m <executable> | grep _avcodec_find_encoder` names the "
            + "binary that wins and `otool -L <executable>` shows the order; link AetherEngine's frameworks "
            + "first, or remove the second copy. Decoding, encoding and struct layouts are undefined past "
            + "this point, and any message about what this FFmpeg build contains describes that one, not ours."
        if let configuration {
            text += " Loaded libavcodec configuration: \(configuration)"
        }
        return text
    }

    /// What the engine says about its FFmpeg at startup: the mismatch report when there is one, and
    /// otherwise the four loaded versions. Healthy sessions carry it too, because "which FFmpeg
    /// answered" is the question a host cannot reconstruct afterwards from a silent log.
    static var verdictLine: String {
        let libraries = loadedLibraries
        if let report = mismatchReport(for: libraries, configuration: loadedConfiguration) {
            return report
        }
        return libraries.map { "\($0.name) \($0.loadedVersionString)" }.joined(separator: ", ")
    }

    /// Emits the verdict once per process. Called from `AetherEngine.init`, after the av_log bridge
    /// is installed so the line lands in the host's sink like every other diagnostic.
    static func logOnce() {
        _ = hasLogged
    }

    private static let hasLogged: Bool = {
        EngineLog.emit("[FFmpeg] \(verdictLine)", category: .engine)
        return true
    }()
}
