import Foundation

/// The startup work a load actually performs, in the order the engine performs it (#361).
///
/// A checkpoint is recorded by the code that finishes the work it names, never by a timer and never
/// from an estimate, so a host can drive a determinate loading bar off completed-over-total and have
/// the number mean something: a slow stretch holds, a skipped stretch jumps.
///
/// The order is the contract. A path that legitimately skips work (the remote-HLS bypass runs no
/// probe and no panel handshake, an audio-only session has no picture) records the checkpoint it
/// does reach, and the ones behind it are credited by that alone. That is why the ladder is a single
/// ordered axis rather than a set: there is no per-path total to publish and nothing ever stalls
/// waiting for a checkpoint its path will never emit.
public enum StartupCheckpoint: Int, CaseIterable, Sendable, Comparable {
    /// `load()` accepted the request and the previous session is torn down.
    case dispatched = 0
    /// The source is open and its first bytes have arrived (connection, redirects, size probe).
    case sourceOpened
    /// `avformat_open_input` returned: the container is identified.
    case containerOpened
    /// `avformat_find_stream_info` returned: tracks, codecs and duration are known. On a slow origin
    /// this is the longest single stretch of a load, and the one a host cannot otherwise see.
    case streamsProbed
    /// The display-criteria handshake settled (or the path had none to run).
    case displayPrepared
    /// The playback route is chosen: native, software, audio, or the remote-HLS bypass.
    case routed
    /// The backend host is constructed and handed its item.
    case sessionConstructed
    /// The session reports itself ready (`isSessionReady`).
    ///
    /// Measured on the native path, this one is usually overtaken by the frame: AVPlayer's layer
    /// holds a picture before the item publishes `readyToPlay`, so the bar steps straight from
    /// `sessionConstructed` to `presenting` there. It is kept because the software and audio paths
    /// do pass it in order, and because on a start where the picture lags readiness it is the only
    /// movement in that stretch.
    case ready
    /// The first frame is on screen, and the end of the ladder. Deliberately not "playing": on the
    /// native path `state` becomes `.playing` before the item is ready, so a ladder ending there
    /// would report a finished startup over a black screen, and a paused mount would never finish
    /// at all. Audio sessions, which have a picture nowhere, reach this at readiness.
    case presenting

    public static func < (lhs: StartupCheckpoint, rhs: StartupCheckpoint) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Checkpoints behind the finish line. `.dispatched` is the origin of the axis, not progress
    /// through it, so a fresh sequence publishes 0 rather than one step of credit for being asked.
    static var total: Int { StartupCheckpoint.allCases.count - 1 }

    init(openStage: DemuxerOpenStage) {
        switch openStage {
        case .sourceOpened:    self = .sourceOpened
        case .containerOpened: self = .containerOpened
        case .streamsProbed:   self = .streamsProbed
        }
    }
}

/// The work currently in flight, i.e. what lies between the last checkpoint and the next one.
/// Distinct from `StartupCheckpoint`, which names work already finished; a host label wants the
/// former ("Analyzing streams") and a progress count wants the latter.
public enum StartupStage: String, Sendable, Equatable {
    case connecting
    case openingContainer
    case analyzingStreams
    case preparingDisplay
    case selectingRoute
    case buildingSession
    case preparingPlayback
    case awaitingFirstFrame
    /// Terminal: the picture is up, nothing is in flight.
    case presenting
}

/// A snapshot of one load's startup progress, scoped to the load generation that produced it (#361).
///
/// The generation is the engine's user-visible startup, not its internal `loadGeneration`: an
/// engine-initiated reroute (an HLS playlist discovered on the loopback path) restarts `load()`
/// underneath the same wait the user is looking at, and the two must not be confused, or the bar
/// falls back to zero halfway through a startup nobody restarted.
public struct StartupProgress: Sendable, Equatable {
    /// The startup this snapshot belongs to. A host holding a snapshot across a `load()` can tell
    /// stale from current without tracking loads itself.
    public let generation: UInt64
    /// The furthest checkpoint this startup has passed.
    public let checkpoint: StartupCheckpoint

    public init(generation: UInt64, checkpoint: StartupCheckpoint) {
        self.generation = generation
        self.checkpoint = checkpoint
    }

    /// Checkpoints passed, out of `total`.
    public var completed: Int { checkpoint.rawValue }
    /// Checkpoints in the full ladder. Constant across every path, so a bar built on it never
    /// re-scales mid-load.
    public var total: Int { StartupCheckpoint.total }
    /// `completed / total`, in 0...1.
    public var fraction: Double { Double(completed) / Double(total) }
    /// What the engine is working on right now.
    public var stage: StartupStage {
        switch checkpoint {
        case .dispatched:         return .connecting
        case .sourceOpened:       return .openingContainer
        case .containerOpened:    return .analyzingStreams
        case .streamsProbed:      return .preparingDisplay
        case .displayPrepared:    return .selectingRoute
        case .routed:             return .buildingSession
        case .sessionConstructed: return .preparingPlayback
        case .ready:              return .awaitingFirstFrame
        case .presenting:         return .presenting
        }
    }
    /// True once the picture is up. A startup that fails or is stopped never reaches this.
    public var isComplete: Bool { checkpoint == .presenting }

    /// The whole publishing rule, as a pure function: the snapshot to publish, or nil to publish
    /// nothing. Checkpoints arrive from detached probe work, from Combine sinks and from `load()`
    /// itself, so all three of the guards below have to hold at one place rather than at each site.
    ///
    /// - A snapshot from another generation is a straggler; a superseded load must not write into
    ///   its successor's sequence, and a checkpoint aimed at a generation that has not started yet
    ///   cannot be honored either.
    /// - A checkpoint at or behind the current one is either a steady republish or a late arrival
    ///   from a stretch already credited. Both publish nothing, which is what makes the axis
    ///   monotonic by construction rather than by convention at the call sites.
    /// - No sequence means nothing to advance: a sink outliving `stop()` cannot start one.
    static func advanced(
        from current: StartupProgress?,
        to checkpoint: StartupCheckpoint,
        generation: UInt64
    ) -> StartupProgress? {
        guard let current, current.generation == generation else { return nil }
        guard checkpoint > current.checkpoint else { return nil }
        return StartupProgress(generation: generation, checkpoint: checkpoint)
    }
}
