import Foundation

/// Marks the window in which a sync is writing remote data into local stores.
///
/// Two systems observe `UserDefaults.didChangeNotification` and push on it:
/// `NuvioSyncManager` (`NuvioSyncService.swift:141`) and the iCloud change
/// journal. Without this flag, applying a pulled change is indistinguishable
/// from a user edit, so every apply bounces straight back out to both
/// transports — and the two keep re-notifying each other.
@MainActor
enum CloudSyncOrigin {
    private(set) static var isApplyingRemote = false

    /// Runs `body` with the flag raised.
    ///
    /// Restores the previous value rather than clearing it, so a nested apply
    /// (a server record applied inside a full-profile apply) unwinds correctly
    /// instead of dropping the guard early for its parent.
    static func applyingRemote<T>(_ body: () throws -> T) rethrows -> T {
        let previous = isApplyingRemote
        isApplyingRemote = true
        defer { isApplyingRemote = previous }
        return try body()
    }
}
