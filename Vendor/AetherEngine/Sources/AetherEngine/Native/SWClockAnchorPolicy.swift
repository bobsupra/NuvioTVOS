import Foundation

/// Where the SW demux loop anchors the synchronizer clock when the first decoded
/// sample arrives (#107).
///
/// Normal files and resumes deliver their first sample at (or within head-of-stream
/// offset of) the load-time anchor, so the anchor is kept verbatim and intrinsic
/// A/V lead-in offsets survive untouched. A mid-stream-joined source (live tuner
/// MPEG-TS opened without `isLive`, live without a DVR ring, or a capture file cut
/// mid-broadcast) delivers first samples hours past the anchor; anchoring at the
/// sample PTS is the only way they ever present. `sessionZeroSeconds` is the offset
/// the host subtracts from the raw synchronizer clock so the published position
/// stays session-relative; the raw clock itself remains the source/subtitle axis.
enum SWClockAnchorPolicy {
    /// Tolerance below which the first sample is considered aligned with the load
    /// anchor. Head-of-stream offsets are a few hundred ms; mid-stream joins are
    /// minutes to hours. Seconds.
    static let toleranceSeconds: Double = 2.0

    struct Resolution: Equatable {
        let anchorSeconds: Double
        let sessionZeroSeconds: Double
    }

    static func resolve(initialSeconds: Double,
                        firstSampleSeconds: Double,
                        toleranceSeconds: Double = SWClockAnchorPolicy.toleranceSeconds) -> Resolution {
        guard firstSampleSeconds.isFinite,
              abs(firstSampleSeconds - initialSeconds) > toleranceSeconds else {
            return Resolution(anchorSeconds: initialSeconds, sessionZeroSeconds: 0)
        }
        return Resolution(anchorSeconds: firstSampleSeconds,
                          sessionZeroSeconds: max(0, firstSampleSeconds - initialSeconds))
    }

    /// Whether a video packet parked on renderer back-pressure has to anchor the clock itself
    /// (#337).
    ///
    /// Both feed loops gate video on `renderer.isReadyForMoreMediaData`, and the renderer only
    /// drains while the synchronizer clock runs, so a park entered with an unarmed clock cannot
    /// end on its own: the combined demux loop is the single reader, and every packet that could
    /// arm the clock is behind the park; the live feeder has a second reader, but once its
    /// look-ahead pump has spent its pre-arm budget nothing else will deliver a first buffer
    /// either. The cycle closes whenever the selected audio stream's first packet lies past the
    /// renderer's fill point (a track grouped late in the mux, or one the host switched to at
    /// start-from-zero), and the session then publishes `.playing` at a frozen clock until a seek
    /// arms it by hand. Anchoring on the video the renderer is already holding is the only exit
    /// that needs nothing from the host.
    static func shouldArmFromParkedVideo(clockArmed: Bool,
                                         isPlaying: Bool,
                                         rendererReadyForMoreData: Bool,
                                         audioArmingStillPossible: Bool) -> Bool {
        guard !clockArmed, isPlaying, !rendererReadyForMoreData else { return false }
        return !audioArmingStillPossible
    }
}
