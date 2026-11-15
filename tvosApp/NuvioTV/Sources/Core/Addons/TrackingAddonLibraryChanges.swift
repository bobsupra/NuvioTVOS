import Foundation

/// Library changes made through a remote library service (Trakt, Simkl,
/// MDBList, WeTrakr), told to tracking add-ons only once the service confirms
/// them.
///
/// Stremio's library events describe what the library is, not what the user
/// asked for: an add-on told `libraryAdd` for a change that then fails stays
/// wrong, since nothing corrects it. Each title's changes run one after
/// another, so rapid add/remove/add from Details, poster cards or Home is
/// confirmed and reported in the order it happened; #514's per-add-on queue
/// then delivers in that order.
@MainActor
enum TrackingAddonLibraryChanges {
    /// How a confirmed change is reported (tests replace it).
    static var report: (Bool, NuvioMeta) -> Void = { isInLibrary, meta in
        TrackingAddonService.sendLibraryMembership(isInLibrary, meta: meta)
    }

    private static var tails: [String: Task<Void, Never>] = [:]

    /// Runs `mutation` after any earlier change for the same title. If it
    /// succeeds, tracking add-ons are told the title is now (or no longer) in
    /// the library. A change cancelled before it runs does nothing.
    /// `completion` gets the result on the main actor, for the caller's UI.
    @discardableResult
    static func perform(
        _ isInLibrary: Bool,
        meta: NuvioMeta,
        mutation: @escaping @MainActor () async -> Bool,
        completion: (@MainActor (Bool) -> Void)? = nil
    ) -> Task<Void, Never> {
        let key = "\(meta.type):\(meta.id)"
        let previous = tails[key]
        let task = Task { @MainActor in
            if let previous { await previous.value }
            guard !Task.isCancelled else {
                completion?(false)
                return
            }
            let succeeded = await mutation()
            // Reported even if the caller's screen moved on: the library did change.
            if succeeded { report(isInLibrary, meta) }
            completion?(succeeded)
        }
        tails[key] = task
        return task
    }
}
