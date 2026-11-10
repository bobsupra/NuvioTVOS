import SwiftUI

/// Making a gesture of one's own: a shape drawn on the touchpad three times.
/// Each drawing is checked as it comes (not a tap, a swipe or a circle), the three together at
/// the end (the same shape, not like another one). Back cancels.
struct PlayerCustomGestureMakerView: View {
    let existing: [CustomGestureShape]
    let tuning: RemoteGestureTuning
    let setPadObserver: (((Double, Double) -> Void)?) -> Void
    let onSave: (CustomGestureShape) -> Void
    let onCancel: () -> Void

    @State private var trace = GestureLiveTrace()
    @State private var drawings: [[PadPoint]] = []
    @State private var problem: CustomGestureMaker.Problem?
    @State private var saved: CustomGestureShape?

    private static let note = Color(red: 1.0, green: 0.82, blue: 0.55)

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            PlayerGestureCapture(
                isActive: true,
                waitsForDouble: { _ in false },
                onGesture: { _ in },
                onBack: onCancel,
                setPadObserver: setPadObserver,
                onInput: { trace.handle($0) },
                onTouchSummary: { summary in
                    trace.handle(summary)
                    drew(summary)
                },
                tuning: tuning
            )
            .ignoresSafeArea()

            VStack(spacing: 34) {
                VStack(spacing: 8) {
                    Text(L10n.string("player_new_custom_gesture", fallback: "New custom gesture"))
                        .font(.system(size: 44, weight: .bold))
                        .foregroundColor(.white)
                    Text(L10n.string("player_draw_custom_gesture_hint", fallback: "Draw a shape on the touchpad three times, the same way each time · Back cancels"))
                        .font(.system(size: 24, weight: .medium))
                        .foregroundColor(.white.opacity(0.55))
                }

                HStack(alignment: .center, spacing: 70) {
                    TimelineView(.animation) { _ in
                        RemotePadCanvas(frame: trace.frame(at: ProcessInfo.processInfo.systemUptime))
                    }
                    .frame(width: 360, height: 360 * RemotePadCanvas.aspect)

                    VStack(alignment: .leading, spacing: 22) {
                        Text(headline)
                            .font(.system(size: 38, weight: .bold))
                            .foregroundColor(.white)
                        Text(problem?.message ?? hint)
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundColor(problem == nil ? .white.opacity(0.6) : Self.note)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 20) {
                            ForEach(0..<CustomGestureMaker.drawingsNeeded, id: \.self) { index in
                                slot(index)
                            }
                        }
                    }
                    .frame(width: 820, alignment: .leading)
                }
            }
            .padding(.top, 60)
            .frame(maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(false)
        }
        .onAppear { trace.setTuning(tuning) }
        .transition(.opacity)
    }

    private var headline: String {
        if let saved { return "Saved as \(saved.name)" }
        return "Drawing \(min(drawings.count + 1, CustomGestureMaker.drawingsNeeded)) of \(CustomGestureMaker.drawingsNeeded)"
    }

    private var hint: String {
        if saved != nil { return "Now give it an action: pick one on the right and draw the shape." }
        return drawings.isEmpty
            ? "A letter, a check mark, a zigzag: something with a corner or a turn, across most of the touchpad."
            : "Again, the same shape the same way."
    }

    private func slot(_ index: Int) -> some View {
        let drawing = index < drawings.count ? CustomGestureMatcher.normalized(drawings[index]) : nil
        return ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.07))
            if let drawing {
                RemotePadCanvas(frame: GestureAnimation.still(drawing))
                    .padding(14)
            } else {
                Text("\(index + 1)")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundColor(.white.opacity(0.25))
            }
        }
        .frame(width: 150, height: 180)
    }

    private func drew(_ summary: TouchSummary) {
        guard saved == nil, !summary.withClick else { return }
        if let problem = CustomGestureMaker.check(summary.points, tuning: tuning) {
            // A tap between drawings is no drawing, and not worth a message once one is under way.
            if problem == .tooShort, summary.duration < tuning.tapMaxDuration { return }
            self.problem = problem
            return
        }
        problem = nil
        drawings.append(summary.points)
        guard drawings.count == CustomGestureMaker.drawingsNeeded else { return }
        switch CustomGestureMaker.make(drawings, existing: existing, tuning: tuning) {
        case let .success(shape):
            saved = shape
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                onSave(shape)
            }
        case let .failure(failure):
            problem = failure.problem
            drawings = []
        }
    }
}
