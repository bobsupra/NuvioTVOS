import Accelerate
import Foundation

// Sync by Audio: when no embedded subtitles can be the reference, the add-on
// subtitle is lined up with where people speak in the soundtrack. The playing audio (AetherEngine's
// audio tap) becomes a speech level 50 times a second; every so often the subtitle lines are slid
// along the last two and a half minutes of it to find where their starts and ends meet speech
// best, and the subtitle delay follows, so a shift that changes partway (another cut, a recap,
// an ad break) is followed too.

enum AudioSubtitleSync {
    /// Speech levels per second (20 ms frames).
    static let framesPerSecond = 50
    /// The furthest a subtitle is looked for either way (seconds).
    static let maxShift = 45.0
    /// The most the subtitle delay takes (`PlayerViewModel.setSubtitleDelayMs`).
    static let maxDelay = 30.0
    /// The audio one estimate looks at: this much before the playhead and after it (the tap runs
    /// up to about 12 s ahead).
    static let windowBefore = 135.0
    static let windowAfter = 15.0
    /// Audio in the window needed for an estimate (seconds).
    static let minHeard = 40.0
    /// Seconds between estimates, once following and while still unsure.
    static let followEvery = 15.0
    static let searchEvery = 5.0
    /// A change waits at most this long for a moment without a line on screen.
    static let maxGapWait = 6.0

    /// The dialogue lines (songs and signs left out), overlapping ones merged.
    static func intervals(of cues: [SubtitleTimingCue]) -> [ClosedRange<Double>] {
        merged(SubtitleSyncParts.Target(cues).lines.map { $0.start...max($0.start, $0.end) })
    }

    /// Every line as it is shown, for finding a moment without one.
    static func shown(_ cues: [SubtitleTimingCue]) -> [ClosedRange<Double>] {
        merged(cues.map { $0.start...max($0.start, $0.end) })
    }

    static func merged(_ ranges: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
        var out: [ClosedRange<Double>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = out.last, range.lowerBound <= last.upperBound + 0.05 {
                out[out.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                out.append(range)
            }
        }
        return out
    }

    // MARK: Estimate

    /// Where the lines meet speech best in `levels` (dB per frame, NaN where nothing was heard),
    /// the first of which is frame `firstFrame` of the source. Lines are in the subtitle's own time.
    static func estimate(
        levels: [Float],
        firstFrame: Int,
        lines: [ClosedRange<Double>],
        maxShift: Double = maxShift
    ) -> AudioSyncEstimate? {
        let fps = Double(framesPerSecond)
        let count = levels.count
        let shiftFrames = Int(maxShift * fps)
        guard count >= framesPerSecond * 20, !lines.isEmpty,
              let speech = speechScores(levels) else { return nil }
        let scores = speech.scores, heard = speech.heard
        let heardCount = heard.reduce(0) { $0 + ($1 ? 1 : 0) }
        guard heardCount >= framesPerSecond * 20 else { return nil }

        // The speech level against the last few seconds' (so a line's start and end count, not
        // whether a stretch is talky), and where speech sets in.
        let wide = movingAverage(scores, half: 100)
        var level = [Float](repeating: 0, count: count)
        for i in 0..<count where heard[i] { level[i] = scores[i] - wide[i] }
        let soft = movingAverage(scores, half: 2)
        var onset = [Float](repeating: 0, count: count)
        var onsetSum: Float = 0
        for i in 1..<count where heard[i] {
            onset[i] = max(soft[i] - soft[i - 1], 0)
            onsetSum += onset[i]
        }
        let onsetMean = onsetSum / Float(heardCount)
        for i in 0..<count where heard[i] { onset[i] -= onsetMean }

        // The lines over the window and as far as they may be shifted either way.
        let extent = count + 2 * shiftFrames
        let origin = firstFrame - shiftFrames
        var mask = [Float](repeating: 0, count: extent)
        var starts = [Float](repeating: 0, count: extent)
        for line in lines {
            let a = Int((line.lowerBound * fps).rounded()) - origin
            let b = Int((line.upperBound * fps).rounded()) - origin
            guard b >= 0, a < extent else { continue }
            let lo = max(a, 0), hi = min(b, extent)
            if lo < hi { for j in lo..<hi { mask[j] = 1 } }
            if a >= 0 { starts[a] = 1 }
        }
        guard mask.contains(1) else { return nil }
        let maskWide = movingAverage(mask, half: 100)
        var lineLevel = [Float](repeating: 0, count: extent)
        for j in 0..<extent { lineLevel[j] = mask[j] - maskWide[j] }
        var lineStart = movingAverage(starts, half: 5).map { $0 * 10 }
        let startMean = lineStart.reduce(0, +) / Float(extent)
        for j in 0..<extent { lineStart[j] -= startMean }

        let span = Float(count) / Float(extent)
        let levelNorm = (sumOfSquares(level) * sumOfSquares(lineLevel) * span).squareRoot()
        let onsetNorm = (sumOfSquares(onset) * sumOfSquares(lineStart) * span).squareRoot()
        guard levelNorm > 0, onsetNorm > 0 else { return nil }

        // Each half of the window on its own, then both: a real match shows in both halves.
        let shifts = 2 * shiftFrames + 1
        let half = count / 2
        func fit(from lo: Int, to hi: Int) -> [Float] {
            let a = correlate(lineLevel, level, from: lo, to: hi, shifts: shifts)
            let b = correlate(lineStart, onset, from: lo, to: hi, shifts: shifts)
            return zip(a, b).map { $0 / levelNorm + $1 / onsetNorm }
        }
        let first = fit(from: 0, to: half)
        let second = fit(from: half, to: count)
        let both = zip(first, second).map { $0 + $1 }

        func shift(at peak: (index: Int, offset: Double)) -> Double {
            (Double(shiftFrames) - (Double(peak.index) + peak.offset)) / fps
        }
        let best = peakOf(both)
        let bestShift = shift(at: best)
        let top = both[best.index]
        guard top > 0 else { return nil }
        let apart = framesPerSecond
        var rivalTop = -Float.infinity
        for k in 0..<shifts where abs(k - best.index) > apart { rivalTop = max(rivalTop, both[k]) }
        let sorted = both.sorted()
        let median = sorted[sorted.count / 2]
        let deviations = both.map { abs($0 - median) }.sorted()
        let spread = Double(deviations[deviations.count / 2]) * 1.4826
        let standout = spread > 0 ? Double(top - median) / spread : 0
        let halvesApart = max(abs(shift(at: peakOf(first)) - bestShift), abs(shift(at: peakOf(second)) - bestShift))

        let windowStart = Double(firstFrame) / fps
        let windowEnd = Double(firstFrame + count) / fps
        let linesInWindow = lines.filter { $0.lowerBound + bestShift < windowEnd && $0.upperBound + bestShift > windowStart }.count
        let speaking = zip(scores, heard).filter { $1 && $0 >= 0.5 }.count

        return AudioSyncEstimate(
            shift: bestShift,
            standout: standout,
            rival: rivalTop.isFinite ? Double(rivalTop / top) : 0,
            halvesApart: halvesApart,
            lines: linesInWindow,
            heard: Double(heardCount) / fps,
            speech: Double(speaking) / Double(heardCount))
    }

    /// 0…1 per frame: how far above the quiet of its surroundings the speech band is.
    static func speechScores(_ levels: [Float]) -> (scores: [Float], heard: [Bool])? {
        let block = 500
        var centers: [Double] = []
        var floors: [Float] = []
        var start = 0
        while start < levels.count {
            let end = min(start + block, levels.count)
            let heard = levels[start..<end].filter { !$0.isNaN }.sorted()
            if heard.count >= 100 {
                floors.append(heard[Int(Double(heard.count - 1) * 0.2)])
                centers.append(Double(start + end) / 2)
            }
            start = end
        }
        guard !floors.isEmpty else { return nil }
        var scores = [Float](repeating: 0, count: levels.count)
        var heard = [Bool](repeating: false, count: levels.count)
        var j = 0
        for i in levels.indices where !levels[i].isNaN {
            let x = Double(i)
            while j + 1 < centers.count, centers[j + 1] <= x { j += 1 }
            let floor: Float
            if x <= centers[0] {
                floor = floors[0]
            } else if j + 1 >= centers.count {
                floor = floors[floors.count - 1]
            } else {
                let t = Float((x - centers[j]) / (centers[j + 1] - centers[j]))
                floor = floors[j] + (floors[j + 1] - floors[j]) * t
            }
            scores[i] = min(max((levels[i] - floor - 3) / 12, 0), 1)
            heard[i] = true
        }
        return (scores, heard)
    }

    /// The mean of each value and the `half` on either side (fewer at the ends).
    static func movingAverage(_ values: [Float], half: Int) -> [Float] {
        guard !values.isEmpty else { return [] }
        var sums = [Double](repeating: 0, count: values.count + 1)
        for i in values.indices { sums[i + 1] = sums[i] + Double(values[i]) }
        return values.indices.map { i in
            let lo = max(i - half, 0), hi = min(i + half + 1, values.count)
            return Float((sums[hi] - sums[lo]) / Double(hi - lo))
        }
    }

    /// `out[k]` = Σ over t in lo..<hi of `lines[k + t] · audio[t]`.
    static func correlate(_ lines: [Float], _ audio: [Float], from lo: Int, to hi: Int, shifts: Int) -> [Float] {
        var out = [Float](repeating: 0, count: shifts)
        guard hi > lo, lines.count >= hi + shifts - 1 else { return out }
        lines.withUnsafeBufferPointer { l in
            audio.withUnsafeBufferPointer { a in
                out.withUnsafeMutableBufferPointer { o in
                    vDSP_conv(l.baseAddress! + lo, 1, a.baseAddress! + lo, 1,
                              o.baseAddress!, 1, vDSP_Length(shifts), vDSP_Length(hi - lo))
                }
            }
        }
        return out
    }

    /// The highest value and where between its neighbours the true top lies (−0.5…0.5).
    static func peakOf(_ values: [Float]) -> (index: Int, offset: Double) {
        var index = 0
        for k in values.indices where values[k] > values[index] { index = k }
        var offset = 0.0
        if index > 0, index < values.count - 1 {
            let l = Double(values[index - 1]), c = Double(values[index]), r = Double(values[index + 1])
            let curve = l - 2 * c + r
            if curve < 0 { offset = min(max(0.5 * (l - r) / curve, -0.5), 0.5) }
        }
        return (index, offset)
    }

    private static func sumOfSquares(_ values: [Float]) -> Float {
        values.reduce(0) { $0 + $1 * $1 }
    }
}

/// One look at the window: how far to shift the subtitle, and how sure that is.
struct AudioSyncEstimate: Equatable, Sendable {
    /// Seconds to show the subtitle later (the subtitle delay that lines it up).
    var shift: Double
    /// How far the best fit stands above the rest (a robust z-score).
    var standout: Double
    /// The best fit more than a second away, against the best (1 = as good).
    var rival: Double
    /// How far the best fits of the window's two halves are from the whole's (seconds).
    var halvesApart: Double
    /// Subtitle lines in the window.
    var lines: Int
    /// Seconds of audio in the window, and the share of it that sounded like speech.
    var heard: Double
    var speech: Double

    static let minStandout = 4.0
    static let maxRival = 0.9
    static let maxHalvesApart = 0.3
    static let minLines = 8

    var isSure: Bool { doubt == nil }

    /// Why it isn't sure.
    var doubt: String? {
        if lines < Self.minLines { return "only \(lines) lines here" }
        if halvesApart > Self.maxHalvesApart { return String(format: "halves %.1f s apart", halvesApart) }
        if standout < Self.minStandout { return String(format: "standout %.1f < %.0f", standout, Self.minStandout) }
        if rival > Self.maxRival { return String(format: "a rival fit at %.2f", rival) }
        return nil
    }
}

/// Band energy (300–3400 Hz, where speech is) of the playing audio in 20 ms frames, numbered from
/// the start of the source (frame f covers f/50 ..< (f+1)/50 s).
struct SpeechLevelMeter {
    struct Biquad {
        var b0: Float, b1: Float, b2: Float, a1: Float, a2: Float
        var z1: Float = 0, z2: Float = 0

        mutating func process(_ x: Float) -> Float {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }

        mutating func reset() {
            z1 = 0
            z2 = 0
        }

        static func highPass(_ frequency: Double, rate: Double) -> Biquad {
            let w = 2 * Double.pi * frequency / rate, c = cos(w), alpha = sin(w) / (2 * 0.7071)
            let a0 = 1 + alpha
            return Biquad(b0: Float((1 + c) / 2 / a0), b1: Float(-(1 + c) / a0), b2: Float((1 + c) / 2 / a0),
                          a1: Float(-2 * c / a0), a2: Float((1 - alpha) / a0))
        }

        static func lowPass(_ frequency: Double, rate: Double) -> Biquad {
            let w = 2 * Double.pi * frequency / rate, c = cos(w), alpha = sin(w) / (2 * 0.7071)
            let a0 = 1 + alpha
            return Biquad(b0: Float((1 - c) / 2 / a0), b1: Float((1 - c) / a0), b2: Float((1 - c) / 2 / a0),
                          a1: Float(-2 * c / a0), a2: Float((1 - alpha) / a0))
        }
    }

    let sampleRate: Double
    let frameLength: Int
    private var highPass: Biquad
    private var lowPass: Biquad
    private var frame: Int?
    private var sum: Double = 0
    private var count = 0
    private var nextSample: Int64?

    init(sampleRate: Double = 48_000) {
        self.sampleRate = sampleRate
        frameLength = max(Int(sampleRate) / AudioSubtitleSync.framesPerSecond, 1)
        highPass = .highPass(300, rate: sampleRate)
        lowPass = .lowPass(3400, rate: sampleRate)
    }

    /// Adds samples whose first plays at `time` (source seconds); returns the frames finished.
    mutating func add(_ samples: UnsafeBufferPointer<Float>, at time: Double, discontinuity: Bool) -> [(frame: Int, level: Float)] {
        guard time.isFinite, time >= 0, !samples.isEmpty else { return [] }
        var first = Int64((time * sampleRate).rounded())
        if discontinuity || nextSample.map({ abs($0 - first) > Int64(sampleRate * 0.05) }) ?? true {
            highPass.reset()
            lowPass.reset()
            frame = nil
            sum = 0
            count = 0
        } else if let nextSample {
            first = nextSample
        }
        var finished: [(frame: Int, level: Float)] = []
        let length = Int64(frameLength)
        for i in 0..<samples.count {
            let index = Int((first + Int64(i)) / length)
            if index != frame {
                if let done = flush() { finished.append(done) }
                frame = index
            }
            let band = highPass.process(samples[i])
            let y = lowPass.process(band)
            sum += Double(y * y)
            count += 1
        }
        nextSample = first + Int64(samples.count)
        // A frame that is complete now needn't wait for the next buffer.
        if count >= frameLength, let done = flush() {
            finished.append(done)
            frame = nil
        }
        return finished
    }

    private mutating func flush() -> (frame: Int, level: Float)? {
        defer {
            sum = 0
            count = 0
        }
        guard let frame, count >= frameLength / 2 else { return nil }
        return (frame, Float(10 * log10(sum / Double(count) + 1e-10)))
    }
}

/// The speech levels heard so far, by frame (NaN where nothing was heard).
struct SpeechLevelTimeline {
    static let blockSize = 500
    private var blocks: [Int: [Float]] = [:]
    private(set) var heardFrames = 0

    mutating func set(_ level: Float, at frame: Int) {
        guard frame >= 0 else { return }
        let block = frame / Self.blockSize, slot = frame % Self.blockSize
        if blocks[block] == nil { blocks[block] = [Float](repeating: .nan, count: Self.blockSize) }
        if blocks[block]![slot].isNaN { heardFrames += 1 }
        blocks[block]![slot] = level
    }

    func levels(from first: Int, count: Int) -> [Float] {
        guard count > 0 else { return [] }
        return (first..<(first + count)).map { frame in
            guard frame >= 0, let block = blocks[frame / Self.blockSize] else { return .nan }
            return block[frame % Self.blockSize]
        }
    }
}

/// When the delay changes: the first sure estimate is taken as it is; after that a different
/// one has to come twice (and be more than `changeAbove` away) before the delay follows it.
struct AudioShiftTracker: Equatable {
    static let changeAbove = 0.3
    static let agreeWithin = 0.2

    enum Step: Equatable {
        case apply(Double)
        /// Not sure, or a change seen once.
        case hold
        /// The applied shift still fits.
        case keep
    }

    private(set) var applied: Double?
    private(set) var candidate: Double?

    mutating func take(_ estimate: AudioSyncEstimate) -> Step {
        guard estimate.isSure else { return .hold }
        guard let applied else { return .apply(estimate.shift) }
        if abs(estimate.shift - applied) <= Self.changeAbove {
            candidate = nil
            return .keep
        }
        if let candidate, abs(estimate.shift - candidate) <= Self.agreeWithin {
            self.candidate = nil
            return .apply((estimate.shift + candidate) / 2)
        }
        candidate = estimate.shift
        return .hold
    }

    mutating func didApply(_ shift: Double) {
        applied = shift
        candidate = nil
    }
}

enum AudioSyncGap {
    /// Whether the delay can change at `time` without a line jumping: none is on screen with the
    /// old delay or the new one, and none is due within `lead`.
    static func isClear(at time: Double, shown: [ClosedRange<Double>], from old: Double, to new: Double, lead: Double = 0.4) -> Bool {
        for delay in [old, new] {
            for line in shown where line.lowerBound + delay <= time + lead && line.upperBound + delay >= time {
                return false
            }
        }
        return true
    }
}
