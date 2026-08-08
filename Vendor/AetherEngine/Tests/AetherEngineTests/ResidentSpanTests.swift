import Testing
import Foundation
@testable import AetherEngine

/// #281: the span is the piece both halves of the cold-start fix stand on, so its boundaries are
/// pinned here rather than inferred from the reader's behaviour.
@Suite("Resident spans (#281)")
struct ResidentSpanTests {

    private func span(start: Int64, bytes: [UInt8]) -> ResidentSpan {
        ResidentSpan(start: start, data: Data(bytes))
    }

    private func read(_ s: ResidentSpan, at offset: Int64, maxLen: Int) -> [UInt8]? {
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: max(1, maxLen))
        defer { buf.deallocate() }
        guard let n = s.serve(into: buf, maxLen: maxLen, at: offset) else { return nil }
        return Array(UnsafeBufferPointer(start: buf, count: n))
    }

    @Test("serves from the middle of the span at the right offset")
    func servesFromMiddle() {
        let s = span(start: 100, bytes: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9])
        #expect(read(s, at: 103, maxLen: 4) == [3, 4, 5, 6])
    }

    @Test("serves the first byte and the last byte")
    func servesEdges() {
        let s = span(start: 100, bytes: [0, 1, 2, 3, 4])
        #expect(read(s, at: 100, maxLen: 1) == [0])
        #expect(read(s, at: 104, maxLen: 1) == [4])
    }

    /// The caller re-enters at the advanced offset, so a read crossing the end is a short serve,
    /// never a miss and never a read past the buffer.
    @Test("a read crossing the end is truncated to the span boundary")
    func truncatesAtEnd() {
        let s = span(start: 100, bytes: [0, 1, 2, 3, 4])
        #expect(read(s, at: 103, maxLen: 64) == [3, 4])
    }

    @Test("an offset outside the span misses rather than serving neighbouring bytes")
    func missesOutside() {
        let s = span(start: 100, bytes: [0, 1, 2, 3, 4])
        #expect(read(s, at: 99, maxLen: 4) == nil)
        #expect(read(s, at: 105, maxLen: 4) == nil)
        #expect(read(s, at: 0, maxLen: 4) == nil)
    }

    @Test("an empty span never serves")
    func emptySpanNeverServes() {
        let s = ResidentSpan(start: 100, data: Data())
        #expect(s.isEmpty)
        #expect(read(s, at: 100, maxLen: 4) == nil)
    }

    @Test("a zero-length request misses instead of serving nothing successfully")
    func zeroLengthMisses() {
        let s = span(start: 100, bytes: [0, 1, 2])
        #expect(s.serve(into: UnsafeMutablePointer<UInt8>.allocate(capacity: 1), maxLen: 0, at: 100) == nil)
    }

    @Test("covers reports the half-open range")
    func coversIsHalfOpen() {
        let s = span(start: 100, bytes: [0, 1, 2, 3, 4])
        #expect(s.covers(100))
        #expect(s.covers(104))
        #expect(!s.covers(105))
        #expect(!s.covers(99))
        #expect(s.end == 105)
    }
}
