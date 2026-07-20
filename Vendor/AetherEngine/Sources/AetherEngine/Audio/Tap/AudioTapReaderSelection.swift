import Foundation

/// #95 follow-up: which tap delivery source fits the current playback path. Pure so the
/// installAudioTap wiring stays a thin dispatch and the branch logic is unit-tested.
enum AudioTapReaderKind: Equatable { case loopback, software, remoteHLS, none }

enum AudioTapReaderSelection {
    static func kind(backend: PlaybackBackend, hasLoopbackSession: Bool,
                     nativeRemoteHLS: Bool, hasLoadedURL: Bool) -> AudioTapReaderKind {
        switch backend {
        case .software:
            return .software
        case .native:
            if hasLoopbackSession { return .loopback }
            if nativeRemoteHLS && hasLoadedURL { return .remoteHLS }
            return .none
        default:
            return .none
        }
    }
}
