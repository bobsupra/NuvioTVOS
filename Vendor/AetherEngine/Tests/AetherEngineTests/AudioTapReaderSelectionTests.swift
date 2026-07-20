import XCTest
@testable import AetherEngine

final class AudioTapReaderSelectionTests: XCTestCase {
    func testLoopbackWhenNativeSessionPresent() {
        XCTAssertEqual(AudioTapReaderSelection.kind(backend: .native, hasLoopbackSession: true,
            nativeRemoteHLS: false, hasLoadedURL: true), .loopback)
    }
    func testRemoteHLSWhenBypassAndNoLoopback() {
        XCTAssertEqual(AudioTapReaderSelection.kind(backend: .native, hasLoopbackSession: false,
            nativeRemoteHLS: true, hasLoadedURL: true), .remoteHLS)
    }
    func testNoneWhenRemoteHLSButNoURL() {
        XCTAssertEqual(AudioTapReaderSelection.kind(backend: .native, hasLoopbackSession: false,
            nativeRemoteHLS: true, hasLoadedURL: false), .none)
    }
    func testSoftwareBackend() {
        XCTAssertEqual(AudioTapReaderSelection.kind(backend: .software, hasLoopbackSession: false,
            nativeRemoteHLS: false, hasLoadedURL: true), .software)
    }
    func testNoneWhenPlainNativeNoLoopback() {
        XCTAssertEqual(AudioTapReaderSelection.kind(backend: .native, hasLoopbackSession: false,
            nativeRemoteHLS: false, hasLoadedURL: true), .none)
    }
}
