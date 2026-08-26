import Foundation
import AetherLibavcodec
import Testing
@testable import AetherEngine

/// #409. The two MP4 fixtures are @orut34iop's, from the report and PR #411: one encode, muxed twice,
/// with the composition-offset table present in one and stream-copied away in the other. That pairing
/// is what makes the property here checkable at all, because the healthy twin IS the expected answer:
/// a repair is correct exactly when it reproduces its timestamps, packet for packet.
@Suite("H.264 missing composition offsets (#409)")
struct H264CompositionOffsetRepairTests {

    // MARK: - the decision

    /// The reported shape: twelve pictures, no composition offsets, a uniform ladder, and a picture
    /// order that regresses inside every mini-GOP.
    private func malformedSamples() -> [H264CompositionOffsetRepair.Sample] {
        let pocs: [Int64] = [0, 8, 4, 2, 6, 16, 12, 10, 14, 24, 20, 18]
        return pocs.enumerated().map { index, poc in
            H264CompositionOffsetRepair.Sample(
                dts: Int64(index) * 1001,
                pts: Int64(index) * 1001,
                pictureOrderCount: poc,
                isKeyframe: index == 0
            )
        }
    }

    private func verdict(
        _ samples: [H264CompositionOffsetRepair.Sample],
        videoDelay: Int = 2,
        streamStartTime: Int64 = 0,
        ladderStart: Int64 = 0
    ) -> H264CompositionOffsetRepair.Verdict {
        H264CompositionOffsetRepair.classify(
            samples: samples, videoDelay: videoDelay,
            streamStartTime: streamStartTime, ladderStart: ladderStart)
    }

    @Test("the reported shape is repaired, with the ladder and picture-order step measured")
    func confirmedShape() {
        #expect(verdict(malformedSamples())
            == .repair(H264CompositionOffsetRepair.Plan(
                step: 1001, decodeLead: 2002, shift: 0, pocStep: 2)))
    }

    @Test("one composition offset ends it: the writer emitted the table")
    func oneOffsetIsHealthy() {
        var samples = malformedSamples()
        samples[3].pts = samples[3].dts + 1001
        #expect(verdict(samples) == .healthy)
    }

    @Test("a stream that presents in decode order is left alone")
    func noReorderNoRepair() {
        let samples = (0..<12).map { index in
            H264CompositionOffsetRepair.Sample(
                dts: Int64(index) * 1001, pts: Int64(index) * 1001,
                pictureOrderCount: Int64(index) * 2, isKeyframe: index == 0)
        }
        #expect(verdict(samples) == .inconclusive("picture order never regresses"))
    }

    @Test("variable frame timing is not repairable by rank arithmetic and stays untouched")
    func nonUniformLadder() {
        var samples = malformedSamples()
        for index in 6..<samples.count { samples[index].dts += 500; samples[index].pts += 500 }
        #expect(verdict(samples) == .inconclusive("decode ladder is not uniform"))
    }

    @Test("a sample that does not start on a picture-order origin cannot be anchored")
    func mustStartOnOrigin() {
        var samples = malformedSamples()
        samples[0].isKeyframe = false
        #expect(verdict(samples) == .inconclusive("sample does not start on a picture-order origin"))
    }

    @Test("too few pictures fails closed")
    func tooFewSamples() {
        let samples = Array(malformedSamples().prefix(8))
        #expect(verdict(samples) == .inconclusive("only 8 sampled pictures"))
    }

    @Test("no declared reorder delay means the container is not describing this defect")
    func requiresReorderDelay() {
        #expect(verdict(malformedSamples(), videoDelay: 0)
            == .inconclusive("reorder delay 0 outside 1...16"))
    }

    @Test("two pictures may never land on one display index")
    func rejectsCollidingDisplayIndices() {
        var samples = malformedSamples()
        samples[4].pictureOrderCount = 4  // already taken by sample 2
        #expect(verdict(samples) == .inconclusive("two pictures share display index 2"))
    }

    /// The step is measured from the sample, so one picture order off the common step would halve it
    /// and spread every following rank over twice the ladder. Distinctness does not catch that;
    /// filling the window does.
    @Test("a picture order that does not advance one rank per picture is refused")
    func rejectsUnalignedPictureOrder() {
        var samples = malformedSamples()
        samples[5].pictureOrderCount = 17
        #expect(verdict(samples) == .inconclusive("display indices do not fill the sampled window"))
    }

    // MARK: - which axis the presentation lands on

    @Test("a writer that left the ladder on the presentation axis needs no shift")
    func shiftWithoutEditList() {
        #expect(H264CompositionOffsetRepair.presentationShift(
            streamStartTime: 0, ladderStart: 0, decodeLead: 2002) == 0)
    }

    @Test("a retained edit list reports the ladder from minus one decode lead, and that is the shift")
    func shiftWithRetainedEditList() {
        #expect(H264CompositionOffsetRepair.presentationShift(
            streamStartTime: 0, ladderStart: -2002, decodeLead: 2002) == 2002)
    }

    @Test("the shift can never drag the picture further than one decode lead off its audio")
    func shiftIsClamped() {
        #expect(H264CompositionOffsetRepair.presentationShift(
            streamStartTime: 0, ladderStart: -100_000, decodeLead: 2002) == 2002)
        #expect(H264CompositionOffsetRepair.presentationShift(
            streamStartTime: 90_000, ladderStart: 0, decodeLead: 2002) == 2002)
        #expect(H264CompositionOffsetRepair.presentationShift(
            streamStartTime: Int64.min, ladderStart: 0, decodeLead: 2002) == 0)
    }

    // MARK: - the rewrite

    private var plan: H264CompositionOffsetRepair.Plan {
        H264CompositionOffsetRepair.Plan(step: 1001, decodeLead: 2002, shift: 0, pocStep: 2)
    }

    @Test("the first mini-GOP lands on the ladder in display order, with DTS pulled back by the lead")
    func rewritesFirstMiniGOP() {
        var rewriter = H264CompositionOffsetRepair.Rewriter(plan: plan)
        let pocs: [Int64] = [0, 8, 4, 2, 6]
        let expected: [(Int64, Int64)] = [(0, -2002), (4004, -1001), (2002, 0), (1001, 1001), (3003, 2002)]
        for (index, poc) in pocs.enumerated() {
            let out = rewriter.rewrite(
                dts: Int64(index) * 1001, pictureOrderCount: poc, isKeyframe: index == 0)
            #expect(out?.pts == expected[index].0)
            #expect(out?.dts == expected[index].1)
        }
        #expect(rewriter.repairedPictures == 5)
        #expect(rewriter.unrepairedPictures == 0)
    }

    @Test("a new coded video sequence re-anchors on its own IDR")
    func reanchorsAtEverySequence() {
        var rewriter = H264CompositionOffsetRepair.Rewriter(plan: plan)
        _ = rewriter.rewrite(dts: 0, pictureOrderCount: 0, isKeyframe: true)
        // Second IDR, 30 pictures in: its picture order restarts at 0 and it is the first of its
        // sequence to be displayed, so it keeps its own decode time as its presentation time.
        let idr = rewriter.rewrite(dts: 30030, pictureOrderCount: 0, isKeyframe: true)
        let idrPTS: Int64 = idr?.pts ?? -1
        let idrDTS: Int64 = idr?.dts ?? -1
        #expect(idrPTS == 30030)
        #expect(idrDTS == 28028)
        let following = rewriter.rewrite(dts: 31031, pictureOrderCount: 8, isKeyframe: false)
        let followingPTS: Int64 = following?.pts ?? -1
        #expect(followingPTS == 34034)
    }

    @Test("a seek re-anchors on the landing keyframe instead of trusting the abandoned sequence")
    func seekReanchors() {
        var rewriter = H264CompositionOffsetRepair.Rewriter(plan: plan)
        _ = rewriter.rewrite(dts: 0, pictureOrderCount: 0, isKeyframe: true)
        rewriter.noteSeek()
        let landing = rewriter.rewrite(dts: 500500, pictureOrderCount: 0, isKeyframe: true)
        let landingPTS: Int64 = landing?.pts ?? -1
        let landingDTS: Int64 = landing?.dts ?? -1
        #expect(landingPTS == 500500)
        #expect(landingDTS == 498498)
    }

    @Test("without an anchor a picture is emitted untouched rather than guessed at")
    func passesThroughWithoutAnchor() {
        var rewriter = H264CompositionOffsetRepair.Rewriter(plan: plan)
        rewriter.noteSeek()
        #expect(rewriter.rewrite(dts: 4004, pictureOrderCount: 8, isKeyframe: false) == nil)
        #expect(rewriter.unrepairedPictures == 1)
    }

    @Test("a picture that would land before its own decode time is refused")
    func refusesPTSBeforeDTS() {
        var rewriter = H264CompositionOffsetRepair.Rewriter(plan: plan)
        _ = rewriter.rewrite(dts: 0, pictureOrderCount: 0, isKeyframe: true)
        // A picture order far behind the anchor would place this picture before its own DTS.
        #expect(rewriter.rewrite(dts: 100 * 1001, pictureOrderCount: 2, isKeyframe: false) == nil)
        #expect(rewriter.unrepairedPictures == 1)
    }

    @Test("an unparseable picture order leaves the packet alone")
    func refusesUnalignedOrder() {
        var rewriter = H264CompositionOffsetRepair.Rewriter(plan: plan)
        _ = rewriter.rewrite(dts: 0, pictureOrderCount: 0, isKeyframe: true)
        #expect(rewriter.rewrite(dts: 1001, pictureOrderCount: 3, isKeyframe: false) == nil)
    }

    // MARK: - end to end, against the twin

    private struct Timestamps: Equatable, CustomStringConvertible {
        var pts: Int64
        var dts: Int64
        var description: String { "pts=\(pts) dts=\(dts)" }
    }

    private static func videoTimestamps(base64: String) throws -> [Timestamps] {
        let data = try #require(Data(base64Encoded: base64, options: .ignoreUnknownCharacters))
        let demuxer = Demuxer()
        try demuxer.open(reader: DataIOReader(data: data), formatHint: "mp4")
        defer { demuxer.close() }
        let videoIndex = demuxer.videoStreamIndex
        var result: [Timestamps] = []
        while let packet = try? demuxer.readPacket() {
            if packet.pointee.stream_index == videoIndex {
                result.append(Timestamps(pts: packet.pointee.pts, dts: packet.pointee.dts))
            }
            var owned: UnsafeMutablePointer<AVPacket>? = packet
            trackedPacketFree(&owned)
        }
        return result
    }

    @Test("the repaired twin carries the healthy twin's timestamps, packet for packet")
    func repairedTwinMatchesHealthyTwin() throws {
        let healthy = try Self.videoTimestamps(base64: Self.healthyCTTSFixtureBase64)
        let repaired = try Self.videoTimestamps(base64: Self.missingCTTSFixtureBase64)
        #expect(healthy.count == 66)
        #expect(repaired.count == healthy.count)
        #expect(repaired == healthy)
    }

    @Test("the healthy twin is delivered exactly as the container wrote it")
    func healthyTwinIsUntouched() throws {
        let healthy = try Self.videoTimestamps(base64: Self.healthyCTTSFixtureBase64)
        // Composition offsets present: reordered pictures, and a decode head one lead below zero.
        #expect(healthy.first == Timestamps(pts: 0, dts: -2002))
        #expect(healthy.contains { $0.pts != $0.dts })
        #expect(zip(healthy, healthy.dropFirst()).allSatisfy { $1.dts - $0.dts == 1001 })
    }

    @Test("the repaired stream presents every picture exactly once, in order")
    func repairedStreamIsABijection() throws {
        let repaired = try Self.videoTimestamps(base64: Self.missingCTTSFixtureBase64)
        let presentation = repaired.map(\.pts).sorted()
        #expect(Set(presentation).count == repaired.count)
        #expect(zip(presentation, presentation.dropFirst()).allSatisfy { $1 - $0 == 1001 })
        #expect(repaired.allSatisfy { $0.pts >= $0.dts })
        #expect(zip(repaired, repaired.dropFirst()).allSatisfy { $1.dts > $0.dts })
    }

    /// 96x64 H.264 Main, 30000/1001 fps, 66 frames, three B-frames per group, from PR #411.
    ///
    ///     ffmpeg -f lavfi -i 'color=c=red:s=96x64:r=30000/1001:d=2.2' -frames:v 66 \
    ///       -c:v libx264 -preset ultrafast -pix_fmt yuv420p -bf 3 -b_strategy 0 -g 66 \
    ///       -sc_threshold 0 -movflags +faststart healthy.mp4
    ///     ffmpeg -i healthy.mp4 -map 0:v:0 -c:v copy -bsf:v 'setts=pts=DTS' \
    ///       -movflags +faststart missing.mp4
    private static let healthyCTTSFixtureBase64 = """
        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
        b25zOiBjYWJhYz0wIHJlZj0xIGRlYmxvY2s9MDowOjAgYW5hbHlzZT0wOjAgbWU9ZGlhIHN1Ym1lPTAgcHN5PTEgcHN5X3JkPTEu
        MDA6MC4wMCBtaXhlZF9yZWY9MCBtZV9yYW5nZT0xNiBjaHJvbWFfbWU9MSB0cmVsbGlzPTAgOHg4ZGN0PTAgY3FtPTAgZGVhZHpv
        bmU9MjEsMTEgZmFzdF9wc2tpcD0xIGNocm9tYV9xcF9vZmZzZXQ9MCB0aHJlYWRzPTIgbG9va2FoZWFkX3RocmVhZHM9MSBzbGlj
        ZWRfdGhyZWFkcz0wIG5yPTAgZGVjaW1hdGU9MSBpbnRlcmxhY2VkPTAgYmx1cmF5X2NvbXBhdD0wIGNvbnN0cmFpbmVkX2ludHJh
        PTAgYmZyYW1lcz0zIGJfcHlyYW1pZD0yIGJfYWRhcHQ9MCBiX2JpYXM9MCBkaXJlY3Q9MSB3ZWlnaHRiPTAgb3Blbl9nb3A9MCB3
        ZWlnaHRwPTAga2V5aW50PTY2IGtleWludF9taW49NiBzY2VuZWN1dD0wIGludHJhX3JlZnJlc2g9MCByYz1jcmYgbWJ0cmVlPTAg
        Y3JmPTIzLjAgcWNvbXA9MC42MCBxcG1pbj0wIHFwbWF4PTY5IHFwc3RlcD00IGlwX3JhdGlvPTEuNDAgcGJfcmF0aW89MS4zMCBh
        cT0wAIAAAAAmZYiEAOhGKAAIY8cAAQPY4AAh5ScnJycnXXXXXXXXXXXXXXXXXXgAAAAHQZokAOoMwAAAAAdBnkJANoMwAAAABwGe
        YUBdBmAAAAAHAZ5jQF0GYAAAAAhBmmg0QHUGYAAAAAlBnoZFEShtBmAAAAAHAZ6lQGUGYAAAAAcBnqdAZQZgAAAACEGarDRAfQZg
        AAAACUGeykUVKG0GYAAAAAcBnulAZQZgAAAABwGe60BlBmAAAAAIQZrwNEB9BmAAAAAJQZ8ORRUodQZgAAAABwGfLUBlBmAAAAAH
        AZ8vQG0GYAAAAAhBmzQ0QH0GYAAAAAlBn1JFFSh1BmAAAAAHAZ9xQG0GYAAAAAcBn3NAbQZgAAAACEGbeDRAfQZgAAAACUGflkUV
        KHUGYAAAAAcBn7VAbQZgAAAABwGft0BtBmAAAAAIQZu8NEB9BmAAAAAJQZ/aRRUodQZgAAAABwGf+UBtBmAAAAAHAZ/7QG0GYAAA
        AAhBm+A0QH0GYAAAAAlBnh5FFSh1BmAAAAAHAZ49QG0GYAAAAAcBnj9AbQZgAAAACEGaJDRAfQZgAAAACUGeQkUVKHUGYAAAAAcB
        nmFAbQZgAAAABwGeY0BtBmAAAAAIQZpoNEB9BmAAAAAJQZ6GRRUodQZgAAAABwGepUBtBmAAAAAHAZ6nQG0GYAAAAAhBmqw0QH0G
        YAAAAAlBnspFFSh1BmAAAAAHAZ7pQG0GYAAAAAcBnutAbQZgAAAACEGa8DRAfQZgAAAACUGfDkUVKHUGYAAAAAcBny1AbQZgAAAA
        BwGfL0BtBmAAAAAIQZs0NEB9BmAAAAAJQZ9SRRUodQZgAAAABwGfcUBtBmAAAAAHAZ9zQG0GYAAAAAhBm3g0QH0GYAAAAAlBn5ZF
        FSh1BmAAAAAHAZ+1QG0GYAAAAAcBn7dAbQZgAAAACEGbvDRAfQZgAAAACUGf2kUVKHUGYAAAAAcBn/lAbQZgAAAABwGf+0BtBmAA
        AAAIQZvgNEB9BmAAAAAJQZ4eRRUodQZgAAAABwGePUBtBmAAAAAHAZ4/QG0GYAAAAAhBmiE0QH0GYA==
        """

    private static let missingCTTSFixtureBase64 = """
        AAAAIGZ0eXBpc29tAAACAGlzb21pc28yYXZjMW1wNDEAAAQpbW9vdgAAAGxtdmhkAAAAAAAAAAAAAAAAAAAD6AAACFgAAQAAAQAA
        AAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAA
        A1N0cmFrAAAAXHRraGQAAAADAAAAAAAAAAAAAAABAAAAAAAACFgAAAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAA
        AAAAAAAAAAAAAABAAAAAAGAAAABAAAAAAAAkZWR0cwAAABxlbHN0AAAAAAAAAAEAAAhYAAAH0gABAAAAAALLbWRpYQAAACBtZGhk
        AAAAAAAAAAAAAAAAAAB1MAABAhJVxAAAAAAALWhkbHIAAAAAAAAAAHZpZGUAAAAAAAAAAAAAAABWaWRlb0hhbmRsZXIAAAACdm1p
        bmYAAAAUdm1oZAAAAAEAAAAAAAAAAAAAACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAAAQAAAjZzdGJsAAAAtnN0c2QA
        AAAAAAAAAQAAAKZhdmMxAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAGAAQABIAAAASAAAAAAAAAABFUxhdmM2Mi4yOC4xMDIgbGli
        eDI2NAAAAAAAAAAAAAAAGP//AAAALGF2Y0MBTUAK/+EAFWdNQArsoxNgIgAAB9IAAdTAHiRLLAEABGjOD8gAAAAQcGFzcAAAAAEA
        AAABAAAAFGJ0cnQAAAAAAAAU8QAAFPEAAAAYc3R0cwAAAAAAAAABAAAAQgAAA+kAAAAUc3RzcwAAAAAAAAABAAAAAQAAABxzdHNj
        AAAAAAAAAAEAAAABAAAAQgAAAAEAAAEcc3RzegAAAAAAAAAAAAAAQgAAAssAAAALAAAACwAAAAsAAAALAAAADAAAAA0AAAALAAAA
        CwAAAAwAAAANAAAACwAAAAsAAAAMAAAADQAAAAsAAAALAAAADAAAAA0AAAALAAAACwAAAAwAAAANAAAACwAAAAsAAAAMAAAADQAA
        AAsAAAALAAAADAAAAA0AAAALAAAACwAAAAwAAAANAAAACwAAAAsAAAAMAAAADQAAAAsAAAALAAAADAAAAA0AAAALAAAACwAAAAwA
        AAANAAAACwAAAAsAAAAMAAAADQAAAAsAAAALAAAADAAAAA0AAAALAAAACwAAAAwAAAANAAAACwAAAAsAAAAMAAAADQAAAAsAAAAL
        AAAADAAAABRzdGNvAAAAAAAAAAEAAARZAAAAYnVkdGEAAABabWV0YQAAAAAAAAAhaGRscgAAAAAAAAAAbWRpcmFwcGwAAAAAAAAA
        AAAAAAAtaWxzdAAAACWpdG9vAAAAHWRhdGEAAAABAAAAAExhdmY2Mi4xMi4xMDIAAAAIZnJlZQAABcxtZGF0AAACnQYF//+Z3EXp
        vebZSLeWLNgg2SPu73gyNjQgLSBjb3JlIDE2NSByMzIyMiBiMzU2MDVhIC0gSC4yNjQvTVBFRy00IEFWQyBjb2RlYyAtIENvcHls
        ZWZ0IDIwMDMtMjAyNSAtIGh0dHA6Ly93d3cudmlkZW9sYW4ub3JnL3gyNjQuaHRtbCAtIG9wdGlvbnM6IGNhYmFjPTAgcmVmPTEg
        ZGVibG9jaz0wOjA6MCBhbmFseXNlPTA6MCBtZT1kaWEgc3VibWU9MCBwc3k9MSBwc3lfcmQ9MS4wMDowLjAwIG1peGVkX3JlZj0w
        IG1lX3JhbmdlPTE2IGNocm9tYV9tZT0xIHRyZWxsaXM9MCA4eDhkY3Q9MCBjcW09MCBkZWFkem9uZT0yMSwxMSBmYXN0X3Bza2lw
        PTEgY2hyb21hX3FwX29mZnNldD0wIHRocmVhZHM9MiBsb29rYWhlYWRfdGhyZWFkcz0xIHNsaWNlZF90aHJlYWRzPTAgbnI9MCBk
        ZWNpbWF0ZT0xIGludGVybGFjZWQ9MCBibHVyYXlfY29tcGF0PTAgY29uc3RyYWluZWRfaW50cmE9MCBiZnJhbWVzPTMgYl9weXJh
        bWlkPTIgYl9hZGFwdD0wIGJfYmlhcz0wIGRpcmVjdD0xIHdlaWdodGI9MCBvcGVuX2dvcD0wIHdlaWdodHA9MCBrZXlpbnQ9NjYg
        a2V5aW50X21pbj02IHNjZW5lY3V0PTAgaW50cmFfcmVmcmVzaD0wIHJjPWNyZiBtYnRyZWU9MCBjcmY9MjMuMCBxY29tcD0wLjYw
        IHFwbWluPTAgcXBtYXg9NjkgcXBzdGVwPTQgaXBfcmF0aW89MS40MCBwYl9yYXRpbz0xLjMwIGFxPTAAgAAAACZliIQA6EYoAAhj
        xwABA9jgACHlJycnJyddddddddddddddddddeAAAAAdBmiQA6gzAAAAAB0GeQkA2gzAAAAAHAZ5hQF0GYAAAAAcBnmNAXQZgAAAA
        CEGaaDRAdQZgAAAACUGehkURKG0GYAAAAAcBnqVAZQZgAAAABwGep0BlBmAAAAAIQZqsNEB9BmAAAAAJQZ7KRRUobQZgAAAABwGe
        6UBlBmAAAAAHAZ7rQGUGYAAAAAhBmvA0QH0GYAAAAAlBnw5FFSh1BmAAAAAHAZ8tQGUGYAAAAAcBny9AbQZgAAAACEGbNDRAfQZg
        AAAACUGfUkUVKHUGYAAAAAcBn3FAbQZgAAAABwGfc0BtBmAAAAAIQZt4NEB9BmAAAAAJQZ+WRRUodQZgAAAABwGftUBtBmAAAAAH
        AZ+3QG0GYAAAAAhBm7w0QH0GYAAAAAlBn9pFFSh1BmAAAAAHAZ/5QG0GYAAAAAcBn/tAbQZgAAAACEGb4DRAfQZgAAAACUGeHkUV
        KHUGYAAAAAcBnj1AbQZgAAAABwGeP0BtBmAAAAAIQZokNEB9BmAAAAAJQZ5CRRUodQZgAAAABwGeYUBtBmAAAAAHAZ5jQG0GYAAA
        AAhBmmg0QH0GYAAAAAlBnoZFFSh1BmAAAAAHAZ6lQG0GYAAAAAcBnqdAbQZgAAAACEGarDRAfQZgAAAACUGeykUVKHUGYAAAAAcB
        nulAbQZgAAAABwGe60BtBmAAAAAIQZrwNEB9BmAAAAAJQZ8ORRUodQZgAAAABwGfLUBtBmAAAAAHAZ8vQG0GYAAAAAhBmzQ0QH0G
        YAAAAAlBn1JFFSh1BmAAAAAHAZ9xQG0GYAAAAAcBn3NAbQZgAAAACEGbeDRAfQZgAAAACUGflkUVKHUGYAAAAAcBn7VAbQZgAAAA
        BwGft0BtBmAAAAAIQZu8NEB9BmAAAAAJQZ/aRRUodQZgAAAABwGf+UBtBmAAAAAHAZ/7QG0GYAAAAAhBm+A0QH0GYAAAAAlBnh5F
        FSh1BmAAAAAHAZ49QG0GYAAAAAcBnj9AbQZgAAAACEGaITRAfQZg
        """

    // MARK: - a cadence that does not land on whole ticks

    /// #409's retest asset. It is constant rate, but a picture is not a whole number of ticks long,
    /// so the sample table alternates between the two neighbouring counts: at `time_base=1/1200000`
    /// the pictures are `200202/5` ticks apart and the ladder repeats `40041,40040,40040,40041,40040`.
    /// Nothing about the defect changed, only the ladder the repair has to read, and a classifier
    /// that demanded one identical step left the file exactly as broken as it found it.
    private func quantizedLadderSamples() -> [H264CompositionOffsetRepair.Sample] {
        let ladder: [Int64] = [
            -80081, -40040, 0, 40040, 80081, 120121, 160162, 200202, 240242, 280283, 320323, 360364,
        ]
        let pocs: [Int64] = [0, 8, 4, 2, 6, 16, 12, 10, 14, 24, 20, 18]
        return zip(ladder, pocs).enumerated().map { index, pair in
            H264CompositionOffsetRepair.Sample(
                dts: pair.0, pts: pair.0, pictureOrderCount: pair.1, isKeyframe: index == 0)
        }
    }

    @Test("a ladder quantized from a fractional cadence is repaired, not called nonuniform")
    func quantizedLadderIsRepaired() {
        let verdict = verdict(
            quantizedLadderSamples(), videoDelay: 2, streamStartTime: 0, ladderStart: -80081)
        guard case .repair(let plan) = verdict else {
            Issue.record("expected a repair, got \(verdict)")
            return
        }
        #expect(plan.cadence == H264CompositionOffsetRepair.Cadence(numerator: 200202, denominator: 5))
        #expect(plan.decodeLead == 80081)
        #expect(plan.shift == 80081)
        #expect(plan.pocStep == 2)
        // The ladder starts on phase 3 of the five-picture period, and the container's retained edit
        // list puts presentation one whole reorder head above it.
        #expect(plan.ladderPhase == 3)
        #expect(plan.ladderOrdinalOffset == 2)
        // Which lands the axis where the healthy twin writes it: the first picture at zero.
        #expect(plan.presentationTimestamp(ordinal: 0) == 0)
        #expect(plan.presentationTimestamp(ordinal: 1) == 40040)
    }

    @Test("the fractional plan reproduces the presentation lattice, including across a sequence")
    func quantizedPlanFollowsTheLattice() {
        guard case .repair(let plan) = verdict(
            quantizedLadderSamples(), videoDelay: 2, streamStartTime: 0, ladderStart: -80081) else {
            Issue.record("expected a repair")
            return
        }
        var rewriter = H264CompositionOffsetRepair.Rewriter(plan: plan)
        // The head, against the healthy twin's first pictures.
        #expect(rewriter.rewrite(dts: -80081, pictureOrderCount: 0, isKeyframe: true).map(\.pts) == 0)
        #expect(rewriter.rewrite(dts: -40040, pictureOrderCount: 8, isKeyframe: false).map(\.pts) == 160162)
        #expect(rewriter.rewrite(dts: 0, pictureOrderCount: 4, isKeyframe: false).map(\.pts) == 80081)
        // A second coded video sequence starts on a ladder point whose distance from the first is
        // not a whole multiple of any integer step. Read back from the lattice it still lands on
        // the twin's timestamp; counted in rounded steps it would be a tick out.
        rewriter.noteSeek()
        #expect(rewriter.rewrite(dts: 560566, pictureOrderCount: 0, isKeyframe: true).map(\.pts) == 640646)
        #expect(rewriter.rewrite(dts: 600606, pictureOrderCount: 8, isKeyframe: false).map(\.pts) == 800808)
    }

    @Test("a sequence the lattice cannot place is still repaired, by the rounded step")
    func offLatticeSequenceFallsBackToTheStep() {
        guard case .repair(let plan) = verdict(
            quantizedLadderSamples(), videoDelay: 2, streamStartTime: 0, ladderStart: -80081) else {
            Issue.record("expected a repair")
            return
        }
        var rewriter = H264CompositionOffsetRepair.Rewriter(plan: plan)
        rewriter.noteSeek()
        // A sequence opening one tick beside the lattice: the ladder has stopped describing itself.
        // The rounded step still describes it to within a tick, and it anchors on the container's own
        // timestamp, so it cannot drift. Handing the picture on in decode order would be the defect.
        let head = rewriter.rewrite(dts: 560567, pictureOrderCount: 0, isKeyframe: true)
        #expect(head?.pts == 640648)
        #expect(head?.dts == 560567)
        #expect(rewriter.rewrite(dts: 600607, pictureOrderCount: 8, isKeyframe: false)?.pts == 800808)
        #expect(rewriter.unrepairedPictures == 0)
    }

    @Test("a sample taken away from the head describes the same axis as one taken at it")
    func quantizedLadderClassifiesFromAnywhere() {
        // The same fixture, sampled from its second IDR instead of its first. The ladder starts on a
        // different phase of the five-picture cycle there, and a repair that assumed the head would
        // place every picture a tick beside the twin, or refuse the file outright.
        let ladder: [Int64] = [
            560566, 600606, 640646, 680687, 720727, 760768, 800808, 840848, 880889, 920929, 960970,
            1001010,
        ]
        let pocs: [Int64] = [0, 8, 4, 2, 6, 16, 12, 10, 14, 24, 20, 18]
        let samples = zip(ladder, pocs).enumerated().map { index, pair in
            H264CompositionOffsetRepair.Sample(
                dts: pair.0, pts: pair.0, pictureOrderCount: pair.1, isKeyframe: index == 0)
        }
        guard case .repair(let plan) = verdict(
            samples, videoDelay: 2, streamStartTime: 0, ladderStart: -80081) else {
            Issue.record("a sample away from the head must still classify")
            return
        }
        #expect(plan.ladderPhase == 4)
        var rewriter = H264CompositionOffsetRepair.Rewriter(plan: plan)
        // The healthy twin's timestamps for those same three pictures.
        #expect(rewriter.rewrite(dts: 560566, pictureOrderCount: 0, isKeyframe: true).map(\.pts) == 640646)
        #expect(rewriter.rewrite(dts: 600606, pictureOrderCount: 8, isKeyframe: false).map(\.pts) == 800808)
        #expect(rewriter.rewrite(dts: 640646, pictureOrderCount: 4, isKeyframe: false).map(\.pts) == 720727)
    }

    @Test("a fractional ladder left on the presentation axis needs no shift either")
    func quantizedLadderOnPresentationAxis() {
        // The other writer shape, and the container is the only thing that says which one it is: the
        // same ladder lifted to non-negative timestamps, reporting a start time on its own head.
        let ladder: [Int64] = [
            0, 40041, 80081, 120121, 160162, 200202, 240243, 280283, 320323, 360364, 400404, 440445,
        ]
        let pocs: [Int64] = [0, 8, 4, 2, 6, 16, 12, 10, 14, 24, 20, 18]
        let samples = zip(ladder, pocs).enumerated().map { index, pair in
            H264CompositionOffsetRepair.Sample(
                dts: pair.0, pts: pair.0, pictureOrderCount: pair.1, isKeyframe: index == 0)
        }
        guard case .repair(let plan) = verdict(
            samples, videoDelay: 2, streamStartTime: 0, ladderStart: 0) else {
            Issue.record("expected a repair")
            return
        }
        #expect(plan.shift == 0)
        #expect(plan.ladderOrdinalOffset == 0)
        #expect(plan.decodeLead == 80081)
        var rewriter = H264CompositionOffsetRepair.Rewriter(plan: plan)
        let head = rewriter.rewrite(dts: 0, pictureOrderCount: 0, isKeyframe: true)
        #expect(head?.pts == 0)
        #expect(head?.dts == -80081)
    }

    @Test("a ladder that wobbles by a tick without repeating is left alone")
    func nonRepeatingWobbleIsNotACadence() {
        let ladder: [Int64] = [0, 40040, 80081, 120121, 160161, 200202, 240242, 280282, 320323, 360364, 400404, 440445]
        let pocs: [Int64] = [0, 8, 4, 2, 6, 16, 12, 10, 14, 24, 20, 18]
        let samples = zip(ladder, pocs).enumerated().map { index, pair in
            H264CompositionOffsetRepair.Sample(
                dts: pair.0, pts: pair.0, pictureOrderCount: pair.1, isKeyframe: index == 0)
        }
        guard case .inconclusive = verdict(samples, videoDelay: 2, streamStartTime: 0, ladderStart: 0) else {
            Issue.record("a ladder with no repeating cycle must not be repaired")
            return
        }
    }

    @Test("a ladder with a dropped picture is left alone")
    func droppedPictureIsNotACadence() {
        let ladder: [Int64] = [0, 40040, 80081, 120121, 160162, 240242, 280283, 320323, 360364, 400404, 440444, 480485]
        let pocs: [Int64] = [0, 8, 4, 2, 6, 16, 12, 10, 14, 24, 20, 18]
        let samples = zip(ladder, pocs).enumerated().map { index, pair in
            H264CompositionOffsetRepair.Sample(
                dts: pair.0, pts: pair.0, pictureOrderCount: pair.1, isKeyframe: index == 0)
        }
        guard case .inconclusive = verdict(samples, videoDelay: 2, streamStartTime: 0, ladderStart: 0) else {
            Issue.record("a two-tick gap is not a quantization")
            return
        }
    }

    @Test("the fractional twin carries the healthy twin's timestamps, packet for packet")
    func repairedRationalTwinMatchesHealthyTwin() throws {
        let healthy = try Self.videoTimestamps(base64: Self.healthyRationalFixtureBase64)
        let repaired = try Self.videoTimestamps(base64: Self.missingRationalFixtureBase64)
        #expect(healthy.count == 33)
        #expect(repaired.count == healthy.count)
        #expect(repaired == healthy)
    }

    @Test("the fractional healthy twin is delivered exactly as the container wrote it")
    func rationalHealthyTwinIsUntouched() throws {
        let healthy = try Self.videoTimestamps(base64: Self.healthyRationalFixtureBase64)
        #expect(healthy.first == Timestamps(pts: 0, dts: -80081))
        #expect(healthy.contains { $0.pts != $0.dts })
        // The point of this pair: the decode ladder does not advance by one constant.
        let steps = Set(zip(healthy, healthy.dropFirst()).map { $1.dts - $0.dts })
        #expect(steps == [40040, 40041])
    }

    @Test("the repaired fractional stream presents every picture exactly once, in order")
    func repairedRationalStreamIsABijection() throws {
        let repaired = try Self.videoTimestamps(base64: Self.missingRationalFixtureBase64)
        let presentation = repaired.map(\.pts).sorted()
        #expect(Set(presentation).count == repaired.count)
        #expect(Set(zip(presentation, presentation.dropFirst()).map { $1 - $0 }) == [40040, 40041])
        #expect(repaired.allSatisfy { $0.pts >= $0.dts })
        #expect(zip(repaired, repaired.dropFirst()).allSatisfy { $1.dts > $0.dts })
    }

    /// 96x64 H.264, 33 frames at 1000000/33367 fps in a 1200000 timescale, so a picture is 200202/5
    /// ticks long and the sample table has to quantize it. Three B pictures per group, a keyframe
    /// every 16, and the composition offsets stream-copied away in the second file, the same way
    /// @orut34iop's original pair was made.
    ///
    ///     ffmpeg -f lavfi -i 'color=c=gray:s=96x64:rate=1000000/33367' -frames:v 33 \
    ///       -c:v libx264 -preset ultrafast -pix_fmt yuv420p -bf 3 -b_strategy 0 -g 16 \
    ///       -sc_threshold 0 -crf 40 -video_track_timescale 1200000 -r 1000000/33367 \
    ///       -movflags +faststart healthy.mp4
    ///     ffmpeg -i healthy.mp4 -map 0:v:0 -c:v copy -bsf:v 'setts=pts=DTS' \
    ///       -movflags +faststart missing.mp4

    private static let healthyRationalFixtureBase64 = """
        AAAAIGZ0eXBpc29tAAACAGlzb21pc28yYXZjMW1wNDEAAAWObW9vdgAAAGxtdmhkAAAAAAAAAAAAAAAAAAAD6AAABE4AAQ
        AAAQAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
        AAAAAAAAAgAABLh0cmFrAAAAXHRraGQAAAADAAAAAAAAAAAAAAABAAAAAAAABE4AAAAAAAAAAAAAAAAAAAAAAAEAAAAAAA
        AAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAGAAAABAAAAAAAAkZWR0cwAAABxlbHN0AAAAAAAAAAEAAAROAAE40QAB
        AAAAAAQwbWRpYQAAACBtZGhkAAAAAAAAAAAAAAAAABJPgAAUKXVVxAAAAAAALWhkbHIAAAAAAAAAAHZpZGUAAAAAAAAAAA
        AAAABWaWRlb0hhbmRsZXIAAAAD221pbmYAAAAUdm1oZAAAAAEAAAAAAAAAAAAAACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAA
        AAx1cmwgAAAAAQAAA5tzdGJsAAAAt3N0c2QAAAAAAAAAAQAAAKdhdmMxAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAGAAQA
        BIAAAASAAAAAAAAAABFUxhdmM2Mi4yOC4xMDEgbGlieDI2NAAAAAAAAAAAAAAAGP//AAAALWF2Y0MBTUAK/+EAFWdNQArs
        oxNgIgABBK4APQkAHiRLLAEABWjOA5yAAAAAEHBhc3AAAAABAAAAAQAAABRidHJ0AAAAAAAAH48AAAAAAAAA4HN0dHMAAA
        AAAAAAGgAAAAEAAJxpAAAAAgAAnGgAAAABAACcaQAAAAEAAJxoAAAAAQAAnGkAAAACAACcaAAAAAEAAJxpAAAAAQAAnGgA
        AAABAACcaQAAAAIAAJxoAAAAAQAAnGkAAAABAACcaAAAAAEAAJxpAAAAAgAAnGgAAAABAACcaQAAAAEAAJxoAAAAAQAAnG
        kAAAACAACcaAAAAAEAAJxpAAAAAQAAnGgAAAABAACcaQAAAAIAAJxoAAAAAQAAnGkAAAABAACcaAAAAAEAAJxpAAAAAgAA
        nGgAAAAcc3RzcwAAAAAAAAADAAAAAQAAABEAAAAhAAABGGN0dHMAAAAAAAAAIQAAAAEAATjRAAAAAQADDgoAAAABAAE40Q
        AAAAEAAAAAAAAAAQAAnGgAAAABAAMOCgAAAAEAATjQAAAAAQAAAAAAAAABAACcaQAAAAEAAw4KAAAAAQABONEAAAABAAAA
        AAAAAAEAAJxoAAAAAQACcaIAAAABAACcaAAAAAEAAJxpAAAAAQABONAAAAABAAMOCgAAAAEAATjRAAAAAQAAAAAAAAABAA
        CcaQAAAAEAAw4KAAAAAQABONEAAAABAAAAAAAAAAEAAJxoAAAAAQADDgoAAAABAAE40AAAAAEAAAAAAAAAAQAAnGkAAAAB
        AAJxoQAAAAEAAJxpAAAAAQAAnGgAAAABAAE40QAAABxzdHNjAAAAAAAAAAEAAAABAAAAIQAAAAEAAACYc3RzegAAAAAAAA
        AAAAAAIQAAAr4AAAALAAAACwAAAAsAAAALAAAADAAAAA0AAAALAAAACwAAAAwAAAANAAAACwAAAAsAAAAMAAAADQAAAAsA
        AAAfAAAACwAAAAsAAAALAAAACwAAAAwAAAANAAAACwAAAAsAAAAMAAAADQAAAAsAAAALAAAADAAAAA0AAAALAAAAHwAAAB
        RzdGNvAAAAAAAAAAEAAAW+AAAAYnVkdGEAAABabWV0YQAAAAAAAAAhaGRscgAAAAAAAAAAbWRpcmFwcGwAAAAAAAAAAAAA
        AAAtaWxzdAAAACWpdG9vAAAAHWRhdGEAAAABAAAAAExhdmY2Mi4xMi4xMDEAAAAIZnJlZQAABGBtZGF0AAACnQYF//+Z3E
        XpvebZSLeWLNgg2SPu73gyNjQgLSBjb3JlIDE2NSByMzIyMiBiMzU2MDVhIC0gSC4yNjQvTVBFRy00IEFWQyBjb2RlYyAt
        IENvcHlsZWZ0IDIwMDMtMjAyNSAtIGh0dHA6Ly93d3cudmlkZW9sYW4ub3JnL3gyNjQuaHRtbCAtIG9wdGlvbnM6IGNhYm
        FjPTAgcmVmPTEgZGVibG9jaz0wOjA6MCBhbmFseXNlPTA6MCBtZT1kaWEgc3VibWU9MCBwc3k9MSBwc3lfcmQ9MS4wMDow
        LjAwIG1peGVkX3JlZj0wIG1lX3JhbmdlPTE2IGNocm9tYV9tZT0xIHRyZWxsaXM9MCA4eDhkY3Q9MCBjcW09MCBkZWFkem
        9uZT0yMSwxMSBmYXN0X3Bza2lwPTEgY2hyb21hX3FwX29mZnNldD0wIHRocmVhZHM9MiBsb29rYWhlYWRfdGhyZWFkcz0x
        IHNsaWNlZF90aHJlYWRzPTAgbnI9MCBkZWNpbWF0ZT0xIGludGVybGFjZWQ9MCBibHVyYXlfY29tcGF0PTAgY29uc3RyYW
        luZWRfaW50cmE9MCBiZnJhbWVzPTMgYl9weXJhbWlkPTIgYl9hZGFwdD0wIGJfYmlhcz0wIGRpcmVjdD0xIHdlaWdodGI9
        MCBvcGVuX2dvcD0wIHdlaWdodHA9MCBrZXlpbnQ9MTYga2V5aW50X21pbj0xIHNjZW5lY3V0PTAgaW50cmFfcmVmcmVzaD
        0wIHJjPWNyZiBtYnRyZWU9MCBjcmY9NDAuMCBxY29tcD0wLjYwIHFwbWluPTAgcXBtYXg9NjkgcXBzdGVwPTQgaXBfcmF0
        aW89MS40MCBwYl9yYXRpbz0xLjMwIGFxPTAAgAAAABlliIQA6JuTk5OTk6666666666666666668AAAAB0GaJADqDMAAAA
        AHQZ5CQDaDMAAAAAcBnmFAXQZgAAAABwGeY0BdBmAAAAAIQZpoNEB1BmAAAAAJQZ6GRREobQZgAAAABwGepUBlBmAAAAAH
        AZ6nQGUGYAAAAAhBmqw0QH0GYAAAAAlBnspFFShtBmAAAAAHAZ7pQGUGYAAAAAcBnutAZQZgAAAACEGa7zRAfQZgAAAACU
        GfDUUVKHUGYAAAAAcBny5AZQZgAAAAG2WIggAPomKMnJycnJ1111111111111111114AAAAAdBmiQA6gzAAAAAB0GeQkA2
        gzAAAAAHAZ5hQGUGYAAAAAcBnmNAZQZgAAAACEGaaDRAdQZgAAAACUGehkURKG0GYAAAAAcBnqVAZQZgAAAABwGep0BlBm
        AAAAAIQZqsNEB9BmAAAAAJQZ7KRRUobQZgAAAABwGe6UBlBmAAAAAHAZ7rQGUGYAAAAAhBmu80QH0GYAAAAAlBnw1FFSh1
        BmAAAAAHAZ8uQG0GYAAAABtliIQAEKJijJycnJyddddddddddddddddddeA=
        """

    private static let missingRationalFixtureBase64 = """
        AAAAIGZ0eXBpc29tAAACAGlzb21pc28yYXZjMW1wNDEAAAR2bW9vdgAAAGxtdmhkAAAAAAAAAAAAAAAAAAAD6AAABAsAAQ
        AAAQAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
        AAAAAAAAAgAAA6B0cmFrAAAAXHRraGQAAAADAAAAAAAAAAAAAAABAAAAAAAABAsAAAAAAAAAAAAAAAAAAAAAAAEAAAAAAA
        AAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAGAAAABAAAAAAAAkZWR0cwAAABxlbHN0AAAAAAAAAAEAAAQLAAE40QAB
        AAAAAAMYbWRpYQAAACBtZGhkAAAAAAAAAAAAAAAAABJPgAAUKXVVxAAAAAAALWhkbHIAAAAAAAAAAHZpZGUAAAAAAAAAAA
        AAAABWaWRlb0hhbmRsZXIAAAACw21pbmYAAAAUdm1oZAAAAAEAAAAAAAAAAAAAACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAA
        AAx1cmwgAAAAAQAAAoNzdGJsAAAAt3N0c2QAAAAAAAAAAQAAAKdhdmMxAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAGAAQA
        BIAAAASAAAAAAAAAABFUxhdmM2Mi4yOC4xMDEgbGlieDI2NAAAAAAAAAAAAAAAGP//AAAALWF2Y0MBTUAK/+EAFWdNQArs
        oxNgIgABBK4APQkAHiRLLAEABWjOA5yAAAAAEHBhc3AAAAABAAAAAQAAABRidHJ0AAAAAAAAH48AAB+PAAAA4HN0dHMAAA
        AAAAAAGgAAAAEAAJxpAAAAAgAAnGgAAAABAACcaQAAAAEAAJxoAAAAAQAAnGkAAAACAACcaAAAAAEAAJxpAAAAAQAAnGgA
        AAABAACcaQAAAAIAAJxoAAAAAQAAnGkAAAABAACcaAAAAAEAAJxpAAAAAgAAnGgAAAABAACcaQAAAAEAAJxoAAAAAQAAnG
        kAAAACAACcaAAAAAEAAJxpAAAAAQAAnGgAAAABAACcaQAAAAIAAJxoAAAAAQAAnGkAAAABAACcaAAAAAEAAJxpAAAAAgAA
        nGgAAAAcc3RzcwAAAAAAAAADAAAAAQAAABEAAAAhAAAAHHN0c2MAAAAAAAAAAQAAAAEAAAAhAAAAAQAAAJhzdHN6AAAAAA
        AAAAAAAAAhAAACvgAAAAsAAAALAAAACwAAAAsAAAAMAAAADQAAAAsAAAALAAAADAAAAA0AAAALAAAACwAAAAwAAAANAAAA
        CwAAAB8AAAALAAAACwAAAAsAAAALAAAADAAAAA0AAAALAAAACwAAAAwAAAANAAAACwAAAAsAAAAMAAAADQAAAAsAAAAfAA
        AAFHN0Y28AAAAAAAAAAQAABKYAAABidWR0YQAAAFptZXRhAAAAAAAAACFoZGxyAAAAAAAAAABtZGlyYXBwbAAAAAAAAAAA
        AAAAAC1pbHN0AAAAJal0b28AAAAdZGF0YQAAAAEAAAAATGF2ZjYyLjEyLjEwMQAAAAhmcmVlAAAEYG1kYXQAAAKdBgX//5
        ncRem95tlIt5Ys2CDZI+7veDI2NCAtIGNvcmUgMTY1IHIzMjIyIGIzNTYwNWEgLSBILjI2NC9NUEVHLTQgQVZDIGNvZGVj
        IC0gQ29weWxlZnQgMjAwMy0yMDI1IC0gaHR0cDovL3d3dy52aWRlb2xhbi5vcmcveDI2NC5odG1sIC0gb3B0aW9uczogY2
        FiYWM9MCByZWY9MSBkZWJsb2NrPTA6MDowIGFuYWx5c2U9MDowIG1lPWRpYSBzdWJtZT0wIHBzeT0xIHBzeV9yZD0xLjAw
        OjAuMDAgbWl4ZWRfcmVmPTAgbWVfcmFuZ2U9MTYgY2hyb21hX21lPTEgdHJlbGxpcz0wIDh4OGRjdD0wIGNxbT0wIGRlYW
        R6b25lPTIxLDExIGZhc3RfcHNraXA9MSBjaHJvbWFfcXBfb2Zmc2V0PTAgdGhyZWFkcz0yIGxvb2thaGVhZF90aHJlYWRz
        PTEgc2xpY2VkX3RocmVhZHM9MCBucj0wIGRlY2ltYXRlPTEgaW50ZXJsYWNlZD0wIGJsdXJheV9jb21wYXQ9MCBjb25zdH
        JhaW5lZF9pbnRyYT0wIGJmcmFtZXM9MyBiX3B5cmFtaWQ9MiBiX2FkYXB0PTAgYl9iaWFzPTAgZGlyZWN0PTEgd2VpZ2h0
        Yj0wIG9wZW5fZ29wPTAgd2VpZ2h0cD0wIGtleWludD0xNiBrZXlpbnRfbWluPTEgc2NlbmVjdXQ9MCBpbnRyYV9yZWZyZX
        NoPTAgcmM9Y3JmIG1idHJlZT0wIGNyZj00MC4wIHFjb21wPTAuNjAgcXBtaW49MCBxcG1heD02OSBxcHN0ZXA9NCBpcF9y
        YXRpbz0xLjQwIHBiX3JhdGlvPTEuMzAgYXE9MACAAAAAGWWIhADom5OTk5OTrrrrrrrrrrrrrrrrrrwAAAAHQZokAOoMwA
        AAAAdBnkJANoMwAAAABwGeYUBdBmAAAAAHAZ5jQF0GYAAAAAhBmmg0QHUGYAAAAAlBnoZFEShtBmAAAAAHAZ6lQGUGYAAA
        AAcBnqdAZQZgAAAACEGarDRAfQZgAAAACUGeykUVKG0GYAAAAAcBnulAZQZgAAAABwGe60BlBmAAAAAIQZrvNEB9BmAAAA
        AJQZ8NRRUodQZgAAAABwGfLkBlBmAAAAAbZYiCAA+iYoycnJycnXXXXXXXXXXXXXXXXXXgAAAAB0GaJADqDMAAAAAHQZ5C
        QDaDMAAAAAcBnmFAZQZgAAAABwGeY0BlBmAAAAAIQZpoNEB1BmAAAAAJQZ6GRREobQZgAAAABwGepUBlBmAAAAAHAZ6nQG
        UGYAAAAAhBmqw0QH0GYAAAAAlBnspFFShtBmAAAAAHAZ7pQGUGYAAAAAcBnutAZQZgAAAACEGa7zRAfQZgAAAACUGfDUUV
        KHUGYAAAAAcBny5AbQZgAAAAG2WIhAAQomKMnJycnJ1111111111111111114A==
        """
}
