import Foundation

/// Piecewise-constant map between the two time axes the native path runs on (#260).
///
/// - **source axis**: the PTS libavformat demuxes out of the file. Subtitle cues, chapter marks,
///   A/53 captions and `AetherEngine.sourceTime` all live here.
/// - **item axis**: what the producer muxes into the fMP4 segments, and therefore what
///   `AVPlayerItem.currentTime()` and its timebase read.
///
/// The two differ by the producer's shift (`videoShiftPts` = `firstActualVideoDts -
/// desiredFirstVideoTfdtPts`): `source = item + shift`. The shift is constant inside one producer
/// epoch and changes at an epoch edge (a VOD restart lands wherever the source seek lands, a live
/// program boundary rebases mid-producer), so the relation is a step function of item time, not one
/// scalar. A single scalar is only correct until the next edge, because AVPlayer keeps presenting
/// frames muxed under the previous shift for as long as its buffer holds them.
///
/// Seams are ordered ascending by `itemSeconds`; the newest seam at or before a position wins. The
/// oldest seam is anchored at `-.infinity` so every position at or above the map's origin resolves.
/// Positions below it (only reachable once the history cap has trimmed the anchor away, which the
/// builder prevents) and an empty map return nil: no axis has been established, and guessing a shift
/// of 0 is exactly the convention-instead-of-a-value mistake that #259 cost.
public struct PresentationAxisMap: Sendable, Equatable {

    /// One epoch edge: from `itemSeconds` onward (item axis), `source = item + shiftSeconds`.
    public struct Seam: Sendable, Equatable {
        /// Item-axis position from which this shift applies. `-.infinity` for the anchor.
        public let itemSeconds: Double
        /// `source - item` for every frame muxed in this epoch.
        public let shiftSeconds: Double

        public init(itemSeconds: Double, shiftSeconds: Double) {
            self.itemSeconds = itemSeconds
            self.shiftSeconds = shiftSeconds
        }
    }

    /// Ascending by `itemSeconds`.
    public private(set) var seams: [Seam]

    /// Bounded history. Losing the oldest entries only costs fidelity for positions many epoch edges
    /// back; the trim re-anchors the new oldest at `-.infinity` so lookups never fall off the bottom.
    public static let maxSeams = 64

    public init(seams: [Seam] = []) {
        self.seams = seams
    }

    public var isEmpty: Bool { seams.isEmpty }

    /// `source - item` in effect at an item-axis position. nil when no epoch covers it.
    public func shiftSeconds(atItemSeconds seconds: Double) -> Double? {
        seams.last(where: { seconds >= $0.itemSeconds })?.shiftSeconds
    }

    /// Source PTS of an item-axis position (an `AVPlayerItem` clock reading, a timebase sample).
    public func sourceSeconds(forItemSeconds seconds: Double) -> Double? {
        shiftSeconds(atItemSeconds: seconds).map { seconds + $0 }
    }

    /// Item-axis position of a source PTS (a subtitle cue time, a chapter mark). Resolves the epoch
    /// by testing each seam against the value it would produce, so the answer stays on the same side
    /// of an edge as `sourceSeconds(forItemSeconds:)`.
    public func itemSeconds(forSourceSeconds seconds: Double) -> Double? {
        seams.last(where: { seconds - $0.shiftSeconds >= $0.itemSeconds })
            .map { seconds - $0.shiftSeconds }
    }

    // MARK: - Building

    /// Drop the whole history and start over from one shift that covers everything. The correct move
    /// when nothing muxed under an older shift can still be on screen: a fresh load, or a live retune
    /// whose old program AVPlayer will never show again.
    public static func anchored(shiftSeconds: Double) -> PresentationAxisMap {
        PresentationAxisMap(seams: [Seam(itemSeconds: -.infinity, shiftSeconds: shiftSeconds)])
    }

    /// Record an epoch edge: from `itemSeconds` on, the muxed bytes carry `shiftSeconds`.
    ///
    /// Seams at or after the edge are dropped, because a producer that starts writing at
    /// `itemSeconds` rewrites everything from there forward (a backward seek makes the old future
    /// unreachable, and its recorded shift wrong). Everything before the edge is kept: those bytes
    /// are already in AVPlayer's buffer on the old axis and stay valid until they are evicted.
    public mutating func appendSeam(shiftSeconds: Double, activatingAtItemSeconds itemSeconds: Double) {
        seams.removeAll(where: { $0.itemSeconds >= itemSeconds })
        seams.append(
            Seam(itemSeconds: seams.isEmpty ? -.infinity : itemSeconds, shiftSeconds: shiftSeconds)
        )
        if seams.count > Self.maxSeams {
            seams.removeFirst(seams.count - Self.maxSeams)
            seams[0] = Seam(itemSeconds: -.infinity, shiftSeconds: seams[0].shiftSeconds)
        }
    }
}

/// Thread-safe mirror so an off-main consumer (a host rendering subtitles on its own thread, the
/// producer pump) can read the axis map the engine maintains on the main actor.
final class AtomicPresentationAxisMap: @unchecked Sendable {
    private let lock = NSLock()
    private var value: PresentationAxisMap
    init(_ initial: PresentationAxisMap = PresentationAxisMap()) { value = initial }
    func get() -> PresentationAxisMap { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ newValue: PresentationAxisMap) { lock.lock(); value = newValue; lock.unlock() }
}
