#if os(tvOS)
import SwiftUI
import UIKit

@MainActor
private final class PlaybackDiagnosticHistoryModel: ObservableObject {
    @Published private(set) var snapshot: PlaybackDiagnosticTimelineStore.Snapshot?
    @Published private(set) var exportURL: URL?
    @Published private(set) var qrImage: UIImage?
    @Published private(set) var message = ""
    private let server = PlaybackDiagnosticExportServer()
    private var requestID = UUID()

    func refresh(preservingMessage: Bool = false) {
        let request = requestID
        PlaybackDiagnosticTimelineStore.shared.snapshot { [weak self] snapshot in
            Task { @MainActor in
                guard let self, self.requestID == request else { return }
                self.snapshot = snapshot
                if snapshot.writeFailed {
                    self.message = "Some diagnostics could not be saved on this Apple TV."
                } else if !preservingMessage && self.exportURL == nil {
                    self.message = ""
                }
            }
        }
    }

    func exportHistory() {
        stopExport()
        let request = requestID
        message = "Preparing local download…"
        PlaybackDiagnosticTimelineStore.shared.snapshot { [weak self] snapshot in
            guard let data = snapshot.timeline.encoded() else {
                Task { @MainActor in
                    guard let self, self.requestID == request else { return }
                    self.message = "The diagnostic report could not be prepared."
                }
                return
            }
            Task { @MainActor in
                guard let self, self.requestID == request else { return }
                self.server.start(report: data) { [weak self] state in
                    Task { @MainActor in
                        guard let self, self.requestID == request else { return }
                        switch state {
                        case .starting:
                            self.message = "Preparing local download…"
                        case .ready(let url):
                            self.exportURL = url
                            self.qrImage = QRCode.image(from: url.absoluteString)
                            self.message = "Scan with a phone on the same trusted local network. This link expires in five minutes."
                        case .failed:
                            self.exportURL = nil
                            self.qrImage = nil
                            self.message = "Local download could not start. Check the Apple TV network connection and try again."
                        case .stopped:
                            self.exportURL = nil
                            self.qrImage = nil
                            self.message = "Local download has stopped."
                        }
                    }
                }
            }
        }
    }

    func stopExport() {
        requestID = UUID()
        server.stop()
        exportURL = nil
        qrImage = nil
        message = "Local download has stopped."
    }

    func clearHistory() {
        stopExport()
        let request = requestID
        PlaybackDiagnosticTimelineStore.shared.removeAll { [weak self] succeeded in
            Task { @MainActor in
                guard let self, self.requestID == request else { return }
                self.message = succeeded ? "Diagnostic history deleted." : "Diagnostic history could not be deleted."
                self.refresh(preservingMessage: true)
            }
        }
    }
}

struct PlaybackDiagnosticHistoryView: View {
    let accentColor: Color
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = PlaybackDiagnosticHistoryModel()
    @State private var confirmDelete = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                Text(L10n.string("diagnostic_history_title", fallback: "Playback Diagnostic History")).font(.largeTitle.bold())
                Text(L10n.string("diagnostic_history_subtitle", fallback: "Recent playback actions saved on this Apple TV. A previous session without a recorded ending is not proof of a crash. Recent events may be missing after a sudden exit."))
                    .font(.system(size: 23)).foregroundStyle(.secondary)
                HStack(spacing: 24) {
                    Button(L10n.string("calendar_refresh", fallback: "Refresh")) { model.refresh() }
                    Button(L10n.string("diagnostic_history_export", fallback: "Export History")) { model.exportHistory() }
                        .disabled(model.snapshot?.timeline.sessions.isEmpty != false)
                    Button(L10n.string("diagnostic_history_delete", fallback: "Delete History"), role: .destructive) { confirmDelete = true }
                    Button(L10n.string("tvos_common_done", fallback: "Done")) { dismiss() }
                }
                .buttonStyle(.bordered)
                .tint(accentColor)

                if !model.message.isEmpty {
                    Text(model.message).font(.system(size: 23))
                }
                if let url = model.exportURL {
                    HStack(spacing: 32) {
                        if let image = model.qrImage {
                            Image(uiImage: image)
                                .interpolation(.none).resizable().scaledToFit()
                                .frame(width: 240, height: 240).padding(12).background(.white)
                                .accessibilityLabel("Diagnostic download link")
                        }
                        VStack(alignment: .leading, spacing: 16) {
                            Text(url.absoluteString).font(.system(size: 21, design: .monospaced))
                            Text(L10n.string("diagnostic_history_download_notice", fallback: "The link downloads a JSON report. No automatic upload is performed. Close this screen or choose Stop Download to end access."))
                                .font(.system(size: 22)).foregroundStyle(.secondary)
                            Button(L10n.string("diagnostic_history_stop_download", fallback: "Stop Download")) { model.stopExport() }
                        }
                    }
                }

                if let snapshot = model.snapshot {
                    if snapshot.timeline.sessions.isEmpty {
                        Text(L10n.string("diagnostic_history_empty", fallback: "No saved events. Enable Persistent Playback History in Advanced Settings, then use the player."))
                    }
                    ForEach(Array(snapshot.timeline.sessions.reversed())) { session in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(session.id == PlaybackTimelineRecorder.sessionID ? L10n.string("diagnostic_session_current", fallback: "This app session") : L10n.string("diagnostic_session_previous", fallback: "Previous app session"))
                                .font(.title2.bold())
                            Text("Nuvio \(session.appVersion) (\(session.build)) · \(session.osVersion)")
                                .font(.system(size: 20)).foregroundStyle(.secondary)
                            Text(session.startedAt.formatted(date: .abbreviated, time: .standard))
                            if session.droppedEvents > 0 {
                                Text("\(session.droppedEvents) older events removed by the history limit.").foregroundStyle(.secondary)
                            }
                            ForEach(Array(session.events.enumerated()), id: \.offset) { _, event in
                                Text("\(event.timestamp.formatted(date: .omitted, time: .standard)) · \(event.name.rawValue)\(event.engine.map { " · " + $0.rawValue } ?? "")")
                                    .font(.system(size: 20, design: .monospaced))
                                    .focusable()
                            }
                        }
                        .padding(24).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
                    }
                    if snapshot.timeline.droppedPendingEvents > 0 {
                        Text(L10n.string("diagnostic_history_dropped_events", fallback: "Some events were dropped because the diagnostic queue was full.")).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(64)
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear { model.refresh() }
        .onDisappear { model.stopExport() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in model.stopExport() }
        .onExitCommand { dismiss() }
        .confirmationDialog(L10n.string("diagnostic_history_delete_confirm", fallback: "Delete diagnostic history from this Apple TV?"), isPresented: $confirmDelete) {
            Button(L10n.string("diagnostic_history_delete", fallback: "Delete History"), role: .destructive) { model.clearHistory() }
            Button(L10n.string("action_cancel", fallback: "Cancel"), role: .cancel) {}
        }
    }
}
#endif
