import Foundation

/// A caption request the system made on its own, published by `AetherEngine.systemCaptionRequest`.
///
/// `language` is the BCP 47 tag of the legible option the system picked (`extendedLanguageTag`),
/// nil for an untagged rendition. The host resolves it against its own subtitle tracks rather than
/// receiving a track id: the rendition ordinals are matched by language rank, not positionally, so
/// the language is the value that survives the round trip intact.
public struct SystemCaptionRequest: Equatable, Sendable {
    public let language: String?

    public init(language: String?) {
        self.language = language
    }
}

/// Burst policy for the native legible deselect pin (Sodalite#38 follow-up).
///
/// The pin re-asserts `select(nil)` whenever something outside the engine selects a legible
/// option while the host still owns subtitles through its on-frame overlay. On iOS 26 that
/// "something" is the system's automatic captions (Settings > Accessibility > Subtitles &
/// Captioning: show when muted, show when skipping back, show when languages differ), and each
/// trigger is a single user action minutes apart, so the pin must stay armed for the whole
/// session rather than for a fixed number of tries.
///
/// What it must not do is spin. If the system re-selects immediately after every deselect, the
/// two are fighting and the engine cannot win; the policy detects that as a burst (several
/// re-asserts inside one short window) and tells the caller to stand down and log instead. A
/// re-assert that arrives after the window is a new episode and restores the full budget.
struct NativeLegibleDeselectPin {
    let burstLimit: Int
    let burstWindow: Double
    private(set) var burst = 0
    private var lastReassert: Double?

    init(burstLimit: Int = 5, burstWindow: Double = 1.0) {
        self.burstLimit = burstLimit
        self.burstWindow = burstWindow
    }

    /// Records a foreign legible selection observed at `now` (seconds, any monotonic clock).
    /// True while the pin should re-assert the deselect, false once the burst limit is spent.
    mutating func admit(now: Double) -> Bool {
        if let last = lastReassert, now - last > burstWindow { burst = 0 }
        lastReassert = now
        burst += 1
        return burst <= burstLimit
    }

    mutating func reset() {
        burst = 0
        lastReassert = nil
    }
}
