import Testing
import Foundation
@testable import AetherEngine

/// AE#509 (AttiK22): a live join that reaches the whole window and places none of it. AVPlayer fetched
/// `init.mp4` and then every segment in order, all answered 200, 25.6 MB across 8 segments, and
/// `loadedTimeRanges` stayed empty with `item.status` never leaving `.unknown`, `item.error` nil and
/// `errorLog()` empty for the full 20 s.
///
/// The producer publishes the epoch's first frame at `pinnedFirstTfdtPts`, and that value was allowed
/// to go negative. `tfdt` carries `unsigned int(64)` (ISO/IEC 14496-12), so a negative item axis has
/// no representation: movenc writes the bits and AVPlayer reads `baseMediaDecodeTime = 2^64 - |dts|`.
/// Measured on the harness at a source 53.7 s below the wrap: `video gate open: actual=-4834592
/// desired=0 pinnedTo=-4834592 shift=0`, seg0 carrying `baseMediaDecodeTime=18446744073704717024`
/// against a playlist starting at 0, and `VERDICT: live FAIL (t=-53.72s, edge=0.00s)` with the item
/// reporting no loaded range at all. With the clamp the same fixture opens at `shift=-4834592`, seg0
/// carries `baseMediaDecodeTime=0`, and the session plays.
///
/// The negative source timestamps are libavformat working as designed, not a corrupt stream. An
/// MPEG-TS whose first DTS sits within 60 s of the 33-bit PTS wrap (`2^33 / 90000 = 95443.72 s`) is
/// classified `AV_PTS_WRAP_SUB_OFFSET` in `update_wrap_reference`, after which every timestamp comes
/// out `2^33` ticks low: demux.c says so in as many words, "correct first time stamps to negative
/// values". A one-line ffmpeg fixture reproduces it, `-output_ts_offset 95390` reads back as
/// `pts_time=-53.717689`.
///
/// The pin itself is AE#408's and stays: a re-aimed gate that opens BELOW a segment's advertised start
/// keeps its own position, because an overlap is what AVPlayer absorbs and a hole is what it waits on
/// forever. A negative source clock is not that case. It is an ordinary live join whose axis the
/// container cannot express, and pinning to it publishes a timeline no playlist can describe.
///
/// Whether this is the reporter's own session is NOT settled, and the third test below is where the
/// gap is stated rather than papered over: the three clocks in his two captures (95173.75, 95181.57,
/// 95258.48) sit 185 to 270 s below the wrap, which is outside the 60 s window libavformat classifies
/// on, so either the number his diagnostic prints is not the demuxer's first DTS or his session is a
/// neighbouring case. What stands on its own is that all three sit in the top 0.3% of a 26.5 h cycle
/// across two rounds days apart, and that the defect this file pins reproduces every one of his
/// observables exactly.
struct Issue509LiveJoinNearPTSWrapTests {

    /// The reporting geometry, in the 90 kHz time base an MPEG-TS demuxes at.
    private static let wrapTicks: Int64 = 1 << 33               // 95443.717 s
    private static let subOffsetWindowTicks: Int64 = 60 * 90_000

    @Test("a live join on a source below the wrap publishes a zero axis, not an unsigned 2^64 one")
    func negativeSourceClockIsClampedAtZero() {
        // -53.717689 s, the value the harness fixture demuxes at (`-output_ts_offset 95390`).
        let firstDts: Int64 = -4_834_592
        let pinned = HLSSegmentProducer.pinnedFirstTfdtPts(
            actualFirstDts: firstDts, desiredTfdtPts: 0, planAnchorPts: 0)
        #expect(pinned == 0)
        // The shift the producer derives from it moves the axis onto zero, which is what the playlist
        // advertises. Unclamped this was 0, and every packet kept its negative source timestamp.
        #expect(firstDts - pinned == firstDts)
    }

    @Test("the value that reached AVPlayer is the unsigned reading of the unclamped pin")
    func unsignedReadingIsSixMillionYears() {
        // What seg0 carried on the harness before the clamp, and what an item cannot place anything
        // against: the same bits read as `unsigned int(64)`.
        let firstDts: Int64 = -4_834_592
        #expect(UInt64(bitPattern: firstDts) == 18_446_744_073_704_717_024)
        // Six million years at 90 kHz, so the distance is not a tolerance question.
        #expect(Double(UInt64(bitPattern: firstDts)) / 90_000.0 / 31_557_600.0 > 6_000_000)
    }

    @Test("the window that produces those timestamps is the last 60 s of the 33-bit wrap")
    func subOffsetWindowIsTheLastMinute() {
        // libavformat's rule in `update_wrap_reference`, restated on the axis a report arrives on: a
        // first DTS at or above this is served negative, anything below it is served as it stands.
        let threshold = Self.wrapTicks - Self.subOffsetWindowTicks
        #expect(abs(Double(threshold) / 90_000.0 - 95_383.7177) < 0.001)
        // The fixture sits inside it; a source a few minutes lower does not, which is what makes this
        // a property of WHERE in the 26.5 h cycle a channel is joined rather than of the channel.
        #expect(Int64(95_390.0 * 90_000) >= threshold)
        #expect(Int64(95_173.75 * 90_000) < threshold)
    }

    @Test("AE#408's early open is untouched by the clamp")
    func earlyOpenStillKeepsItsPosition() {
        // Every operand AE#408 works with is at or above zero, so the clamp cannot reach its cases.
        #expect(HLSSegmentProducer.pinnedFirstTfdtPts(
            actualFirstDts: 243_118, desiredTfdtPts: 244_119, planAnchorPts: 0) == 243_118)
        #expect(HLSSegmentProducer.pinnedFirstTfdtPts(
            actualFirstDts: 255_297, desiredTfdtPts: 244_119, planAnchorPts: 0) == 244_119)
        // An early open whose whole margin is the plan anchor still lands where AE#418 put it.
        #expect(HLSSegmentProducer.pinnedFirstTfdtPts(
            actualFirstDts: 48_128, desiredTfdtPts: 48_128, planAnchorPts: 1_024) == 47_104)
    }

    @Test("a plan anchor above the source clock cannot publish a negative restart axis either")
    func planAnchorOvershootIsClampedToo() {
        // The same expression reaches below zero without any wrap involved, when the anchor a restart
        // folds back is above the sample the gate opened on.
        #expect(HLSSegmentProducer.pinnedFirstTfdtPts(
            actualFirstDts: 1_000, desiredTfdtPts: 48_128, planAnchorPts: 90_000) == 0)
    }
}
