import Foundation

/// A mixed MP4 can carry valid ctts at the head and zero offsets in a later IDR sequence.
/// Restore that sequence's display ownership of the ORIGINAL timestamp slots, the way #511 does
/// for Matroska: the slot is READ from the file, never fitted to a cadence, so an interval change
/// inside the sequence is reproduced rather than guessed away.
///
/// The slot a picture needs is a packet away, not a plan away. A picture coded ahead of its own
/// slot waits exactly the mini-GOP the reorder created, so nothing is held for the length of a
/// sequence and no sequence is too long to repair.
enum H264PartialCompositionRepair {
    /// A picture cannot sit further from its own slot than the reorder delay the container
    /// declares. `video_delay` is the honest bound; this is only the ceiling on believing it.
    static let maximumReorderDepth = 16
    /// A sequence past this is not a GOP any more, and the ladder is one Int64 per picture.
    static let maximumPictures = 1 << 16
    /// Interleaving, not reordering, decides how many foreign packets sit inside the wait. A
    /// container that puts more than this between two video packets gives up its repair rather
    /// than its playback.
    static let maximumHeldPackets = 1024
    static let maximumHeldBytes = 32 << 20
    /// A candidate sequence has to show its reordering before anything is rewritten. A stream
    /// that reorders at all shows it within its reorder delay; this is slack, not a policy.
    static let maximumProofPictures = 64

    enum Claim: Equatable {
        /// The slot is still ahead of the reader. The picture waits, and so does everything
        /// behind it, because the container's own order is what leaves this demuxer.
        case wait
        case time(Int64)
        /// Not a shape this policy owns. The caller hands the packets back as they arrived.
        case refuse
    }

    /// The decode slots of one coded video sequence, in the order they are read.
    struct SlotLadder {
        private var slots: [Int64] = []
        private var claimed: [Bool] = []

        var count: Int { slots.count }
        var isEmpty: Bool { slots.isEmpty }

        /// Records the next decode slot. False when the ladder stops being one: a slot that does
        /// not rise is not a decode ladder, and a missing timestamp is not a slot at all.
        mutating func append(dts: Int64) -> Bool {
            guard dts != Int64.min, slots.count < Self.limit else { return false }
            if let last = slots.last, dts <= last { return false }
            slots.append(dts)
            claimed.append(false)
            return true
        }

        /// The presentation time the picture at `decodeIndex` owns, given its display `rank`.
        /// `.wait` while its slot is still ahead of the reader, which is the mini-GOP.
        mutating func claim(rank: Int, decodeIndex: Int, lead: Int64, reorderDepth: Int) -> Claim {
            guard lead > 0, rank >= 0, decodeIndex >= 0, decodeIndex < slots.count,
                  abs(rank - decodeIndex) <= reorderDepth, rank < Self.limit else { return .refuse }
            guard rank < slots.count else { return .wait }
            // One slot, one picture. A rank claimed twice is a sequence this policy cannot own.
            guard !claimed[rank] else { return .refuse }
            let (pts, overflow) = slots[rank].addingReportingOverflow(lead)
            guard !overflow, pts >= slots[decodeIndex] else { return .refuse }
            claimed[rank] = true
            return .time(pts)
        }

        private static var limit: Int { H264PartialCompositionRepair.maximumPictures }
    }
}
