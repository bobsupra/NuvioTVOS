import Foundation

@main
struct SoftwareReadAdmissionTests {
    static func main() {
        let admits = SoftwareReadAdmission.admits
        precondition(admits(0, 0, 0, false))
        for read: UInt64 in [0, 1, 2, .max] {
            for requested: UInt64 in [0, 1, 2, .max] {
                for settled: UInt64 in [0, 1, 2, .max] {
                    for stopped in [false, true] {
                        precondition(admits(read, requested, settled, stopped)
                            == (!stopped && read == requested && requested == settled))
                    }
                }
            }
        }
        // The first new-generation packet must not be consumed by an old host iteration that
        // enters the cache only after a seek has already opened and settled its own generation.
        precondition(!admits(7, 8, 8, false))
        // EOF and errors use the exact same gate BEFORE their terminal branches.
        for _ in ["packet", "EOF", "error", "closed", "delayed onEnd", "tail park"] {
            precondition(!admits(7, 8, 7, false))
            precondition(!admits(7, 8, 8, false))
            precondition(!admits(8, 8, 7, false))
            precondition(!admits(8, 8, 8, true))
            precondition(admits(8, 8, 8, false))
        }
        var terminal = SoftwareTerminalGeneration()
        precondition(!terminal.shouldPark(generation: 7))
        precondition(terminal.record(7))
        precondition(!terminal.record(7))
        precondition(terminal.shouldPark(generation: 7))
        // EOF has been read and its callback queued, but a seek wins MainActor first. The old
        // callback is rejected, and the still-live consumer is released for generation 8.
        precondition(!admits(7, 8, 8, false))
        precondition(!terminal.shouldPark(generation: 8))
        precondition(admits(8, 8, 8, false))
        precondition(terminal.record(8))
        precondition(!terminal.record(8))
        precondition(terminal.shouldPark(generation: 8))
        precondition(!admits(8, 8, 8, true)) // stop exits the condition wait, not a new EOF.
        print("PASS: host read admission across old/new/open/settled seek generations; stale EOF/errors/tail tasks rejected; terminal callbacks once per generation and superseding seek resumes consumer")
    }
}
