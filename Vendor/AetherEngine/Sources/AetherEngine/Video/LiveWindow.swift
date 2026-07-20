// Sources/AetherEngine/Video/LiveWindow.swift
import Foundation

/// Session-relative DVR timeline in seconds since first decoded frame, monotonic. `windowSeconds == nil` = live-only (no rewind).
struct LiveWindow: Equatable {
    let windowSeconds: Double?
    private(set) var edgeTime: Double = 0
    private var playhead: Double = 0

    init(windowSeconds: Double?) { self.windowSeconds = windowSeconds }

    mutating func noteEdge(_ t: Double) { edgeTime = Swift.max(edgeTime, t) }
    mutating func notePlayhead(_ t: Double) { playhead = t }

    static let edgeTolerance: Double = 2.0

    var seekableRange: ClosedRange<Double>? {
        guard let w = windowSeconds else { return nil }
        return Swift.max(0, edgeTime - w)...edgeTime
    }
    func clamp(_ t: Double) -> Double {
        guard let r = seekableRange else { return edgeTime }
        return Swift.min(Swift.max(t, r.lowerBound), r.upperBound)
    }
    var behindLiveSeconds: Double { Swift.max(0, edgeTime - playhead) }
    var isAtEdge: Bool { behindLiveSeconds <= Self.edgeTolerance }
}
