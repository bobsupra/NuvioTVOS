import Foundation

/// Packet payload, EOF, errors and deferred end-of-media work all belong to the same read
/// generation. The host obtains requested/settled generations together under its seek-state lock.
/// A pause is not a new generation; stop or an open/completed newer seek rejects old work.
enum SoftwareReadAdmission {
    static func admits(readGeneration: UInt64, requestedGeneration: UInt64,
                       settledGeneration: UInt64, stopRequested: Bool) -> Bool {
        !stopRequested && readGeneration == requestedGeneration
            && requestedGeneration == settledGeneration
    }
}

/// The combined VOD loop stays alive after one EOF/error publication. MainActor may reject that
/// publication when a seek supersedes it; a permanently exited loop could not serve the new seek.
/// The owning loop uses its condition variable while parked, waking on stop or a new generation.
struct SoftwareTerminalGeneration {
    private var terminal: UInt64?

    /// true exactly once per terminal generation; prevents duplicate EOF/error callbacks.
    mutating func record(_ generation: UInt64) -> Bool {
        guard terminal != generation else { return false }
        terminal = generation
        return true
    }

    func shouldPark(generation: UInt64) -> Bool {
        terminal == generation
    }
}
