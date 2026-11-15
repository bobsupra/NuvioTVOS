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
    /// Who a change belongs to: the profile that started it and its selected
    /// library account at that time.
    struct Owner {
        let profileID: String?
        /// Still that profile and library account (no profile switch, logout
        /// or relink since).
        let isCurrent: @MainActor () -> Bool

        init(profileID: String?, isCurrent: @escaping @MainActor () -> Bool) {
            self.profileID = profileID
            self.isCurrent = isCurrent
        }

        /// The owner `context` captured: its profile and library account.
        init(context: SelectedLibraryMutationContext) {
            self.init(profileID: ProfileSettings.activeProfileID, isCurrent: { context.isCurrent })
        }
    }

    /// How a confirmed change is reported (tests replace it). It goes to the
    /// owner's tracking add-ons with the owner's consent, even if another
    /// profile is active by the time the service confirms it.
    static var report: (Bool, NuvioMeta, String?) -> Void = { isInLibrary, meta, profileID in
        TrackingAddonService.sendLibraryMembership(isInLibrary, meta: meta, profileID: .some(profileID))
    }

    private static var tails: [String: Task<Void, Never>] = [:]

    /// Runs `mutation` after any earlier change for the same title, but only
    /// if `owner` is still current when its turn comes: a change queued before
    /// a profile switch, logout or relink never runs against the new profile
    /// or account. If it succeeds, the owner's tracking add-ons are told. A
    /// change cancelled before it runs does nothing. `completion` gets the
    /// result on the main actor, for the caller's UI.
    @discardableResult
    static func perform(
        _ isInLibrary: Bool,
        meta: NuvioMeta,
        owner: Owner,
        mutation: @escaping @MainActor () async -> Bool,
        completion: (@MainActor (Bool) -> Void)? = nil
    ) -> Task<Void, Never> {
        let key = "\(meta.type):\(meta.id)"
        let previous = tails[key]
        let task = Task { @MainActor in
            if let previous { await previous.value }
            guard !Task.isCancelled, owner.isCurrent() else {
                completion?(false)
                return
            }
            let succeeded = await mutation()
            // Reported even if the screen, or the active profile, moved on while
            // the service answered: the owner's library did change.
            if succeeded { report(isInLibrary, meta, owner.profileID) }
            completion?(succeeded)
        }
        tails[key] = task
        return task
    }
}
