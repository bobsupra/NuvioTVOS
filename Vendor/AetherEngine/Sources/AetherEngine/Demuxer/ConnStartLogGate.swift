import Foundation

/// Decides which `conn start` lines a reader writes.
///
/// A reader walking forward on a fast link starts a bounded range every few hundred milliseconds
/// (32 MiB at gigabit is 0.29 s), and the subtitle prefetcher walks up to 270 s of lead that way
/// when an OCR worker is armed. One line per range then filled a 300-line host log buffer with a
/// single 40 s playback (Sodalite#117). A range that picks up exactly where the previous one ended
/// says nothing new about who is on the link, so contiguous starts log at most once per interval
/// and the next line that does log carries the count it stood for. A start anywhere else (first
/// connection, seek, reconnect mid-range) always logs.
struct ConnStartLogGate {
    static let contiguousInterval: TimeInterval = 10

    private var lastEmitAt: TimeInterval?
    private var suppressed = 0

    /// nil = skip this line. Otherwise emit it, with the number of contiguous starts skipped since
    /// the previous emitted line.
    mutating func admit(continuesPrevious: Bool, now: TimeInterval) -> Int? {
        if continuesPrevious, let lastEmitAt, now - lastEmitAt < Self.contiguousInterval {
            suppressed += 1
            return nil
        }
        let skipped = suppressed
        suppressed = 0
        lastEmitAt = now
        return skipped
    }
}
