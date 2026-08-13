import CloudKit
import Combine
import Foundation

/// Binds `CloudSyncEngine` to the app's real storage.
///
/// Owns the two directions: local edits become pending record changes, and
/// arriving records are merged into the profile suites and the server stores.
/// Every apply runs inside `CloudSyncOrigin.applyingRemote`, so the observers
/// below — and `NuvioSyncManager`'s — can tell a pulled change from a user edit.
@MainActor
final class CloudSyncManager: ObservableObject {
    /// The attached manager, for callers outside the view tree — the Settings
    /// diagnostics rows. Weak so the root owning it stays authoritative.
    static private(set) weak var current: CloudSyncManager?

    @Published private(set) var statusText = "Not started"
    @Published private(set) var lastSyncDate: Date?

    /// Whether iCloud is acting as the settings authority on this Apple TV.
    ///
    /// False on sideloaded builds, which ship without the iCloud entitlement,
    /// and on a TV signed out of iCloud. In both cases there is no second
    /// authority to conflict with, so the Nuvio account stays the settings
    /// fallback rather than leaving the user with no sync at all.
    static var isSettingsAuthority: Bool { current?.engine.isRunning == true }

    /// True once iCloud has merged at least once. Until then this device holds
    /// nothing authoritative, so it must not mirror its defaults outward over
    /// an account row other platforms are still reading.
    static var hasCompletedInitialSync: Bool { current?.engine.lastSyncDate != nil }

    private let engine = CloudSyncEngine()
    private var observers: [NSObjectProtocol] = []
    private var didAttach = false

    private weak var authManager: AuthManager?
    private weak var profileViewModel: ProfileViewModel?

    /// Last-known server ids, so a store change can be turned into saves and
    /// deletes. Neither store reports *what* changed, only that it did.
    private var knownSMBServerIDs: Set<String> = []
    private var knownJellyfinServerIDs: Set<String> = []

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    // MARK: - Lifecycle

    func attach(authManager: AuthManager, profileViewModel: ProfileViewModel) {
        self.authManager = authManager
        self.profileViewModel = profileViewModel
        Self.current = self
        guard !didAttach else { return }
        didAttach = true

        activateJournalForActiveProfile()
        knownSMBServerIDs = Set(SMBServerStore.shared.servers.map(\.id))
        knownJellyfinServerIDs = Set(JellyfinServerStore.shared.servers.map(\.id))

        observe(SettingsChangeJournal.changedNotification) { [weak self] in
            self?.enqueueActiveProfileSettings()
        }
        observe(SMBServerStore.changedNotification) { [weak self] in
            self?.enqueueSMBServerChanges()
        }
        observe(JellyfinServerStore.changedNotification) { [weak self] in
            self?.enqueueJellyfinServerChanges()
        }
        observe(ProfileManager.profilesChangedNotification) { [weak self] in
            self?.activateJournalForActiveProfile()
            self?.enqueueProfileList()
        }
        observe(NuvioSyncManager.addonOrderChangedNotification) { [weak self] in
            self?.enqueueAddonList()
        }

        Task { await start() }
    }

    /// User switches, read from the active profile's suite. Both default on.
    static var isEnabled: Bool {
        ProfileSettings.current.object(forKey: SettingsKey.iCloudSyncEnabled) as? Bool ?? true
    }

    static var syncsSecrets: Bool {
        ProfileSettings.current.object(forKey: SettingsKey.iCloudSyncSecrets) as? Bool ?? true
    }

    func start() async {
        guard Self.isEnabled else {
            statusText = "Turned off for this Apple TV"
            return
        }
        await engine.start(dataSource: self)
        await refreshStatus()
    }

    /// Reacts to the Settings toggle without waiting for a relaunch.
    func setEnabled(_ enabled: Bool) async {
        if enabled {
            await start()
        } else {
            engine.stop()
            statusText = "Turned off for this Apple TV"
        }
    }

    /// Deletes this account's sync zone and every local trace of it.
    ///
    /// Destructive across devices: the zone is shared, so the records other
    /// Apple TVs are reading disappear too. They keep their local settings and
    /// re-seed the zone on their next push.
    func resetCloudData() async {
        await engine.deleteZone()
        CloudSyncStateStore.reset()
        knownSMBServerIDs = []
        knownJellyfinServerIDs = []
        await refreshStatus()
    }

    /// Pulls whatever has changed elsewhere. Called when Settings appears and
    /// on app activation — an Apple TV is usually foregrounded when in use, so
    /// this covers the realistic cases without depending on push.
    func syncNow() async {
        // iCloud can become available after launch — the TV was signed out, or
        // the network was down — so a manual sync is also the retry path for
        // an engine that never started.
        if !engine.isRunning {
            await engine.start(dataSource: self)
        }
        await engine.fetchChanges()
        await engine.sendChanges()
        await refreshStatus()
    }

    private func refreshStatus() async {
        let availability = await CloudSyncAvailability.current()
        lastSyncDate = engine.lastSyncDate
        statusText = engine.lastError ?? availability.displayText
    }

    private func observe(_ name: Notification.Name, handler: @escaping () -> Void) {
        observers.append(
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in
                    // A pulled change must not be re-uploaded as a local edit.
                    guard !CloudSyncOrigin.isApplyingRemote else { return }
                    handler()
                }
            }
        )
    }

    private func activateJournalForActiveProfile() {
        guard let profileID = ProfileSettings.activeProfileID else { return }
        SettingsChangeJournal.shared.activate(profileID: profileID)
    }

    // MARK: - Enqueueing local changes

    private func enqueueActiveProfileSettings() {
        guard let profileID = ProfileSettings.activeProfileID else { return }
        engine.enqueueSaves([
            .profileSettings(profileID: profileID),
            .addonList(profileID: profileID),
            .homeLayout(profileID: profileID)
        ])
    }

    private func enqueueAddonList() {
        guard let profileID = ProfileSettings.activeProfileID else { return }
        engine.enqueueSaves([.addonList(profileID: profileID)])
    }

    private func enqueueProfileList() {
        engine.enqueueSaves([.profileList])
    }

    private func enqueueSMBServerChanges() {
        let current = Set(SMBServerStore.shared.servers.map(\.id))
        let removed = knownSMBServerIDs.subtracting(current)
        knownSMBServerIDs = current

        // Re-saving every server on any change costs little (a profile has a
        // handful) and avoids needing the stores to report which one moved.
        engine.enqueueSaves(current.map { .smbServer(serverID: $0) })
        dismiss(removed.map { .smbServer(serverID: $0) })
        undismiss(current.map { .smbServer(serverID: $0) })
    }

    private func enqueueJellyfinServerChanges() {
        let current = Set(JellyfinServerStore.shared.servers.map(\.id))
        let removed = knownJellyfinServerIDs.subtracting(current)
        knownJellyfinServerIDs = current

        engine.enqueueSaves(current.map { .jellyfinServer(serverID: $0) })
        dismiss(removed.map { .jellyfinServer(serverID: $0) })
        undismiss(current.map { .jellyfinServer(serverID: $0) })
    }

    // MARK: - Local removals

    /// Record names this Apple TV has removed locally.
    ///
    /// Deletions deliberately do not propagate — removing a server here must
    /// not remove it from another Apple TV. But the shared record still exists,
    /// so without remembering the removal the next fetch would simply put it
    /// back. Kept in the profile suite rather than the sync cache: Caches is
    /// purgeable, and a purge would resurrect every deleted server.
    private static let dismissedKey = "nuvio.icloud.dismissedRecords"

    private var dismissedRecordNames: Set<String> {
        get {
            let stored = ProfileSettings.current.stringArray(forKey: Self.dismissedKey) ?? []
            return Set(stored)
        }
        set {
            ProfileSettings.current.set(Array(newValue).sorted(), forKey: Self.dismissedKey)
        }
    }

    private func dismiss(_ identities: [CloudSyncSchema.Identity]) {
        guard !identities.isEmpty else { return }
        dismissedRecordNames.formUnion(identities.map(CloudSyncSchema.recordName(for:)))
    }

    private func undismiss(_ identities: [CloudSyncSchema.Identity]) {
        guard !identities.isEmpty else { return }
        var names = dismissedRecordNames
        let removed = Set(identities.map(CloudSyncSchema.recordName(for:)))
        guard !names.isDisjoint(with: removed) else { return }
        names.subtract(removed)
        dismissedRecordNames = names
    }

    private func isDismissed(_ identity: CloudSyncSchema.Identity) -> Bool {
        dismissedRecordNames.contains(CloudSyncSchema.recordName(for: identity))
    }

    private func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}

// MARK: - CloudSyncDataSource

extension CloudSyncManager: CloudSyncDataSource {
    func record(for identity: CloudSyncSchema.Identity, base: CKRecord?) -> CKRecord? {
        do {
            switch identity {
            case .profileList:
                let profiles = profileViewModel?.profiles ?? []
                guard !profiles.isEmpty else { return nil }
                let snapshot = ProfileListSnapshot(
                    profiles: profiles.map {
                        ProfileSnapshot(id: $0.id, name: $0.name, avatarId: $0.avatarId, isAdmin: $0.isAdmin)
                    },
                    updatedAt: now()
                )
                return try CloudSyncSchema.makeProfileListRecord(snapshot, base: base)

            case .profileSettings(let profileID):
                var snapshot = SettingsSnapshot.export(
                    from: ProfileSettings.store(for: profileID),
                    stamps: SettingsChangeJournal.shared.currentStamps(),
                    deviceID: CloudSyncEngine.deviceID
                )
                if Self.syncsSecrets {
                    // AI subtitle keys and the Simkl token have no suite entry.
                    KeychainSecretBridge.inject(into: &snapshot)
                } else {
                    // Abstain completely. Dropping the values but keeping their
                    // stamps would publish a live tombstone and delete the
                    // credentials every other Apple TV holds.
                    snapshot.secrets = [:]
                    for key in CloudSyncPolicy.secretKeys + CloudSyncPolicy.keychainSecretKeys {
                        snapshot.stamps.removeValue(forKey: key)
                    }
                }
                return try CloudSyncSchema.makeSettingsRecord(snapshot, profileID: profileID, base: base)

            case .addonList(let profileID):
                let snapshot = KeyedSettingsSnapshot.export(
                    keys: CloudSyncPolicy.addonKeys,
                    from: ProfileSettings.store(for: profileID),
                    updatedAt: now()
                )
                return try CloudSyncSchema.makeKeyedRecord(snapshot, identity: identity, base: base)

            case .homeLayout(let profileID):
                let snapshot = KeyedSettingsSnapshot.export(
                    keys: CloudSyncPolicy.homeLayoutKeys,
                    from: ProfileSettings.store(for: profileID),
                    updatedAt: now()
                )
                return try CloudSyncSchema.makeKeyedRecord(snapshot, identity: identity, base: base)

            case .smbServer(let serverID):
                // Gone locally: returning nil drops the pending change rather
                // than uploading a resurrected server.
                guard let config = SMBServerStore.shared.server(id: serverID) else { return nil }
                let scope = ProfileSettings.activeProfileScope
                let snapshot = SMBServerSnapshot(
                    config: config,
                    password: SMBCredentialStore.password(forServerID: serverID, profileScope: scope),
                    updatedAt: now()
                )
                return try CloudSyncSchema.makeSMBRecord(
                    snapshot,
                    profileID: ProfileSettings.activeProfileID ?? "",
                    base: base
                )

            case .jellyfinServer(let serverID):
                guard let config = JellyfinServerStore.shared.server(id: serverID) else { return nil }
                let scope = ProfileSettings.activeProfileScope
                let snapshot = JellyfinServerSnapshot(
                    config: config,
                    token: JellyfinCredentialStore.token(forServerID: serverID, profileScope: scope),
                    updatedAt: now()
                )
                return try CloudSyncSchema.makeJellyfinRecord(
                    snapshot,
                    profileID: ProfileSettings.activeProfileID ?? "",
                    base: base
                )
            }
        } catch {
            print("iCloud sync could not build \(identity): \(error.localizedDescription)")
            return nil
        }
    }

    func apply(_ record: CKRecord, identity: CloudSyncSchema.Identity) {
        // Removed here on purpose — do not let another device's copy restore it.
        guard !isDismissed(identity) else { return }

        switch identity {
        case .profileList:
            applyProfileList(record)
        case .profileSettings(let profileID):
            applySettings(record, profileID: profileID)
        case .addonList(let profileID):
            applyKeyed(record, keys: CloudSyncPolicy.addonKeys, profileID: profileID)
        case .homeLayout(let profileID):
            applyKeyed(record, keys: CloudSyncPolicy.homeLayoutKeys, profileID: profileID)
        case .smbServer:
            applySMBServer(record)
        case .jellyfinServer:
            applyJellyfinServer(record)
        }
    }

    /// Remote deletions are never applied.
    ///
    /// Removing a server — or resetting settings — on one Apple TV must not
    /// take it off the others. The cost is that clearing a server everywhere
    /// means removing it on each device; the benefit is that one accident on
    /// one TV cannot destroy the rest. This device keeps its copy and re-uploads
    /// it, which also restores the record for whoever deleted it.
    func delete(identity: CloudSyncSchema.Identity) {}

    func initialPendingIdentities() -> [CloudSyncSchema.Identity] {
        guard let profileID = ProfileSettings.activeProfileID else { return [] }
        var identities: [CloudSyncSchema.Identity] = [
            .profileList,
            .profileSettings(profileID: profileID),
            .addonList(profileID: profileID),
            .homeLayout(profileID: profileID)
        ]
        identities += SMBServerStore.shared.servers.map { .smbServer(serverID: $0.id) }
        identities += JellyfinServerStore.shared.servers.map { .jellyfinServer(serverID: $0.id) }
        return identities.filter { !isDismissed($0) }
    }

    // MARK: - Apply helpers

    private func applyProfileList(_ record: CKRecord) {
        // The Nuvio account owns profiles when one is attached; applying
        // iCloud's copy on top would fight the account pull. The record is
        // still written, so a later sign-out has something to fall back on.
        guard authManager?.isAuthenticated != true,
              let snapshot = CloudSyncSchema.profileListSnapshot(from: record),
              let profileViewModel else {
            return
        }
        let profiles = snapshot.profiles.map {
            Profile(id: $0.id, name: $0.name, isAdmin: $0.isAdmin, avatarId: $0.avatarId)
        }
        profileViewModel.applyRemoteProfiles(profiles)
    }

    private func applySettings(_ record: CKRecord, profileID: String) {
        guard let remote = CloudSyncSchema.settingsSnapshot(from: record) else { return }

        let defaults = ProfileSettings.store(for: profileID)
        let isActive = profileID == ProfileSettings.activeProfileID
        let localStamps = isActive ? SettingsChangeJournal.shared.currentStamps() : [:]

        var local = SettingsSnapshot.export(
            from: defaults,
            stamps: localStamps,
            deviceID: CloudSyncEngine.deviceID
        )
        let handlesSecrets = isActive && Self.syncsSecrets
        if handlesSecrets {
            KeychainSecretBridge.inject(into: &local)
        }

        let merged = SettingsSnapshot.merge(local: local, remote: remote)
        merged.apply(to: defaults, includeSecrets: Self.syncsSecrets)
        // Only the active profile's Keychain secrets are readable, so merging
        // another profile's would compare its remote values against nothing and
        // clobber credentials this device cannot see.
        if handlesSecrets {
            KeychainSecretBridge.apply(merged, profileScope: profileID)
        }

        if isActive {
            // Adopt the merged stamps rather than restamping now, or this
            // device would win every future comparison for those keys.
            SettingsChangeJournal.shared.adoptMergedStamps(merged.stamps)
        }
    }

    private func applyKeyed(_ record: CKRecord, keys: [String], profileID: String) {
        guard let remote = CloudSyncSchema.keyedSnapshot(from: record) else { return }
        remote.apply(keys: keys, to: ProfileSettings.store(for: profileID))
    }

    private func applySMBServer(_ record: CKRecord) {
        guard let (snapshot, profileID) = CloudSyncSchema.smbSnapshot(from: record) else { return }

        SMBCredentialStore.save(
            snapshot.password,
            forServerID: snapshot.config.id,
            profileScope: profileID
        )

        if profileID == ProfileSettings.activeProfileID {
            SMBServerStore.shared.upsert(snapshot.config)
            knownSMBServerIDs.insert(snapshot.config.id)
        } else {
            upsertServerBlob(
                snapshot.config,
                key: SettingsKey.smbServers,
                profileID: profileID
            )
        }
    }

    private func applyJellyfinServer(_ record: CKRecord) {
        guard let (snapshot, profileID) = CloudSyncSchema.jellyfinSnapshot(from: record) else { return }

        JellyfinCredentialStore.save(
            snapshot.token,
            forServerID: snapshot.config.id,
            profileScope: profileID
        )

        if profileID == ProfileSettings.activeProfileID {
            JellyfinServerStore.shared.upsert(snapshot.config)
            knownJellyfinServerIDs.insert(snapshot.config.id)
        } else {
            upsertServerBlob(
                snapshot.config,
                key: SettingsKey.jellyfinServers,
                profileID: profileID
            )
        }
    }

    /// Both server stores read and write `ProfileSettings.current`, so they can
    /// only ever touch the active profile. A record belonging to another
    /// profile has to be merged into that profile's blob directly.
    private func upsertServerBlob<T: Codable & Identifiable>(
        _ config: T,
        key: String,
        profileID: String
    ) where T.ID == String {
        let defaults = ProfileSettings.store(for: profileID)
        var servers: [T] = []
        if let data = defaults.data(forKey: key) {
            servers = (try? JSONDecoder().decode([T].self, from: data)) ?? []
        }
        if let index = servers.firstIndex(where: { $0.id == config.id }) {
            servers[index] = config
        } else {
            servers.append(config)
        }
        guard let encoded = try? JSONEncoder().encode(servers) else { return }
        defaults.set(encoded, forKey: key)
    }
}
