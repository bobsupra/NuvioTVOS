import XCTest
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil
import AetherLibswresample
@testable import AetherEngine

/// AE#396 cost a downstream adopter five fixtures and two devices, and the defect was never in the
/// engine: their app linked a second FFmpeg (a static archive, `-force_load`ed, so its `avcodec_*`
/// became ordinary definitions in the executable and beat our dylib for every other object in the
/// same link). The engine expects libavcodec 62 and was executing against 61. The only trace it left
/// was `flac bridge encoder absent from this FFmpeg build` - a sentence about a build that was not
/// ours, and reads as a statement about ours.
///
/// The engine could not notice, because `avcodec_version` and `avcodec_configuration` appeared zero
/// times in `Sources/`. These tests pin the witness that closes that hole: what the headers said at
/// compile time against what the loaded binary answers at runtime.
///
/// The sharp one is `loadedLibrariesMatchTheHeadersThisBuildCompiledAgainst`. In a host with a
/// second FFmpeg ahead of ours in the link, that test is the one that fails.
final class FFmpegRuntimeCheckTests: XCTestCase {

    // MARK: - The report

    private func library(_ name: String, compiled: UInt32, loaded: (UInt32, UInt32, UInt32)) -> FFmpegRuntimeCheck.Library {
        FFmpegRuntimeCheck.Library(
            name: name,
            compiledMajor: compiled,
            loadedVersion: (loaded.0 << 16) | (loaded.1 << 8) | loaded.2)
    }

    func testReportIsNilWhenEveryMajorMatches() {
        let libs = [
            library("libavcodec", compiled: 62, loaded: (62, 28, 102)),
            library("libavutil", compiled: 60, loaded: (60, 13, 100)),
        ]
        XCTAssertNil(FFmpegRuntimeCheck.mismatchReport(for: libs, configuration: "--enable-encoder=flac"))
    }

    func testReportNamesTheLibraryAndBothMajors() throws {
        let libs = [library("libavcodec", compiled: 62, loaded: (61, 19, 101))]
        let report = try XCTUnwrap(FFmpegRuntimeCheck.mismatchReport(for: libs, configuration: nil))
        XCTAssertTrue(report.contains("libavcodec"), report)
        XCTAssertTrue(report.contains("62"), "the compiled-against major must be named: \(report)")
        XCTAssertTrue(report.contains("61.19.101"), "the loaded version must be named in full: \(report)")
    }

    func testReportBlamesASecondFFmpegRatherThanTheEnginesOwn() throws {
        let libs = [library("libavcodec", compiled: 62, loaded: (61, 19, 101))]
        let report = try XCTUnwrap(FFmpegRuntimeCheck.mismatchReport(for: libs, configuration: nil))
        // A reader who sees this line has to end up looking at their link, not at our build.
        XCTAssertTrue(report.lowercased().contains("link"),
                      "the report must point at the link order, that is the only place a host can fix it: \(report)")
        XCTAssertTrue(report.contains("nm -m") || report.contains("otool"),
                      "the report must name the command that shows which binary wins: \(report)")
    }

    func testReportListsEveryMismatchedLibraryAndNoMatchingOne() throws {
        let libs = [
            library("libavcodec", compiled: 62, loaded: (61, 19, 101)),
            library("libavformat", compiled: 62, loaded: (61, 7, 100)),
            library("libavutil", compiled: 60, loaded: (60, 13, 100)),
        ]
        let report = try XCTUnwrap(FFmpegRuntimeCheck.mismatchReport(for: libs, configuration: nil))
        XCTAssertTrue(report.contains("libavcodec"), report)
        XCTAssertTrue(report.contains("libavformat"), report)
        XCTAssertFalse(report.contains("libavutil"),
                       "a library that matches is noise in a report about the ones that do not: \(report)")
    }

    func testReportCarriesTheLoadedConfigurationWhenThereIsOne() throws {
        let libs = [library("libavcodec", compiled: 62, loaded: (61, 19, 101))]
        let report = try XCTUnwrap(
            FFmpegRuntimeCheck.mismatchReport(for: libs, configuration: "--enable-encoder=eac3"))
        // The encoder-absence line is the symptom this witness explains; the configuration of the
        // binary that actually answered is what makes the two legible together.
        XCTAssertTrue(report.contains("--enable-encoder=eac3"), report)
    }

    // MARK: - The process this test runs in

    func testLoadedLibrariesCoverEveryFFmpegLibraryTheEngineLinks() {
        let names = Set(FFmpegRuntimeCheck.loadedLibraries.map(\.name))
        XCTAssertEqual(names, ["libavcodec", "libavformat", "libavutil", "libswresample"])
    }

    /// The sharp one. Fails in exactly the situation AE#396 turned out to be.
    func testLoadedLibrariesMatchTheHeadersThisBuildCompiledAgainst() {
        for lib in FFmpegRuntimeCheck.loadedLibraries {
            XCTAssertEqual(
                lib.loadedMajor, lib.compiledMajor,
                "\(lib.name): compiled against \(lib.compiledMajor), loaded \(lib.loadedVersionString). "
                + "A second FFmpeg is ahead of AetherEngine's in this link.")
        }
        XCTAssertNil(FFmpegRuntimeCheck.mismatchReport(
            for: FFmpegRuntimeCheck.loadedLibraries,
            configuration: FFmpegRuntimeCheck.loadedConfiguration))
    }

    func testLoadedConfigurationIsTheOneTheEngineShips() throws {
        let configuration = try XCTUnwrap(FFmpegRuntimeCheck.loadedConfiguration)
        // Both bridge encoders are FFmpegBuild's; their absence is what AE#396 reported.
        XCTAssertTrue(configuration.contains("--enable-encoder=flac"), configuration)
        XCTAssertTrue(configuration.contains("--enable-encoder=eac3"), configuration)
    }

    // MARK: - The identity the encoder-absence line carries

    func testAvcodecIdentityNamesOnlyTheVersionWhenItMatches() {
        let identity = FFmpegRuntimeCheck.identity(
            of: library("libavcodec", compiled: 62, loaded: (62, 28, 102)))
        XCTAssertEqual(identity, "libavcodec 62.28.102")
    }

    func testAvcodecIdentityNamesTheExpectedMajorWhenItDoesNot() {
        let identity = FFmpegRuntimeCheck.identity(
            of: library("libavcodec", compiled: 62, loaded: (61, 19, 101)))
        XCTAssertTrue(identity.contains("61.19.101"), identity)
        XCTAssertTrue(identity.contains("62"), "an unexpected build has to say what was expected: \(identity)")
    }

    // MARK: - The line the engine emits at init

    func testVerdictLineNamesEveryLinkedLibraryWithItsVersionWhenHealthy() {
        let line = FFmpegRuntimeCheck.verdictLine
        for lib in FFmpegRuntimeCheck.loadedLibraries {
            XCTAssertTrue(line.contains("\(lib.name) \(lib.loadedVersionString)"),
                          "\(lib.name) missing from the init line: \(line)")
        }
        XCTAssertFalse(line.contains("ERROR:"), line)
    }
}
