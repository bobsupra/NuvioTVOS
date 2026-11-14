import Foundation
import MediaPlayer

/// Values copied out of MediaPlayer callbacks before crossing to the main actor.
enum PlayerRemoteIntent: Sendable {
    case play, pause, toggle, position(Double), skip(Double)

    static func skipInterval(_ interval: Double, isForward: Bool) -> Self? {
        guard interval.isFinite, interval >= 0 else { return nil }
        return .skip(isForward ? interval : -interval)
    }

    @MainActor func localIntent(positionMs: Int64, isPlaying: Bool) -> WatchPartyLocalIntent? {
        switch self {
        case .play: return .play
        case .pause: return .pause
        case .toggle: return isPlaying ? .pause : .play
        case .position(let seconds):
            guard let value = PlayerViewModel.watchPartySeekMilliseconds(seconds) else { return nil }
            return .seek(value)
        case .skip(let seconds):
            let delta = seconds * 1000
            guard delta.isFinite, delta > Double(Int64.min), delta < Double(Int64.max) else { return nil }
            return .seek(max(0, WatchPartyTimeMath.add(positionMs, Int64(delta))))
        }
    }
}

/// Removes only this registration's targets. Events already queued on MainActor retain the old
/// generation and cannot reach a replacement owner. Acknowledgement means queued, not RPC success.
@MainActor
final class PlayerRemoteCommandTargets {
    private(set) var generation = UUID()
    private var removals: [@MainActor () -> Void] = []

    func retainRemoval(_ remove: @escaping @MainActor () -> Void) { removals.append(remove) }

    func deliver(_ intent: PlayerRemoteIntent, generation: UUID,
                 action: @MainActor (PlayerRemoteIntent) -> Void) {
        guard self.generation == generation else { return }
        action(intent)
    }

    func stop() {
        generation = UUID() // Invalidate before removal can synchronously re-enter.
        let callbacks = removals
        removals.removeAll()
        for remove in callbacks { remove() }
    }

    func add(_ command: MPRemoteCommand, intent: PlayerRemoteIntent,
             action: @escaping @MainActor @Sendable (PlayerRemoteIntent) -> Void) {
        add(command, resolve: { _ in intent }, action: action)
    }

    func add(_ command: MPRemoteCommand,
             resolve: @escaping @Sendable (MPRemoteCommandEvent) -> PlayerRemoteIntent?,
             action: @escaping @MainActor @Sendable (PlayerRemoteIntent) -> Void) {
        let mark = generation
        let target = command.addTarget { [weak self] event in
            guard let intent = resolve(event) else { return .commandFailed }
            Task { @MainActor [weak self] in self?.deliver(intent, generation: mark, action: action) }
            return .success
        }
        retainRemoval { command.removeTarget(target) }
    }
}
