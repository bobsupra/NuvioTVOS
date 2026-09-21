import Foundation

struct SWPerformanceSnapshot: Equatable, Sendable {
    var videoPacketCalls: UInt64 = 0
    var videoDecodeNanoseconds: UInt64 = 0
    var videoConversionNanoseconds: UInt64 = 0
    var videoFrames: UInt64 = 0
    var audioPacketCalls: UInt64 = 0
    var audioDecodeNanoseconds: UInt64 = 0
    var audioBuffers: UInt64 = 0

    static let zero = SWPerformanceSnapshot()

    var totalNanoseconds: UInt64 {
        videoDecodeNanoseconds &+ videoConversionNanoseconds &+ audioDecodeNanoseconds
    }

    static func + (lhs: Self, rhs: Self) -> Self {
        Self(
            videoPacketCalls: lhs.videoPacketCalls &+ rhs.videoPacketCalls,
            videoDecodeNanoseconds: lhs.videoDecodeNanoseconds &+ rhs.videoDecodeNanoseconds,
            videoConversionNanoseconds: lhs.videoConversionNanoseconds &+ rhs.videoConversionNanoseconds,
            videoFrames: lhs.videoFrames &+ rhs.videoFrames,
            audioPacketCalls: lhs.audioPacketCalls &+ rhs.audioPacketCalls,
            audioDecodeNanoseconds: lhs.audioDecodeNanoseconds &+ rhs.audioDecodeNanoseconds,
            audioBuffers: lhs.audioBuffers &+ rhs.audioBuffers
        )
    }

    func delta(since previous: Self) -> Self {
        func difference(_ current: UInt64, _ old: UInt64) -> UInt64 {
            current >= old ? current - old : current
        }
        return Self(
            videoPacketCalls: difference(videoPacketCalls, previous.videoPacketCalls),
            videoDecodeNanoseconds: difference(videoDecodeNanoseconds, previous.videoDecodeNanoseconds),
            videoConversionNanoseconds: difference(videoConversionNanoseconds, previous.videoConversionNanoseconds),
            videoFrames: difference(videoFrames, previous.videoFrames),
            audioPacketCalls: difference(audioPacketCalls, previous.audioPacketCalls),
            audioDecodeNanoseconds: difference(audioDecodeNanoseconds, previous.audioDecodeNanoseconds),
            audioBuffers: difference(audioBuffers, previous.audioBuffers)
        )
    }

    func debugLine(interval: TimeInterval, filmGrain: String) -> String {
        let seconds = max(interval, 0.001)
        let millisecondsPerSecond: (UInt64) -> Double = {
            Double($0) / 1_000_000.0 / seconds
        }
        let perSecond: (UInt64) -> Double = { Double($0) / seconds }
        return String(
            format: "SWPERF vdec=%.1fms/s conv=%.1fms/s frames=%.1f vpkts=%.1f adec=%.1fms/s apkts=%.1f aout=%.1f grain=%@",
            millisecondsPerSecond(videoDecodeNanoseconds),
            millisecondsPerSecond(videoConversionNanoseconds),
            perSecond(videoFrames),
            perSecond(videoPacketCalls),
            millisecondsPerSecond(audioDecodeNanoseconds),
            perSecond(audioPacketCalls),
            perSecond(audioBuffers),
            filmGrain
        )
    }
}
