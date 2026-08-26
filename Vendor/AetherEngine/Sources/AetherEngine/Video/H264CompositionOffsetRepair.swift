import Foundation
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil

/// #409: some MP4 writers drop the `ctts` table while keeping a bitstream that reorders pictures.
/// Every sample then reports `PTS == DTS`, so the container hands decode order out as presentation
/// order. Nothing downstream can recover from that on its own: stream-copying those timestamps into
/// fMP4 makes AVPlayer show each future reference picture before the B pictures it precedes, and a
/// software decode has the same axis on its frames. Measured on a 66-frame twin pair (identical
/// bitstream, `ctts` removed from one), 45 of 66 pictures were presented at a time belonging to a
/// different picture and the content order stepped backwards 30 times.
///
/// The information the container lost is still in the bitstream: each slice header carries a picture
/// order count, which is display order. libavcodec's H.264 *parser* reads it without decoding
/// anything (`output_picture_number`), and it reads MP4's length-prefixed AVCC packets directly, so
/// the repair costs one slice-header parse per video packet and no pixels.
///
/// The rewrite reproduces what the muxer should have written:
///
///     PTS = (DTS of the picture that opened this coded video sequence) + shift + displayIndex * step
///     DTS = DTS + shift - videoDelay * step
///
/// Both forms are expressed relative to the packet's own timestamps, never to a counter, so a demuxer
/// that starts mid-file (a resume seek) and one that starts at byte 0 produce the same axis for the
/// same picture. Pulling DTS back by the decode lead is what keeps `PTS >= DTS`, the invariant the
/// fMP4 muxer and its output sanitizer enforce; a healthy file carries exactly the same negative head
/// (the twin's first packet is `pts=0 dts=-2002`), so this is the shape the pipeline already handles.
///
/// A picture is not always a whole number of ticks long, and then no `step` describes the ladder: the
/// sample table has to alternate between the two neighbouring tick counts, and the file's second
/// report against this issue was exactly that (`200202/5` ticks at a 1200000 timescale). Such a ladder
/// carries something a uniform one cannot, its rounding pattern, which is the phase of the lattice it
/// was quantized from. Reading that phase turns `displayIndex * step` into a place on the lattice and
/// the arithmetic above into its whole-tick special case. The one thing the ladder cannot say is how
/// far it runs ahead of presentation, so that still comes from the container header.
///
/// Verified against four fixture pairs (498 packets, both edit-list shapes, both whole and fractional
/// cadences, 10 IDR boundaries): every repaired packet matches its healthy twin's PTS and DTS exactly.
enum H264CompositionOffsetRepair {

    /// One sampled picture. Deliberately values only, so the decision is testable without FFmpeg.
    struct Sample: Equatable, Sendable {
        var dts: Int64
        var pts: Int64
        var pictureOrderCount: Int64
        var isKeyframe: Bool
    }

    /// A frame cadence that is constant but does not land on a whole number of ticks. #409's second
    /// asset is one: at `time_base=1/1200000` its pictures are `200202/5` ticks apart, so the sample
    /// table can only alternate between 40040 and 40041 in a five-picture cycle. Nothing about the
    /// defect changes, only the ladder the repair has to read.
    struct Cadence: Equatable, Sendable {
        let numerator: Int64
        let denominator: Int64

        init?(numerator: Int64, denominator: Int64) {
            guard numerator > 0, denominator > 0 else { return nil }
            let divisor = H264CompositionOffsetRepair.greatestCommonDivisor(numerator, denominator)
            self.numerator = numerator / divisor
            self.denominator = denominator / divisor
        }

        /// Whole ticks per picture, rounded down.
        var wholeTicks: Int64 { numerator / denominator }

        /// Where the picture with this ordinal sits, relative to ordinal zero. Ties round away from
        /// zero, which is how FFmpeg rescales, so the lattice reproduces what a healthy muxer wrote
        /// for the same source rather than something a half tick beside it.
        func timestamp(at ordinal: Int64) -> Int64? {
            Self.roundedQuotient(ordinal, times: numerator, dividedBy: denominator)
        }

        /// The inverse, and it is exact for every point the lattice produced: a lattice value is at
        /// most half a tick away from the real product, so dividing it by a cadence of two ticks or
        /// more can never reach the neighbouring ordinal. Cadences below that are refused for this
        /// reason, not for a lack of precision in the multiply.
        func ordinal(at timestamp: Int64) -> Int64? {
            Self.roundedQuotient(timestamp, times: denominator, dividedBy: numerator)
        }

        /// `round(value * factor / divisor)` at full width, so a long timeline cannot overflow the
        /// intermediate product and land the repair on a wrapped timestamp.
        private static func roundedQuotient(_ value: Int64, times factor: Int64, dividedBy divisor: Int64) -> Int64? {
            guard value != Int64.min, factor > 0, divisor > 0 else { return nil }
            let negative = value < 0
            let magnitude = UInt64(negative ? -value : value)
            let product = magnitude.multipliedFullWidth(by: UInt64(factor))
            guard product.high < UInt64(divisor) else { return nil }
            let division = UInt64(divisor).dividingFullWidth(product)
            var quotient = division.quotient
            if division.remainder * 2 >= UInt64(divisor) {
                let (rounded, overflow) = quotient.addingReportingOverflow(1)
                guard !overflow else { return nil }
                quotient = rounded
            }
            guard quotient <= UInt64(Int64.max) else { return nil }
            return negative ? -Int64(quotient) : Int64(quotient)
        }
    }

    /// What the rewrite needs, all of it derived once at the head of the session.
    struct Plan: Equatable, Sendable {
        /// Ticks between two consecutive pictures in decode order.
        var step: Int64
        /// `videoDelay * step`: how far DTS runs ahead of presentation in a well-formed file.
        var decodeLead: Int64
        /// Ticks between the sampled DTS ladder and the presentation timeline. 0 when the broken
        /// writer left the ladder on the presentation axis; `decodeLead` when it kept the edit list
        /// that trims the reorder head (both shapes occur, see `presentationShift`).
        var shift: Int64
        /// Ticks a picture order count advances per displayed picture. 2 for frame coding, but
        /// measured rather than assumed.
        var pocStep: Int64
        /// Set only when the ladder is a quantization of a fractional cadence. `step` then carries
        /// the rounded cadence and still describes the stream to within a tick, which is what the
        /// arithmetic falls back to; the lattice is what reproduces the muxer exactly.
        var cadence: Cadence?
        /// Where lattice ordinal 0 sits on this timeline, and which lattice ordinal the first
        /// sampled picture sits on. A whole-tick ladder has no phase to speak of; a quantized one
        /// does, and its rounding pattern is the only place that phase is written down. It is not
        /// implied by anything else: the reporting asset for this case sits on phase 2 while its
        /// reorder delay is 1.
        var latticeOrigin: Int64 = 0
        var ladderPhase: Int64 = 0
        /// How many ordinals the decode ladder runs ahead of presentation: 0 when the writer left the
        /// ladder on the presentation axis, `videoDelay` when it kept the edit list that trims the
        /// reorder head, and the values between when it trims part of one. The ladder cannot say
        /// which, so this is read from the container the same way `shift` is.
        var ladderOrdinalOffset: Int64 = 0

        /// The timestamp of a presentation ordinal, nil unless this plan carries a lattice.
        func presentationTimestamp(ordinal: Int64) -> Int64? {
            guard let cadence else { return nil }
            let (phased, phaseOverflow) = ordinal.addingReportingOverflow(ladderPhase)
            let (placed, placeOverflow) = phased.addingReportingOverflow(ladderOrdinalOffset)
            guard !phaseOverflow, !placeOverflow, let offset = cadence.timestamp(at: placed) else {
                return nil
            }
            let (timestamp, overflow) = latticeOrigin.addingReportingOverflow(offset)
            return overflow ? nil : timestamp
        }

        /// Reads a ladder timestamp back into the presentation ordinal of the picture it belongs to.
        /// nil when the timestamp is not on the lattice, which is deliberate: a ladder that drifted
        /// off its own cadence must fall back to the scalar anchor instead of being placed a whole
        /// picture away from where it belongs.
        func presentationOrdinal(ladderTimestamp: Int64) -> Int64? {
            guard let cadence else { return nil }
            let (offset, offsetOverflow) = ladderTimestamp.subtractingReportingOverflow(latticeOrigin)
            guard !offsetOverflow, let ordinal = cadence.ordinal(at: offset),
                  cadence.timestamp(at: ordinal) == offset else { return nil }
            let (presentation, overflow) = ordinal.subtractingReportingOverflow(ladderPhase)
            return overflow ? nil : presentation
        }
    }

    enum Verdict: Equatable, Sendable {
        /// The container carries composition offsets: nothing to repair, and the cheapest, most
        /// common outcome (one packet decides it for a healthy reordered file).
        case healthy
        /// Not this defect, or not enough evidence to act. Never repairs.
        case inconclusive(String)
        case repair(Plan)
    }

    /// Video packets to sample before deciding. A healthy file leaves after the first packet that
    /// shows an offset; only the broken shape pays the full window, which has to span at least one
    /// mini-GOP for the picture order to prove reordering at all.
    static let sampleTarget = 12
    /// Below this the ladder and the reorder evidence are too thin to trust; sampling stops early
    /// only on a healthy verdict or EOF.
    static let minimumSamples = 9
    /// Held-packet ceiling while sampling. A UHD intra head could otherwise park tens of megabytes
    /// waiting for a verdict that a broken file reaches in twelve packets.
    static let sampleByteBudget = 8 << 20
    /// Packets of any kind the sample may hold. A demuxer whose video stream is discarded (the
    /// subtitle side reader does exactly that) would otherwise never reach its video quota and hold
    /// the whole interleave waiting for pictures that are not coming.
    static let heldPacketCeiling = 96

    /// The presentation axis a repaired stream lands on.
    ///
    /// Two writers produce this defect and they differ by one decode lead. One drops `ctts` and
    /// leaves the sample ladder where presentation starts (first reported DTS 0); the other keeps
    /// the edit list that trims the reorder head, so the same ladder is reported from `-decodeLead`.
    /// The container states which one it is: `AVStream.start_time` is the presentation start after
    /// edit-list handling, and the first index entry is where the ladder starts. The difference is
    /// the shift, clamped to `[0, decodeLead]` because no honest file needs more and a malformed
    /// header must not be able to drag the video off its audio by an arbitrary amount.
    static func presentationShift(
        streamStartTime: Int64,
        ladderStart: Int64,
        decodeLead: Int64
    ) -> Int64 {
        guard streamStartTime != Int64.min, ladderStart != Int64.min, decodeLead > 0 else { return 0 }
        let raw = streamStartTime - ladderStart
        return min(max(raw, 0), decodeLead)
    }

    /// Fail-closed decision over the sampled head. Anything unproven returns `.inconclusive`, which
    /// leaves the stream exactly as the container delivered it.
    static func classify(
        samples: [Sample],
        videoDelay: Int,
        streamStartTime: Int64,
        ladderStart: Int64
    ) -> Verdict {
        guard videoDelay > 0, videoDelay <= 16 else {
            return .inconclusive("reorder delay \(videoDelay) outside 1...16")
        }
        // One composition offset is proof the writer emitted the table, and it ends the sampling
        // before the window fills.
        if samples.contains(where: { $0.pts != Int64.min && $0.dts != Int64.min && $0.pts != $0.dts }) {
            return .healthy
        }
        guard samples.count >= minimumSamples else {
            return .inconclusive("only \(samples.count) sampled pictures")
        }
        guard samples.allSatisfy({ $0.dts != Int64.min && $0.pts == $0.dts }) else {
            return .inconclusive("timestamps are not uniformly PTS == DTS")
        }
        guard let first = samples.first, first.isKeyframe, first.pictureOrderCount == 0 else {
            return .inconclusive("sample does not start on a picture-order origin")
        }

        // A ladder that advances by one constant is what lets a rank be turned back into a timestamp
        // without buffering packets. A picture whose length is not a whole number of ticks cannot
        // produce such a ladder at all: the sample table has to alternate between the two
        // neighbouring counts, and the cycle it repeats names the fraction it is quantizing (#409's
        // retest asset: 200202/5 ticks at a 1200000 timescale, cycling 40041,40040,40040,40041,40040).
        // Everything else, genuine variable frame timing included, is left alone rather than guessed at.
        var deltas: [Int64] = []
        deltas.reserveCapacity(samples.count - 1)
        for index in 1..<samples.count {
            let (delta, overflow) = samples[index].dts
                .subtractingReportingOverflow(samples[index - 1].dts)
            guard !overflow, delta > 0 else {
                return .inconclusive("decode timestamps do not advance")
            }
            deltas.append(delta)
        }
        guard let shortestStep = deltas.min(), let longestStep = deltas.max() else {
            return .inconclusive("no ladder step")
        }
        var cadence: Cadence?
        var step = shortestStep
        if shortestStep != longestStep {
            guard longestStep - shortestStep == 1,
                  let quantized = quantizedCadence(deltas: deltas),
                  let roundedStep = quantized.timestamp(at: 1) else {
                return .inconclusive("decode ladder is not uniform")
            }
            cadence = quantized
            step = roundedStep
        }
        guard step > 0 else { return .inconclusive("no ladder step") }

        // Without a picture-order regression the file presents in decode order and there is nothing
        // to repair, whatever its reorder delay claims.
        let pocs = samples.map(\.pictureOrderCount)
        guard zip(pocs, pocs.dropFirst()).contains(where: { $1 < $0 }) else {
            return .inconclusive("picture order never regresses")
        }
        guard pocs.allSatisfy({ $0 >= 0 }) else { return .inconclusive("negative picture order count") }

        // The step is measured, not assumed: frame coding advances the count by 2, but a stream that
        // uses a different increment stays repairable as long as it is consistent.
        var pocStep: Int64 = 0
        for value in pocs where value > 0 { pocStep = greatestCommonDivisor(pocStep, value) }
        guard pocStep > 0 else { return .inconclusive("picture order does not advance") }

        // The strongest available self-check: the display indices the plan would produce must be a
        // bijection onto the sampled window. A wrong picture-order step or a stream this arithmetic
        // does not describe collapses two pictures onto one time, and that is caught here rather
        // than on screen.
        var displayIndices: Set<Int64> = []
        for sample in samples {
            let index = sample.pictureOrderCount / pocStep
            guard sample.pictureOrderCount % pocStep == 0 else {
                return .inconclusive("picture order is not a multiple of its step")
            }
            guard displayIndices.insert(index).inserted else {
                return .inconclusive("two pictures share display index \(index)")
            }
        }
        // Distinct is not enough. A single picture order that is not on the common step drags the
        // measured step down (a stray 17 among even counts makes it 1), and the indices that follow
        // are then spread over twice the ladder while still being distinct. Ranks have to FILL the
        // window they came from: the span may exceed the sample only by the pictures still in flight
        // at its ragged edge, which is the reorder delay.
        guard let maxIndex = displayIndices.max(), let minIndex = displayIndices.min(),
              maxIndex - minIndex + 1 <= Int64(samples.count + videoDelay + 1) else {
            return .inconclusive("display indices do not fill the sampled window")
        }

        // The reorder head is one decode lead long, and with a fractional cadence that lead is a
        // rounded distance on the lattice rather than a multiple of a whole step.
        let ladderOrigin = ladderStart == Int64.min ? (samples.first?.dts ?? Int64.min) : ladderStart
        let decodeLead: Int64
        if let cadence {
            guard let head = cadence.timestamp(at: -Int64(videoDelay)), head < 0 else {
                return .inconclusive("cadence does not describe a reorder head")
            }
            decodeLead = -head
        } else {
            let (lead, overflow) = Int64(videoDelay).multipliedReportingOverflow(by: step)
            guard !overflow else { return .inconclusive("reorder head does not fit the timeline") }
            decodeLead = lead
        }
        guard decodeLead > 0 else { return .inconclusive("no decode lead") }
        let shift = presentationShift(
            streamStartTime: streamStartTime, ladderStart: ladderOrigin, decodeLead: decodeLead)

        // A fractional cadence is read back off a lattice, so the lattice has to be located first,
        // and that takes two readings the ladder cannot both give. The phase and the origin come from
        // the ladder itself: its rounding pattern is the phase, and only one phase of the period can
        // reproduce the sampled window picture for picture. How far the ladder runs ahead of
        // presentation does NOT come from the ladder, because every alignment fits it equally well;
        // that is the same question `presentationShift` already answers from the container header,
        // and here it has to resolve to a whole number of ordinals to be usable at all.
        var latticeOrigin: Int64 = 0
        var ladderPhase: Int64 = 0
        var ladderOrdinalOffset: Int64 = 0
        if let cadence {
            guard let fit = latticeFit(samples: samples, cadence: cadence) else {
                return .inconclusive(
                    "ladder does not follow one \(cadence.numerator)/\(cadence.denominator) phase")
            }
            ladderPhase = fit.phase
            latticeOrigin = fit.origin
            let alignment = (0...Int64(videoDelay)).first { candidate in
                cadence.timestamp(at: -candidate).map { -$0 } == shift
            }
            guard let alignment else {
                return .inconclusive("reorder head is not a whole number of pictures")
            }
            ladderOrdinalOffset = alignment
        }

        return .repair(
            Plan(
                step: step,
                decodeLead: decodeLead,
                shift: shift,
                pocStep: pocStep,
                cadence: cadence,
                latticeOrigin: latticeOrigin,
                ladderPhase: ladderPhase,
                ladderOrdinalOffset: ladderOrdinalOffset
            )
        )
    }

    /// Which phase of the cadence the sampled ladder starts on, and where that puts lattice ordinal
    /// zero. Every sampled picture has to land exactly, and the answer has to be the only phase in
    /// the period that does, or the ladder is not evidence of a lattice at all. This is what lets a
    /// sample taken anywhere describe the same axis as a sample taken at the head.
    static func latticeFit(samples: [Sample], cadence: Cadence) -> (phase: Int64, origin: Int64)? {
        guard let head = samples.first?.dts else { return nil }
        var found: (phase: Int64, origin: Int64)?
        for phase in 0..<cadence.denominator {
            guard let headOffset = cadence.timestamp(at: phase) else { continue }
            let (origin, originOverflow) = head.subtractingReportingOverflow(headOffset)
            guard !originOverflow else { continue }
            var fits = true
            for (index, sample) in samples.enumerated() {
                let (ordinal, ordinalOverflow) = phase.addingReportingOverflow(Int64(index))
                guard !ordinalOverflow, let offset = cadence.timestamp(at: ordinal) else {
                    fits = false
                    break
                }
                let (predicted, overflow) = origin.addingReportingOverflow(offset)
                guard !overflow, predicted == sample.dts else {
                    fits = false
                    break
                }
            }
            guard fits else { continue }
            guard found == nil else { return nil }
            found = (phase, origin)
        }
        return found
    }

    /// The cadence a two-valued ladder is quantizing, read from the cycle it repeats. A cycle has to
    /// be seen through twice before it counts, because one pass of a pattern is not evidence that it
    /// is a pattern: a short run of jitter can hold any shape once. The cycle also has to be
    /// primitive, so that the ticks it spans really are its period and not a multiple of a shorter
    /// one, and a picture has to be at least two ticks long, which is what makes reading a timestamp
    /// back into its ordinal exact.
    static func quantizedCadence(deltas: [Int64]) -> Cadence? {
        guard deltas.count >= 4 else { return nil }
        for period in 2...(deltas.count / 2) {
            guard deltas.indices.allSatisfy({ deltas[$0] == deltas[$0 % period] }) else { continue }
            var ticks: Int64 = 0
            for delta in deltas.prefix(period) {
                let (sum, overflow) = ticks.addingReportingOverflow(delta)
                guard !overflow else { return nil }
                ticks = sum
            }
            guard let cadence = Cadence(numerator: ticks, denominator: Int64(period)),
                  cadence.denominator == Int64(period), cadence.wholeTicks >= 2 else { continue }
            return cadence
        }
        return nil
    }

    static func greatestCommonDivisor(_ a: Int64, _ b: Int64) -> Int64 {
        var x = abs(a), y = abs(b)
        while y != 0 { (x, y) = (y, x % y) }
        return x
    }

    /// Applies a confirmed plan packet by packet. Holds exactly one piece of state, the decode
    /// timestamp of the picture that opened the current coded video sequence, because picture order
    /// counts restart at every IDR.
    struct Rewriter {
        let plan: Plan
        /// Set at the first keyframe seen, and again whenever the picture order restarts.
        private(set) var sequenceAnchorDTS: Int64?
        /// The presentation ordinal this sequence starts at, read back off the lattice. Only a
        /// fractional cadence has one; without it the scalar anchor above carries the sequence.
        private(set) var sequenceBaseOrdinal: Int64?
        /// A seek leaves the parser and the sequence anchor behind; the next keyframe re-anchors.
        private var awaitingReanchor = true
        /// Pictures emitted untouched because no anchor was available or the arithmetic did not
        /// close. Surfaced so a stream this repair does not describe is visible as a number.
        private(set) var unrepairedPictures = 0
        private(set) var repairedPictures = 0

        init(plan: Plan) { self.plan = plan }

        mutating func noteSeek() {
            awaitingReanchor = true
            sequenceAnchorDTS = nil
            sequenceBaseOrdinal = nil
        }

        /// nil when the picture cannot be placed; the caller then emits it untouched.
        mutating func rewrite(
            dts: Int64,
            pictureOrderCount: Int64,
            isKeyframe: Bool
        ) -> (pts: Int64, dts: Int64)? {
            guard dts != Int64.min, plan.pocStep > 0 else {
                unrepairedPictures += 1
                return nil
            }
            // A picture order of 0 on a keyframe is an IDR: a new coded video sequence starts here
            // and its first picture is also the first to be displayed. After a seek the landing
            // keyframe anchors even if its count is not 0, which is the only way an open-GOP entry
            // point can be placed at all; mid-sequence keyframes must not re-anchor, or every open
            // GOP would restart the display axis under a picture that has not moved.
            if isKeyframe, pictureOrderCount == 0 {
                sequenceAnchorDTS = dts
                sequenceBaseOrdinal = plan.presentationOrdinal(ladderTimestamp: dts)
                awaitingReanchor = false
            } else if awaitingReanchor, isKeyframe {
                guard pictureOrderCount % plan.pocStep == 0 else {
                    unrepairedPictures += 1
                    return nil
                }
                let landingIndex = pictureOrderCount / plan.pocStep
                sequenceAnchorDTS = dts - landingIndex * plan.step
                sequenceBaseOrdinal = plan.presentationOrdinal(ladderTimestamp: dts)
                    .flatMap { ordinal -> Int64? in
                        let (base, overflow) = ordinal.subtractingReportingOverflow(landingIndex)
                        return overflow ? nil : base
                    }
                awaitingReanchor = false
            }
            guard let anchor = sequenceAnchorDTS, !awaitingReanchor,
                  pictureOrderCount >= 0, pictureOrderCount % plan.pocStep == 0 else {
                unrepairedPictures += 1
                return nil
            }
            let displayIndex = pictureOrderCount / plan.pocStep
            // On a lattice the picture is placed by its ordinal, which reproduces the muxer exactly
            // even where the fraction rounds the other way. Without one, or when the sequence could
            // not be read back onto the lattice, the rounded step still describes the stream to
            // within a tick, and a tick beside the twin beats a picture left in decode order.
            let pts = sequenceBaseOrdinal
                .flatMap { base -> Int64? in
                    let (ordinal, overflow) = base.addingReportingOverflow(displayIndex)
                    return overflow ? nil : plan.presentationTimestamp(ordinal: ordinal)
                }
                ?? (anchor &+ plan.shift &+ displayIndex &* plan.step)
            let newDTS = dts &+ plan.shift &- plan.decodeLead
            // The muxer invariant. A picture that lands before its own decode time means the
            // arithmetic no longer describes this stream, and passing it through unchanged is
            // better than handing the muxer something it will silently clamp.
            guard pts >= newDTS else {
                unrepairedPictures += 1
                return nil
            }
            repairedPictures += 1
            return (pts, newDTS)
        }
    }
}

/// Reads a picture order count per packet with libavcodec's H.264 parser. No decoder is opened and
/// no picture is reconstructed: the parser walks the slice header, which is where display order
/// lives. It takes MP4's length-prefixed AVCC payload directly as long as the codec context carries
/// the `avcC` extradata, so no Annex-B conversion sits in the packet path.
final class H264PictureOrderReader {
    private var parser: UnsafeMutablePointer<AVCodecParserContext>?
    private var context: UnsafeMutablePointer<AVCodecContext>?

    init?(codecParameters: UnsafePointer<AVCodecParameters>, timeBase: AVRational) {
        guard let codec = avcodec_find_decoder(AV_CODEC_ID_H264),
              let context = avcodec_alloc_context3(codec) else { return nil }
        self.context = context
        guard avcodec_parameters_to_context(context, codecParameters) >= 0 else { return nil }
        context.pointee.pkt_timebase = timeBase
        guard let parser = av_parser_init(Int32(AV_CODEC_ID_H264.rawValue)) else { return nil }
        self.parser = parser
        // MP4 samples are whole access units; without this the parser hunts for start codes that
        // length-prefixed payloads do not contain.
        parser.pointee.flags |= Int32(PARSER_FLAG_COMPLETE_FRAMES)
    }

    deinit {
        if let parser { av_parser_close(parser) }
        var owned = context
        avcodec_free_context(&owned)
    }

    /// Drops the parser's carried state after a discontinuity, the way libavformat's own seek does
    /// (`ff_read_frame_flush` closes the stream parser). A picture order count is computed against
    /// the previous picture's, so a parser that survived a jump can answer for the wrong sequence.
    func reset() {
        guard let parser else { return }
        av_parser_close(parser)
        self.parser = av_parser_init(Int32(AV_CODEC_ID_H264.rawValue))
        self.parser?.pointee.flags |= Int32(PARSER_FLAG_COMPLETE_FRAMES)
    }

    /// nil when the parser could not resolve this access unit.
    func pictureOrderCount(for packet: UnsafeMutablePointer<AVPacket>) -> Int64? {
        guard let parser, let context, let data = packet.pointee.data, packet.pointee.size > 0 else {
            return nil
        }
        var outData: UnsafeMutablePointer<UInt8>?
        var outSize: Int32 = 0
        let consumed = av_parser_parse2(
            parser, context, &outData, &outSize,
            data, packet.pointee.size,
            packet.pointee.pts, packet.pointee.dts, packet.pointee.pos
        )
        guard consumed >= 0, outSize > 0 else { return nil }
        return Int64(parser.pointee.output_picture_number)
    }
}

/// Per-demuxer runtime for the #409 repair: samples the head, decides once, then rewrites.
///
/// Sampling holds packets instead of rewinding the source. A rewind is not available to every
/// session (a custom source cannot be reopened, and a probe demuxer handed to playback must not be
/// left at an unknown position), and it would pay for the read twice; holding the first packets
/// costs one small queue and keeps the decision on the same bytes playback is about to consume.
/// Every packet is held, not just video, so the interleaving the container chose survives the
/// verdict.
final class H264CompositionOffsetRepairSession {

    enum Phase: Equatable { case sampling, repairing, off }

    private(set) var phase: Phase = .sampling
    private let streamIndex: Int32
    private let videoDelay: Int
    private let streamStartTime: Int64
    private let ladderStart: Int64
    private var reader: H264PictureOrderReader?
    private var rewriter: H264CompositionOffsetRepair.Rewriter?
    private var samples: [H264CompositionOffsetRepair.Sample] = []
    private var held: [(packet: UnsafeMutablePointer<AVPacket>, pictureOrderCount: Int64?)] = []
    private var heldBytes = 0
    private var verdictDescription = "sampling"

    /// nil unless this stream is the exact shape the defect needs: ISO-BMFF, H.264, and a bitstream
    /// that declares reordered pictures. Everything else never sees a parser or a held packet.
    init?(
        containerFormatName: String?,
        stream: UnsafeMutablePointer<AVStream>,
        streamIndex: Int32,
        ladderStart: Int64
    ) {
        let containers = containerFormatName?.split(separator: ",") ?? []
        guard containers.contains("mov") || containers.contains("mp4") else { return nil }
        guard let codecpar = stream.pointee.codecpar,
              codecpar.pointee.codec_id == AV_CODEC_ID_H264,
              codecpar.pointee.video_delay > 0,
              let reader = H264PictureOrderReader(
                codecParameters: codecpar, timeBase: stream.pointee.time_base)
        else { return nil }
        self.streamIndex = streamIndex
        self.videoDelay = Int(codecpar.pointee.video_delay)
        self.streamStartTime = stream.pointee.start_time
        self.ladderStart = ladderStart
        self.reader = reader
    }

    deinit {
        for entry in held {
            var owned: UnsafeMutablePointer<AVPacket>? = entry.packet
            trackedPacketFree(&owned)
        }
    }

    var hasHeldPackets: Bool { !held.isEmpty }

    /// True once the sample has produced a verdict; until then no consumer may read an axis from
    /// this demuxer, because the repair may still be about to move it.
    var isDecided: Bool { phase != .sampling }

    /// Ticks every decode timestamp moves by, so the container's own index can be read on the same
    /// axis as the packets. nil while sampling or when nothing is repaired. The plan built from the
    /// index and the packets that fill it have to agree: measured, a plan on the raw ladder against
    /// repaired packets cut segment 2 one picture past its keyframe, which is a segment AVPlayer
    /// cannot start at.
    var decodeTimestampOffset: Int64? {
        guard phase == .repairing, let rewriter else { return nil }
        return rewriter.plan.shift - rewriter.plan.decodeLead
    }

    /// Returns true when the packet was taken over by the session and must not be emitted yet.
    /// A packet the session keeps is owned by it until `dequeue()` hands it back.
    func ingest(_ packet: UnsafeMutablePointer<AVPacket>) -> Bool {
        switch phase {
        case .off:
            return false
        case .repairing:
            guard packet.pointee.stream_index == streamIndex else { return false }
            applyRepair(to: packet, pictureOrderCount: reader?.pictureOrderCount(for: packet))
            return false
        case .sampling:
            var pictureOrderCount: Int64?
            if packet.pointee.stream_index == streamIndex {
                pictureOrderCount = reader?.pictureOrderCount(for: packet)
                samples.append(
                    H264CompositionOffsetRepair.Sample(
                        dts: packet.pointee.dts,
                        pts: packet.pointee.pts,
                        pictureOrderCount: pictureOrderCount ?? -1,
                        isKeyframe: (packet.pointee.flags & AV_PKT_FLAG_KEY) != 0
                    )
                )
            }
            held.append((packet, pictureOrderCount))
            heldBytes += Int(max(0, packet.pointee.size))
            if samples.count >= H264CompositionOffsetRepair.sampleTarget
                || heldBytes >= H264CompositionOffsetRepair.sampleByteBudget
                || held.count >= H264CompositionOffsetRepair.heldPacketCeiling
                || earlyHealthyVerdict {
                decide()
            }
            return true
        }
    }

    /// A healthy file usually proves itself on its first packet, and paying twelve packets of hold
    /// for it would tax every well-formed MP4 with B-frames on the platform.
    private var earlyHealthyVerdict: Bool {
        guard let last = samples.last else { return false }
        return last.pts != Int64.min && last.dts != Int64.min && last.pts != last.dts
    }

    /// EOF during sampling. Decides on what is there, so the held packets are still delivered.
    func endOfStream() {
        if phase == .sampling { decide() }
    }

    func noteSeek() {
        // The held packets belong to the position that was abandoned, in EVERY phase, not just while
        // the sample is still open: a settled verdict leaves the sample it read in the queue, and
        // `dequeue()` hands that queue out ahead of anything read after the seek. Dropping it only
        // during `.sampling` republished the old position's packets at the landing, which on a healthy
        // file (verdict `.off`, sample still held) put two duplicate pictures into the stream a
        // producer had already emitted.
        dropHeldPackets()
        switch phase {
        case .sampling:
            // The sample restarts where the source now stands.
            samples.removeAll(keepingCapacity: true)
        case .repairing:
            rewriter?.noteSeek()
            reader?.reset()
        case .off:
            break
        }
    }

    private func dropHeldPackets() {
        for entry in held {
            var owned: UnsafeMutablePointer<AVPacket>? = entry.packet
            trackedPacketFree(&owned)
        }
        held.removeAll(keepingCapacity: true)
        heldBytes = 0
    }

    /// Puts a packet at the head of the queue. Used by the demuxer when a sample ends on a packet
    /// the session did not take over, so decode order survives the handover.
    func enqueueFront(_ packet: UnsafeMutablePointer<AVPacket>) {
        held.insert((packet, nil), at: 0)
    }

    func dequeue() -> UnsafeMutablePointer<AVPacket>? {
        guard phase != .sampling, !held.isEmpty else { return nil }
        return held.removeFirst().packet
    }

    var summary: String {
        var text = "phase=\(phase) verdict=\(verdictDescription)"
        if let rewriter {
            text += " repaired=\(rewriter.repairedPictures) unrepaired=\(rewriter.unrepairedPictures)"
        }
        return text
    }

    private func decide() {
        let verdict = H264CompositionOffsetRepair.classify(
            samples: samples,
            videoDelay: videoDelay,
            streamStartTime: streamStartTime,
            ladderStart: ladderStart
        )
        switch verdict {
        case .repair(let plan):
            // The cadence and its phase belong in the line: on a fractional ladder they are the
            // reading the verdict rests on, and a repair that reports only a rounded step cannot be
            // told apart from one that measured the ladder wrong.
            let cadenceDescription = plan.cadence.map {
                " cadence=\($0.numerator)/\($0.denominator) phase=\(plan.ladderPhase)"
                    + " ladderAhead=\(plan.ladderOrdinalOffset)"
            } ?? ""
            verdictDescription = "repair step=\(plan.step) lead=\(plan.decodeLead) "
                + "shift=\(plan.shift) pocStep=\(plan.pocStep)" + cadenceDescription
            phase = .repairing
            var rewriter = H264CompositionOffsetRepair.Rewriter(plan: plan)
            for entry in held where entry.packet.pointee.stream_index == streamIndex {
                applyRepair(to: entry.packet, pictureOrderCount: entry.pictureOrderCount, using: &rewriter)
            }
            self.rewriter = rewriter
            EngineLog.emit(
                "[Demuxer] #409 missing H.264 composition offsets confirmed on stream \(streamIndex): "
                + "\(verdictDescription) samples=\(samples.count)",
                category: .demux
            )
        case .healthy:
            verdictDescription = "healthy"
            disarm()
        case .inconclusive(let reason):
            verdictDescription = "inconclusive (\(reason))"
            // Only worth a line when the stream looked like a candidate: a file that simply carries
            // composition offsets is the normal case and says nothing.
            EngineLog.emit(
                "[Demuxer] #409 composition-offset probe on stream \(streamIndex) left the stream "
                + "untouched: \(reason) (samples=\(samples.count))",
                category: .demux
            )
            disarm()
        }
        samples.removeAll(keepingCapacity: false)
    }

    private func disarm() {
        phase = .off
        reader = nil
    }

    private func applyRepair(
        to packet: UnsafeMutablePointer<AVPacket>,
        pictureOrderCount: Int64?
    ) {
        guard var rewriter else { return }
        applyRepair(to: packet, pictureOrderCount: pictureOrderCount, using: &rewriter)
        self.rewriter = rewriter
    }

    private func applyRepair(
        to packet: UnsafeMutablePointer<AVPacket>,
        pictureOrderCount: Int64?,
        using rewriter: inout H264CompositionOffsetRepair.Rewriter
    ) {
        guard let pictureOrderCount,
              let repaired = rewriter.rewrite(
                dts: packet.pointee.dts,
                pictureOrderCount: pictureOrderCount,
                isKeyframe: (packet.pointee.flags & AV_PKT_FLAG_KEY) != 0)
        else { return }
        packet.pointee.pts = repaired.pts
        packet.pointee.dts = repaired.dts
    }
}
