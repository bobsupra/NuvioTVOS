// Pure DTS ordering for the producer's dual-demuxer pull-merge (demuxed-audio HLS ingest).
// Side packet yields when its rescaled timestamp is strictly lower; ties go to main. Blocking
// read mechanics are not testable without demuxers.
import XCTest
import AetherLibavutil
@testable import AetherEngine

final class DualSourceMergeOrderTests: XCTestCase {

    private let ts90k = AVRational(num: 1, den: 90_000)

    func testInterleavesByDtsInSharedTimebase() {
        // 90 kHz clock: video 25fps (3600-tick spacing), audio AAC ~21.3ms (1920-tick spacing).
        var videoDts: Int64 = 0
        var audioDts: Int64 = 900   // intrinsic head-of-stream offset
        for _ in 0..<100 {
            let sideFirst = DualSourceMergeOrder.sideFirst(
                mainTicks: videoDts, mainTimeBase: ts90k,
                sideTicks: audioDts, sideTimeBase: ts90k
            )
            XCTAssertEqual(sideFirst, audioDts < videoDts,
                           "video=\(videoDts) audio=\(audioDts)")
            if sideFirst { audioDts += 1920 } else { videoDts += 3600 }
        }
    }

    func testUnequalCadenceDrainsTheLaggingSource() {
        let videoDts: Int64 = 7200
        var audioDts: Int64 = 0
        var sideYields = 0
        while DualSourceMergeOrder.sideFirst(
            mainTicks: videoDts, mainTimeBase: ts90k,
            sideTicks: audioDts, sideTimeBase: ts90k
        ) {
            sideYields += 1
            audioDts += 1920
        }
        XCTAssertEqual(sideYields, 4)  // 0, 1920, 3840, 5760 < 7200
        XCTAssertEqual(audioDts, 7680)
    }

    func testRescalesAcrossDifferentTimebases() {
        // main=1/1000, side=1/90000: comparison must rescale to a common clock, not compare raw ticks.
        let ms = AVRational(num: 1, den: 1000)
        XCTAssertTrue(DualSourceMergeOrder.sideFirst(
            mainTicks: 500, mainTimeBase: ms,
            sideTicks: 36_000, sideTimeBase: ts90k   // 400 ms
        ))
        XCTAssertFalse(DualSourceMergeOrder.sideFirst(
            mainTicks: 500, mainTimeBase: ms,
            sideTicks: 54_000, sideTimeBase: ts90k   // 600 ms
        ))
    }

    func testTieYieldsMainFirst() {
        // Ties yield main first: segment cuts key off video keyframes.
        XCTAssertFalse(DualSourceMergeOrder.sideFirst(
            mainTicks: 3600, mainTimeBase: ts90k,
            sideTicks: 3600, sideTimeBase: ts90k
        ))
    }

    func testTimestamplessPacketYieldsImmediately() {
        // Int64.min == NOPTS: yield immediately without rescaling; downstream pump owns repair.
        XCTAssertTrue(DualSourceMergeOrder.sideFirst(
            mainTicks: 100, mainTimeBase: ts90k,
            sideTicks: Int64.min, sideTimeBase: ts90k
        ))
        XCTAssertFalse(DualSourceMergeOrder.sideFirst(
            mainTicks: Int64.min, mainTimeBase: ts90k,
            sideTicks: 100, sideTimeBase: ts90k
        ))
    }
}
