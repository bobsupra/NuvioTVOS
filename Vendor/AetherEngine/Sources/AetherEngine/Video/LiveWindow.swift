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

    /// Sodalite#104: how far the edge moved the last time it moved at all.
    ///
    /// The edge is a STEP function: it advances once per segment cut, by a whole segment duration.
    /// The playhead is continuous. So their difference sawtooths from one segment down to zero and
    /// back for as long as the session runs, and any question asked of that difference has to know
    /// the size of the step it is riding on. Zero until the first advance, which is not a step but
    /// the place the session starts.
    private(set) var lastEdgeStepSeconds: Double = 0

    /// Sodalite#104 round 4: the TARGETDURATION the live playlist declares, when one is served.
    ///
    /// This outranks `lastEdgeStepSeconds` wherever it exists, because the two answer different
    /// questions. The declared duration is how long a segment IS; the observed step is how the
    /// source happened to DELIVER, and a tuner or transcode route delivers in bursts. Judging the
    /// edge by the burst made the tolerance as wide as the burst: measured on a device, a viewer who
    /// had deliberately rewound was told they were at the live edge a few seconds later, when the
    /// next burst widened the window under them.
    private(set) var targetDurationSeconds: Double?

    mutating func noteTargetDuration(_ seconds: Double?) {
        guard let seconds, seconds > 0 else { return }
        targetDurationSeconds = seconds
    }

    /// Sodalite#104 round 2: how far behind the edge a session that IS keeping up actually plays.
    ///
    /// The software live path publishes the READER's frontier as the edge, and a client cannot sit on
    /// it: the media that moved it has not been decoded yet, and on a source that hands over in
    /// chunks the distance sawtooths by a whole chunk. Nothing on that path declares a
    /// TARGETDURATION, and `lastEdgeStepSeconds` is no answer either, because on a frontier the
    /// engine samples once per publish that step measures the PUBLISH RATE: it is however much media
    /// arrived since the last tick, so it dithers between a few hundredths of a second and a whole
    /// chunk, and the tolerance dithers with it. Measured on the harness against a loopback origin
    /// running 6 s ahead of the wall clock, driven through the software path: after a return-to-live
    /// the session's distance sawtoothed 1.38 to 2.63 s while the tolerance moved between 2.03 and
    /// 3.32 s, and the verdict flipped inside a forty-second run with the remote untouched.
    ///
    /// So the cadence is measured where it can be measured: the distances the session holds while the
    /// verdict already says it is at the edge. That gate is what keeps a deliberate rewind from
    /// teaching the tolerance patience, which is the trap round 4 fell into from the other side: a
    /// session 30 s back is not at the edge, so it contributes no samples at all.
    ///
    /// A robust MAXIMUM (second largest of twelve), because the tolerance has to cover the peak of
    /// the sawtooth rather than its average, and not a plain maximum, so one outsized tick cannot
    /// teach it a distance the source does not actually cost.
    private var trackingDistances: [Double] = []

    /// Twelve samples at one every half second of media is about six seconds of history, which spans
    /// the sawtooth of every delivery rhythm measured here.
    static let trackingSampleCount = 12
    /// Below this the answer is "no measurement", not a small one: the first ticks after a join are
    /// taken while the pipeline is still filling.
    static let trackingMinimumSamples = 4

    /// The distance this source costs a client that is keeping up, or nil while there is not enough
    /// of it to read.
    var trackingCadenceSeconds: Double? {
        guard trackingDistances.count >= Self.trackingMinimumSamples else { return nil }
        let sorted = trackingDistances.sorted()
        return sorted[sorted.count - 2]
    }

    mutating func noteEdge(_ t: Double) {
        let previous = edgeTime
        edgeTime = Swift.max(edgeTime, t)
        if previous > 0, edgeTime > previous { lastEdgeStepSeconds = edgeTime - previous }
    }
    mutating func notePlayhead(_ t: Double) { playhead = t }
    mutating func noteResidentFloor(_ t: Double?) { residentFloorSeconds = t }

    /// Slack for tick granularity, on top of whatever the cadence costs. On its own it was the whole
    /// tolerance, which is the Sodalite#104 defect: see `isAtEdge`.
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

    /// Sodalite#104: is the playhead as close to the edge as this stream lets a client be?
    ///
    /// Not a constant distance, because the quantity it is asked about is not a constant one.
    /// `behindLiveSeconds` sawtooths by a whole segment duration in every healthy session, so a 2.0 s
    /// tolerance sat under the peak and the flag toggled twice per cut: measured on the harness, an
    /// untouched 45 s session at 4 s segments flipped it 17 times, with `behind` running
    /// 3.10 -> 2.10 -> 1.10 -> 0.00 and starting over. A host drawing a LIVE badge and a
    /// "Return to Live" affordance from this flag therefore greyed out and offered to return from
    /// somewhere the viewer never went, and the affordance could not converge either: pressing it
    /// lands at the edge, and the next cut immediately puts a whole segment back between the two.
    ///
    /// Right after a cut, one segment behind the new edge is the closest a client can be, because the
    /// segment that just moved the edge has not been played yet. So the step is the distance, and the
    /// constant stays as slack for tick granularity on top of it. The step is the LAST one rather
    /// than a maximum, so an outsized jump (a rebase, a source resuming) widens the reading for the
    /// one cycle it describes and not for the rest of the session.
    var isWithinEdgeTolerance: Bool { behindLiveSeconds <= edgeToleranceSeconds }

    /// The verdict a host draws its LIVE badge and its Return to Live chip from: the test above with
    /// HYSTERESIS.
    ///
    /// Sodalite#104 round 2. The test is a threshold on a quantity that sawtooths by construction, so
    /// wherever the sawtooth happens to straddle the threshold the verdict alternates at the publish
    /// rate however well the tolerance is chosen: measured after a return-to-live on a 6 s-lead
    /// origin, a distance running 1.4 to 2.6 s against a 2.0 s tolerance flipped it inside a
    /// forty-second run with the remote untouched. A badge that says "you are live" and a focusable
    /// chip that changes the shape of the button row are not quantities to be dithered, so leaving
    /// the edge costs one more slack than entering it. Entering is a measurement of the same sawtooth
    /// the tolerance is drawn from; leaving is a statement to the viewer that they are no longer live.
    private(set) var isAtEdge = false

    /// Extra distance the verdict needs before it gives the edge up, on top of the tolerance.
    static let edgeExitSlack: Double = 2.0

    /// Settle the verdict for this publish, and take a cadence sample when the session is keeping up.
    ///
    /// - Parameter tracking: true when the playhead advanced by playback alone since the last settle
    ///   (the session playing, no seek in flight, and a rate-limited tick), which is the only state
    ///   whose distance describes what this source costs a client at the edge.
    mutating func settleEdgeVerdict(tracking: Bool) {
        let limit = isAtEdge ? edgeToleranceSeconds + Self.edgeExitSlack : edgeToleranceSeconds
        isAtEdge = behindLiveSeconds <= limit
        guard tracking, isAtEdge else { return }
        trackingDistances.append(behindLiveSeconds)
        if trackingDistances.count > Self.trackingSampleCount {
            trackingDistances.removeFirst(trackingDistances.count - Self.trackingSampleCount)
        }
    }

    /// Sodalite#104: one segment, plus the constant as slack for tick granularity.
    ///
    /// The segment comes from the playlist when one is served. Where none is (remote HLS live and the
    /// software live path declare nothing here) the measured distance of a session that is keeping up
    /// stands in for it, because on those paths the edge is a read frontier and the distance a client
    /// holds below it IS this source's cadence. The observed edge step is the last resort, and on the
    /// software path it is one packet, which is why it needed the term above it (round 2).
    var edgeToleranceSeconds: Double {
        Self.edgeTolerance + (targetDurationSeconds ?? trackingCadenceSeconds ?? lastEdgeStepSeconds)
    }
}
