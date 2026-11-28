import Foundation

/// Trakt replaces a title's saved paused position with a "watching" session when playback starts.
/// If no pause or stop follows (the app is killed or crashes mid-title, the power goes out), that
/// session simply expires and the title drops out of Continue Watching with its progress gone.
///
/// While something plays, a small note of it is kept (at most every 30 s); a pause or stop that
/// reaches Trakt removes it. A note left by an earlier launch means that session never closed, so
/// the pause it was missing is sent once the same profile is active again.
@MainActor
enum TraktOpenPlaybackRecovery {
    struct Note: Codable, Equatable {
        var meta: NuvioMeta
        var position: Double
        var duration: Double
        var season: Int?
        var episode: Int?
        var profileID: String?
        var launch: String
        var savedAt: Date
    }

    static let key = "nuvio.trakt.openPlayback"
    static let maxAge: TimeInterval = 3 * 24 * 60 * 60
    static let saveInterval: TimeInterval = 30
    /// This process, so a launch never "recovers" its own session.
    static let launchID = UUID().uuidString
    private static var lastSave = Date.distantPast
    static var defaults: UserDefaults = .standard

    static func update(
        meta: NuvioMeta,
        position: Double,
        duration: Double,
        season: Int?,
        episode: Int?,
        profileID: String?,
        force: Bool = false,
        now: Date = Date()
    ) {
        guard duration > 60, position > 0,
              force || now.timeIntervalSince(lastSave) >= saveInterval else { return }
        lastSave = now
        let note = Note(
            meta: meta,
            position: position,
            duration: duration,
            season: season,
            episode: episode,
            profileID: profileID,
            launch: launchID,
            savedAt: now
        )
        if let data = try? JSONEncoder().encode(note) {
            defaults.set(data, forKey: key)
        }
    }

    /// A pause or stop for this title reached Trakt.
    static func clear(metaID: String) {
        guard let note = read(), note.meta.id == metaID else { return }
        defaults.removeObject(forKey: key)
        lastSave = .distantPast
    }

    static func read() -> Note? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Note.self, from: $0) }
    }

    /// The pause to send for a note an earlier launch left behind, if it still applies.
    static func pending(activeProfileID: String?, now: Date = Date()) -> Note? {
        guard let note = read(), note.launch != launchID else { return nil }
        guard now.timeIntervalSince(note.savedAt) < maxAge else {
            defaults.removeObject(forKey: key)
            return nil
        }
        let progress = note.position / note.duration
        guard progress > 0.01, progress < 0.95 else {
            defaults.removeObject(forKey: key)
            return nil
        }
        // Sent under the profile that was watching; kept until that profile is active.
        guard note.profileID == nil || note.profileID == activeProfileID else { return nil }
        return note
    }

    /// Called once a profile is active after launch.
    static func recoverIfNeeded() async {
        guard let note = pending(activeProfileID: WatchedStore.activeProfileId) else { return }
        let sent = await TraktProgressService.reportPlayback(
            meta: note.meta,
            position: note.position,
            duration: note.duration,
            season: note.season,
            episode: note.episode,
            action: .pause,
            store: ProfileSettings.current,
            sourceOverride: .trakt,
            profileId: note.profileID
        )
        if sent, read()?.launch == note.launch {
            defaults.removeObject(forKey: key)
        }
    }
}
