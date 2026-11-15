import Foundation

/// LOCAL PROTOTYPE: not wired into NuvioTV. All profile writes and reads that
/// can reuse an ID must be serialized through the same coordinator.
/// Implementations must return an error, rather than an empty list, when the
/// authoritative profile store cannot be read.
@MainActor
protocol IPTVRetirementStorage {
    /// These operations must be durable on success and must never silently
    /// replace unreadable data with an empty set.
    func loadPending() throws -> Set<String>
    func savePendingDurably(_ ids: Set<String>) throws
    func loadProfileIDsAuthoritatively() throws -> Set<String>
    func deleteIPTVSources(profileID: String) throws
}

/// Proof of the ordering for profile retirement; this deliberately blocks ID
/// reuse while cleanup is pending instead of risking a late delete of new data.
@MainActor
struct IPTVRetirementCoordinator {
    let storage: any IPTVRetirementStorage

    /// Run before allowing profile creation, replacement or source access.
    /// A prepared but uncommitted removal is rolled back if the original
    /// profile remains; committed removals are cleaned and then unmarked.
    func recover() throws {
        var pending = try storage.loadPending()
        guard !pending.isEmpty else { return }
        let active = try storage.loadProfileIDsAuthoritatively()
        for id in pending.sorted() {
            if !active.contains(id) {
                // Idempotent; on failure keep the journal entry and block reuse.
                try storage.deleteIPTVSources(profileID: id)
            }
            pending.remove(id)
            try storage.savePendingDurably(pending)
        }
    }

    /// `commitProfiles` must throw on failure and write the same authoritative
    /// store that recovery reads. It must not call back into the coordinator.
    func retire(_ ids: Set<String>, commitProfiles: () throws -> Void) throws {
        try recover()
        guard !ids.isEmpty else { try commitProfiles(); return }
        let current = try storage.loadProfileIDsAuthoritatively()
        // Never mark an absent ID: it could already have a pending lifecycle.
        guard ids.isSubset(of: current) else { throw Error.invalidRetirement }
        try storage.savePendingDurably(ids)
        try commitProfiles()
        // If commit fails or the process ends here, the durable journal stays.
        // Recovery decides based on the authoritative profile list.
        try recover()
    }

    enum Error: Swift.Error { case invalidRetirement }
}
