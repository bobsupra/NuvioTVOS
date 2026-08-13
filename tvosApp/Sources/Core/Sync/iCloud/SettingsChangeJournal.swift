import Foundation

/// Per-key modification stamps for the active profile's settings.
///
/// `UserDefaults` records no modification times, and there are 100+
/// `@AppStorage` call sites, so wrapping every write is off the table. This
/// diffs the suite against a cached baseline whenever
/// `UserDefaults.didChangeNotification` fires and stamps only the keys that
/// actually moved — zero call-site changes, reusing a notification the app
/// already posts.
///
/// The stamps are what make `SettingsSnapshot.merge` per-key rather than
/// whole-blob: a theme change here and a subtitle-size change on another Apple
/// TV both survive.
@MainActor
final class SettingsChangeJournal {
    static let shared = SettingsChangeJournal()

    /// Posted once stamps actually change, so the sync manager knows there is
    /// something local worth pushing.
    static let changedNotification = Notification.Name("nuvio.tv.icloud.settingsStamped")

    /// Sidecar key inside the profile's own suite. Deliberately not a
    /// `SettingsKey`, so it is never synced, diffed, or stamped itself.
    private static let stampsKey = "nuvio.icloud.settings.stamps"

    /// Long enough that dragging a slider stamps once instead of per frame,
    /// short enough that leaving a settings screen has already flushed.
    private static let debounce = Duration.seconds(2)

    private var profileID: String?
    private var defaults: UserDefaults = .standard
    private var baseline: [String: SettingValue] = [:]
    private var stamps: [String: Int64] = [:]
    private var observer: NSObjectProtocol?
    private var keychainObserver: NSObjectProtocol?
    private var flushTask: Task<Void, Never>?

    private init() {}

    deinit {
        flushTask?.cancel()
        for observer in [observer, keychainObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Points the journal at a profile and rebuilds its baseline. Call on
    /// launch and on every profile switch, alongside
    /// `ProfileSettings.setActiveProfile`.
    func activate(profileID: String) {
        guard self.profileID != profileID else { return }
        flushTask?.cancel()
        self.profileID = profileID
        defaults = ProfileSettings.store(for: profileID)
        stamps = Self.loadStamps(from: defaults)
        baseline = snapshotValues()
        startObservingIfNeeded()
    }

    func currentStamps() -> [String: Int64] { stamps }

    /// Adopts the stamps produced by a merge.
    ///
    /// A value pulled from another Apple TV must keep *that* device's
    /// timestamp. Restamping it "now" would make this device win every future
    /// comparison for that key, and the older edit would never be able to
    /// correct it.
    func adoptMergedStamps(_ merged: [String: Int64]) {
        stamps = merged
        baseline = snapshotValues()
        persistStamps()
    }

    // MARK: - Change detection

    private func startObservingIfNeeded() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduleFlush() }
        }
        // A Keychain write posts no `didChangeNotification`, so without this a
        // newly saved API key would go unstamped until some unrelated setting
        // happened to change.
        keychainObserver = NotificationCenter.default.addObserver(
            forName: KeychainSecretBridge.changedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduleFlush() }
        }
    }

    private func scheduleFlush() {
        // A remote apply is not a local edit. Its stamps arrive through
        // `adoptMergedStamps` instead of being minted here.
        guard !CloudSyncOrigin.isApplyingRemote else { return }

        flushTask?.cancel()
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    private func flush() {
        guard profileID != nil else { return }

        let current = snapshotValues()
        // `persistStamps` writes into the same suite, which posts
        // `didChangeNotification` and lands back here. The stamps key is not a
        // watched key, so this comparison sees no change and the loop stops.
        guard current != baseline else { return }

        let now = Int64(Date().timeIntervalSince1970 * 1000)
        for key in CloudSyncPolicy.stampedKeys where current[key] != baseline[key] {
            stamps[key] = now
        }
        baseline = current
        persistStamps()
        NotificationCenter.default.post(name: Self.changedNotification, object: nil)
    }

    private func snapshotValues() -> [String: SettingValue] {
        var values: [String: SettingValue] = [:]
        for key in CloudSyncPolicy.plainKeys + CloudSyncPolicy.secretKeys
            + CloudSyncPolicy.addonKeys + CloudSyncPolicy.homeLayoutKeys {
            values[key] = SettingValue.read(from: defaults, key: key)
        }
        // Keychain-resident secrets have no suite entry to read.
        for secret in KeychainSecretBridge.Secret.allCases {
            values[secret.rawValue] = KeychainSecretBridge.read(secret).map(SettingValue.string)
        }
        return values
    }

    // MARK: - Persistence

    private func persistStamps() {
        guard let data = try? JSONEncoder().encode(stamps) else { return }
        defaults.set(data, forKey: Self.stampsKey)
    }

    private static func loadStamps(from defaults: UserDefaults) -> [String: Int64] {
        guard let data = defaults.data(forKey: stampsKey),
              let stamps = try? JSONDecoder().decode([String: Int64].self, from: data) else {
            return [:]
        }
        return stamps
    }
}
