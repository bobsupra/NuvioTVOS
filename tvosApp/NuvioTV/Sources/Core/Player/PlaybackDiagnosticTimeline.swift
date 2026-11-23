import Foundation
import UIKit

/// Structured, allowlisted breadcrumbs. Never accepts URLs, error text or track names.
struct PlaybackDiagnosticTimeline: Codable, Sendable, Equatable {
    enum EventName: String, Codable, Sendable {
        case recordingEnabled, recordingDisabled, appActive, appBackgrounded, terminationRequested
        case playbackLoadRequested, playbackStarted, playbackStopRequested, playbackStopped, engineChanged, playbackError
        case audioSelectionRequested, audioSelectionReturned
        case subtitleSelectionRequested, subtitleSelectionReturned, externalSubtitleRequested
        case controlsShown, controlsHidden, settingsOpened, settingsClosed
        case sidePanelOpened, sidePanelClosed, backPressed, sourceSelectionRequested
        case audioMenuFocusLeft, audioMenuFocusReturned, subtitleMenuFocusLeft, subtitleMenuFocusReturned
        case controlsExitReceived, focusSinkFocused, focusSinkUnfocused
        // Opt-in, allowlisted Watch Party breadcrumbs: no room IDs, codes, member IDs or URLs.
        case partyPauseReceived, partyPlayReceived, partyStateRejected
        case partyPauseAccepted, partyPlayAccepted
        case partyPauseBindingObserved, partyPlayBindingObserved
        case partyBindingDeferredSample, partyBindingDeferredBehind, partyBindingDeferredBusy
        case partyRemotePauseStarted, partyRemotePlayStarted
        case partyRemoteTransportIssued, partyRemoteEffectFailed
        case trailerResolvedAddonStreams, trailerResolvedTrailerio, trailerResolvedImdb
        case trailerResolvedYouTube, trailerResolvedProxy, trailerResolutionFailed
        case trailerPlaybackStarted, trailerPlaybackFailed
    }

    enum Engine: String, Codable, Sendable { case aether, mpv }

    struct Event: Codable, Sendable, Equatable {
        let timestamp: Date
        let name: EventName
        let engine: Engine?
    }

    struct Session: Codable, Sendable, Identifiable, Equatable {
        let id: UUID
        let startedAt: Date
        let appVersion: String
        let build: String
        let osVersion: String
        var events: [Event]
        var droppedEvents: Int = 0
    }

    static let maximumSessions = 6
    static let maximumEventsPerSession = 80
    static let maximumBytes = 128 * 1024
    var schemaVersion: Int = 1
    var sessions: [Session] = []
    var droppedPendingEvents: Int = 0

    mutating func append(_ event: Event, session: Session) {
        if !sessions.contains(where: { $0.id == session.id }) { sessions.append(session) }
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        sessions[index].events.append(event)
        let extra = sessions[index].events.count - Self.maximumEventsPerSession
        if extra > 0 {
            sessions[index].events.removeFirst(extra)
            sessions[index].droppedEvents += extra
        }
        if sessions.count > Self.maximumSessions {
            sessions.removeFirst(sessions.count - Self.maximumSessions)
        }
    }

    static func decode(_ data: Data) -> PlaybackDiagnosticTimeline? {
        guard data.count <= maximumBytes,
              let value = try? JSONDecoder().decode(Self.self, from: data),
              value.schemaVersion == 1,
              value.sessions.count <= maximumSessions,
              value.sessions.allSatisfy({ $0.events.count <= maximumEventsPerSession }) else { return nil }
        return value
    }

    func encoded() -> Data? {
        guard let data = try? JSONEncoder().encode(self), data.count <= Self.maximumBytes else { return nil }
        return data
    }
}

/// Serial disk writer with a bounded ingress queue, independent of the main actor.
final class PlaybackDiagnosticTimelineStore: @unchecked Sendable {
    static let shared = PlaybackDiagnosticTimelineStore()
    static let maximumPendingEvents = 128
    private let queue = DispatchQueue(label: "nuvio.diagnostic-timeline", qos: .utility)
    private let lock = NSLock()
    private let file: URL?
    private var pending: [(PlaybackDiagnosticTimeline.Event, PlaybackDiagnosticTimeline.Session)] = []
    private var droppedPending = 0
    private var scheduled = false
    private var timeline: PlaybackDiagnosticTimeline?
    private var writeFailed = false

    struct Snapshot: Sendable {
        let timeline: PlaybackDiagnosticTimeline
        let writeFailed: Bool
    }

    init(directory: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("NuvioTV/DiagnosticTimeline", isDirectory: true)) {
        file = directory?.appendingPathComponent("timeline.json")
    }

    func append(_ event: PlaybackDiagnosticTimeline.Event, session: PlaybackDiagnosticTimeline.Session) {
        lock.lock()
        if pending.count == Self.maximumPendingEvents {
            pending.removeFirst()
            droppedPending += 1
        }
        pending.append((event, session))
        let needsSchedule = !scheduled
        scheduled = true
        lock.unlock()
        if needsSchedule {
            queue.asyncAfter(deadline: .now() + 0.5) { self.drain() }
        }
    }

    func snapshot(_ completion: @escaping @Sendable (Snapshot) -> Void) {
        queue.async {
            self.drain()
            completion(Snapshot(timeline: self.load(), writeFailed: self.writeFailed))
        }
    }

    /// Ordered with snapshots/writes. Pending events at the moment of deletion are discarded.
    func removeAll(_ completion: @escaping @Sendable (Bool) -> Void) {
        lock.lock()
        pending.removeAll()
        droppedPending = 0
        lock.unlock()
        queue.async {
            self.timeline = PlaybackDiagnosticTimeline()
            do {
                if let file = self.file, FileManager.default.fileExists(atPath: file.path) {
                    try FileManager.default.removeItem(at: file)
                }
                self.writeFailed = false
                completion(true)
            } catch {
                self.writeFailed = true
                completion(false)
            }
        }
    }

    private func load() -> PlaybackDiagnosticTimeline {
        if let timeline { return timeline }
        if let file,
           let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size <= PlaybackDiagnosticTimeline.maximumBytes,
           let data = try? Data(contentsOf: file),
           let value = PlaybackDiagnosticTimeline.decode(data) {
            timeline = value
        } else {
            timeline = PlaybackDiagnosticTimeline()
        }
        return timeline ?? PlaybackDiagnosticTimeline()
    }

    private func drain() {
        lock.lock()
        let batch = pending
        let dropped = droppedPending
        pending.removeAll(keepingCapacity: true)
        droppedPending = 0
        scheduled = false
        lock.unlock()
        guard !batch.isEmpty || dropped > 0 else { return }
        var value = load()
        value.droppedPendingEvents += dropped
        for (event, session) in batch { value.append(event, session: session) }
        timeline = value
        guard let data = value.encoded(), let file else {
            writeFailed = true
            return
        }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            writeFailed = false
        } catch {
            writeFailed = true
        }
    }
}

/// Uses a separate local-only preference; enabling existing issue snapshots does not opt in.
@MainActor
enum PlaybackTimelineRecorder {
    static let enabledKey = "nuvio.tv.settings.advanced.persistentPlaybackTimeline"
    static let sessionID = UUID()
    private static var observers: [NSObjectProtocol] = []

    private static var session: PlaybackDiagnosticTimeline.Session {
        let bundle = Bundle.main
        return PlaybackDiagnosticTimeline.Session(
            id: sessionID, startedAt: startedAt,
            appVersion: String((bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown").prefix(32)),
            build: String((bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown").prefix(32)),
            osVersion: String(ProcessInfo.processInfo.operatingSystemVersionString.prefix(128)), events: []
        )
    }
    private static let startedAt = Date()

    static func record(_ name: PlaybackDiagnosticTimeline.EventName, engine: PlayerEngineKind? = nil) {
        guard ProfileSettings.current.bool(forKey: enabledKey) else { return }
        installObserversIfNeeded()
        let backend: PlaybackDiagnosticTimeline.Engine? = engine.map { $0 == .aether ? .aether : .mpv }
        PlaybackDiagnosticTimelineStore.shared.append(.init(timestamp: Date(), name: name, engine: backend), session: session)
    }

    static func setEnabled(_ enabled: Bool) {
        // Record the disable marker while permission is still enabled.
        if !enabled { record(.recordingDisabled) }
        ProfileSettings.current.set(enabled, forKey: enabledKey)
        if enabled { record(.recordingEnabled) }
    }

    private static func installObserversIfNeeded() {
        guard observers.isEmpty else { return }
        let pairs: [(Notification.Name, PlaybackDiagnosticTimeline.EventName)] = [
            (UIApplication.didBecomeActiveNotification, .appActive),
            (UIApplication.didEnterBackgroundNotification, .appBackgrounded),
            (UIApplication.willTerminateNotification, .terminationRequested)
        ]
        for (notification, event) in pairs {
            observers.append(NotificationCenter.default.addObserver(forName: notification, object: nil, queue: .main) { _ in
                Task { @MainActor in record(event) }
            })
        }
    }
}
