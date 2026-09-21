import Foundation
import Testing
@testable import AetherEngine

/// AE#526: the no-argument reload refused in silence, and a host cannot tell that from a reload that
/// worked.
///
/// Measured on a device: a live direct-ingest session (a custom, forward-only source) was torn down
/// by the paused-background grace window (#127), the host called `reloadAtCurrentPosition()` on the
/// way back in, the call returned without doing anything or saying anything, and the player sat on a
/// spinner for twenty minutes. The vocabulary for refusing already existed one file over and this
/// path was the one that did not use it.
@Suite("AE#526 a refusal is said out loud")
struct Issue526ReloadRefusalIsSpokenTests {

    @Test("the refusal a forward-only custom source earns is the one the reader already names")
    func theRefusalIsTheExistingOne() {
        // `sessionReloadRefusal` has answered this question correctly the whole time. The throwing
        // path now returns the same word rather than nothing at all.
        #expect(SessionReloadRefusal.customSourceNotSeekable.rawValue == "customSourceNotSeekable")
        #expect(SessionReloadRefusal.customSourceNotSeekable.description
                == "the custom source is not seekable")
    }

    @Test("it is an error a host can catch, not a silent return")
    func itIsThrown() {
        let error = AetherEngineError.sessionNotReloadable(.customSourceNotSeekable)
        #expect(error.errorDescription?.isEmpty == false)
        // A host that switches on the refusal can tell "cannot be rebuilt" from "nothing was loaded",
        // which is what decides between tuning again and showing nothing.
        guard case .sessionNotReloadable(let refusal) = error else {
            Issue.record("expected a reload refusal")
            return
        }
        #expect(refusal == .customSourceNotSeekable)
        #expect(refusal != .noActiveSession)
    }
}
