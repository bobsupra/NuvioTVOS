import SwiftUI

/// Recording a gesture for an action: the pad shows live what the finger and the
/// buttons do, the gesture is done twice to be saved, and every kind of gesture loops at the bottom
/// as a hint. Back cancels.
struct PlayerGestureRecorderView: View {
    let action: PlayerGestureAction
    let bindings: PlayerGestureBindings
    let tuning: RemoteGestureTuning
    let setPadObserver: (((Double, Double) -> Void)?) -> Void
    let onSave: (RemoteGesture) -> Void
    let onCancel: () -> Void
    /// Shapes of one's own, so one can be recorded for the action.
    var customShapes: [CustomGestureShape] = []

    @State private var session = GestureRecordingSession()
    @State private var trace = GestureLiveTrace()
    @State private var recognizedAt = Date()
    @State private var isSaving = false

    private static let note = Color(red: 1.0, green: 0.82, blue: 0.55)

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            PlayerGestureCapture(
                isActive: true,
                waitsForDouble: { _ in true },
                onGesture: record,
                onBack: onCancel,
                setPadObserver: setPadObserver,
                onInput: { trace.handle($0) },
                onTouchSummary: { trace.handle($0) },
                tuning: tuning,
                customShapes: customShapes
            )
            .ignoresSafeArea()

            VStack(spacing: 34) {
                VStack(spacing: 8) {
                    Text(L10n.string("player_do_gesture_for", fallback: "Do the gesture for"))
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundColor(.white.opacity(0.55))
                    Text(action.title)
                        .font(.system(size: 44, weight: .bold))
                        .foregroundColor(.white)
                }

                HStack(alignment: .center, spacing: 70) {
                    TimelineView(.animation) { _ in
                        RemotePadCanvas(
                            frame: trace.frame(at: ProcessInfo.processInfo.systemUptime),
                            zones: tuning
                        )
                    }
                    .frame(width: 360, height: 360 * RemotePadCanvas.aspect)

                    stepPanel
                        .frame(width: 820, alignment: .leading)
                }

                hints
            }
            .padding(.top, 50)
            .frame(maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(false)
        }
        .onAppear { trace.setTuning(tuning) }
        .transition(.opacity)
    }

    // MARK: What happened so far

    private var stepPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            TimelineView(.animation) { _ in
                let live = trace.status(at: ProcessInfo.processInfo.systemUptime)
                Text(live ?? headline)
                    .font(.system(size: 38, weight: .bold))
                    .foregroundColor(live == nil ? .white : RemotePadCanvas.accent)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(height: 100, alignment: .bottomLeading)

            Text(subtitle)
                .font(.system(size: 24, weight: .medium))
                .foregroundColor(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)

            recognizedCards

            HStack(spacing: 12) {
                ForEach(0..<2, id: \.self) { index in
                    Circle()
                        .fill(index < confirmedCount ? RemotePadCanvas.accent : Color.clear)
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.5), lineWidth: 2))
                        .frame(width: 18, height: 18)
                }
                Text("Do it twice to save · Back cancels")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(.white.opacity(0.4))
            }
        }
    }

    @ViewBuilder
    private var recognizedCards: some View {
        switch session.step {
        case .first:
            Color.clear.frame(height: 190)
        case let .confirm(gesture), let .done(gesture):
            recognizedCard(gesture, label: meaningLine(gesture))
        case let .mismatch(first, second):
            HStack(spacing: 24) {
                recognizedCard(first, label: "first")
                recognizedCard(second, label: "second")
            }
        }
    }

    private func recognizedCard(_ gesture: RemoteGesture, label: String) -> some View {
        HStack(spacing: 18) {
            AnimatedGesturePad(gesture: gesture, start: recognizedAt)
                .frame(width: 130, height: 130 * RemotePadCanvas.aspect)
            VStack(alignment: .leading, spacing: 8) {
                Text(gesture.title)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(label)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(Self.note)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(0.07)))
        .frame(height: 190)
    }

    private var headline: String {
        switch session.step {
        case .first: return "Do the gesture"
        case let .confirm(gesture): return "Recognized: \(gesture.title)"
        case .mismatch: return "Doesn’t match"
        case let .done(gesture): return "Saved: \(gesture.title)"
        }
    }

    private var subtitle: String {
        switch session.step {
        case .first: return "The pad on the left shows what the remote picks up."
        case .confirm: return "Do it once more to confirm."
        case .mismatch: return "The second one came out different. Do the gesture again."
        case .done: return "\(action.title) has a new gesture."
        }
    }

    private var confirmedCount: Int {
        switch session.step {
        case .first, .mismatch: return 0
        case .confirm: return 1
        case .done: return 2
        }
    }

    private func meaningLine(_ gesture: RemoteGesture) -> String {
        let meaning = PlayerGestureMeaning(of: gesture, in: bindings)
        if meaning == .action(action) { return "already set for this action" }
        return "now: \(meaning.title)"
    }

    // MARK: Every kind, looping

    private var hints: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.string("player_gesture_you_can_use", fallback: "You can use"))
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.white.opacity(0.45))
            HStack(alignment: .top, spacing: 26) {
                ForEach(Array(GestureFamily.shown.enumerated()), id: \.element) { index, family in
                    VStack(spacing: 6) {
                        AnimatedGestureFamilyPad(family: family, offset: Double(index) * 0.37, showsVariant: false)
                            .frame(width: 104, height: 104 * RemotePadCanvas.aspect)
                        Text(family.title)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.white.opacity(0.6))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .frame(width: 136)
                }
            }
        }
    }

    // MARK: Input

    private func record(_ gesture: RemoteGesture) {
        guard !isSaving else { return }
        let step = session.record(gesture)
        recognizedAt = Date()
        if case let .done(saved) = step {
            isSaving = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
                onSave(saved)
            }
        }
    }
}
