import Foundation
import Combine

@MainActor
protocol WatchPartyServiceRemote: WatchPartySessionRemote {
    func create(identity: WatchPartyIdentity, media: WatchPartyMedia,
                playback: WatchPartyPlayback?) async throws -> WatchPartySnapshot
    func join(code: String, identity: WatchPartyIdentity) async throws -> WatchPartySnapshot
    func preview(code: String) async throws -> WatchPartyPreview
    func enabled() async throws -> Bool
}

extension WatchPartyAPI: WatchPartyServiceRemote {}

struct WatchPartyEnvironment: Equatable {
    let configuration: ServerConfiguration
    let userID: String
    let profileID: String
    let identity: WatchPartyIdentity

    /// Avatar metadata is cosmetic and can arrive after the profile catalog loads. It must not
    /// invalidate a live room's authenticated membership context.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.configuration == rhs.configuration && lhs.userID == rhs.userID && lhs.profileID == rhs.profileID
            && lhs.identity.deviceID == rhs.identity.deviceID
            && lhs.identity.displayName == rhs.identity.displayName
    }
}

struct WatchPartyRecentRoom: Codable, Equatable, Identifiable, Sendable {
    let roomID: String
    let code: String
    let title: String
    let type: String
    let season: Int?
    let episode: Int?
    let episodeTitle: String?
    let poster: String?
    let hostName: String
    let memberCount: Int
    let maxMembers: Int
    let lastUsed: Date

    var id: String { roomID }
}

private enum WatchPartyRecentRoomsStore {
    private static let limit = 8
    private static let keyPrefix = "nuvio.watchParty.recentRooms.v1"

    static func load(profileID: String, backendIdentity: String, userID: String) -> [WatchPartyRecentRoom] {
        load(
            from: ProfileSettings.store(for: profileID),
            backendIdentity: backendIdentity,
            userID: userID
        )
    }

    static func recordAccepted(
        _ snapshot: WatchPartySnapshot,
        profileID: String,
        backendIdentity: String,
        userID: String
    ) {
        guard let party = snapshot.party else { return }
        let rawHostName = snapshot.members.first(where: { $0.id == party.hostMemberID })?.displayName
        let hostName = rawHostName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let room = WatchPartyRecentRoom(
            roomID: party.id,
            code: WatchPartyCode.normalize(party.code),
            title: party.media.title,
            type: party.media.type,
            season: party.media.season,
            episode: party.media.episode,
            episodeTitle: party.media.episodeTitle,
            poster: party.media.poster,
            hostName: hostName.flatMap { $0.isEmpty ? nil : $0 } ?? L10n.string("party_badge_host", fallback: "Host"),
            memberCount: snapshot.members.count,
            maxMembers: party.maxMembers,
            lastUsed: Date()
        )
        record(
            room,
            in: ProfileSettings.store(for: profileID),
            backendIdentity: backendIdentity,
            userID: userID
        )
    }

    private static func load(
        from defaults: UserDefaults,
        backendIdentity: String,
        userID: String
    ) -> [WatchPartyRecentRoom] {
        guard let data = defaults.data(forKey: storageKey(backendIdentity: backendIdentity, userID: userID)),
              let rooms = try? JSONDecoder().decode([WatchPartyRecentRoom].self, from: data) else {
            return []
        }
        return Array(rooms.sorted { $0.lastUsed > $1.lastUsed }.prefix(limit))
    }

    private static func record(
        _ room: WatchPartyRecentRoom,
        in defaults: UserDefaults,
        backendIdentity: String,
        userID: String
    ) {
        guard !room.roomID.isEmpty, WatchPartyCode.isValid(room.code) else { return }
        var rooms = load(from: defaults, backendIdentity: backendIdentity, userID: userID)
        rooms.removeAll { $0.roomID == room.roomID || $0.code == room.code }
        rooms.insert(room, at: 0)
        guard let data = try? JSONEncoder().encode(Array(rooms.prefix(limit))) else { return }
        defaults.set(data, forKey: storageKey(backendIdentity: backendIdentity, userID: userID))
    }

    private static func storageKey(backendIdentity: String, userID: String) -> String {
        let scope = Data("\(backendIdentity.utf8.count):\(backendIdentity)\(userID.utf8.count):\(userID)".utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "\(keyPrefix).\(scope)"
    }
}

enum WatchPartyServiceError: Error, Equatable {
    case busy, alreadyInRoom, unavailable, membershipOutcomeUncertain, newJoinRequired, requestFailed
    case rejected(WatchPartyFailure)
}

/// App-level owner. Construction is inert; the future root/UI explicitly invokes its operations.
@MainActor
final class WatchPartyService: ObservableObject {
    typealias EnvironmentProvider = @MainActor () -> WatchPartyEnvironment?
    typealias RemoteFactory = @MainActor (WatchPartyEnvironment, WatchPartyRequestContext,
                                         @escaping WatchPartyAPI.ContextValidator) -> any WatchPartyServiceRemote
    typealias SessionFactory = @MainActor (any WatchPartyServiceRemote, WatchPartyEnvironment,
                                          WatchPartyRequestContext, @escaping WatchPartyAPI.ContextValidator) -> WatchPartySession

    @Published private(set) var session: WatchPartySession?
    @Published private(set) var busy = false
    @Published private(set) var available: Bool?
    @Published private(set) var failure: WatchPartyFailure?
    @Published private(set) var membershipOutcomeUncertain = false

    /// The request epoch is already revoked, but room/account storage is still intact.
    /// Root cancels playback consumers synchronously here, before session.stop notifies them.
    let contextDidInvalidate = PassthroughSubject<Void, Never>()

    private let environment: EnvironmentProvider
    private let makeRemote: RemoteFactory
    private let makeSession: SessionFactory
    private var captured: WatchPartyEnvironment?
    private var context: WatchPartyRequestContext?
    private var remote: (any WatchPartyServiceRemote)?
    private var revision = UUID()
    private var operation: UUID?
    private var connectionTask: Task<Void, Error>?
    private var invalidatingContext = false
    // Owned subscriptions are cancelled on destruction; their closures retain the service weakly.
    var authObservation: AnyCancellable?

    init(environment: @escaping EnvironmentProvider, makeRemote: @escaping RemoteFactory,
         makeSession: @escaping SessionFactory) {
        self.environment = environment
        self.makeRemote = makeRemote
        self.makeSession = makeSession
    }

    /// Root must call synchronously for profile/backend transitions, even A→B→A.
    /// Account transitions are also observed by the Auth composition below.
    func invalidateContext() {
        guard !invalidatingContext else { return }
        invalidatingContext = true
        defer { invalidatingContext = false }
        revision = UUID()
        operation = nil
        connectionTask?.cancel(); connectionTask = nil
        contextDidInvalidate.send(())
        session?.onChange = nil
        session?.stop()
        session = nil
        remote = nil; captured = nil; context = nil
        busy = false; available = nil; failure = nil; membershipOutcomeUncertain = false
    }

    /// Explicit acknowledgement after an ambiguous create/join; never called by recovery logic.
    func acknowledgeUncertainMembershipOutcome() { membershipOutcomeUncertain = false }

    func checkAvailability() async throws -> Bool {
        let setup = try begin()
        defer { finish(setup.operation) }
        do {
            let result = try await setup.remote.enabled()
            try check(setup.context, operation: setup.operation)
            available = result
            return result
        } catch { throw report(error, context: setup.context, operation: setup.operation) }
    }

    func preview(code: String) async throws -> WatchPartyPreview {
        let setup = try begin()
        defer { finish(setup.operation) }
        do {
            let value = try await setup.remote.preview(code: code)
            try check(setup.context, operation: setup.operation)
            if let failure = WatchPartyFailure(serverCode: value.error) { throw WatchPartyServiceError.rejected(failure) }
            return value
        } catch { throw report(error, context: setup.context, operation: setup.operation) }
    }

    func recentRooms() -> [WatchPartyRecentRoom] {
        guard let current = environment() else { return [] }
        return WatchPartyRecentRoomsStore.load(
            profileID: current.profileID,
            backendIdentity: current.configuration.backendIdentity,
            userID: current.userID
        )
    }

    func create(media: WatchPartyMedia, playback: WatchPartyPlayback? = nil) async throws {
        try await enter { remote, identity in try await remote.create(identity: identity, media: media, playback: playback) }
    }

    func join(code: String) async throws {
        guard WatchPartyCode.isValid(code) else { throw WatchPartyAPIError.invalidCode }
        let code = WatchPartyCode.normalize(code)
        try await enter { remote, identity in try await remote.join(code: code, identity: identity) }
    }

    /// Context teardown does not perform a leave with obsolete credentials.
    func leave(endForEveryone: Bool = false) async throws {
        let setup = try begin()
        defer { finish(setup.operation) }
        guard let current = session, current.party != nil else { return }
        do {
            try await current.leave(endForEveryone: endForEveryone)
            try check(setup.context, operation: setup.operation)
            if let reason = current.failure { throw WatchPartyServiceError.rejected(reason) }
            current.onChange = nil
            if session === current { session = nil }
        } catch {
            if isCurrent(setup.context), session === current, current.party == nil {
                current.onChange = nil; session = nil
            }
            throw report(error, context: setup.context, operation: setup.operation)
        }
    }

    /// Serializes the host-only change with other room mutations and lets the session apply
    /// the authoritative snapshot returned by the RPC.
    func setHostOnly(enabled: Bool) async throws {
        let setup = try begin()
        defer { finish(setup.operation) }
        guard let current = session, current.party != nil else { throw WatchPartySessionError.notReady }
        do {
            try await current.setHostOnly(enabled)
            try check(setup.context, operation: setup.operation)
            if let reason = current.failure { throw WatchPartyServiceError.rejected(reason) }
        } catch {
            throw report(error, context: setup.context, operation: setup.operation)
        }
    }

    func removeMember(memberID: String) async throws {
        let setup = try begin()
        defer { finish(setup.operation) }
        guard let current = session, current.party != nil else { throw WatchPartySessionError.notReady }
        do {
            try await current.removeMember(memberID)
            try check(setup.context, operation: setup.operation)
            if let reason = current.failure { throw WatchPartyServiceError.rejected(reason) }
        } catch {
            throw report(error, context: setup.context, operation: setup.operation)
        }
    }

    func updateMedia(_ media: WatchPartyMedia) async throws {
        let setup = try begin()
        defer { finish(setup.operation) }
        guard let current = session, current.party != nil else { throw WatchPartySessionError.notReady }
        do {
            try await current.updateMedia(media)
            try check(setup.context, operation: setup.operation)
            if let failure = current.failure { throw WatchPartyServiceError.rejected(failure) }
        } catch {
            throw report(error, context: setup.context, operation: setup.operation)
        }
    }

    func resume() async throws {
        let setup = try begin()
        defer { finish(setup.operation) }
        guard let session else { return }
        guard session.membershipExit == nil else { throw WatchPartyServiceError.newJoinRequired }
        guard session.party != nil else { return }
        do {
            let task = Task { try await session.reconnect() }
            connectionTask = task
            defer { if self.session === session { connectionTask = nil } }
            try await task.value
            try check(setup.context, operation: setup.operation)
        } catch { throw report(error, context: setup.context, operation: setup.operation) }
    }

    private func enter(_ request: @MainActor (any WatchPartyServiceRemote, WatchPartyIdentity) async throws -> WatchPartySnapshot) async throws {
        let setup = try begin()
        defer { finish(setup.operation) }
        guard session?.party == nil else { throw WatchPartyServiceError.alreadyInRoom }
        guard !membershipOutcomeUncertain else { throw WatchPartyServiceError.membershipOutcomeUncertain }
        var submitted = false
        var accepted = false
        do {
            let enabled = try await setup.remote.enabled()
            try check(setup.context, operation: setup.operation)
            available = enabled
            guard enabled else { throw WatchPartyServiceError.unavailable }
            submitted = true
            let snapshot = try await request(setup.remote, setup.environment.identity)
            try check(setup.context, operation: setup.operation)
            if let failure = WatchPartyFailure(serverCode: snapshot.error) { throw WatchPartyServiceError.rejected(failure) }
            guard let info = snapshot.party, !info.id.isEmpty,
                  let member = snapshot.memberID, !member.isEmpty,
                  snapshot.members.contains(where: { $0.id == member }) else { throw WatchPartyAPIError.invalidResponse }
            accepted = true
            WatchPartyRecentRoomsStore.recordAccepted(
                snapshot,
                profileID: setup.environment.profileID,
                backendIdentity: setup.environment.configuration.backendIdentity,
                userID: setup.environment.userID
            )
            let validator: WatchPartyAPI.ContextValidator = { [weak self] in self?.isCurrent($0) == true }
            let current = makeSession(setup.remote, setup.environment, setup.context, validator)
            session?.onChange = nil; session?.stop()
            session = current
            current.onChange = { [weak self, weak current] in
                guard let self, let current, self.session === current, self.isCurrent(setup.context) else { return }
                self.objectWillChange.send()
            }
            // Membership is now known. Caller cancellation must not discard it or repeat create/join.
            // Context invalidation explicitly cancels this owner-held task and stops the session.
            let task = Task { try await current.start(snapshot: snapshot) }
            connectionTask = task
            defer { if session === current { connectionTask = nil } }
            do { try await task.value }
            catch {
                try check(setup.context, operation: setup.operation)
                // Membership was accepted. Keep the reconnecting session instead of repeating create/join.
                guard current.party != nil else { throw error }
                failure = .network
            }
            try check(setup.context, operation: setup.operation)
        } catch {
            if isCurrent(setup.context), operation == setup.operation,
               submitted, !accepted, isAmbiguous(error) { membershipOutcomeUncertain = true }
            throw report(error, context: setup.context, operation: setup.operation)
        }
    }

    private struct Setup {
        let environment: WatchPartyEnvironment
        let context: WatchPartyRequestContext
        let remote: any WatchPartyServiceRemote
        let operation: UUID
    }

    private func begin() throws -> Setup {
        try Task.checkCancellation()
        guard !invalidatingContext else { throw WatchPartyAPIError.staleContext }
        let current = environment()
        if captured != current { invalidateContext() }
        guard let current else { throw WatchPartyAPIError.signInRequired }
        guard !busy else { throw WatchPartyServiceError.busy }
        if context == nil {
            let value = WatchPartyRequestContext(backendIdentity: current.configuration.backendIdentity,
                                                userID: current.userID, profileID: current.profileID, epoch: revision)
            captured = current; context = value
            let validator: WatchPartyAPI.ContextValidator = { [weak self] in self?.isCurrent($0) == true }
            remote = makeRemote(current, value, validator)
        } else if session?.party == nil,
                  let context,
                  let captured,
                  (captured.identity.avatarURL != current.identity.avatarURL
                    || captured.identity.avatarColor != current.identity.avatarColor) {
            // Refresh the cosmetic identity before the next room entry, without changing the
            // authenticated context or replacing a remote used by an active membership.
            self.captured = current
            let validator: WatchPartyAPI.ContextValidator = { [weak self] in self?.isCurrent($0) == true }
            remote = makeRemote(current, context, validator)
        }
        guard let context, let remote else { throw WatchPartyAPIError.staleContext }
        let token = UUID()
        operation = token; busy = true; failure = nil
        return Setup(environment: current, context: context, remote: remote, operation: token)
    }

    func isCurrent(_ value: WatchPartyRequestContext) -> Bool {
        !invalidatingContext && context == value && value.epoch == revision && captured == environment()
    }

    private func check(_ value: WatchPartyRequestContext, operation: UUID) throws {
        try Task.checkCancellation()
        guard isCurrent(value), self.operation == operation else { throw WatchPartyAPIError.staleContext }
    }

    private func finish(_ token: UUID) {
        guard operation == token else { return }
        operation = nil; busy = false
    }

    private func isAmbiguous(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let error = error as? WatchPartyAPIError {
            switch error {
            case .transport, .invalidResponse: return true
            case .httpStatus(let status): return status >= 500
            default: return false
            }
        }
        return !(error is WatchPartyServiceError)
    }

    private func report(_ error: Error, context: WatchPartyRequestContext, operation: UUID) -> Error {
        guard isCurrent(context), self.operation == operation else { return WatchPartyAPIError.staleContext }
        if error is CancellationError { return CancellationError() }
        if let value = error as? WatchPartyServiceError {
            switch value {
            case .rejected(let reason): failure = reason
            case .unavailable: failure = .unavailable
            default: failure = .network
            }
            return value
        }
        if let value = error as? WatchPartyAPIError {
            failure = value == .signInRequired ? .signInRequired : .network
            return value
        }
        if let value = error as? WatchPartySessionError {
            failure = value == .forbidden ? nil : .network
            return value
        }
        failure = .network
        return WatchPartyServiceError.requestFailed
    }
}
