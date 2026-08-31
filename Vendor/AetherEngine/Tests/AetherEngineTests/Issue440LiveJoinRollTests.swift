import AVFoundation
import Testing
@testable import AetherEngine

/// AE#440: a live join presents its first frame and can then hold it perfectly still for seconds while
/// AVPlayer decides whether to let the rate roll. Two halves are pinned here: which phase a host sees
/// across that hold, and when the engine is allowed to cut it short.
@Suite("AE#440 live join: intent, motion, and the stall-avoidance hold")
struct Issue440LiveJoinRollTests {

    // MARK: - The phase across the hold

    /// The report's exact shape: the autostart has written `state = .playing`, AVPlayer has the picture
    /// up and is holding it, and nothing has moved yet. `.playing` here is what dropped a host's spinner
    /// 2.7 s before motion.
    @Test("an autostart that has not rolled yet reads as loading, not playing")
    func startedButNotRolledIsLoading() {
        #expect(PlaybackPhase.derive(state: .playing, isBuffering: false, isSeeking: false,
                                     stall: .flowing, transportHasRolled: false) == .loading)
    }

    /// The wait publishes `isBuffering` too, and a start is not a RE-buffer: `.rebuffering` is reserved
    /// for an underrun after playback existed, so the axis that names the hold has to be the roll.
    @Test("a buffering start before the first roll is still loading")
    func bufferingBeforeFirstRollIsLoading() {
        #expect(PlaybackPhase.derive(state: .playing, isBuffering: true, isSeeking: false,
                                     stall: .flowing, transportHasRolled: false) == .loading)
    }

    @Test("the same buffering, once the transport has rolled, is a rebuffer")
    func bufferingAfterFirstRollIsRebuffering() {
        #expect(PlaybackPhase.derive(state: .playing, isBuffering: true, isSeeking: false,
                                     stall: .flowing, transportHasRolled: true) == .rebuffering)
    }

    @Test("the roll itself is the edge to .playing")
    func rollIsThePlayingEdge() {
        #expect(PlaybackPhase.derive(state: .playing, isBuffering: false, isSeeking: false,
                                     stall: .flowing, transportHasRolled: true) == .playing)
    }

    /// A paused mount (`autoplay: false`) never rolls and must not read as a session still arriving:
    /// it is honestly not playing.
    @Test("a paused mount that never rolled is paused, not loading")
    func pausedMountStaysPaused() {
        #expect(PlaybackPhase.derive(state: .paused, isBuffering: false, isSeeking: false,
                                     stall: .flowing, transportHasRolled: false) == .paused)
    }

    /// The reader axis is about the SOURCE and outranks everything below it (#410); a join over a dead
    /// origin must keep saying so rather than reporting a startup that is merely slow.
    @Test("a dead source outranks the not-yet-rolled start")
    func stallOutranksNotRolled() {
        #expect(PlaybackPhase.derive(state: .playing, isBuffering: true, isSeeking: false,
                                     stall: .reconnecting, transportHasRolled: false)
                == .stalled(reconnecting: true))
    }

    /// A host seek during the start is a host action and stays visible, as it is after the roll.
    @Test("a seek during the start still reads as seeking")
    func seekOutranksNotRolled() {
        #expect(PlaybackPhase.derive(state: .playing, isBuffering: false, isSeeking: true,
                                     stall: .flowing, transportHasRolled: false) == .seeking)
    }

    @Test("terminal states ignore the roll axis entirely")
    func terminalStatesUnaffected() {
        #expect(PlaybackPhase.derive(state: .ended, isBuffering: false, isSeeking: false,
                                     stall: .flowing, transportHasRolled: false) == .ended)
        #expect(PlaybackPhase.derive(state: .error("boom"), isBuffering: false, isSeeking: false,
                                     stall: .flowing, transportHasRolled: false) == .error("boom"))
        #expect(PlaybackPhase.derive(state: .idle, isBuffering: false, isSeeking: false,
                                     stall: .flowing, transportHasRolled: false) == .idle)
    }

    // MARK: - When the hold may be cut short

    @Test("the armed join holding on a non-empty buffer is the case this exists for")
    func firesOnTheHold() {
        #expect(NativeAVPlayerHost.shouldStartLiveJoinImmediately(
            armed: true, alreadySpent: false, hostWantsToPlay: true,
            isWaitingToMinimizeStalls: true, playbackBufferEmpty: false, bufferedAheadSeconds: 4.0))
    }

    @Test("never without the opt-in")
    func offByDefault() {
        #expect(!NativeAVPlayerHost.shouldStartLiveJoinImmediately(
            armed: false, alreadySpent: false, hostWantsToPlay: true,
            isWaitingToMinimizeStalls: true, playbackBufferEmpty: false, bufferedAheadSeconds: 4.0))
    }

    /// One shot, and it belongs to the join. Past it AVPlayer's stall policy is the right one: a live
    /// channel that runs dry mid-stream should wait rather than spin at rate 1 over nothing.
    @Test("a spent one-shot never fires again in the session")
    func onceOnly() {
        #expect(!NativeAVPlayerHost.shouldStartLiveJoinImmediately(
            armed: true, alreadySpent: true, hostWantsToPlay: true,
            isWaitingToMinimizeStalls: true, playbackBufferEmpty: false, bufferedAheadSeconds: 4.0))
    }

    /// An empty buffer is the documented failure shape: `AVPlayer.h` says the call then behaves as if
    /// the buffer had emptied during playback, which is what parks rate at 0 and never resumes.
    @Test("never over an empty buffer")
    func refusesEmptyBuffer() {
        #expect(!NativeAVPlayerHost.shouldStartLiveJoinImmediately(
            armed: true, alreadySpent: false, hostWantsToPlay: true,
            isWaitingToMinimizeStalls: true, playbackBufferEmpty: true, bufferedAheadSeconds: 0.0))
    }

    /// `EvaluatingBufferingRate` is the brief monitoring period Apple documents as not worth showing a
    /// spinner for. Firing there would preempt an evaluation about to start playback by itself.
    @Test("never while AVPlayer is only evaluating its buffering rate")
    func refusesEvaluatingReason() {
        #expect(!NativeAVPlayerHost.shouldStartLiveJoinImmediately(
            armed: true, alreadySpent: false, hostWantsToPlay: true,
            isWaitingToMinimizeStalls: false, playbackBufferEmpty: false, bufferedAheadSeconds: 4.0))
    }

    /// A host that paused during the join asked for a still picture; overriding into motion would
    /// resurrect a session the host put down.
    @Test("never against a host that does not want to play")
    func refusesWithoutPlayIntent() {
        #expect(!NativeAVPlayerHost.shouldStartLiveJoinImmediately(
            armed: true, alreadySpent: false, hostWantsToPlay: false,
            isWaitingToMinimizeStalls: true, playbackBufferEmpty: false, bufferedAheadSeconds: 4.0))
    }

    /// The reason string the host compares against is AVFoundation's own, not a literal of ours.
    @Test("the hold is identified by AVFoundation's own reason constant")
    func reasonConstantIsTheOneAVPlayerPublishes() {
        #expect(AVPlayer.WaitingReason.toMinimizeStalls.rawValue
                == "AVPlayerWaitingToMinimizeStallsReason")
    }

    /// The device A/B that settled this (AE#440, 6.53.0) sampled the buffer across every hold in the
    /// control run and found `empty=false` with 3.7 to 4.9 s ahead of the playhead, for the hold's whole
    /// duration. That is the shape the lever is for: AVPlayer holds a real cushion while it waits on its
    /// own rate estimate, so starting on it costs nothing (0 stalls, 0 drops, 10 of 10 zaps).
    @Test("the depth measured on hardware across the real hold is allowed through")
    func firesAtTheDepthMeasuredOnDevice() {
        for ahead in [3.7, 4.0, 4.9] {
            #expect(NativeAVPlayerHost.shouldStartLiveJoinImmediately(
                armed: true, alreadySpent: false, hostWantsToPlay: true,
                isWaitingToMinimizeStalls: true, playbackBufferEmpty: false,
                bufferedAheadSeconds: ahead))
        }
    }

    /// `isPlaybackBufferEmpty` is the documented MINIMUM from `AVPlayer.h`, not a measure of safety: a
    /// single served fragment reads `false` exactly as a four-second cushion does. Behind that boolean
    /// the device run found 3.7 s; behind the same boolean a starved join can hold 0.2 s, and cutting
    /// the wait short there trades a still picture for an immediate stall. The depth is what separates
    /// them, so the depth is what the guard reads.
    @Test("a non-empty buffer that is only a fragment is still refused")
    func refusesAFragment() {
        for ahead in [0.0, 0.2, 0.9, 1.4] {
            #expect(!NativeAVPlayerHost.shouldStartLiveJoinImmediately(
                armed: true, alreadySpent: false, hostWantsToPlay: true,
                isWaitingToMinimizeStalls: true, playbackBufferEmpty: false,
                bufferedAheadSeconds: ahead))
        }
    }

    @Test("the threshold itself is inclusive, so a cushion exactly at the floor may start")
    func thresholdIsInclusive() {
        #expect(NativeAVPlayerHost.shouldStartLiveJoinImmediately(
            armed: true, alreadySpent: false, hostWantsToPlay: true,
            isWaitingToMinimizeStalls: true, playbackBufferEmpty: false,
            bufferedAheadSeconds: NativeAVPlayerHost.minimumLiveJoinBufferAhead))
    }

    /// A non-finite reading is an absent one. `currentTime()` on an item that has not resolved yields
    /// NaN, and NaN fails every comparison silently, so it must be rejected explicitly rather than by
    /// falling through a `>=`.
    @Test("a non-finite depth is refused rather than compared")
    func refusesNonFiniteDepth() {
        #expect(!NativeAVPlayerHost.shouldStartLiveJoinImmediately(
            armed: true, alreadySpent: false, hostWantsToPlay: true,
            isWaitingToMinimizeStalls: true, playbackBufferEmpty: false,
            bufferedAheadSeconds: .nan))
        #expect(!NativeAVPlayerHost.shouldStartLiveJoinImmediately(
            armed: true, alreadySpent: false, hostWantsToPlay: true,
            isWaitingToMinimizeStalls: true, playbackBufferEmpty: false,
            bufferedAheadSeconds: .infinity))
    }

    /// Both readings have to agree. AVPlayer calling the buffer empty outranks a span that looks deep,
    /// because the empty flag is the one `AVPlayer.h` ties the failure mode to.
    @Test("AVPlayer's own empty flag outranks a deep-looking span")
    func emptyFlagOutranksDepth() {
        #expect(!NativeAVPlayerHost.shouldStartLiveJoinImmediately(
            armed: true, alreadySpent: false, hostWantsToPlay: true,
            isWaitingToMinimizeStalls: true, playbackBufferEmpty: true,
            bufferedAheadSeconds: 4.0))
    }

    /// The depth is the CONTIGUOUS span ahead of the playhead, not the sum of every loaded range: an
    /// island past a gap cannot sustain a rate that has to cross the gap to reach it.
    @Test("an island past a gap does not count toward the depth")
    func depthIgnoresIslandPastGap() {
        let now = 100.0
        let ranges = [(100.0, 100.6), (120.0, 128.0)]
        let ahead = NativeAVPlayerHost.contiguousBufferedEnd(ranges: ranges, now: now) - now
        #expect(abs(ahead - 0.6) < 0.001)
        #expect(!NativeAVPlayerHost.shouldStartLiveJoinImmediately(
            armed: true, alreadySpent: false, hostWantsToPlay: true,
            isWaitingToMinimizeStalls: true, playbackBufferEmpty: false,
            bufferedAheadSeconds: ahead))
    }

    /// The default is what a host gets without asking, and since 6.55.0 that is on: the device A/B
    /// measured the join tail removed (press-to-motion 6.4-7.2 s down to 4.3-5.6 s) with stalls and
    /// drops unchanged at zero in both arms.
    @Test("a live join starts immediately unless the host opts out")
    func defaultIsOn() {
        #expect(LoadOptions().liveJoinStartsImmediately)
        #expect(!LoadOptions(liveJoinStartsImmediately: false).liveJoinStartsImmediately)
    }

    /// An inherited property of the span helper, pinned here because the floor is 1.5 s and this can
    /// move the reading by up to 1 s: `contiguousBufferedEnd` treats a range starting within a second
    /// AFTER the playhead as contiguous with it (AE#422 kept that tolerance for the gap between the
    /// rendered frame and the range's reported start). It cannot reach the join case, since the lever
    /// only runs once a frame is presented over a buffer AVPlayer calls non-empty, but a reader of the
    /// floor should see it rather than infer a stricter measure than exists.
    @Test("a sub-tolerance gap ahead of the playhead is bridged, not subtracted")
    func toleranceBridgesASubSecondGap() {
        let ahead = NativeAVPlayerHost.contiguousBufferedEnd(ranges: [(100.8, 103.0)], now: 100.0) - 100.0
        #expect(abs(ahead - 3.0) < 0.001)
    }

    // MARK: - Round 3: what a refused hold did next

    /// The decision is taken at the hold's edges only, so a join that begins starved and fills while
    /// the reason stands still gets no second look and leaves no trace of having needed one. The
    /// witness reports the crossing in the terms the decision would be taken in, and does not act.
    @Test("a crossing under a standing hold is reported as observed, not as a start")
    func crossingLineNamesItselfAsObservationOnly() {
        let line = NativeAVPlayerHost.liveJoinHoldAccount(
            outcome: .crossed, standingSeconds: 0.62,
            reading: .init(bufferEmpty: false, aheadSeconds: 2.34))
        #expect(line.contains("still standing 0.62s after the refusal"))
        #expect(line.contains("ahead 2.34s"))
        #expect(line.contains("floor 1.50s"))
        #expect(line.contains("observed only"))
    }

    /// A witness silent about its own negative cannot be told from one that never ran, which is the
    /// reading error #447 round 3 had to correct in the seal line. So both negatives speak, and each
    /// names which of them it is.
    @Test("both negatives speak, and say which negative they are")
    func negativesAreDistinguishable() {
        let ended = NativeAVPlayerHost.liveJoinHoldAccount(
            outcome: .holdEnded, standingSeconds: 1.81,
            reading: .init(bufferEmpty: false, aheadSeconds: 0.42))
        let budget = NativeAVPlayerHost.liveJoinHoldAccount(
            outcome: .budgetSpent, standingSeconds: 5.0,
            reading: .init(bufferEmpty: true, aheadSeconds: 0.0))
        #expect(ended.contains("the wait ended 1.81s after the refusal"))
        #expect(ended.contains("last reading ahead 0.42s, empty=false"))
        #expect(budget.contains("still standing after 5.00s of sampling"))
        #expect(budget.contains("empty=true"))
        #expect(ended != budget)
    }

    /// The witness asks the guard, it does not re-implement it: the sample it reports as a crossing is
    /// exactly a sample the guard would have fired on.
    @Test("the crossing the witness reports is the guard's own verdict")
    func witnessAsksTheSameGuard() {
        for (empty, ahead, expected) in [(false, 2.34, true), (false, 1.49, false), (true, 4.0, false)]
            as [(Bool, Double, Bool)] {
            #expect(NativeAVPlayerHost.shouldStartLiveJoinImmediately(
                armed: true, alreadySpent: false, hostWantsToPlay: true,
                isWaitingToMinimizeStalls: true, playbackBufferEmpty: empty,
                bufferedAheadSeconds: ahead) == expected)
        }
    }

    /// The sampling bound has to outlive the holds both reports measured (1.55 to 2.81 s) and to be
    /// finer than the shortest of them, or the witness answers a question nobody asked.
    @Test("the sampling budget outlives the measured holds and resolves inside them")
    func witnessBudgetCoversTheMeasuredHolds() {
        let budget = NativeAVPlayerHost.liveJoinHoldWitnessInterval
            * Double(NativeAVPlayerHost.liveJoinHoldWitnessSamples)
        #expect(budget >= 2.81)
        #expect(NativeAVPlayerHost.liveJoinHoldWitnessInterval <= 1.55 / 4)
    }

    // MARK: - Round 4: the witness has to speak on the ordinary ending

    /// The field defect, in one assertion. `startLiveJoinImmediatelyIfHolding` spends the one-shot on
    /// the `.playing` edge, so the rate rolling and the one-shot being spent are the SAME event. Reading
    /// the spend as "this witness no longer applies" therefore swallowed the ordinary ending: three
    /// refusals on 6.56.1, one line.
    @Test("the roll that spends the one-shot reports the hold ending, it does not silence the witness")
    func spentOneShotIsAnEndingNotASilence() {
        #expect(NativeAVPlayerHost.liveJoinHoldWitnessEnding(
            itemIsCurrent: true, waitWasCutShort: false, oneShotSpent: true,
            hostWantsToPlay: true, isWaitingToPlay: false) == .holdEnded)
    }

    /// Both orderings of the same edge, because the observer that mirrors `timeControlStatus` and the
    /// one that spends the one-shot are not guaranteed to have run in the same order as the sample.
    @Test("either half of the roll edge is enough to end the witness")
    func eitherHalfOfTheRollEnds() {
        #expect(NativeAVPlayerHost.liveJoinHoldWitnessEnding(
            itemIsCurrent: true, waitWasCutShort: false, oneShotSpent: true,
            hostWantsToPlay: true, isWaitingToPlay: true) == .holdEnded)
        #expect(NativeAVPlayerHost.liveJoinHoldWitnessEnding(
            itemIsCurrent: true, waitWasCutShort: false, oneShotSpent: false,
            hostWantsToPlay: true, isWaitingToPlay: false) == .holdEnded)
    }

    /// A host that put the session down is an ending too, and it is the one case that was never silent.
    @Test("a host that stopped wanting to play ends the witness")
    func pausedHostEnds() {
        #expect(NativeAVPlayerHost.liveJoinHoldWitnessEnding(
            itemIsCurrent: true, waitWasCutShort: false, oneShotSpent: false,
            hostWantsToPlay: false, isWaitingToPlay: true) == .holdEnded)
    }

    /// The override firing also spends the one-shot, so without its own flag it would report the exact
    /// opposite of what happened: the cushion HAD reached the floor, an edge read it, and the wait was
    /// cut rather than ending on its own.
    @Test("an override that cut the wait is not reported as the wait ending on its own")
    func cutShortOutranksThePlainSpend() {
        #expect(NativeAVPlayerHost.liveJoinHoldWitnessEnding(
            itemIsCurrent: true, waitWasCutShort: true, oneShotSpent: true,
            hostWantsToPlay: true, isWaitingToPlay: true) == .cutShort)
        let line = NativeAVPlayerHost.liveJoinHoldAccount(
            outcome: .cutShort, standingSeconds: 0.75,
            reading: .init(bufferEmpty: false, aheadSeconds: 1.92))
        #expect(line.contains("cut short at an edge 0.75s after the refusal"))
        #expect(!line.contains("without the buffer reaching the floor"))
    }

    /// An abandoned join is a different fact from a resolved one, and the reader outside cannot infer
    /// it: this is the exit that used to return without a word.
    @Test("an item replaced under the witness is an ending with a line of its own")
    func replacedItemSpeaks() {
        #expect(NativeAVPlayerHost.liveJoinHoldWitnessEnding(
            itemIsCurrent: false, waitWasCutShort: false, oneShotSpent: true,
            hostWantsToPlay: false, isWaitingToPlay: false) == .itemReplaced)
        #expect(NativeAVPlayerHost.liveJoinHoldAccount(
            outcome: .itemReplaced, standingSeconds: 2.0,
            reading: .init(bufferEmpty: true, aheadSeconds: 0)).contains("abandoned rather than resolved"))
    }

    /// The only reason to keep sampling: the hold is still up, on this item, with the host still asking
    /// for motion.
    @Test("a hold that is still standing keeps the witness sampling")
    func standingHoldKeepsSampling() {
        #expect(NativeAVPlayerHost.liveJoinHoldWitnessEnding(
            itemIsCurrent: true, waitWasCutShort: false, oneShotSpent: false,
            hostWantsToPlay: true, isWaitingToPlay: true) == nil)
    }

    /// Six outcomes, six distinct sentences. A witness whose lines collide is back to being unreadable
    /// from outside.
    @Test("every outcome produces a line, and no two are the same")
    func everyOutcomeHasItsOwnLine() {
        let outcomes: [NativeAVPlayerHost.LiveJoinHoldOutcome] =
            [.crossed, .holdEnded, .cutShort, .itemReplaced, .hostGone, .budgetSpent]
        let lines = outcomes.map {
            NativeAVPlayerHost.liveJoinHoldAccount(
                outcome: $0, standingSeconds: 1.0,
                reading: .init(bufferEmpty: false, aheadSeconds: 2.0))
        }
        #expect(Set(lines).count == outcomes.count)
        #expect(lines.allSatisfy { $0.hasPrefix("AE#440 live join: ") && $0.count > 40 })
    }

    // MARK: - Round 5: a reading that was never taken, and a session that survives its item

    /// The 6.56.2 field capture's one unaccountable line: a refusal at `empty=false` whose witness
    /// reported `ahead 0.00s, empty=true` 0.26 s later, on a join that reached `playing` regardless.
    /// Nothing had changed in the buffer. The hold ended inside the first sampling interval, so the
    /// witness had taken no reading of its own and printed the placeholder it was initialised with.
    @Test("an ending inside the first interval reports no reading rather than an invented one")
    func endingBeforeTheFirstSampleSaysSo() {
        let line = NativeAVPlayerHost.liveJoinHoldAccount(
            outcome: .holdEnded, standingSeconds: 0.26, reading: nil)
        #expect(line.contains("the wait ended 0.26s after the refusal"))
        #expect(line.contains("no reading of its own was taken"))
        // The two figures a reader would take as measurements must not appear at all.
        #expect(!line.contains("ahead 0.00s"))
        #expect(!line.contains("empty="))
        // The floor is the number the sentence is about, so it travels either way.
        #expect(line.contains("floor 1.50s"))
    }

    /// Every ending that can arrive before the first sample has to survive the same absence, because
    /// the ending is checked before the sample is taken.
    @Test("no outcome invents a buffer reading when none was taken")
    func noOutcomeInventsAReading() {
        let outcomes: [NativeAVPlayerHost.LiveJoinHoldOutcome] =
            [.holdEnded, .cutShort, .itemReplaced, .hostGone, .budgetSpent]
        for outcome in outcomes {
            let line = NativeAVPlayerHost.liveJoinHoldAccount(
                outcome: outcome, standingSeconds: 0.25, reading: nil)
            #expect(!line.contains("empty="), "\(outcome) claims a buffer state it never read")
            #expect(!line.contains("ahead 0.00s"), "\(outcome) claims a cushion it never read")
        }
    }

    /// The reporter's rejoin: a #446 swap went through `WaitingToMinimizeStalls` twice and produced no
    /// AE#440 line at all, decision or witness. The lever was not silent, it was disarmed: the swap
    /// called `load` with the item arguments only, so the host re-declared the session as VOD.
    @Test("an item swap keeps the contract its session was loaded under")
    @MainActor
    func swapKeepsTheSessionContract() {
        let host = NativeAVPlayerHost()
        let contract = NativeAVPlayerHost.SessionLoadContract(
            isLive: true, liveJoinStartsImmediately: true, forwardBufferDuration: 0,
            surfaceEndFailures: true, httpHeaders: ["X-Emby-Token": "t"], armIngestFallback: false,
            readinessDeadline: 20)
        host.load(url: URL(string: "http://127.0.0.1:1/live/media.m3u8")!,
                  startPosition: nil, contract: contract)
        #expect(host.sessionContract == contract)

        host.swapItem(url: URL(string: "http://127.0.0.1:1/live/media.m3u8")!, startPosition: nil)
        #expect(host.sessionContract == contract)
    }

    /// The other half of the same fact: a load that IS a new session states its own contract, so a live
    /// zap's override cannot be left armed in front of the next VOD title's cold start.
    @Test("a new load replaces the contract rather than inheriting it")
    @MainActor
    func newLoadStatesItsOwnContract() {
        let host = NativeAVPlayerHost()
        host.load(url: URL(string: "http://127.0.0.1:1/live/media.m3u8")!, startPosition: nil,
                  contract: .init(isLive: true, liveJoinStartsImmediately: true))
        host.load(url: URL(string: "http://127.0.0.1:1/vod/media.m3u8")!, startPosition: 0,
                  contract: .init())
        #expect(host.sessionContract == NativeAVPlayerHost.SessionLoadContract())
        #expect(!host.sessionContract.isLive)
    }

    /// The third silent exit, and the one a rejoin takes: the swap's hold stood for 70 ms, the buffer
    /// reading is asynchronous, and a hold that ends while it is in flight is correctly left alone. What
    /// was wrong is that it said nothing, which from outside reads as a lever that was never armed.
    @Test("a hold that ended before the reading came back says so")
    func abandonedDecisionSpeaks() {
        let rolled = NativeAVPlayerHost.liveJoinDecisionAbandoned(afterSeconds: 0.07, rolled: true)
        #expect(rolled.contains("the rate had rolled"))
        #expect(rolled.contains("0.07s later"))
        #expect(rolled.contains("no decision was taken"))

        // A host that paused under the reading ended the hold too, and did not roll: the line must not
        // claim motion that never happened.
        let paused = NativeAVPlayerHost.liveJoinDecisionAbandoned(afterSeconds: 0.12, rolled: false)
        #expect(!paused.contains("rolled"))
        #expect(paused.contains("no decision was taken"))
    }
}
