import Foundation
import CoreMedia
import CoreVideo
import AVFoundation

#if canImport(UIKit)
import UIKit
#endif

#if os(tvOS)
import AVKit
import QuartzCore
#endif

/// HDMI HDR-mode handshake via AVDisplayManager (tvOS 11.2+). Programs AVDisplayCriteria before playback so the panel finishes its mode negotiation before the first frame. No-op stub on iOS/macOS. Lifted from Sodalite's PlayerViewModel so the engine owns the handshake; hosts no longer touch UIWindow.avDisplayManager.
@MainActor
final class DisplayCriteriaController {

    /// Override window discovery. Default walks connectedScenes and picks the first window; multi-window or custom-presentation hosts can supply their own resolver here.
    nonisolated(unsafe) static var windowProvider: (@MainActor () -> Any?)?

    /// Whether apply() wrote preferredDisplayCriteria this session. reset() is gated on this so AVKit-sole-writer hosts (LoadOptions.suppressDisplayCriteria=true) get zero engine writes; a nil write on a suppressed session races AVKit's in-flight criteria and collapsed EDR headroom to 1.0 (DrHurt#4 Build 176).
    private var didApply: Bool = false

    /// True when the last apply() set HDR color extensions. waitForSwitch uses this to distinguish a legitimate SDR rate-only settle (headroom 1.0 expected) from an HDR handshake failure (headroom 1.0 is wrong).
    private var lastCriteriaWasHDR: Bool = false

    /// #133: the criteria last written to the panel (nil until the first apply, cleared by reset()). Lets a
    /// same-format zap detect that the mode is already active and skip the redundant write + settle wait,
    /// which on unobservable-DV panels otherwise burns the full ~3s waitForSwitch cap on every channel change.
    private var lastApplied: AppliedCriteria?

    /// Has a criteria write ever demonstrably driven THIS display into HDR (headroom observed above 1.0)?
    ///
    /// Deliberately never cleared, not by `reset()` and not by a switch that ends at headroom 1.0. The
    /// headroom is a transition artifact, so its absence proves nothing (see `panelPresentsHDR`) and any
    /// invalidation rule built on it would re-arm the very false negative this exists to answer. A display
    /// change cannot strand it either: `effectiveVideoFormat` clamps to `displayCapabilities` before
    /// `apply()`, so an SDR route writes SDR criteria and never consults the proof.
    private var panelProvenToEngageHDR: Bool = false

    #if os(tvOS)
    /// #339: armed at the criteria write, not when the play gate opens, so an engine-written switch is
    /// observable end to end instead of having to be guessed at from the in-progress flag.
    private let observation = SwitchObservation()
    #endif

    /// The arm generation whose record has been spent. Only a gate that ends the load's wait spends it, so
    /// both gates of one load see the same evidence while a later, unarmed gate sees none
    /// (`recordIsFreshEvidence`).
    private var spentArmGeneration: Int = 0

    /// The identifying inputs of an apply(): equal signatures mean the panel is already in the target mode.
    struct AppliedCriteria: Equatable {
        let isHDR: Bool
        let effectiveRate: Float
        let codecType: CMVideoCodecType
        let hasExtensions: Bool
    }

    enum ApplyResult {
        /// HDR/DV criteria written; a dynamic-range switch is expected (caller should pre-flight waitForSwitch).
        case willSwitch
        /// SDR rate-only criteria written; sub-second, no pre-flight wait needed.
        case applied
        /// Criteria identical to what is already active; nothing written, no switch pending (#133).
        case unchanged
    }

    /// #133 pure decision: skip only when we previously applied (`didApply`) exactly these criteria and have
    /// not reset since. Otherwise write, returning whether a dynamic-range switch is expected (HDR) or not (SDR).
    nonisolated static func applyOutcome(didApply: Bool, last: AppliedCriteria?, target: AppliedCriteria) -> ApplyResult {
        if didApply, last == target { return .unchanged }
        return target.isHDR ? .willSwitch : .applied
    }

    /// How long `waitForSwitch` blind-polls for a switch to *start* before giving up (Stage 1). The wait is
    /// blind by construction: nothing reports "a criteria write is inbound", so the budget is a bet on the
    /// writer's latency and every millisecond of it is startup time when the bet is wrong (#274).
    enum StartGrace: Equatable {
        /// Nothing can be pending; return before touching the display manager.
        case skip
        /// 200 ms: only a rate-only switch could still start (the pre-#274 budget, sized for a synchronous
        /// engine write). The engine declines to pre-flight its own rate-only writes on the d87b54d premise
        /// that they are sub-second.
        ///
        /// That premise is now contradicted, though not yet by a run that also juddered: on the Sodalite#49
        /// reporter's Apple TV a rate-only SDR switch was measured at ~2.9 s end to end, and two further
        /// runs never reported an end at all inside Stage 2's cap. Reading that as "shorten nothing, widen
        /// nothing" is deliberate: one panel is not grounds for making every session's cold start wait
        /// longer, and the runs that produced these numbers played cleanly.
        case brief
        /// 1000 ms: a dynamic-range switch may still be inbound from a writer whose timing we don't control
        /// (AVKit's auto-criteria path fires from the AVPlayerItem formatDescription). DV P5 cold start
        /// depends on this budget.
        case full

        /// The budget both as the log lines report it and as Stage 1 spends it. Latency fixes are verified
        /// off the number they moved, so both the spent-time line and the #289 skip line name it (#274).
        var budgetMs: Int {
            switch self {
            case .skip:  0
            case .brief: 200
            case .full:  1000
            }
        }
    }

    /// Stage 2's ceiling: long enough that an unobservable DV switch does not gate the first frame the way
    /// the old fixed 5 s poll did, short enough to stay a startup cost.
    ///
    /// **Do not raise this to "fit" the measured switch duration.** Twelve device measurements (Apple TV 4K
    /// 3rd gen, tvOS 26.5, 2026-08-09, dynamic-range and range-plus-rate alike) put a real switch at 2779 to
    /// 2898 ms, so the pre-flight gate reliably breaks out here at ~2.0 s with the panel still switching.
    /// That looks like a defect and is currently load-bearing: breaking out is what lets `loadNative` start
    /// while the switch finishes, and the play gate then waits out whatever is left. Timed end to end:
    ///
    ///     cap 2000: pre-flight breaks +2020, load ~850 ms, play() at ~+2918
    ///     cap 4000: pre-flight ends +2892 on the notification, load ~850 ms, play() at ~+3740
    ///
    /// The "corrected" cap costs a full load's worth of startup, ~820 ms here, because the load is serialised
    /// behind the wait. The way to spend that time properly is to load *during* the switch rather than to
    /// pick a cap that overlaps them by accident (AE#348); until then this number is doing two jobs and only
    /// one of them is written on it.
    nonisolated static let stage2CapMs = 2000

    /// What the settle wait is allowed to cost, decided by what else is waiting on it.
    enum SettleCap: Equatable {
        /// `stage2CapMs`. For a gate that runs *before* the item is built, where breaking out early is what
        /// releases the load, and for live, where a zap must not sit behind a panel handshake.
        case standard
        /// Wait for the end that was observed to be coming, up to `observedEndCapMs`. For a gate that runs
        /// after the item is ready: nothing else is pending, so the wait costs only itself.
        case awaitObservedEnd
    }

    /// Ceiling for `awaitObservedEnd`. Only reachable when a start notification was recorded and its end
    /// never arrives, which did not happen once across sixteen device switches; the real numbers are 2.8 s
    /// for a dynamic-range switch and 3.55 s for a rate switch.
    nonisolated static let observedEndCapMs = 6000

    /// A gate that ran after the load, on a switch it saw start, waits for that switch to end.
    ///
    /// The measurement that decides this (Apple TV 4K 3rd gen, tvOS 26.5, 2026-08-09, SDR 25p on a 60 Hz
    /// system, so a rate-only write with no pre-flight): the item was ready at +443 ms, the cap released
    /// `play()` at +2130 ms, and the panel finished switching at +3555 ms. **The panel blanks throughout**,
    /// which is the part no log shows: the first visible frame lands at +3555 ms either way, so releasing
    /// early buys no picture at all and costs 1.4 s of content played into a dark screen.
    ///
    /// This is the answer to "a rate-only switch does not need to be waited out" (Sodalite#49, DrHurt). It
    /// does not need to be waited out for *correctness*, since only a range change can fail AVPlayer, but
    /// waiting is free where the panel is dark anyway, and not waiting is not.
    nonisolated static func settleCapMs(cap: SettleCap, startRecorded: Bool) -> Int {
        guard cap == .awaitObservedEnd, startRecorded else { return stage2CapMs }
        return observedEndCapMs
    }

    /// Both stages spend a deadline, not a poll count. `n` sleeps of `m` ms is only `n * m` on an idle
    /// scheduler: the same 40 x 50 ms Stage 2 ran 2082 ms in one of the reporter's runs and 2862 ms in
    /// another, on a device reporting `thermal=serious` throughout. A budget that stretches 40 % under the
    /// load it exists to survive is not a budget, and it was the second measurement defect in a row to make
    /// #49's logs unreadable (Sodalite#49).
    nonisolated static func isBudgetSpent(elapsedMs: Int, budgetMs: Int) -> Bool {
        elapsedMs >= budgetMs
    }

    /// #289: with Match Content off, nothing can start a switch, so waiting for one is pure startup latency
    /// on the path that gates `play()`. `apply()` already declines to write criteria in that state, but it
    /// returns `.applied`, which is neither of the two outcomes the play-gate short-circuits on, and a
    /// sole-writer host never reaches `apply()` at all: tvOS ignores `preferredDisplayCriteria` for AVKit's
    /// write just the same, so that path can only be caught here.
    ///
    /// Read live from the display manager rather than from `LoadOptions.matchContentEnabled`: the host flag
    /// is a snapshot that can be stale in the dangerous direction (reporting off while matching is on would
    /// skip a wait a DV cold start needs).
    nonisolated static func shouldWait(startGrace: StartGrace, matchingEnabled: Bool) -> Bool {
        startGrace != .skip && matchingEnabled
    }

    /// Who wrote the criteria a switch belongs to, and what range they asked for. Only the engine's own HDR
    /// write makes a switch that ends with EDR headroom still at 1.0 a failure; a switch the engine never
    /// initiated carries no target range it could check against, so attributing one produced a false "panel
    /// stayed SDR despite HDR criteria" WARN on sole-writer hosts (#274). The Stage 2 cap reads the same
    /// attribution: an engine rate-only write that never reports an end is not the unobservable-DV case its
    /// log line claimed for every session alike (Sodalite#49).
    enum CriteriaAttribution: Equatable {
        /// Engine wrote SDR rate-only criteria: a settle at headroom 1.0 is the expected end state.
        case engineRateOnly
        /// Engine wrote HDR criteria: a settle at headroom 1.0 is a real dynamic-range handshake failure.
        case engineHDR
        /// Engine never wrote this session (sole-writer host): the switch was somebody else's, its target
        /// range is not knowable here.
        case hostDriven
    }

    /// Will the panel present this session in HDR?
    ///
    /// `UIScreen.currentEDRHeadroom` is not a readout of the panel's HDMI mode. It is raised around a
    /// dynamic-range TRANSITION and decays back to 1.0 while the panel keeps presenting HDR (device trace,
    /// HDR10+ panel, 2026-08-02: headroom fell 1.20 -> 1.00 thirteen seconds into a confirmed HDR10 session
    /// with `isDisplayModeSwitchInProgress` false throughout). A replay that starts before the TV has dropped
    /// back to SDR therefore makes no transition at all, the headroom never rises, and the single read taken
    /// after `waitForSwitch` concluded "panel is SDR". On tvOS that one boolean IS the master-vs-media routing
    /// gate (`resolveUseMasterPlaylist`, where `builtInPanelEngagesOnDemand` is false), so the session was
    /// served media-direct with no HDR signaling and labelled SDR while the TV itself reported HDR.
    ///
    /// So the reading is trusted only as a positive. Its absence is answered by what this display has already
    /// proven: once a criteria write has driven it into HDR, asking for HDR again puts it there. A panel that
    /// never engages (Match Frame Rate on, Match Dynamic Range off, which tvOS reports through the same
    /// combined toggle) never sets the proof and keeps the conservative answer, so it is still never offered a
    /// PQ master it would reject with -11848.
    ///
    /// `UIScreen.potentialEDRHeadroom` looks like the way out of all of this and is not. It reads **1.00 on
    /// tvOS regardless of the display's mode**, measured 2026-08-09 on an Apple TV 4K (3rd gen), tvOS 26.5,
    /// HDR10 panel, same title played once with the box set to 4K HDR and once to 4K SDR:
    ///
    ///     4K HDR, t+2.5s:  current 1.20, potential 1.00
    ///     4K HDR, t+20s:   current 1.00, potential 1.00
    ///     4K SDR, t+2.5s:  current 1.00, potential 1.00
    ///
    /// The first row is the one that closes it: the panel was demonstrably in an HDR mode, and the value
    /// documented as the maximum the screen can display read *lower* than the live one at the same instant,
    /// from the same `UIScreen`. That is not a sampling-time problem, it is a property tvOS does not
    /// maintain. There is no mode read-back; do not go looking for one here again (Sodalite#49).
    ///
    /// The residual risk is the reverse: Match Dynamic Range switched off in Settings after a proven session,
    /// without the app being killed. That offers one master to an SDR panel, which the reactive master-to-media
    /// fallback (#98) and the startup-readiness gate (#35) already recover from. Trading a rare, self-healing
    /// fallback for a silent permanent HDR loss on every replay is the point of this function.
    nonisolated static func panelPresentsHDR(
        headroomAboveOne: Bool,
        attribution: CriteriaAttribution,
        panelProvenToEngageHDR: Bool
    ) -> Bool {
        if headroomAboveOne { return true }
        return attribution == .engineHDR && panelProvenToEngageHDR
    }

    nonisolated static func criteriaAttribution(didApply: Bool, lastCriteriaWasHDR: Bool) -> CriteriaAttribution {
        guard didApply else { return .hostDriven }
        return lastCriteriaWasHDR ? .engineHDR : .engineRateOnly
    }

    /// How the gate learned a switch was running. This is the one bit that separates "the panel was already
    /// switching while the AVPlayerItem was built" from "the switch started after the gate opened", the
    /// ordering question Sodalite#49 was filed on and which no log line could answer.
    ///
    /// Since #339 the notifications are recorded from the criteria write onward rather than from gate entry,
    /// so `preGateObserved` answers that question with two timestamps. The flag-derived cases remain for what
    /// the notifications miss, and each one now indicts something specific: `preGate` says a switch was
    /// running that this session's write never announced, `inGateFlagOnly` says the start notification for a
    /// switch inside the gate went missing. Both are measurements of the observation itself, which is what
    /// makes the #339 change checkable on a device rather than only in review.
    enum StartSignal: String, Equatable {
        /// Start notification recorded between the criteria write and the gate opening.
        case preGateObserved = "pre-gate (start notification, before gate entry)"
        /// In-progress flag set on the first poll with no start recorded since the write: the switch began
        /// before the observation was armed, or its notification never arrived.
        case preGate = "pre-gate (flag only, no start notification since the criteria write)"
        /// Mode-switch-start notification arrived while the gate was polling.
        case inGate = "in-gate"
        /// The flag rose after the first poll and no start notification ever arrived. The switch began
        /// inside the gate either way; what is missing is the notification, not the ordering.
        case inGateFlagOnly = "in-gate (flag only, start notification missed)"
        /// Nothing observed within the budget.
        case none = "none"
    }

    /// Stage 1's per-poll verdict, `nil` while nothing has been observed yet. Pure so the distinction the
    /// whole of #49 rests on is covered by tests rather than by reading a device log.
    nonisolated static func classifyStart(isFirstPoll: Bool,
                                          startNotificationFired: Bool,
                                          switchInProgress: Bool) -> StartSignal? {
        if startNotificationFired { return .inGate }
        guard switchInProgress else { return nil }
        return isFirstPoll ? .preGate : .inGateFlagOnly
    }

    /// What the observation already knows when the gate opens (#339). The observers are armed at the
    /// criteria write, so a switch that started, or started and finished, while the item was being built is
    /// knowable here instead of having to be inferred from a flag inside Stage 1.
    enum ObservedSwitch: Equatable {
        /// Start and end both recorded before the gate opened, and the panel is not switching now: there is
        /// nothing left to wait for.
        case settled(startBeforeGateMs: Int, switchMs: Int)
        /// A start was recorded and no end followed it. Stage 1 has nothing left to discover, so the gate
        /// goes straight to waiting the end out.
        case running(startBeforeGateMs: Int)
        /// Nothing usable recorded since the write.
        case none
    }

    /// May a raised EDR headroom end the wait?
    ///
    /// The headroom rises *with* the dynamic-range transition, so during a switch it reports "HDR is coming
    /// up", not "the panel is done". Device measurement (Apple TV 4K 3rd gen, tvOS 26.5, 2026-08-09): a run
    /// whose headroom reached 1.20 at +374 ms belonged to a switch that ended at +2853 ms, and the gate
    /// released `play()` 2.5 s into a running HDMI handshake. That is the "first frame hits a mid-transition
    /// panel" case the whole wait exists to prevent, and the shape Sodalite#49 was filed on.
    ///
    /// The deciding input is whether **this load recorded a start notification at all**, not whether one
    /// arrived since this gate opened. A load runs two gates (pre-flight, then play), the second finds the
    /// record already consumed, and reading that as "no observable switch" let the headroom end the wait
    /// 759 ms early on the very next device run. If a start was recorded, its end will be too, and the
    /// notification or the in-progress flag is the authority: on that device the flag cleared within 1 ms of
    /// the notification.
    ///
    /// Without a recorded start the headroom is the only end signal there is, which is the unobservable-DV
    /// panel the Stage 2 cap exists for, so it keeps its say there.
    nonisolated static func startPhaseHeadroomSettles(startRecorded: Bool, switchInProgress: Bool) -> Bool {
        !startRecorded && !switchInProgress
    }

    /// Stage 2 has already classified a start, so the flag is expected to be set and cannot disqualify the
    /// headroom the way it does in Stage 1; an unobservable-DV panel sticks it `true` for the whole switch.
    /// A recorded start still rules the headroom out.
    nonisolated static func settlePhaseHeadroomSettles(startRecorded: Bool) -> Bool {
        !startRecorded
    }

    /// May the entry fast-exit take a raised headroom as "nothing to wait for"?
    ///
    /// Its purpose is the panel a previous session already drove into HDR: no transition is pending and the
    /// wait would be dead time. A panel that is mid-switch produces the same raised headroom for the
    /// opposite reason, so the in-progress flag has to agree. Same device run: the play gate read headroom
    /// 1.20 at entry and returned in 0 ms while the switch had another 2.4 s to run.
    nonisolated static func entryHeadroomIsSettled(headroomAboveOne: Bool, switchInProgress: Bool) -> Bool {
        headroomAboveOne && !switchInProgress
    }

    /// Whether a recorded switch belongs to the load whose gate is asking (#339).
    ///
    /// The record survives between loads, so a gate that runs without a preceding arm must not read it: an
    /// engine-writer reload re-applies no criteria and arms nothing, and inheriting the previous load's start
    /// would make it wait out an end that can no longer arrive.
    ///
    /// Marking the record spent is a separate decision (`consumesRecord`), because a load runs up to two
    /// gates and both are entitled to the same evidence. The pre-flight deliberately does not spend it: on
    /// the device, a play gate that opened after its switch had ended found the record already spent, fell
    /// back to Stage 1 and paid its 200 ms grace for a switch it could have known was over.
    nonisolated static func recordIsFreshEvidence(recordGeneration: Int, lastSpentGeneration: Int) -> Bool {
        recordGeneration != 0 && recordGeneration != lastSpentGeneration
    }

    /// Pure verdict on the recorded timestamps.
    ///
    /// Two asymmetries are deliberate. A `settled` conclusion needs *both* a start and an end, because an end
    /// alone can belong to an older switch (the criteria reset a sole-writer load performs makes one), and
    /// mistaking that for this session's settle would hand a DV P5 cold start to a panel still in SDR. And
    /// `switchInProgress` may only veto, never confirm: the flag is documented as unreliable right after a
    /// write, so it can move the gate towards waiting and never towards proceeding.
    nonisolated static func observedSwitch(startedAtNanos: UInt64?,
                                           endedAtNanos: UInt64?,
                                           gateEntryNanos: UInt64,
                                           switchInProgress: Bool) -> ObservedSwitch {
        guard let started = startedAtNanos else { return .none }
        let startBeforeGateMs = elapsedMs(fromNanos: started, toNanos: gateEntryNanos)
        if let ended = endedAtNanos, ended >= started, !switchInProgress {
            return .settled(startBeforeGateMs: startBeforeGateMs,
                            switchMs: elapsedMs(fromNanos: started, toNanos: ended))
        }
        return .running(startBeforeGateMs: startBeforeGateMs)
    }

    /// The numbers a settle log needs to be usable: when the switch started relative to the gate, how long
    /// the whole gate took, and, when both notifications were seen, how long the panel's switch actually
    /// took. All three used to be unavailable: the stage budgets were reported instead of measurements
    /// (#49), and a switch that completed before the gate opened produced no numbers at all (#339).
    nonisolated static func timingSuffix(startSignal: StartSignal, stage1Ms: Int, totalMs: Int,
                                         startBeforeGateMs: Int? = nil, switchMs: Int? = nil) -> String {
        let start = startBeforeGateMs.map { "start \(startSignal.rawValue) \($0)ms before gate entry" }
            ?? "start \(startSignal.rawValue) after \(stage1Ms)ms"
        let measured = switchMs.map { ", switch \($0)ms end to end" } ?? ""
        return "\(start), total \(totalMs)ms\(measured)"
    }

    /// Guarded against reversed arguments: unsigned uptime subtraction traps, and a diagnostic helper is a
    /// poor reason to crash playback.
    nonisolated static func elapsedMs(fromNanos start: UInt64, toNanos end: UInt64) -> Int {
        guard end > start else { return 0 }
        return Int(Double(end - start) / 1_000_000)
    }

    nonisolated static func elapsedMs(since start: DispatchTime) -> Int {
        elapsedMs(fromNanos: start.uptimeNanoseconds, toNanos: DispatchTime.now().uptimeNanoseconds)
    }

    init() {}

    /// Program AVDisplayCriteria before the session starts. `.sdr` programs a rate-only criteria so Match Frame Rate still engages. `codecTag` nil derives from format (`'dvh1'` for DV, `'hvc1'` otherwise). `omitColorExtensions` skips BT.2020 extensions for diagnostic builds. Returns `.willSwitch` when a dynamic-range switch is expected (caller should call waitForSwitch), `.applied` for an SDR rate-only write, or `.unchanged` when the criteria are already active and nothing was written (#133).
    @discardableResult
    func apply(format: VideoFormat, frameRate: Double?, codecTag: FourCharCode?, omitColorExtensions: Bool) -> ApplyResult {
        #if os(tvOS)
        // Reset up front so a skipped apply (Match Content off, no window)
        // can't leave a prior HDR session's flag for waitForSwitch to read.
        lastCriteriaWasHDR = false
        guard #available(tvOS 17.0, *) else {
            EngineLog.emit("[DisplayCriteria] skipped: tvOS < 17", category: .engine)
            return .applied
        }

        guard let window = resolveWindow() else {
            EngineLog.emit("[DisplayCriteria] skipped: no window", category: .engine)
            return .applied
        }

        let displayManager = window.avDisplayManager

        // isDisplayCriteriaMatchingEnabled covers both Match Dynamic Range and Match Frame Rate; tvOS picks the applicable dimension internally.
        guard displayManager.isDisplayCriteriaMatchingEnabled else {
            EngineLog.emit("[DisplayCriteria] skipped: Match Content disabled (both Dynamic Range AND Frame Rate off)", category: .engine)
            return .applied
        }

        // HDR sources attach BT.2020 + transfer + matrix extensions; SDR carries only codec + rate so Match Frame Rate can engage without Match Dynamic Range (DrHurt #4: previously early-returned for SDR and Match Frame Rate never fired).
        let isHDR = (format != .sdr)
        // Codec FourCC drives the HDMI mode: 'hvc1' -> HDR10/HLG, 'dvh1' -> Dolby Vision. Using HEVC for a DV source kept DrHurt's Philips panel in HDR10 instead of DV (P8 MKV). ref: Jellyfin #16179, KSPlayer #633.
        let dvh1: FourCharCode = 0x64766831
        let codecType: CMVideoCodecType = codecTag ?? (format == .dolbyVision ? dvh1 : kCMVideoCodecType_HEVC)
        let effectiveRate = Float(frameRate ?? 24.0)
        let hasExtensions = isHDR && !omitColorExtensions

        // #133: skip the panel write when these criteria are already active. Re-writing identical criteria
        // triggers a redundant mode switch that, on unobservable-DV panels, sticks isDisplayModeSwitchInProgress
        // true and makes the following waitForSwitch burn its full ~3s cap on every same-format zap.
        let target = AppliedCriteria(isHDR: isHDR, effectiveRate: effectiveRate,
                                     codecType: codecType, hasExtensions: hasExtensions)
        // #133 follow-up diag: the unchanged-skip only fires for ~1/3-1/2 of eligible same-format zaps. When we have
        // a prior applied signature and still don't skip, log the exact field that diverged (rate/codec/HDR/ext or
        // didApply cleared) so the retest pinpoints why last != target instead of guessing.
        if didApply, let last = lastApplied, last != target {
            EngineLog.emit(
                "[DisplayCriteria] diag no-skip: signature diverged"
                + " rate \(last.effectiveRate)->\(target.effectiveRate)"
                + " codec \(fourccString(last.codecType))->\(fourccString(target.codecType))"
                + " hdr \(last.isHDR)->\(target.isHDR)"
                + " ext \(last.hasExtensions)->\(target.hasExtensions)",
                category: .engine
            )
        } else if !didApply, lastApplied == nil {
            EngineLog.emit(
                "[DisplayCriteria] diag no-skip: no baseline (didApply=false, lastApplied=nil) "
                + "-> first apply this controller instance (a RESET or a fresh controller cleared it)",
                category: .engine
            )
        }
        if case .unchanged = Self.applyOutcome(didApply: didApply, last: lastApplied, target: target) {
            // Keep lastCriteriaWasHDR consistent with the still-active criteria for any waitForSwitch classification.
            lastCriteriaWasHDR = isHDR
            EngineLog.emit(
                "[DisplayCriteria] skipped SET reason=unchanged (format=\(format) codec=\(fourccString(codecType)) "
                + "rate=\(frameRate.map { String(format: "%.3f", $0) } ?? "default(24)"))",
                category: .engine
            )
            return .unchanged
        }

        let transferFunction: CFString = switch format {
        case .hlg: kCVImageBufferTransferFunction_ITU_R_2100_HLG
        default:   kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
        }
        let extensions: NSDictionary? = hasExtensions ? [
            kCMFormatDescriptionExtension_ColorPrimaries: kCVImageBufferColorPrimaries_ITU_R_2020,
            kCMFormatDescriptionExtension_TransferFunction: transferFunction,
            kCMFormatDescriptionExtension_YCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_2020,
        ] : nil

        var formatDesc: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: codecType,
            width: 3840, height: 2160,
            extensions: extensions,
            formatDescriptionOut: &formatDesc
        )
        guard let desc = formatDesc else { return .applied }

        // Always pass the real rate; tvOS uses it when Match Frame Rate is on, ignores it otherwise (dynamic-range switch still fires).
        let criteria = AVDisplayCriteria(refreshRate: effectiveRate, formatDescription: desc)
        // #339: arm before the write. The switch this triggers can start and finish while the AVPlayerItem
        // is being built, and observers registered at gate entry miss both notifications; that is why two of
        // three device runs in Sodalite#49 never saw an end for a switch that was already over.
        observation.arm()
        displayManager.preferredDisplayCriteria = criteria
        didApply = true
        lastCriteriaWasHDR = isHDR
        lastApplied = target

        EngineLog.emit(
            "[DisplayCriteria] SET: format=\(format) codec=\(fourccString(codecType)) "
            + "rate=\(frameRate.map { String(format: "%.3f", $0) } ?? "default(24)") "
            + "extensions=\(extensions != nil ? "HDR" : "none")",
            category: .engine
        )
        // SDR rate-only switches are sub-second; only HDR criteria need the waitForSwitch delay.
        return isHDR ? .willSwitch : .applied
        #else
        return .applied
        #endif
    }

    /// Arm the mode-switch observation for a write this controller does not make.
    ///
    /// A sole-writer host (`LoadOptions.suppressDisplayCriteria`) leaves the criteria to AVKit, which writes
    /// them from the AVPlayerItem's formatDescription somewhere inside the load. The engine has to be
    /// listening before that load starts, not when the gate opens, or the same switch goes unobserved as in
    /// the engine-writer case (#339). Idempotent: re-arming only clears the record and keeps the observers.
    func armSwitchObservation() {
        #if os(tvOS)
        guard resolveWindow() != nil else { return }
        observation.arm()
        #endif
    }

    /// Block until the panel settles its HDR mode negotiation, bounded so an
    /// unobservable switch can't stall the first frame.
    ///
    /// Callers: the engine pre-flight gates this on `apply()`'s isHDR return; the
    /// play-gate call after the host loads sizes `startGrace` by what can still be
    /// inbound (`AetherEngine.playGateGrace`), so a session that no dynamic-range
    /// switch can reach doesn't pay the DV cold-start budget (#274).
    ///
    /// `preferredDisplayCriteria` is a *hint*: when Match Content is enabled the TV
    /// performs the switch over HDMI and reports progress via the AVDisplayManager
    /// mode-switch notifications. We proceed the instant the OS signals the switch
    /// is done (`AVDisplayManagerModeSwitchEndNotification`) or EDR headroom rises.
    /// Otherwise we bound the wait, because on some panels a Dolby Vision switch is
    /// effectively unobservable to the app: `currentEDRHeadroom` stays 1.0 and
    /// `isDisplayModeSwitchInProgress` can stick `true` even though the panel
    /// visibly enters DV. A blind fixed poll made every such load wait the full
    /// timeout. Presenting slightly early on that fallback is at worst cosmetic:
    /// the panel is mid re-sync (black) during the handshake and shows the correct
    /// frame once it locks. The decode/color-correctness guard is Stage 1 below.
    /// `consumesRecord: false` leaves the observation readable for the load's second gate. The pre-flight
    /// passes it: it waits an HDR switch out before the item is built, and the play gate that follows is
    /// entitled to the same start/end timestamps (#339).
    func waitForSwitch(startGrace: StartGrace = .full,
                       consumesRecord: Bool = true,
                       settleCap: SettleCap = .standard) async {
        #if os(tvOS)
        guard startGrace != .skip else { return }
        guard let window = resolveWindow() else { return }
        let displayManager = window.avDisplayManager
        let screen = window.screen
        let entry = DispatchTime.now()

        // #289: Match Content off means no writer can start a switch, so every millisecond of the budget is
        // dead startup time. The headroom fast-exit below cannot cover it: the panel never transitioned, so
        // the headroom sits at 1.0 and the wait runs its full Stage 1.
        guard Self.shouldWait(startGrace: startGrace,
                              matchingEnabled: displayManager.isDisplayCriteriaMatchingEnabled) else {
            EngineLog.emit("[DisplayCriteria] no wait: Match Content disabled, nothing can start a switch (skipped \(startGrace.budgetMs)ms Stage 1 budget)", category: .engine)
            return
        }

        // Fast exit: panel already in HDR (headroom already raised, e.g. a prior
        // HDR/DV session left it there) and not currently switching.
        if Self.entryHeadroomIsSettled(headroomAboveOne: observeHeadroom(screen),
                                       switchInProgress: displayManager.isDisplayModeSwitchInProgress) {
            EngineLog.emit("[DisplayCriteria] no switch needed (EDR headroom \(String(format: "%.2f", screen.currentEDRHeadroom)) at entry, panel not switching)", category: .engine)
            return
        }

        // What the observation armed at the criteria write already knows (#339). Everything the stages read
        // from here on is measured against this snapshot, so an end belonging to an older switch (the reset
        // a sole-writer load performs can produce one) cannot settle a gate waiting on a newer one.
        let gateSnapshot = observation.snapshot()
        var startSignal = StartSignal.none
        var stage1Ms = 0
        var preGateStartMs: Int?

        let observed: ObservedSwitch
        if Self.recordIsFreshEvidence(recordGeneration: gateSnapshot.generation,
                                      lastSpentGeneration: spentArmGeneration) {
            observed = Self.observedSwitch(
                startedAtNanos: gateSnapshot.startedAt,
                endedAtNanos: gateSnapshot.endedAt,
                gateEntryNanos: entry.uptimeNanoseconds,
                switchInProgress: displayManager.isDisplayModeSwitchInProgress)
        } else {
            observed = .none
        }
        if consumesRecord { spentArmGeneration = gateSnapshot.generation }

        switch observed {
        case .settled(let before, let measured):
            // The whole switch happened while the item was being built. Before #339 this run was
            // indistinguishable from an unobservable panel and paid the full Stage 2 cap for it.
            EngineLog.emit("[DisplayCriteria] switch settled before the gate opened (\(Self.timingSuffix(startSignal: .preGateObserved, stage1Ms: 0, totalMs: Self.elapsedMs(since: entry), startBeforeGateMs: before, switchMs: measured))); nothing left to wait for", category: .engine)
            return
        case .running(let before):
            // Start already recorded: Stage 1 has nothing to discover, only the end is still open.
            startSignal = .preGateObserved
            preGateStartMs = before
        case .none:
            break
        }

        // Stage 1: `startGrace` for the switch to actually start. The handshake
        // initiates asynchronously after the criteria write (and AVKit's sole-writer
        // path fires it later than the engine pre-flight), so give it headroom
        // before the DV asset loads; starting the decode mid-write races an
        // AVPlayer error on DV Profile 8.1.
        //
        // Which signal ends this stage is recorded, not just that one did: the in-progress flag being set on
        // the *first* poll means the panel was already switching while the item was built, which is the
        // ordering Sodalite#49 suspected. Reading that same flag on a later poll says the opposite (the
        // switch began after entry) and used to be logged as if it said the same, which is why the second
        // round of reporter logs still could not answer the question. `classifyStart` holds that line, and
        // with the observation armed at the write both of its flag-only verdicts now report a missing
        // notification rather than standing in for one.
        if startSignal == .none {
            var isFirstPoll = true
            while !Self.isBudgetSpent(elapsedMs: Self.elapsedMs(since: entry), budgetMs: startGrace.budgetMs) {
                let headroomSettles = observeHeadroom(screen)
                    && Self.startPhaseHeadroomSettles(
                        startRecorded: gateSnapshot.startedAt != nil || observation.hasNewStart(since: gateSnapshot),
                        switchInProgress: displayManager.isDisplayModeSwitchInProgress)
                if observation.hasNewEnd(since: gateSnapshot) || headroomSettles {
                    EngineLog.emit("[DisplayCriteria] settled during start phase (after \(Self.elapsedMs(since: entry))ms, EDR headroom \(String(format: "%.2f", screen.currentEDRHeadroom)))", category: .engine)
                    return
                }
                if let signal = Self.classifyStart(
                    isFirstPoll: isFirstPoll,
                    startNotificationFired: observation.hasNewStart(since: gateSnapshot),
                    switchInProgress: displayManager.isDisplayModeSwitchInProgress) {
                    startSignal = signal
                    break
                }
                isFirstPoll = false
                try? await Task.sleep(for: .milliseconds(10))
            }
            // Time spent, not the budget: the polls carry scheduler overhead, and everything downstream is
            // reported relative to this (#49).
            stage1Ms = Self.elapsedMs(since: entry)
            if startSignal == .none {
                // No switch started within the grace: panel already satisfies the criteria
                // or the setter was a no-op. Don't block; AVPlayer tonemaps or errors for real.
                EngineLog.emit("[DisplayCriteria] no switch started (EDR headroom \(String(format: "%.2f", screen.currentEDRHeadroom)) after \(stage1Ms)ms, budget \(startGrace.budgetMs)ms); proceeding", category: .engine)
                return
            }
        }

        // Stage 2: proceed as soon as ANY reliable signal says settled (the
        // mode-switch-end notification, EDR headroom rising for HDR10/HLG, or the
        // in-progress flag clearing), else a bounded ~2s cap so a panel whose DV
        // switch is unobservable to the app can't gate the first frame the way the
        // old fixed 5s poll did.
        // What this gate may spend waiting for the end, given who is waiting on it (`settleCapMs`).
        let capMs = Self.settleCapMs(
            cap: settleCap,
            startRecorded: gateSnapshot.startedAt != nil || observation.hasNewStart(since: gateSnapshot))
        let stage2Entry = DispatchTime.now()
        func timing() -> String {
            // The panel's own switch duration whenever both notifications were seen. This is the number the
            // `.brief` premise ("engine rate-only writes settle sub-second") has never been checked against
            // on hardware, and before #339 an engine-written switch could not produce it at all.
            let now = observation.snapshot()
            let switchMs: Int? = {
                guard let started = now.startedAt, let ended = now.endedAt, ended >= started else { return nil }
                return Self.elapsedMs(fromNanos: started, toNanos: ended)
            }()
            return Self.timingSuffix(startSignal: startSignal, stage1Ms: stage1Ms,
                                     totalMs: Self.elapsedMs(since: entry),
                                     startBeforeGateMs: preGateStartMs, switchMs: switchMs)
        }
        while !Self.isBudgetSpent(elapsedMs: Self.elapsedMs(since: stage2Entry), budgetMs: capMs) {
            try? await Task.sleep(for: .milliseconds(50))
            if observation.hasNewEnd(since: gateSnapshot) {
                EngineLog.emit("[DisplayCriteria] switch settled via modeSwitchEnd (\(timing()))", category: .engine)
                return
            }
            // Only meaningful when this load recorded no start: the headroom rises with the transition, so
            // during an observable switch it is the panel warming up, not the panel being done.
            if observeHeadroom(screen), Self.settlePhaseHeadroomSettles(
                startRecorded: gateSnapshot.startedAt != nil || observation.hasNewStart(since: gateSnapshot)) {
                EngineLog.emit("[DisplayCriteria] switch settled via EDR (\(timing()), headroom \(String(format: "%.2f", screen.currentEDRHeadroom)))", category: .engine)
                return
            }
            if !displayManager.isDisplayModeSwitchInProgress {
                // Headroom is still 1.0 here (the EDR check above runs first each tick).
                switch Self.criteriaAttribution(didApply: didApply, lastCriteriaWasHDR: lastCriteriaWasHDR) {
                case .engineRateOnly:
                    // SDR rate-only criteria: refresh-rate switch settled, panel correctly stayed SDR.
                    EngineLog.emit("[DisplayCriteria] rate-only switch settled (\(timing()), SDR, EDR headroom 1.0 as expected)", category: .engine)
                case .engineHDR:
                    // Headroom 1.0 after an HDR write is NOT evidence of a refusal. The value is only raised
                    // by a dynamic-range transition, so a panel that was already in HDR reads identically to
                    // one that refused. The proof is the tie-breaker this line used to lack, and without it
                    // it accused a panel that was demonstrably showing HDR at that moment.
                    EngineLog.emit(panelProvenToEngageHDR
                        ? "[DisplayCriteria] switch ended (\(timing())) at EDR headroom 1.0; this panel is proven to engage HDR, so it was already in the target mode and no transition raised the headroom"
                        : "[DisplayCriteria] WARN switch ended (\(timing())) at EDR headroom 1.0 and this panel has never been observed engaging HDR: rate-only matching, or a real dynamic-range handshake failure",
                        category: .engine)
                case .hostDriven:
                    // #274: sole-writer host. The engine wrote nothing, so it has no target range to compare
                    // the SDR end state against; a host SDR rate write ending SDR is correct and used to be
                    // logged as an HDR handshake failure.
                    EngineLog.emit("[DisplayCriteria] host switch ended (\(timing()), EDR headroom 1.0; engine wrote no criteria this session, target range unknown)", category: .engine)
                }
                return
            }
        }
        // Cap reached: the in-progress flag never cleared. "Unobservable DV panel" was the blanket
        // explanation, but it only fits an HDR write; an engine rate-only write sitting here for two
        // seconds contradicts the sub-second premise the .brief budget rests on and is worth reading as
        // its own event (Sodalite#49). Two of the reporter's three second-round runs landed here, both
        // rate-only SDR, so this is the common outcome on that panel rather than an edge case.
        let headroom = String(format: "%.2f", screen.currentEDRHeadroom)
        switch Self.criteriaAttribution(didApply: didApply, lastCriteriaWasHDR: lastCriteriaWasHDR) {
        case .engineRateOnly:
            EngineLog.emit("[DisplayCriteria] proceed after cap (\(timing()); engine rate-only criteria, switch never reported end, panel may still be mid-switch; EDR headroom \(headroom))", category: .engine)
        case .engineHDR:
            // "Unobservable DV panel" was the blanket reading here, but a panel that was already in HDR
            // when the criteria were re-written produces the same silence: no transition, so no headroom
            // rise and no end within the cap. The proof separates the two.
            EngineLog.emit(panelProvenToEngageHDR
                ? "[DisplayCriteria] proceed after cap (\(timing()); engine HDR criteria on a panel proven to engage HDR, so most likely already in the target mode; EDR headroom \(headroom))"
                : "[DisplayCriteria] proceed after cap (\(timing()); engine HDR criteria, switch not observable, likely DV; EDR headroom \(headroom))",
                category: .engine)
        case .hostDriven:
            EngineLog.emit("[DisplayCriteria] proceed after cap (\(timing()); engine wrote no criteria this session, switch not observable; EDR headroom \(headroom))", category: .engine)
        }
        #endif
    }

    /// Measure the refresh rate the panel is actually running at, by timing display-link ticks over
    /// `ticks` callbacks (~0.7 s at 60 Hz). tvOS exposes no read-back of the mode a criteria write landed
    /// on (`UIScreen.maximumFramesPerSecond` reports what the screen is capable of, not the active HDMI
    /// mode), so this is the only evidence that separates a panel which ignored the criteria and kept the
    /// system rate from one that took a rate not dividing the content rate (60.000 for 29.970 content).
    /// Returns the measured rate plus the mode's nominal rate from the link's frame duration.
    func measureRefreshRate(ticks: Int = 40) async -> (measured: Double, nominal: Double)? {
        #if os(tvOS)
        guard let window = resolveWindow() else { return nil }
        let sampler = DisplayLinkSampler()
        sampler.start(screen: window.screen)
        for _ in 0..<120 {
            if sampler.tickCount >= ticks { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return sampler.finish()
        #else
        return nil
        #endif
    }

    /// Whether the panel presents this session in HDR, read after apply() + waitForSwitch() settle. A live
    /// headroom above 1.0 answers it; a decayed one is answered by `panelPresentsHDR` from what this display
    /// has already proven, because the headroom is a transition artifact and its absence proves nothing.
    func currentPanelIsHDR() -> Bool {
        #if os(tvOS)
        guard let window = resolveWindow() else { return false }
        return Self.panelPresentsHDR(
            headroomAboveOne: observeHeadroom(window.screen),
            attribution: Self.criteriaAttribution(didApply: didApply, lastCriteriaWasHDR: lastCriteriaWasHDR),
            panelProvenToEngageHDR: panelProvenToEngageHDR
        )
        #else
        return false
        #endif
    }

    #if os(tvOS)
    /// Single funnel for every headroom read, so one observation of a real HDR engage is remembered after the
    /// value decays. Returns whether the panel reports HDR right now.
    private func observeHeadroom(_ screen: UIScreen) -> Bool {
        guard screen.currentEDRHeadroom > 1.001 else { return false }
        if !panelProvenToEngageHDR {
            EngineLog.emit("[DisplayCriteria] panel proven to engage HDR (headroom \(String(format: "%.2f", screen.currentEDRHeadroom))); later sessions trust an accepted HDR write even after the headroom decays", category: .engine)
            panelProvenToEngageHDR = true
        }
        return true
    }
    #endif

    /// Nil-out preferredDisplayCriteria to return the panel to default. No-op when apply() was never called this session (suppressed host) to avoid racing AVKit's in-flight criteria management.
    func reset() {
        #if os(tvOS)
        guard didApply else { return }
        guard let window = resolveWindow() else {
            didApply = false
            lastApplied = nil
            return
        }
        window.avDisplayManager.preferredDisplayCriteria = nil
        didApply = false
        lastApplied = nil   // #133: a RESET returns the panel to default; the next apply must re-establish it.
        EngineLog.emit("[DisplayCriteria] RESET", category: .engine)
        #endif
    }

    // MARK: - Window resolution

    #if os(tvOS)
    private func resolveWindow() -> UIWindow? {
        if let provider = Self.windowProvider, let win = provider() as? UIWindow {
            return win
        }
        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first
    }

    #endif
}

#if os(tvOS)
/// Records `AVDisplayManager` mode-switch notifications from the moment a criteria write is imminent.
///
/// `waitForSwitch` used to register these observers when it opened, which is after the engine's own write and
/// sometimes after the switch that write triggers has already finished. Both notifications then landed
/// outside the window and the gate fell back on `isDisplayModeSwitchInProgress`, a flag its own call site
/// documents as unreliable right after a write. Sodalite#49's device logs are that defect twice over: two
/// runs spent the entire Stage 2 cap waiting for an end that had happened, and a third labelled a switch it
/// had watched begin as one that predated it (#339).
///
/// Notifications arrive on an arbitrary queue, so every field is lock-guarded. The counters exist to keep
/// "recorded before I looked" apart from "arrived while I waited": an end belonging to an older switch must
/// never settle a gate that is waiting on a newer one.
private final class SwitchObservation: @unchecked Sendable {
    struct Snapshot {
        let startedAt: UInt64?
        let endedAt: UInt64?
        let startCount: Int
        let endCount: Int
        /// Bumped by every arm, 0 until the first one. Lets a gate tell a record written for this load from
        /// one left by the previous load, which must not settle anything.
        let generation: Int
    }

    private let lock = NSLock()
    private var startedAt: UInt64?
    private var endedAt: UInt64?
    private var startCount = 0
    private var endCount = 0
    private var generation = 0
    private var tokens: [NSObjectProtocol] = []

    /// Clear the record and, on first use, register. Called immediately before a criteria write so
    /// everything the following gate reads belongs to that write.
    ///
    /// `object: nil` is the load-bearing part. tvOS posts both notifications from an
    /// **`AVSharedDisplayManager`**, not from the `AVDisplayManager` that `window.avDisplayManager` returns
    /// and that `preferredDisplayCriteria` is written to. Filtering on that manager, which is what this code
    /// did from the start, dropped every notification the settle gate exists to read. Device probe, Apple TV
    /// 4K (3rd gen), tvOS 26.5, 2026-08-09, listening on all objects:
    ///
    ///     FIRED AVDisplayManagerModeSwitchStartNotification object=AVSharedDisplayManager@0x10b581a10
    ///     our manager=AVDisplayManager@0x1036fdfa0
    ///
    /// Six start/end pairs arrived that way in three playbacks while the engine's filtered observers saw
    /// none. That, not the registration point, is why no run in Sodalite#49 ever reported an end.
    func arm() {
        lock.lock()
        startedAt = nil
        endedAt = nil
        startCount = 0
        endCount = 0
        generation += 1
        let needsRegistration = tokens.isEmpty
        lock.unlock()

        guard needsRegistration else { return }
        // Weak, or the token retains the block retains this object for the process lifetime.
        let start = NotificationCenter.default.addObserver(
            forName: .AVDisplayManagerModeSwitchStart, object: nil, queue: nil
        ) { [weak self] _ in self?.record(isStart: true) }
        let end = NotificationCenter.default.addObserver(
            forName: .AVDisplayManagerModeSwitchEnd, object: nil, queue: nil
        ) { [weak self] _ in self?.record(isStart: false) }
        lock.lock()
        tokens = [start, end]
        lock.unlock()
    }

    /// First start since arming (so a switch is measured from its beginning), latest end.
    private func record(isStart: Bool) {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        if isStart {
            startedAt = startedAt ?? now
            startCount += 1
        } else {
            endedAt = now
            endCount += 1
        }
        lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(startedAt: startedAt, endedAt: endedAt,
                        startCount: startCount, endCount: endCount, generation: generation)
    }

    func hasNewStart(since snapshot: Snapshot) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return startCount > snapshot.startCount
    }

    func hasNewEnd(since snapshot: Snapshot) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return endCount > snapshot.endCount
    }

    deinit {
        tokens.forEach { NotificationCenter.default.removeObserver($0) }
    }
}

/// Times display-link ticks so the caller can read the active HDMI mode's refresh rate. Enough ticks
/// separate 59.940 from 60.000 (a 0.1% miss against 29.970 content is a repeated frame every ~16 s).
@MainActor
private final class DisplayLinkSampler: NSObject {
    private var link: CADisplayLink?
    private var firstTimestamp: CFTimeInterval = 0
    private var lastTimestamp: CFTimeInterval = 0
    private var nominalDuration: CFTimeInterval = 0
    private(set) var tickCount = 0

    func start(screen: UIScreen) {
        let link = screen.displayLink(withTarget: self, selector: #selector(tick(_:)))
        link?.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        nominalDuration = link.targetTimestamp - link.timestamp
        if tickCount == 0 { firstTimestamp = link.timestamp }
        lastTimestamp = link.timestamp
        tickCount += 1
    }

    func finish() -> (measured: Double, nominal: Double)? {
        link?.invalidate()
        link = nil
        guard tickCount >= 2, lastTimestamp > firstTimestamp else { return nil }
        return (
            measured: Double(tickCount - 1) / (lastTimestamp - firstTimestamp),
            nominal: nominalDuration > 0 ? 1.0 / nominalDuration : 0
        )
    }
}
#endif
