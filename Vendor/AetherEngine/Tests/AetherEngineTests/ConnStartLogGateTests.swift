import Testing
import Foundation
@testable import AetherEngine

/// Sodalite#117: a subtitle prefetcher walking forward at gigabit wrote a `conn start` line every
/// 0.29 s and filled the host's 300-line log with one 40 s playback. The gate summarises contiguous
/// ranges and never hides a start that repositions the reader.
struct ConnStartLogGateTests {

    @Test("the first start logs, even when marked contiguous")
    func firstStartLogs() {
        var gate = ConnStartLogGate()
        #expect(gate.admit(continuesPrevious: true, now: 0) == 0)
    }

    @Test("a contiguous walk logs once per interval and the next line carries the skipped count")
    func contiguousWalkIsSummarised() {
        var gate = ConnStartLogGate()
        #expect(gate.admit(continuesPrevious: false, now: 0) == 0)
        var logged: [Int] = []
        // 100 ranges 0.29 s apart, the reported cadence: 29 s of walking.
        for i in 1...100 {
            if let skipped = gate.admit(continuesPrevious: true, now: Double(i) * 0.29) {
                logged.append(skipped)
            }
        }
        #expect(logged.count == 2, "a 29 s walk should log at 10 s and 20 s, got \(logged.count) lines")
        #expect(logged.reduce(0, +) + logged.count <= 100)
    }

    @Test("a start that does not continue the previous range always logs, with the pending count")
    func repositionAlwaysLogs() {
        var gate = ConnStartLogGate()
        _ = gate.admit(continuesPrevious: false, now: 0)
        #expect(gate.admit(continuesPrevious: true, now: 0.3) == nil)
        #expect(gate.admit(continuesPrevious: true, now: 0.6) == nil)
        #expect(gate.admit(continuesPrevious: false, now: 0.9) == 2)
        #expect(gate.admit(continuesPrevious: false, now: 1.0) == 0)
    }
}
