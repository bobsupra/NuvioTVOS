import Foundation
import AVFoundation

/// Off-main hop for batched synchronous AVFoundation property reads (#134). Getters backed by
/// figplayer (`accessLog`, `currentTime`, `loadedTimeRanges`, ...) are sync XPC round-trips to
/// mediaserverd; on the main actor a momentarily busy media server turns any of them into a
/// fully blocked main thread and, past the watchdog threshold, a process kill. Batch such reads
/// in `body` and run them here on a caller-owned serial queue: a stalled reply then parks a GCD
/// thread, not the main thread or the shared cooperative pool.
///
/// `refs` crosses the isolation boundary unchecked; `body` must restrict itself to documented
/// thread-safe AVFoundation getters and must not touch actor-isolated state.
enum AVFoundationOffMain {
    private struct UncheckedRefs<Refs>: @unchecked Sendable {
        let refs: Refs
    }

    static func read<Refs, T: Sendable>(
        _ refs: Refs,
        on queue: DispatchQueue,
        _ body: @escaping @Sendable (Refs) -> T
    ) async -> T {
        let boxed = UncheckedRefs(refs: refs)
        return await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: body(boxed.refs))
            }
        }
    }
}
