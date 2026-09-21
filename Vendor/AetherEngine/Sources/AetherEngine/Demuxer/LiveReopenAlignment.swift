import Foundation

/// Where a freshly allocated `AVIOContext` should start reading when the source behind it is a
/// live reader the engine RETAINED across a rebuild (AE#460 follow-up).
///
/// A custom live source is rebuilt on its own reader rather than reopened by URL: an option
/// correction (`reloadAtCurrentPosition(applying:)`), an audio-track switch, a background return.
/// The reader is still where the session left it, but a fresh `AVIOContext` starts its byte axis at
/// 0 regardless, so libavformat reads the host's spool from the base. Measured on
/// `aetherctl customio --live`: the playhead fell from 41.5 s to 1.9 s and the host was asked to
/// re-deliver every byte it had already delivered (15 MB, a 61 s window, at I/O speed).
///
/// Aligning the axis to the cursor makes the rebuild the edge rejoin `LiveReloadPolicy` already
/// promises on the URL branch, where a live reload is a fresh join by policy.
///
/// Pure so the rule is pinned without a container: the three inputs decide, and the caller only
/// performs the seek.
enum LiveReopenAlignment {

    enum Decision: Equatable {
        /// Read from where the context already is. A first open (cursor at 0) and every VOD open
        /// land here: VOD needs byte 0 to parse its header, and the backend seeks to the resume
        /// position afterwards.
        case readFromCurrentPosition
        /// Seek the fresh context to this byte offset before the container is opened.
        case alignTo(Int64)
        /// The source survives the rebuild but will not say where it is, so the reopen reads it
        /// from the base. Named rather than silent: on a live host that is a rewind.
        case cannotAlignReaderSilentOnPosition
    }

    /// `sourceSurvivesReopen` is what separates the two nils: a provider that opens its own
    /// transport per session (the HTTP reader) starts at 0 because there is nothing older to be at,
    /// while a retained host reader that will not report its cursor is a case worth naming.
    /// `currentSourceOffset` is an autoclosure because reading it calls into the host's reader, and
    /// every ordinary open would otherwise pay that call to reach a guard that ignores it.
    static func decision(
        isLive: Bool,
        isSeekable: Bool,
        sourceSurvivesReopen: Bool,
        currentSourceOffset: @autoclosure () -> Int64?
    ) -> Decision {
        guard isLive, isSeekable, sourceSurvivesReopen else { return .readFromCurrentPosition }
        switch currentSourceOffset() {
        case .some(let offset) where offset > 0: return .alignTo(offset)
        case .some: return .readFromCurrentPosition
        case .none: return .cannotAlignReaderSilentOnPosition
        }
    }

    /// What the alignment achieved, read back from the READER rather than from the seek's own
    /// return value (AE#460 round 3).
    ///
    /// `avio_seek` reports the AVIO axis, which for a successful `SEEK_SET` is the offset that was
    /// asked for, so its return proves the reader accepted the seek and nothing more. Whether the
    /// reader is still where the axis was aligned TO has exactly one witness: the reader's own
    /// second position report.
    ///
    /// It can differ, because aligning the axis round-trips the reported cursor back through the
    /// reader's `SEEK_SET`. A reader that reports its position on one axis and takes `SEEK_SET` on
    /// another (absolute one way, relative to a join offset the other) therefore MOVES under an
    /// alignment meant to leave it alone, and on a live spool that is the rewind this whole rule
    /// exists to prevent. libavformat's own probe seeks travel the same axis, so the agreement is a
    /// contract either way (`docs/formats.md`); this only makes breaking it visible in one line
    /// instead of in a host's re-delivered window.
    enum Verification: Equatable {
        /// The axis moved and the reader did not, which is the whole invariant.
        case aligned
        /// The reader refused the seek. The reopen reads from wherever the context is instead.
        case seekRefused(landed: Int64)
        /// The reader answered the seek and then reported itself somewhere else, so its position
        /// report and its `SEEK_SET` argument are not on the same axis.
        case readerMovedUnderAlignment(to: Int64)
    }

    /// `readerReportsAfter` is nil for a reader that will not report a position at all, which the
    /// decision above already named and which is not re-judged here.
    static func verify(
        requestedOffset: Int64,
        avioLanded: Int64,
        readerReportsAfter: Int64?
    ) -> Verification {
        guard avioLanded == requestedOffset else { return .seekRefused(landed: avioLanded) }
        guard let after = readerReportsAfter, after != requestedOffset else { return .aligned }
        return .readerMovedUnderAlignment(to: after)
    }
}
