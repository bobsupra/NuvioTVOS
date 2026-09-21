import Testing
@testable import AetherEngine

/// #511: a Matroska writer that hands its block timestamps out in coding order.
///
/// The slots and picture orders below are the reporting asset's own, measured by the reporter and
/// contributed as a numeric fixture on PR #511: 60 pictures of one coded video sequence plus the IDR
/// that closes it, `video_delay=1`, `time_base=1/1000`, nominal 30000/1001. Two properties of that
/// ladder are what a repair has to survive, and both are why this one reads the slots rather than
/// computing them. It is a quantization of a fractional cadence, so its slots alternate between 33
/// and 34 ticks in a pattern that takes 21 slots before a lattice can name its phase at all; and its
/// FIRST slot sits 7 ticks below the value that pattern gives it, because a Matroska block cannot be
/// placed before its own cluster origin.
@Suite("#511 Matroska coding-order presentation slots")
struct Issue511MatroskaCodingOrderTests {
    typealias Permutation = H264MatroskaSlotPermutation
    typealias Sample = H264CompositionOffsetRepair.Sample

    static let reportedSlots: [Int64] = [
        0, 40, 73, 107, 140, 173, 207, 240, 274, 307, 340, 374, 407, 440, 474, 507, 541, 574, 607,
        641, 674, 707, 741, 774, 807, 841, 874, 908, 941, 974, 1008, 1041, 1074, 1108, 1141, 1174,
        1208, 1241, 1275, 1308, 1341, 1375, 1408, 1441, 1475, 1508, 1542, 1575, 1608, 1642, 1675,
        1708, 1742, 1775, 1808, 1842, 1875, 1909, 1942, 1975, 2009,
    ]
    static let reportedPictureOrder: [Int64] = [
        0, 8, 2, 4, 6, 14, 10, 12, 20, 16, 18, 24, 22, 30, 26, 28, 36, 32, 34, 42, 38, 40, 48, 44, 46,
        56, 50, 52, 54, 60, 58, 66, 62, 64, 72, 68, 70, 78, 74, 76, 84, 80, 82, 90, 86, 88, 96, 92,
        94, 102, 98, 100, 108, 104, 106, 114, 110, 112, 118, 116, 0,
    ]

    /// The decode ladder libavformat derives from a rising presentation one: the slot `videoDelay`
    /// pictures back, and unstated for the head of the stream.
    static func derivedDecodeTimestamps(_ slots: [Int64], videoDelay: Int) -> [Int64] {
        slots.indices.map { $0 < videoDelay ? Int64.min : slots[$0 - videoDelay] }
    }

    static func samples(slots: [Int64], pocs: [Int64], videoDelay: Int = 1) -> [Sample] {
        let dts = derivedDecodeTimestamps(slots, videoDelay: videoDelay)
        return slots.indices.map { index in
            Sample(
                dts: dts[index],
                pts: slots[index],
                pictureOrderCount: pocs[index],
                isKeyframe: pocs[index] == 0
            )
        }
    }

    /// Feeds a window through the permutation the way the session does, and reports what each picture
    /// came out with. nil means the picture had to go out untouched.
    static func permute(
        _ samples: [Sample],
        pocStep: Int64 = 2,
        videoDelay: Int = 1,
        startingSeeked: Bool = false
    ) -> (placed: [Int64?], waits: [Int], sequence: Permutation.Sequence) {
        var sequence = Permutation.Sequence(pocStep: pocStep, videoDelay: videoDelay)
        if !startingSeeked { sequence.noteSeek() }
        var ranks: [Int64?] = []
        for sample in samples {
            ranks.append(
                sequence.admit(
                    slot: sample.pts,
                    pictureOrderCount: sample.pictureOrderCount,
                    isKeyframe: sample.isKeyframe))
        }
        // A picture is emitted once the packet carrying its slot has arrived. Rebuild the wait each
        // one paid, in video packets, from the final sequence.
        var placed: [Int64?] = []
        var waits: [Int] = []
        for (index, rank) in ranks.enumerated() {
            guard let rank else {
                placed.append(nil)
                waits.append(0)
                continue
            }
            placed.append(sequence.slot(forRank: rank))
            waits.append(max(0, Int(rank) - index))
        }
        return (placed, waits, sequence)
    }

    @Test("the reported window is read as slots handed out in coding order")
    func classifiesTheReportedWindow() {
        let window = Array(
            Self.samples(slots: Self.reportedSlots, pocs: Self.reportedPictureOrder)
                .prefix(Permutation.sampleTarget))
        #expect(Permutation.classify(samples: window, videoDelay: 1) == .permute(pocStep: 2))
    }

    @Test("every picture carries the slot its own display rank owns, and the multiset is the file's")
    func permutesTheReportedSequence() throws {
        let sequenceSamples = Array(
            Self.samples(slots: Self.reportedSlots, pocs: Self.reportedPictureOrder).prefix(60))
        let result = Self.permute(sequenceSamples)
        let placed = try result.placed.map { try #require($0) }
        for (index, poc) in Self.reportedPictureOrder.prefix(60).enumerated() {
            #expect(placed[index] == Self.reportedSlots[Int(poc / 2)])
        }
        // Nothing is computed, so the repaired times are the file's own set, rounding and all.
        #expect(placed.sorted() == Array(Self.reportedSlots.prefix(60)))
        // The slot the writer clamped onto the cluster origin stays where it was written.
        #expect(placed[0] == 0)
        #expect(result.sequence.repairedPictures == 60)
        #expect(result.sequence.unrepairedPictures == 0)
        #expect(result.sequence.brokenReason == nil)
    }

    @Test("the wait a picture pays is its mini-GOP, not its sequence")
    func waitsOneMiniGOP() {
        let sequenceSamples = Array(
            Self.samples(slots: Self.reportedSlots, pocs: Self.reportedPictureOrder).prefix(60))
        let waits = Self.permute(sequenceSamples).waits
        // Measured on the reporting asset: three video packets, in a 60-picture sequence.
        #expect(waits.max() == 3)
    }

    @Test("a picture never lands before the decode time the container states for it")
    func keepsTheMuxerInvariant() {
        let sequenceSamples = Array(
            Self.samples(slots: Self.reportedSlots, pocs: Self.reportedPictureOrder).prefix(60))
        let placed = Self.permute(sequenceSamples).placed
        for (index, sample) in sequenceSamples.enumerated() {
            guard let slot = placed[index], sample.dts != Int64.min else { continue }
            #expect(slot >= sample.dts)
        }
    }

    @Test("a new IDR restarts the ranks and owns its own slot")
    func restartsOnTheNextSequence() throws {
        let all = Self.samples(slots: Self.reportedSlots, pocs: Self.reportedPictureOrder)
        let result = Self.permute(all)
        #expect(try #require(result.placed[60]) == Self.reportedSlots[60])
        #expect(result.sequence.slots == [Self.reportedSlots[60]])
    }

    @Test("a healthy reordered MKV is out on the packet that steps back, not after the window")
    func healthyLadderExits() {
        // The same pictures with their slots where the format says they belong: in display order,
        // attached to the picture that owns them.
        let healthy = Self.reportedPictureOrder.prefix(12).map { poc in
            Sample(
                dts: Int64.min,
                pts: Self.reportedSlots[Int(poc / 2)],
                pictureOrderCount: poc,
                isKeyframe: poc == 0
            )
        }
        #expect(Permutation.classify(samples: Array(healthy), videoDelay: 1) == .healthy)
        // Three packets are enough: I, the P that follows it, and the first B between them.
        #expect(Permutation.classify(samples: Array(healthy.prefix(3)), videoDelay: 1) == .healthy)
    }

    @Test("shapes this permutation does not describe are left alone")
    func failsClosed() {
        func verdict(slots: [Int64], pocs: [Int64], videoDelay: Int = 1) -> Permutation.Verdict {
            Permutation.classify(
                samples: Self.samples(slots: slots, pocs: pocs, videoDelay: videoDelay),
                videoDelay: videoDelay)
        }
        let slots = Array(Self.reportedSlots.prefix(12))
        let pocs = Array(Self.reportedPictureOrder.prefix(12))
        #expect(verdict(slots: slots, pocs: pocs) == .permute(pocStep: 2))
        // Two pictures claiming one display rank, and two claiming one slot.
        var collision = pocs
        collision[4] = collision[3]
        #expect(verdict(slots: slots, pocs: collision).isInconclusive)
        var duplicate = slots
        duplicate[5] = duplicate[4]
        #expect(verdict(slots: duplicate, pocs: pocs).isInconclusive)
        // Ranks that do not fill the window they came from.
        var sparse = pocs
        sparse[11] = 400
        #expect(verdict(slots: slots, pocs: sparse).isInconclusive)
        // A window that does not start on a sequence origin: nothing anchors the ranks.
        #expect(verdict(slots: Array(slots.dropFirst()), pocs: Array(pocs.dropFirst())).isInconclusive)
        // Coding order that is already display order has nothing to repair.
        #expect(verdict(slots: slots, pocs: (0..<12).map { Int64($0) * 2 }).isInconclusive)
        // Too few pictures to call it.
        #expect(verdict(slots: Array(slots.prefix(8)), pocs: Array(pocs.prefix(8))).isInconclusive)
        // A picture further behind its own slot than the reorder delay the container declares would
        // land before its own decode time.
        #expect(verdict(slots: slots, pocs: [0, 8, 6, 2, 4, 10, 12, 14, 16, 18, 20, 22]).isInconclusive)
    }

    @Test("variable slot spacing is repaired: the permutation never reads a cadence")
    func doesNotNeedACadence() throws {
        // Deliberately not near-CFR. The slots are still the file's own presentation times, so the
        // picture that owns each one is the only question, and picture order answers it.
        let slots: [Int64] = [0, 40, 61, 130, 131, 400, 402, 403, 900, 1000, 1001, 1500, 1502]
        let pocs = Array(Self.reportedPictureOrder.prefix(13))
        let samples = Self.samples(slots: slots, pocs: pocs)
        #expect(Permutation.classify(samples: samples, videoDelay: 1) == .permute(pocStep: 2))
        let placed = try Self.permute(samples).placed.map { try #require($0) }
        for (index, poc) in pocs.enumerated() {
            #expect(placed[index] == slots[Int(poc / 2)])
        }
    }

    @Test("after a seek only an IDR re-anchors, and anything else goes out untouched")
    func reanchorsOnlyOnAnIDR() throws {
        let all = Self.samples(slots: Self.reportedSlots, pocs: Self.reportedPictureOrder)
        // A landing in the middle of a sequence: a display rank is counted from an IDR this reader
        // has not seen, so nothing is placed until the next one arrives.
        var stranded = Permutation.Sequence(pocStep: 2, videoDelay: 1)
        stranded.noteSeek()
        for sample in all[1..<12] {
            #expect(
                stranded.admit(
                    slot: sample.pts, pictureOrderCount: sample.pictureOrderCount,
                    isKeyframe: false) == nil)
        }
        #expect(stranded.repairedPictures == 0)
        #expect(stranded.unrepairedPictures == 11)
        // The IDR that closes the sequence re-anchors it, and the pictures after it place normally.
        #expect(stranded.admit(slot: all[60].pts, pictureOrderCount: 0, isKeyframe: true) == 0)
        #expect(stranded.slot(forRank: 0) == Self.reportedSlots[60])
    }

    @Test("a stream that stops being this shape stops the permutation instead of half-applying it")
    func stopsRatherThanHalfApplying() {
        var sequence = Permutation.Sequence(pocStep: 2, videoDelay: 1)
        sequence.noteSeek()
        #expect(sequence.admit(slot: 0, pictureOrderCount: 0, isKeyframe: true) == 0)
        #expect(sequence.admit(slot: 40, pictureOrderCount: 4, isKeyframe: false) == 2)
        // A slot that no longer rises is not this defect any more.
        #expect(sequence.admit(slot: 20, pictureOrderCount: 2, isKeyframe: false) == nil)
        #expect(sequence.brokenReason != nil)
        // A keyframe whose picture order could not be read may or may not open a sequence, and both
        // guesses misplace every picture after it.
        var unreadable = Permutation.Sequence(pocStep: 2, videoDelay: 1)
        unreadable.noteSeek()
        #expect(unreadable.admit(slot: 0, pictureOrderCount: nil, isKeyframe: true) == nil)
        #expect(unreadable.brokenReason != nil)
    }

    @Test("a picture whose order the parser missed is the only one that goes out untouched")
    func oneMissedPictureCostsOnePicture() throws {
        var samples = Array(
            Self.samples(slots: Self.reportedSlots, pocs: Self.reportedPictureOrder).prefix(13))
        var sequence = Permutation.Sequence(pocStep: 2, videoDelay: 1)
        sequence.noteSeek()
        var ranks: [Int64?] = []
        for (index, sample) in samples.enumerated() {
            ranks.append(
                sequence.admit(
                    slot: sample.pts,
                    pictureOrderCount: index == 6 ? nil : sample.pictureOrderCount,
                    isKeyframe: sample.isKeyframe))
        }
        // A picture is emitted once the packet carrying its slot has arrived, so the placement is
        // read off the finished sequence rather than off the state at the moment it was admitted.
        let placed = ranks.map { rank in rank.flatMap { sequence.slot(forRank: $0) } }
        #expect(placed[6] == nil)
        #expect(sequence.unrepairedPictures == 1)
        #expect(sequence.brokenReason == nil)
        // The slot that picture carried still belongs to whichever picture owns its coding position,
        // so the pictures around it are placed exactly as before.
        samples[6].pictureOrderCount = -1
        for index in [0, 1, 2, 3, 4, 5, 7, 8, 9, 10, 11, 12] {
            let poc = Self.reportedPictureOrder[index]
            #expect(try #require(placed[index]) == Self.reportedSlots[Int(poc / 2)])
        }
    }
}

private extension H264MatroskaSlotPermutation.Verdict {
    var isInconclusive: Bool {
        if case .inconclusive = self { return true }
        return false
    }
}
