// Sources/AetherEngine/Video/LiveWindow.swift
import Foundation

/// Session-relative DVR timeline in seconds since first decoded frame, monotonic. `windowSeconds == nil` = live-only (no rewind).
struct LiveWindow: Equatable {
    let windowSeconds: Double?
    private(set) var edgeTime: Double = 0
    private var playhead: Double = 0

    init(windowSeconds: Double?) { self.windowSeconds = windowSeconds }

    /// AE#441: the oldest position the segment cache actually holds and can play forward from, on the
    /// same session axis as `edgeTime`. nil where no cache can be asked (the software live path, and
    /// before the first segment is resident), which leaves the range exactly as it was.
    ///
    /// The window is a POLICY and this is the FACT, and they diverge for the whole first `window`
    /// seconds of every session: a three-minute-old session with a 1800 s window advertised thirty
    /// minutes of rewind, and a seek into the advertised-but-never-written region was accepted and
    /// silently clamped.
    private(set) var residentFloorSeconds: Double?

    mutating func noteEdge(_ t: Double) { edgeTime = Swift.max(edgeTime, t) }
    mutating func notePlayhead(_ t: Double) { playhead = t }
    mutating func noteResidentFloor(_ t: Double?) { residentFloorSeconds = t }

    static let edgeTolerance: Double = 2.0

    var seekableRange: ClosedRange<Double>? { seekableRange(edge: edgeTime) }

    /// AE#446 round 3: the same range against an edge sampled NOW rather than the running maximum
    /// `noteEdge` keeps. `edgeTime` folds every tick of the session into one number, and an item swap
    /// or a timeline rebase re-anchors the axis under it, so a caller holding a fresh sample of the
    /// item's own clock has a better edge than this window does. The monotonic maximum stays what the
    /// session PUBLISHES; it is not what a seek should be measured against.
    func seekableRange(edge: Double) -> ClosedRange<Double>? {
        guard let w = windowSeconds else { return nil }
        // The intersection of what the session is willing to keep and what it actually holds. The
        // clamp against the edge is not defensive dressing: a floor read from the cache while the
        // edge is still catching up can exceed it for a tick, and a reversed ClosedRange traps.
        let policy = Swift.max(0, edge - w)
        let honest = Swift.max(policy, residentFloorSeconds ?? 0)
        return Swift.min(honest, edge)...edge
    }
    func clamp(_ t: Double) -> Double { clamp(t, edge: edgeTime) }
    func clamp(_ t: Double, edge: Double) -> Double {
        guard let r = seekableRange(edge: edge) else { return edge }
        return Swift.min(Swift.max(t, r.lowerBound), r.upperBound)
    }
    var behindLiveSeconds: Double { Swift.max(0, edgeTime - playhead) }
    var isAtEdge: Bool { behindLiveSeconds <= Self.edgeTolerance }
}
