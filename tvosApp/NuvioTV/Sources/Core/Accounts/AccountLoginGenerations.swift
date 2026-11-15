import Foundation

/// Keeps a late login answer from undoing what the viewer did meanwhile.
///
/// A login captures its profile, then waits for the service (AniList, MAL) to
/// answer. Each profile has a generation number: starting a login and removing
/// the login (logging out, deleting the profile, signing out of Nuvio) both
/// move it on. A login only saves while its generation is still current, so:
/// - logged out (or signed out) meanwhile: the answer saves nothing;
/// - a newer login started meanwhile: only the newest one can save;
/// - switched to another profile meanwhile: nothing changes for the profile
///   that started the login, so it still saves there.
final class AccountLoginGenerations: @unchecked Sendable {
    private let lock = NSLock()
    private var generations: [String: UInt64] = [:]

    /// Starts a login for `profileScope`; any earlier one for it can no longer save.
    func begin(for profileScope: String) -> UInt64 {
        lock.withLock {
            let next = (generations[profileScope] ?? 0) &+ 1
            generations[profileScope] = next
            return next
        }
    }

    /// The profile's current generation, without starting anything. Work that
    /// captures it can only save while nothing removed the profile's data since.
    func current(for profileScope: String) -> UInt64 {
        lock.withLock { generations[profileScope] ?? 0 }
    }

    /// Removes a profile's login: moves the generation on and runs `remove`
    /// under the lock, so a login still waiting can't bring it back.
    func invalidate(_ profileScope: String, _ remove: () -> Void = {}) {
        lock.withLock {
            generations[profileScope] = (generations[profileScope] ?? 0) &+ 1
            remove()
        }
    }

    /// Invalidates a group atomically, for operations such as signing out.
    func invalidate(_ profileScopes: Set<String>, _ remove: () -> Void) {
        lock.withLock {
            for scope in profileScopes {
                generations[scope] = (generations[scope] ?? 0) &+ 1
            }
            remove()
        }
    }

    /// Runs `body` with no login saved or removed meanwhile, for a
    /// read-then-write such as keeping a renewed token.
    func exclusive<T>(_ body: () throws -> T) rethrows -> T {
        try lock.withLock(body)
    }

    /// Runs `save` only if `generation` is still the profile's current one. The
    /// check and the save happen under one lock, as do removals, so a removal
    /// can't slip between them.
    @discardableResult
    func commit(_ generation: UInt64, for profileScope: String, _ save: () -> Void) -> Bool {
        lock.withLock {
            // A profile nothing was started or removed for is at generation 0,
            // the same value `current(for:)` reports for it.
            guard (generations[profileScope] ?? 0) == generation else { return false }
            save()
            return true
        }
    }
}

/// The anime-tracker logins kept per profile (AniList, MAL). Removing them also
/// stops a login still waiting for that profile, so it can't save afterwards.
enum ProfileAccountLogins {
    /// A profile was deleted, here or on another device. Profile ids can be
    /// reused, so a new profile must not inherit the old one's logins.
    static func remove(for profileID: String) {
        AniListAccount.removeLogin(for: profileID)
        MALKeychain.remove(for: profileID)
    }
}
