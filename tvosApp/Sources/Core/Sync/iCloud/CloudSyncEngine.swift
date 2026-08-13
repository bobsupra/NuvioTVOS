import CloudKit
import Foundation

/// What the engine needs from local storage.
///
/// Keeps `CloudSyncEngine` unaware of `SMBServerStore`, `ProfileSettings`, and
/// friends: the engine deals in `CKRecord`s and identities, and Phase 3 supplies
/// the object that knows how to build and apply them.
@MainActor
protocol CloudSyncDataSource: AnyObject {
    /// The record to upload for this identity, or nil if it no longer exists
    /// locally — CloudKit reads that as "drop this pending change".
    func record(for identity: CloudSyncSchema.Identity, base: CKRecord?) -> CKRecord?

    /// Applies a record that arrived from another Apple TV.
    func apply(_ record: CKRecord, identity: CloudSyncSchema.Identity)

    /// Applies a deletion that happened on another Apple TV.
    func delete(identity: CloudSyncSchema.Identity)

    /// Everything worth uploading on a cold start, so a device that has never
    /// synced seeds the zone instead of waiting for an edit.
    func initialPendingIdentities() -> [CloudSyncSchema.Identity]
}

/// Drives `CKSyncEngine` against the private database.
///
/// The engine owns scheduling, batching, retries, and change tokens; this class
/// owns the mapping to local storage and the conflict policy. It never fetches
/// on its own beyond what `CKSyncEngine` schedules — callers ask for
/// `fetchChanges()` when a screen appears.
@MainActor
final class CloudSyncEngine {
    /// Posted after a fetch has applied remote changes, so UI that is already
    /// on screen can reload.
    static let didApplyRemoteChangesNotification = Notification.Name("nuvio.tv.icloud.didApplyRemoteChanges")

    private(set) var lastError: String?
    private(set) var lastSyncDate: Date?

    /// True once `start` has stood the engine up against a reachable container.
    var isRunning: Bool { engine != nil }

    private var engine: CKSyncEngine?
    private weak var dataSource: CloudSyncDataSource?

    /// Stable per-device identifier, used as the merge tiebreak in
    /// `SettingsSnapshot.merge`. Only needs to be stable and distinct, never
    /// meaningful, so a generated UUID beats anything user-identifying.
    static let deviceID: String = {
        let key = "nuvio.icloud.deviceID"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let generated = UUID().uuidString
        UserDefaults.standard.set(generated, forKey: key)
        return generated
    }()

    func start(dataSource: CloudSyncDataSource) async {
        guard engine == nil else { return }
        guard await CloudSyncAvailability.current().canSync else {
            lastError = "iCloud unavailable"
            return
        }

        self.dataSource = dataSource

        let container = CKContainer(identifier: CloudSync.containerID)
        var configuration = CKSyncEngine.Configuration(
            database: container.privateCloudDatabase,
            stateSerialization: CloudSyncStateStore.loadState(),
            delegate: self
        )
        // Sync is manual. The engine still tracks pending changes and keeps its
        // state, but nothing goes over the network until `fetchChanges` or
        // `sendChanges` is called from the Sync Now action.
        configuration.automaticallySync = false
        let engine = CKSyncEngine(configuration)
        self.engine = engine

        // Creating the zone is idempotent; CloudKit ignores it when it exists.
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: CloudSyncSchema.zoneID))])

        let identities = dataSource.initialPendingIdentities()
        if !identities.isEmpty {
            enqueueSaves(identities)
        }
    }

    func stop() {
        engine = nil
        dataSource = nil
    }

    func enqueueSaves(_ identities: [CloudSyncSchema.Identity]) {
        guard let engine else { return }
        engine.state.add(
            pendingRecordZoneChanges: identities.map {
                .saveRecord(CloudSyncSchema.recordID(for: $0))
            }
        )
    }

    /// Removes the sync zone from the private database. Everything in it goes,
    /// for every device on the account.
    func deleteZone() async {
        guard let engine else { return }
        engine.state.add(pendingDatabaseChanges: [.deleteZone(CloudSyncSchema.zoneID)])
        do {
            try await engine.sendChanges()
            lastError = nil
        } catch {
            lastError = Self.shortDescription(for: error)
        }
        self.engine = nil
    }

    func fetchChanges() async {
        guard let engine else { return }
        do {
            try await engine.fetchChanges()
            lastSyncDate = Date()
            lastError = nil
        } catch {
            lastError = Self.shortDescription(for: error)
        }
    }

    func sendChanges() async {
        guard let engine else { return }
        do {
            try await engine.sendChanges()
            lastSyncDate = Date()
            lastError = nil
        } catch {
            lastError = Self.shortDescription(for: error)
        }
    }

    /// `CKSyncEngine` surfaces a generic "Failed to send changes" for almost
    /// everything, so the useful part — the `CKError` code and the per-record
    /// partial errors — has to be unpacked by hand. The full error also goes to
    /// the console, since the Settings row can only show so much.
    private static func shortDescription(for error: Error) -> String {
        print("iCloud sync error: \(error)")

        guard let ckError = error as? CKError else {
            let singleLine = error.localizedDescription.replacingOccurrences(of: "\n", with: " ")
            return String(singleLine.prefix(160))
        }

        var parts = ["CKError.\(String(describing: ckError.code))"]

        if let partial = ckError.partialErrorsByItemID, !partial.isEmpty {
            let details = partial.compactMap { key, value -> String? in
                let name = (key as? CKRecord.ID)?.recordName ?? String(describing: key)
                guard let itemError = value as? CKError else { return name }
                return "\(name)=\(String(describing: itemError.code))"
            }
            parts += details.sorted().prefix(4)
        } else {
            let singleLine = ckError.localizedDescription.replacingOccurrences(of: "\n", with: " ")
            parts.append(singleLine)
        }

        return String(parts.joined(separator: " · ").prefix(240))
    }
}

// MARK: - CKSyncEngineDelegate

extension CloudSyncEngine: CKSyncEngineDelegate {
    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            CloudSyncStateStore.saveState(update.stateSerialization)

        case .accountChange(let change):
            handleAccountChange(change)

        case .fetchedRecordZoneChanges(let changes):
            applyFetched(changes)

        case .sentRecordZoneChanges(let sent):
            handleSent(sent, syncEngine: syncEngine)

        case .willFetchChanges, .willFetchRecordZoneChanges,
             .didFetchRecordZoneChanges, .didFetchChanges,
             .willSendChanges, .didSendChanges,
             .fetchedDatabaseChanges, .sentDatabaseChanges:
            break

        @unknown default:
            break
        }
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard let dataSource else { return nil }

        let scope = context.options.scope
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }

        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { recordID in
            await MainActor.run {
                guard let identity = CloudSyncSchema.identity(forRecordName: recordID.recordName) else {
                    return nil
                }
                // Replaying the last known system fields keeps the change tag
                // current, so an uncontested save skips the conflict round trip.
                let base = CloudSyncStateStore.systemFields(forRecordName: recordID.recordName)
                return dataSource.record(for: identity, base: base)
            }
        }
    }

    // MARK: - Event handling

    private func handleAccountChange(_ change: CKSyncEngine.Event.AccountChange) {
        switch change.changeType {
        case .signIn:
            // Nothing local is authoritative for the new account yet; a fetch
            // will bring its zone down.
            break
        case .signOut, .switchAccounts:
            // State from the previous account describes records this one cannot
            // see. Keeping it would make every save fail against a zone that
            // does not exist here.
            CloudSyncStateStore.reset()
            engine = nil
        @unknown default:
            break
        }
    }

    private func applyFetched(_ changes: CKSyncEngine.Event.FetchedRecordZoneChanges) {
        guard let dataSource else { return }
        var applied = false

        CloudSyncOrigin.applyingRemote {
            for modification in changes.modifications {
                let record = modification.record
                guard let identity = CloudSyncSchema.identity(forRecordName: record.recordID.recordName) else {
                    continue
                }
                dataSource.apply(record, identity: identity)
                CloudSyncStateStore.storeSystemFields(of: record)
                applied = true
            }

            for deletion in changes.deletions {
                guard let identity = CloudSyncSchema.identity(forRecordName: deletion.recordID.recordName) else {
                    continue
                }
                dataSource.delete(identity: identity)
                CloudSyncStateStore.forgetSystemFields(forRecordName: deletion.recordID.recordName)
                applied = true
            }
        }

        guard applied else { return }
        lastSyncDate = Date()
        NotificationCenter.default.post(name: Self.didApplyRemoteChangesNotification, object: nil)
    }

    private func handleSent(
        _ sent: CKSyncEngine.Event.SentRecordZoneChanges,
        syncEngine: CKSyncEngine
    ) {
        for saved in sent.savedRecords {
            CloudSyncStateStore.storeSystemFields(of: saved)
        }

        for failed in sent.failedRecordSaves {
            let recordID = failed.record.recordID
            switch failed.error.code {
            case .serverRecordChanged:
                // Someone else wrote first. Adopt the server's version — which
                // carries the current change tag — apply it locally so the two
                // sides merge, then let the next batch re-send the result.
                guard let identity = CloudSyncSchema.identity(forRecordName: recordID.recordName) else {
                    continue
                }
                guard let serverRecord = failed.error.serverRecord else {
                    // No server record to reconcile against, so re-sending the
                    // same tagless record would fail identically forever. Drop
                    // the cached tag and let the next real edit rebuild it.
                    CloudSyncStateStore.forgetSystemFields(forRecordName: recordID.recordName)
                    lastError = "serverRecordChanged with no server record: \(recordID.recordName)"
                    continue
                }
                CloudSyncStateStore.storeSystemFields(of: serverRecord)
                CloudSyncOrigin.applyingRemote {
                    dataSource?.apply(serverRecord, identity: identity)
                }
                syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])

            case .zoneNotFound, .userDeletedZone:
                // Expected on a first run: the record save can reach the server
                // before the zone exists. Recreate the zone and re-enqueue,
                // rather than dropping the change.
                //
                // Deliberately no `CloudSyncStateStore.reset()` here — the local
                // state and system-fields cache are still valid, and clearing
                // them out from under a running engine only loses change tags.
                syncEngine.state.add(
                    pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: CloudSyncSchema.zoneID))]
                )
                syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])

            case .unknownItem:
                // The schema has not been deployed to this environment yet.
                lastError = "CloudKit schema missing — deploy it in the CloudKit Console"

            default:
                lastError = Self.shortDescription(for: failed.error)
            }
        }
    }
}
