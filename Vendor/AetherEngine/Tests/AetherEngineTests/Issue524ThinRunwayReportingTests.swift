import Foundation
import Testing
@testable import AetherEngine

/// AE#524 round 2: the thin-runway line fired 17 ms after a load, on an item that could not have
/// fetched anything yet, and read `0.00s of fetched runway, playhead 0.00s against a seekable edge
/// of 0.00s`. That is a non-measurement in the shape of a measurement, reported from the field on
/// AE#440. The line exists for a session that DECAYS, so a thin reading counts only once the item
/// being measured has been seen holding the floor.
@Suite("AE#524 a thin runway is a decay, not a mount")
struct Issue524ThinRunwayReportingTests {

    // MARK: - The mount

    /// The reported shape: the first reading of a fresh load is empty because nothing has been placed
    /// yet, not because the client is running out.
    @Test("an item that has never held the floor stays silent")
    func freshMountDoesNotReport() {
        #expect(!AetherEngine.reportsThinLiveRunway(
            itemGeneration: 1, healthyGeneration: nil, alreadyNoted: false))
    }

    /// The case the line was written for: 57 s of healthy fetching, then the deficit accumulates.
    @Test("a thin reading on an item that held the floor reports")
    func decayReports() {
        #expect(AetherEngine.reportsThinLiveRunway(
            itemGeneration: 1, healthyGeneration: 1, alreadyNoted: false))
    }

    /// One line per episode, not one per second: the caller latches, and the latch is cleared by a
    /// reading back above the floor.
    @Test("a second thin second stays silent")
    func reportsOncePerEpisode() {
        #expect(!AetherEngine.reportsThinLiveRunway(
            itemGeneration: 1, healthyGeneration: 1, alreadyNoted: true))
    }

    // MARK: - The swap

    /// An in-place swap (#446 rejoin) mounts a fresh item on a session whose playhead and edge are
    /// real, and that item holds nothing for about 190 ms. Time since load cannot separate that from
    /// a decay; the item can. The previous item's health does not travel.
    @Test("health does not carry across an item swap")
    func swapDisarms() {
        #expect(!AetherEngine.reportsThinLiveRunway(
            itemGeneration: 2, healthyGeneration: 1, alreadyNoted: false))
    }

    /// And the swapped-in item earns the line for itself as soon as it has been healthy once.
    @Test("the swapped-in item reports once it has held the floor")
    func swappedItemReportsAfterItsOwnHealth() {
        #expect(AetherEngine.reportsThinLiveRunway(
            itemGeneration: 2, healthyGeneration: 2, alreadyNoted: false))
    }

    /// Paths with no native host read generation -1 for the whole session (software live), which is a
    /// stable item rather than a missing one, so the rule must treat it like any other.
    @Test("a hostless session is one item, not none")
    func hostlessSessionIsStable() {
        #expect(!AetherEngine.reportsThinLiveRunway(
            itemGeneration: -1, healthyGeneration: nil, alreadyNoted: false))
        #expect(AetherEngine.reportsThinLiveRunway(
            itemGeneration: -1, healthyGeneration: -1, alreadyNoted: false))
    }
}
