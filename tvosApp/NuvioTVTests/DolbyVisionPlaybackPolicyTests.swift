//
//  DolbyVisionPlaybackPolicyTests.swift
//  NuvioTVTests
//
//  Unit tests for the Android-style Dolby Vision engine policy on tvOS.
//

import XCTest
@testable import NuvioTV

final class DolbyVisionPlaybackPolicyTests: XCTestCase {

    private func resolve(
        url: String,
        name: String? = nil,
        description: String? = nil,
        filename: String? = nil,
        engine: String = "Auto"
    ) -> DolbyVisionPlaybackPolicy.Result {
        DolbyVisionPlaybackPolicy.resolve(
            .init(
                urlString: url,
                streamName: name,
                streamDescription: description,
                filename: filename,
                engineSetting: engine
            )
        )
    }

    // MARK: - Detection

    func testDetectsDVTokenInName() {
        XCTAssertTrue(
            DolbyVisionPlaybackPolicy.isDolbyVisionLikely(
                urlString: "https://cdn.example/file.mkv",
                streamName: "4K HDR DV Atmos"
            )
        )
    }

    func testDetectsDolbyVisionPhrase() {
        XCTAssertTrue(
            DolbyVisionPlaybackPolicy.isDolbyVisionLikely(
                urlString: "https://cdn.example/movie.mp4",
                streamDescription: "Dolby Vision Profile 5"
            )
        )
    }

    func testDoesNotTreatHDRAloneAsDV() {
        XCTAssertFalse(
            DolbyVisionPlaybackPolicy.isDolbyVisionLikely(
                urlString: "https://cdn.example/file.mkv",
                streamName: "2160p HDR10 HEVC"
            )
        )
    }

    // MARK: - Containers

    func testMP4IsAVPlayerFriendly() {
        XCTAssertTrue(
            DolbyVisionPlaybackPolicy.isAVPlayerFriendlyContainer(
                urlString: "https://cdn.example/title.mp4?token=abc"
            )
        )
    }

    func testHLSIsAVPlayerFriendly() {
        XCTAssertTrue(
            DolbyVisionPlaybackPolicy.isAVPlayerFriendlyContainer(
                urlString: "https://cdn.example/master.m3u8"
            )
        )
    }

    func testMKVIsNotAVPlayerFriendly() {
        XCTAssertFalse(
            DolbyVisionPlaybackPolicy.isAVPlayerFriendlyContainer(
                urlString: "https://cdn.example/remux.mkv"
            )
        )
    }

    // MARK: - Auto policy

    func testAutoDVMP4StartsMPVForNativeRemux() {
        let r = resolve(
            url: "https://cdn.example/movie.mp4",
            name: "2160p DV HEVC",
            engine: "Auto"
        )
        XCTAssertEqual(r.decision, .nativeRemux)
        XCTAssertEqual(r.engine, .mpv)
        XCTAssertTrue(r.isDolbyVisionLikely)
    }

    func testAutoDVMKVStartsMPVForNativeRemux() {
        let r = resolve(
            url: "https://cdn.example/movie.mkv",
            name: "UHD DoVi HDR10",
            engine: "Auto"
        )
        XCTAssertEqual(r.decision, .nativeRemux)
        XCTAssertEqual(r.engine, .mpv)
        XCTAssertTrue(r.isDolbyVisionLikely)
    }

    func testAutoDVProfile7KeepsMPVHdrFallback() {
        let r = resolve(
            url: "https://cdn.example/movie.mkv",
            name: "UHD Dolby Vision Profile 7",
            engine: "Auto"
        )
        XCTAssertEqual(r.decision, .mpvHdrFallback)
        XCTAssertEqual(r.engine, .mpv)
    }

    func testAutoNonDVDefaultsToMPV() {
        let r = resolve(
            url: "https://cdn.example/movie.mkv",
            name: "1080p BluRay x264",
            engine: "Auto"
        )
        XCTAssertEqual(r.decision, .mpvDefault)
        XCTAssertEqual(r.engine, .mpv)
    }

    // MARK: - Forced settings

    func testForcedAVPlayerAlwaysUsesAVPlayer() {
        let r = resolve(
            url: "https://cdn.example/movie.mkv",
            name: "1080p",
            engine: "AVPlayer"
        )
        XCTAssertEqual(r.engine, .avPlayer)
        XCTAssertEqual(r.decision, .nativeAVPlayer)
    }

    func testForcedMPVKitKeepsDVAsHdrFallback() {
        let r = resolve(
            url: "https://cdn.example/movie.mp4",
            name: "DV Profile 5",
            engine: "MPVKit"
        )
        XCTAssertEqual(r.engine, .mpv)
        XCTAssertEqual(r.decision, .mpvHdrFallback)
    }

    func testNativeRemuxDoesNotClaimDVBeforeFirstFrame() {
        let r = resolve(
            url: "https://cdn.example/movie.mp4",
            name: "DV",
            engine: "Auto"
        )
        XCTAssertNil(DolbyVisionPlaybackPolicy.statusMessage(for: r))
    }

    func testStatusMessageForMPVFallback() {
        let r = resolve(
            url: "https://cdn.example/movie.mkv",
            name: "DV Profile 7",
            engine: "Auto"
        )
        XCTAssertEqual(
            DolbyVisionPlaybackPolicy.statusMessage(for: r),
            "Dolby Vision → HDR10/PQ (MPV)"
        )
    }
}
