import Foundation

// Remote gestures in the player: which gesture does which action, kept in the
// profile, and what the player does with a gesture nobody bound.

/// What a gesture can do during playback.
enum PlayerGestureAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case nextChapter, previousChapter, openChapters, skipIntro
    case forward30, back30, playPause, nextEpisode
    case toggleSubtitles, cycleAudio, faster

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nextChapter: return "Next chapter"
        case .previousChapter: return "Previous chapter"
        case .openChapters: return "Open chapters"
        case .skipIntro: return "Skip intro / outro"
        case .forward30: return "Jump +30 s"
        case .back30: return "Jump −30 s"
        case .playPause: return "Play / pause"
        case .nextEpisode: return "Next episode"
        case .toggleSubtitles: return "Subtitles on / off"
        case .cycleAudio: return "Next audio track"
        case .faster: return "Playback speed"
        }
    }
}

struct PlayerGestureBinding: Codable, Hashable, Sendable {
    var gesture: RemoteGesture
    var action: PlayerGestureAction
}

/// Which gesture does which action: one gesture per action and one action per gesture.
struct PlayerGestureBindings: Codable, Equatable, Sendable {
    private(set) var bindings: [PlayerGestureBinding]

    init(bindings: [PlayerGestureBinding]) {
        self.bindings = bindings
    }

    /// The ready-made gestures (Expert mode off), and where Expert mode starts and resets to.
    /// None of them takes what the player does itself (clicks and taps on a side seek, holding
    /// a side rewinds, a swipe up or down shows the controls or InSight), and none is a double
    /// tap, so a single tap never waits.
    static let defaults = PlayerGestureBindings(bindings: [
        PlayerGestureBinding(gesture: .swipe(.right, long: true), action: .nextChapter),
        PlayerGestureBinding(gesture: .swipe(.left, long: true), action: .previousChapter),
        PlayerGestureBinding(gesture: .swipeBack(.right), action: .skipIntro),
        PlayerGestureBinding(gesture: .swipeBack(.left), action: .back30),
        PlayerGestureBinding(gesture: .swipeBack(.up), action: .toggleSubtitles),
        PlayerGestureBinding(gesture: .swipeBack(.down), action: .cycleAudio),
        PlayerGestureBinding(gesture: .hold(.center), action: .openChapters),
        PlayerGestureBinding(gesture: .circle(clockwise: true), action: .nextEpisode),
    ])

    func action(for gesture: RemoteGesture) -> PlayerGestureAction? {
        bindings.first { $0.gesture == gesture }?.action
    }

    func gesture(for action: PlayerGestureAction) -> RemoteGesture? {
        bindings.first { $0.action == action }?.gesture
    }

    /// Gives `action` this gesture. The action that had it before loses it and is returned.
    @discardableResult
    mutating func bind(_ gesture: RemoteGesture, to action: PlayerGestureAction) -> PlayerGestureAction? {
        let previous = bindings.first { $0.gesture == gesture && $0.action != action }?.action
        bindings.removeAll { $0.action == action || $0.gesture == gesture }
        bindings.append(PlayerGestureBinding(gesture: gesture, action: action))
        return previous
    }

    mutating func unbind(_ action: PlayerGestureAction) {
        bindings.removeAll { $0.action == action }
    }

    /// The gesture is gone (a deleted custom shape): whatever it did is unbound.
    mutating func unbind(gesture: RemoteGesture) {
        bindings.removeAll { $0.gesture == gesture }
    }
}

/// The switch and the bindings, per profile.
enum PlayerGestureSettings {
    static let enabledKey = "nuvio.tv.settings.playback.remoteGesturesEnabled"
    static let bindingsKey = "nuvio.tv.settings.playback.remoteGestureBindings"

    /// Off until switched on in the player (Gestures tab).
    static func isEnabled(in settings: UserDefaults = ProfileSettings.current) -> Bool {
        settings.object(forKey: enabledKey) as? Bool ?? false
    }

    static func setEnabled(_ enabled: Bool, in settings: UserDefaults = ProfileSettings.current) {
        settings.set(enabled, forKey: enabledKey)
    }

    static func bindings(in settings: UserDefaults = ProfileSettings.current) -> PlayerGestureBindings {
        guard let data = settings.data(forKey: bindingsKey),
              let saved = try? JSONDecoder().decode(PlayerGestureBindings.self, from: data) else {
            return .defaults
        }
        return saved
    }

    static func save(_ bindings: PlayerGestureBindings, in settings: UserDefaults = ProfileSettings.current) {
        guard let data = try? JSONEncoder().encode(bindings) else { return }
        settings.set(data, forKey: bindingsKey)
    }

    static let sensitivityKey = "nuvio.tv.settings.playback.remoteGestureSensitivity"

    static func sensitivity(in settings: UserDefaults = ProfileSettings.current) -> PlayerGestureSensitivity {
        guard let data = settings.data(forKey: sensitivityKey),
              let saved = try? JSONDecoder().decode(PlayerGestureSensitivity.self, from: data) else {
            return PlayerGestureSensitivity()
        }
        return saved
    }

    static func save(_ sensitivity: PlayerGestureSensitivity, in settings: UserDefaults = ProfileSettings.current) {
        guard let data = try? JSONEncoder().encode(sensitivity) else { return }
        settings.set(data, forKey: sensitivityKey)
    }

    // MARK: Expert mode

    static let expertKey = "nuvio.tv.settings.playback.remoteGestureExpert"

    /// Off: the ready-made gestures with the default sensitivity and no shapes of one's own.
    /// One's own gestures, shapes and sensitivity stay saved and apply again in expert mode.
    static func isExpert(in settings: UserDefaults = ProfileSettings.current) -> Bool {
        settings.object(forKey: expertKey) as? Bool ?? false
    }

    static func setExpert(_ expert: Bool, in settings: UserDefaults = ProfileSettings.current) {
        settings.set(expert, forKey: expertKey)
    }

    /// The gestures that work now.
    static func activeBindings(in settings: UserDefaults = ProfileSettings.current) -> PlayerGestureBindings {
        isExpert(in: settings) ? bindings(in: settings) : .defaults
    }

    static func activeSensitivity(in settings: UserDefaults = ProfileSettings.current) -> PlayerGestureSensitivity {
        isExpert(in: settings) ? sensitivity(in: settings) : PlayerGestureSensitivity()
    }

    static func activeShapes(in settings: UserDefaults = ProfileSettings.current) -> [CustomGestureShape] {
        isExpert(in: settings) ? CustomGestureStore.shapes(in: settings) : []
    }
}

/// The few recognizer settings the Gestures tab offers (Expert mode), each in a handful of steps.
enum PlayerGestureSensitivityKnob: String, CaseIterable, Codable, Identifiable, Sendable {
    case doubleWindow, longPress, swipeLength, circle, centerSize, customShapes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .doubleWindow: return "Double click / tap"
        case .longPress: return "Long press / hold"
        case .swipeLength: return "Swipe"
        case .circle: return "Circle"
        case .centerSize: return "Center area"
        case .customShapes: return "Custom shapes"
        }
    }

    var steps: [String] {
        switch self {
        case .doubleWindow: return ["fast 0.25 s", "normal 0.35 s", "slow 0.45 s"]
        case .longPress: return ["0.4 s", "0.5 s", "0.7 s"]
        case .swipeLength: return ["sensitive", "normal", "firm"]
        case .circle: return ["¾ turn", "normal 300°", "full turn"]
        case .centerSize: return ["small", "normal", "large"]
        case .customShapes: return ["strict", "normal", "loose"]
        }
    }

    /// The values tried on a remote, but a large middle (taps on the sides went to the middle).
    var defaultStep: Int {
        self == .centerSize ? 2 : 1
    }

    func apply(step: Int, to tuning: inout RemoteGestureTuning) {
        let step = min(max(step, 0), steps.count - 1)
        switch self {
        case .doubleWindow:
            tuning.doubleWindow = [0.25, 0.35, 0.45][step]
        case .longPress:
            let seconds = [0.4, 0.5, 0.7][step]
            tuning.longPress = seconds
            tuning.holdMinDuration = seconds
        case .swipeLength:
            let factor = [0.7, 1.0, 1.3][step]
            tuning.swipeMinPoints = 250 * factor
            tuning.swipeLongPoints = 900 * factor
        case .circle:
            tuning.circleDegrees = [270, 300, 350][step]
        case .centerSize:
            tuning.sideThreshold = [0.15, 0.20, 0.30][step]
        case .customShapes:
            tuning.customShapeDistance = [0.10, 0.15, 0.21][step]
        }
    }
}

/// The chosen step of each knob, kept in the profile.
struct PlayerGestureSensitivity: Codable, Equatable, Sendable {
    private var steps: [String: Int] = [:]

    init() {}

    func step(_ knob: PlayerGestureSensitivityKnob) -> Int {
        min(max(steps[knob.rawValue] ?? knob.defaultStep, 0), knob.steps.count - 1)
    }

    /// The next step, round to the first after the last.
    mutating func cycle(_ knob: PlayerGestureSensitivityKnob) {
        steps[knob.rawValue] = (step(knob) + 1) % knob.steps.count
    }

    /// No corners in the player: a touch is in the middle or on one of the four sides.
    var tuning: RemoteGestureTuning {
        var tuning = RemoteGestureTuning()
        tuning.cornerTouches = false
        for knob in PlayerGestureSensitivityKnob.allCases {
            knob.apply(step: step(knob), to: &tuning)
        }
        return tuning
    }
}

/// What the player does with a gesture nobody bound (while playing with the controls hidden).
enum PlayerBuiltInGesture {
    case seekBack, seekForward
    case holdSeekBack, holdSeekForward
    case select, playPause
    case revealControls, openPanel
    case peek

    static func action(for gesture: RemoteGesture) -> PlayerBuiltInGesture? {
        switch gesture {
        case .click(.select, .single): return .select
        case .click(.playPause, .single): return .playPause
        case .click(.left, .single): return .seekBack
        case .click(.right, .single): return .seekForward
        case .click(.left, .long): return .holdSeekBack
        case .click(.right, .long): return .holdSeekForward
        case .click(.up, .single), .swipe(.up, _): return .revealControls
        case .click(.down, .single), .swipe(.down, _): return .openPanel
        case let .tap(side, double: false):
            switch side {
            case .left, .topLeft, .bottomLeft: return .seekBack
            case .right, .topRight, .bottomRight: return .seekForward
            case .center, .top, .bottom: return .peek
            }
        default: return nil
        }
    }

    /// For the Gestures tab: what binding this gesture takes away.
    var title: String {
        switch self {
        case .seekBack: return "seek back"
        case .seekForward: return "seek forward"
        case .holdSeekBack: return "rewind"
        case .holdSeekForward: return "fast forward"
        case .select: return "pause"
        case .playPause: return "play / pause"
        case .revealControls: return "show controls"
        case .openPanel: return "InSight"
        case .peek: return "peek"
        }
    }
}
