// Tests/AetherEngineTests/NativeSubtitleCueStoreTests.swift
import CoreGraphics
import XCTest
@testable import AetherEngine

final class NativeSubtitleCueStoreTests: XCTestCase {
    private func cue(_ id: Int, _ a: Double, _ b: Double, _ s: String) -> SubtitleCue {
        SubtitleCue(id: id, startTime: a, endTime: b, body: .text(s))
    }

    private static func onePixel() -> CGImage {
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    func test_windowReturnsOverlappingCuesOnAVPlayerAxis() {
        let store = NativeSubtitleCueStore()
        store.setShiftSeconds(10)
        store.replaceCues([cue(1, 100, 102, "a"), cue(2, 200, 201, "b")]) // axis: 90-92, 190-191
        let win = store.cuesInWindow(start: 88, end: 94)
        XCTAssertEqual(win.count, 1)
        XCTAssertEqual(win[0].text, "a")
        XCTAssertEqual(win[0].start, 90, accuracy: 0.0001)
    }

    func test_filtersBitmapCues_clearReleases() {
        let store = NativeSubtitleCueStore()
        store.appendCues([cue(1, 0, 1, "t")])
        XCTAssertEqual(store.cueCount, 1)
        store.clear()
        XCTAssertEqual(store.cueCount, 0)
    }

    func test_imageCuesAreExcluded() {
        let store = NativeSubtitleCueStore()
        store.appendCues([
            SubtitleCue(id: 1, startTime: 0, endTime: 1, body: .text("t")),
            SubtitleCue(id: 2, startTime: 0, endTime: 1,
                        body: .image(SubtitleImage(cgImage: Self.onePixel(), position: .zero)))
        ])
        XCTAssertEqual(store.cueCount, 1)
    }
}
