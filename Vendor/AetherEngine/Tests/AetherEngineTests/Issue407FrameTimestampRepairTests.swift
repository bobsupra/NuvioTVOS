import Testing
import Foundation
@testable import AetherEngine

/// #407 (classicjazz): VC-1 judder on Apple TV, reported as "the software decoder reads
/// `AVFrame.pts` where every other FFmpeg-based player reads `best_effort_timestamp`, and for
/// VC-1 in Matroska the raw PTS is unset on every I and P picture".
///
/// The measurement behind that report is real and reproduces on a plain ffprobe: a Matroska
/// `V_MS/VFW/FOURCC` track (which is how WVC1 is stored) carries the block time in DTS, so
/// `AVPacket.pts` is `AV_NOPTS_VALUE` on the pictures the demuxer cannot reorder, and the decoded
/// frames inherit that. It does not describe what the ENGINE sees: `Demuxer.applyDemuxerOptions`
/// opens every source with `fflags=+genpts`, which fills exactly those gaps a layer earlier
/// (measured with `aetherctl pktdump`: `NOPTS_pts=0` over 300 VC-1 packets, and the same ffprobe
/// run with `-fflags +genpts` reports a complete, evenly spaced series). So the judder has another
/// cause, and the timestamp path was never the one exercised.
///
/// What the report did expose is that the direct decode path had no fallback of its own. With
/// `+genpts` suppressed the session does not judder, it dies: every frame reaches
/// `SampleBufferRenderer.enqueue` unschedulable and is dropped, the picture never appears and the
/// demux loop runs a 58 s file dry in 2.5 s because nothing paces it (measured). That is the state
/// live MPEG-TS can also reach on its own, and it is one flag on one open away at any time, so the
/// repair belongs at the frame, not at the container: read `best_effort_timestamp` when the
/// decoder set no PTS, and keep the drop as the last resort it was meant to be.
@Suite("Decoded-frame timestamp repair from best_effort_timestamp (#407)")
struct Issue407FrameTimestampRepairTests {

    /// The common case. A decoder-set PTS is never overwritten: `best_effort_timestamp` is a guess
    /// derived from that same PTS plus the packet DTS, so preferring it could only ever move a
    /// correctly timed frame.
    @Test("a frame that carries a PTS is left alone")
    func timedFrameUntouched() {
        #expect(SoftwareVideoDecoder.repairedPTS(pts: 41708, bestEffort: 41708) == nil)
        #expect(SoftwareVideoDecoder.repairedPTS(pts: 41708, bestEffort: 0) == nil)
        #expect(SoftwareVideoDecoder.repairedPTS(pts: 41708, bestEffort: Int64.min) == nil)
        // Zero is a timestamp, not an absence: the first frame of every source has it.
        #expect(SoftwareVideoDecoder.repairedPTS(pts: 0, bestEffort: 41708) == nil)
        // So is a negative one (a container with a non-zero start time, or an edit-list shift).
        #expect(SoftwareVideoDecoder.repairedPTS(pts: -1000, bestEffort: 0) == nil)
    }

    /// The reported shape: the picture has no PTS of its own, libavcodec reconstructed one from the
    /// packet DTS. Without this the frame is unschedulable and gets dropped a layer lower.
    @Test("an untimed frame takes the best-effort timestamp")
    func untimedFrameRepaired() {
        #expect(SoftwareVideoDecoder.repairedPTS(pts: Int64.min, bestEffort: 41708) == 41708)
        #expect(SoftwareVideoDecoder.repairedPTS(pts: Int64.min, bestEffort: 0) == 0)
        #expect(SoftwareVideoDecoder.repairedPTS(pts: Int64.min, bestEffort: -1000) == -1000)
    }

    /// Neither field is usable. There is nothing left to time the frame with, so the repair reports
    /// no opinion and the unschedulable gate below stays the one that decides. Returning a
    /// substitute here (0, or the last frame's PTS) would put a wrongly placed picture into the
    /// reorder buffer, which is worse than one missing frame: it reorders its neighbours on the way
    /// out.
    @Test("a frame with no timestamp at all stays untimed")
    func doublyUntimedFrameNotInvented() {
        #expect(SoftwareVideoDecoder.repairedPTS(pts: Int64.min, bestEffort: Int64.min) == nil)
    }
}
