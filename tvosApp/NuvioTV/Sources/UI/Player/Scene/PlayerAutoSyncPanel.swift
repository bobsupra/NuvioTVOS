import SwiftUI

/// The AutoSubSync tab of the bottom panel: run AutoSubSync on the playing add-on subtitle by
/// hand, switch between its synced copy and its own timing, and see what the last run looked at:
/// the reference tried, the parts with shifts of their own, and what couldn't be checked.
/// Sync by Audio (AetherEngine) lines it up with the speech in the soundtrack instead and keeps
/// following it; while it has something to show, the right side is about it.
struct PlayerAutoSyncPanel: View {
    @ObservedObject var viewModel: PlayerViewModel
    let focusedControlID: FocusState<String?>.Binding
    let focusContext: ScenePanelWatchPartyFocusContext
    let onDismiss: () -> Void

    static let runID = "autosync.run"
    static let toggleID = "autosync.toggle"
    static let audioID = "autosync.audio"

    var body: some View {
        let subtitle = viewModel.activeAddonSubtitle
        let state = subtitle.flatMap { viewModel.subtitleAutoSyncStates[$0.url] }
        let report = subtitle.flatMap { viewModel.subtitleAutoSyncReports[$0.url] }
        let usingOriginal = subtitle.map { viewModel.isSubtitleAutoSyncUsingOriginal($0.url) } ?? false
        let audio = viewModel.audioSyncStatus.flatMap { $0.subtitleURL == subtitle?.url ? $0 : nil }
        return HStack(alignment: .top, spacing: 40) {
            VStack(alignment: .leading, spacing: 14) {
                Text(subtitleTitle(subtitle))
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(statusText(state, usingOriginal: usingOriginal))
                    .font(.system(size: 20, weight: .medium).monospacedDigit())
                    .foregroundStyle(statusColor(state))
                    .lineLimit(2)
                HStack(spacing: 18) {
                    controlButton(
                        id: Self.runID,
                        title: isChecking(state)
                            ? L10n.string("player_autosync_running", fallback: "Checking…")
                            : L10n.string("player_autosync_run", fallback: "Sync Now"),
                        systemImage: "arrow.triangle.2.circlepath",
                        enabled: subtitle != nil && !isChecking(state)
                    ) {
                        viewModel.runSubtitleAutoSyncNow()
                    }
                    if case .synced? = state {
                        controlButton(
                            id: Self.toggleID,
                            title: usingOriginal
                                ? L10n.string("player_autosync_use_synced", fallback: "Synced Timing")
                                : L10n.string("player_subtitle_autosync_original", fallback: "Original Timing"),
                            systemImage: usingOriginal ? "checkmark.circle" : "arrow.uturn.backward",
                            enabled: true
                        ) {
                            viewModel.toggleSubtitleAutoSyncTiming()
                        }
                    }
                }
                .padding(.top, 4)
                audioRow(subtitle: subtitle, audio: audio)
            }
            .frame(width: 520, alignment: .leading)

            Group {
                if let audio {
                    audioDiagnostics(audio)
                } else {
                    diagnostics(report, hasSubtitle: subtitle != nil, checked: state != nil)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 60)
        .padding(.top, 8)
        .onChange(of: focusedControlID.wrappedValue) { _, id in
            focusContext.onFocusChanged(id)
        }
    }

    // MARK: Controls

    private func controlButton(
        id: String,
        title: String,
        systemImage: String,
        enabled: Bool,
        upToTabs: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        let isFocused = focusedControlID.wrappedValue == id
        return Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(isFocused ? Color.black : Color.white)
                .padding(.horizontal, 26)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(isFocused ? Color.white : Color.white.opacity(0.12))
                )
                .opacity(enabled ? 1 : 0.45)
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused(focusedControlID, equals: id)
        .disabled(!enabled || (focusContext.entryLocked && id != focusContext.entryFocusTarget))
        .focusEffectDisabledIfAvailable()
        .onExitCommand(perform: onDismiss)
        .onMoveCommand { direction in
            if direction == .up, upToTabs { focusContext.onMoveUpFromContent() }
        }
        .scaleEffect(isFocused ? 1.05 : 1)
        .animation(.easeOut(duration: 0.14), value: isFocused)
    }

    // MARK: Sync by Audio

    private var isOnAether: Bool { viewModel.activeEngineKind == .aether }

    private func audioRow(subtitle: NuvioSubtitle?, audio: AudioSyncStatus?) -> some View {
        let running = viewModel.isAudioSyncRunning && audio?.isRunning == true
        return HStack(spacing: 18) {
            controlButton(
                id: Self.audioID,
                title: running
                    ? L10n.string("player_autosync_audio_stop", fallback: "Stop Listening")
                    : L10n.string("player_autosync_audio", fallback: "Sync by Audio"),
                systemImage: running ? "stop.circle" : "waveform",
                enabled: subtitle != nil && (running || isOnAether),
                upToTabs: false
            ) {
                viewModel.toggleAudioSync()
            }
            Text(audioSummary(audio))
                .font(.system(size: 18, weight: .medium).monospacedDigit())
                .foregroundStyle(audioColor(audio))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func audioSummary(_ audio: AudioSyncStatus?) -> String {
        guard isOnAether || audio?.isRunning == true else {
            return L10n.string("player_autosync_audio_needs_aether", fallback: "Needs AetherEngine (playing on MPV)")
        }
        guard let audio else {
            return L10n.string("player_autosync_audio_hint", fallback: "Listens to the speech and follows it")
        }
        switch audio.phase {
        case .reading:
            return "Reading the subtitle…"
        case .listening:
            return String(format: "Listening · %.0f s heard", audio.heard)
        case .following:
            return String(format: "Following · %@", Self.seconds(audio.applied ?? 0))
                + (audio.pending.map { " → " + Self.seconds($0) } ?? "")
        case .stopped(let reason):
            return audio.applied.map { "\(reason) · kept " + Self.seconds($0) } ?? reason
        }
    }

    private func audioColor(_ audio: AudioSyncStatus?) -> Color {
        switch audio?.phase {
        case .following?: return Color(red: 0.42, green: 0.86, blue: 0.52)
        case .stopped?: return Color(red: 1.0, green: 0.74, blue: 0.36)
        default: return .white.opacity(0.7)
        }
    }

    private func audioDiagnostics(_ audio: AudioSyncStatus) -> some View {
        HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 8) {
                row(L10n.string("player_autosync_engine", fallback: "Engine"), isOnAether ? "AetherEngine · audio tap (downmix)" : "MPV")
                row(L10n.string("player_autosync_subtitles", fallback: "Subtitles"), audio.lines > 0 ? "\(audio.lines) dialogue lines" : "")
                row(L10n.string("player_autosync_heard", fallback: "Heard"), heardText(audio))
                if let last = audio.last {
                    row(L10n.string("player_autosync_estimate", fallback: "Estimate"), estimateText(last, count: audio.estimates), lines: 2)
                    row("", last.doubt.map { "not sure: " + $0 } ?? "sure", secondary: true, warning: last.doubt != nil)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)

            VStack(alignment: .leading, spacing: 8) {
                row(L10n.string("player_autosync_applied", fallback: "Delay"),
                    (audio.applied.map(Self.seconds) ?? "–")
                        + (audio.pending.map { " · next " + Self.seconds($0) + " (waits for a gap)" } ?? ""))
                ForEach(Array(audio.changes.suffix(4).reversed().enumerated()), id: \.offset) { index, change in
                    row(index == 0 ? L10n.string("player_autosync_changes", fallback: "Changes") : "",
                        Self.clock(change.at) + "  " + Self.seconds(change.shift), secondary: index > 0)
                }
                if let note = audio.note {
                    row(L10n.string("player_autosync_notes", fallback: "Notes"), note, secondary: true, lines: 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func heardText(_ audio: AudioSyncStatus) -> String {
        guard audio.heard > 0 else { return "" }
        var text = String(format: "%.0f s of the last %.0f s", audio.heard,
                          AudioSubtitleSync.windowBefore + AudioSubtitleSync.windowAfter)
        if let last = audio.last { text += String(format: " · speech %.0f %%", last.speech * 100) }
        return text
    }

    private func estimateText(_ estimate: AudioSyncEstimate, count: Int) -> String {
        Self.seconds(estimate.shift)
            + String(format: " · standout %.1f · rival %.2f · halves %.2f s · %d lines · #%d",
                     estimate.standout, estimate.rival, estimate.halvesApart, estimate.lines, count)
    }

    private static func seconds(_ value: Double) -> String {
        String(format: "%+.2f s", value)
    }

    private static func clock(_ time: Double) -> String {
        let total = Int(max(time, 0))
        let h = total / 3600, m = total / 60 % 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    // MARK: Text

    private func subtitleTitle(_ subtitle: NuvioSubtitle?) -> String {
        guard let subtitle else {
            return L10n.string("player_autosync_choose", fallback: "Choose add-on subtitles in the subtitle menu")
        }
        let language = SubtitleLanguageDisplay.name(for: subtitle.language)
        return [language, subtitle.label, subtitle.source]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            .joined(separator: " · ")
    }

    private func isChecking(_ state: SubtitleAutoSyncState?) -> Bool {
        if case .checking? = state { return true }
        return false
    }

    private func statusText(_ state: SubtitleAutoSyncState?, usingOriginal: Bool) -> String {
        switch state {
        case nil:
            return L10n.string("player_autosync_not_checked", fallback: "Not checked yet")
        case .checking:
            return L10n.string("player_autosync_running", fallback: "Checking…")
        case .synced(let result):
            let synced = L10n.format("subtitle_autosync_synced_toast", fallback: "Subtitles synced (%@)", result.shortLabel)
            return usingOriginal
                ? synced + " · " + L10n.string("player_subtitle_autosync_original", fallback: "Original Timing")
                : synced
        case .kept(let issue):
            return issue.message
        }
    }

    private func statusColor(_ state: SubtitleAutoSyncState?) -> Color {
        switch state {
        case .synced, .kept(.inSync): return Color(red: 0.42, green: 0.86, blue: 0.52)
        case .kept: return Color(red: 1.0, green: 0.74, blue: 0.36)
        case .checking, nil: return .white.opacity(0.7)
        }
    }

    // MARK: Diagnostics

    @ViewBuilder
    private func diagnostics(_ report: SubtitleAutoSyncReport?, hasSubtitle: Bool, checked: Bool) -> some View {
        if let report {
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    row(L10n.string("player_autosync_source", fallback: "Source"), report.source)
                    row(L10n.string("player_autosync_subtitles", fallback: "Subtitles"), report.subtitle)
                    row(L10n.string("player_autosync_index", fallback: "Index"), report.index)
                    // A line per track, with why it was left out.
                    ForEach(Array(report.tracks.prefix(6).enumerated()), id: \.offset) { _, track in
                        row("", track, secondary: true)
                    }
                    ForEach(Array(report.attempts.prefix(3).enumerated()), id: \.offset) { index, attempt in
                        row(index == 0 ? L10n.string("player_autosync_reference", fallback: "Reference") : "", attempt, lines: 2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)

                VStack(alignment: .leading, spacing: 8) {
                    row(L10n.string("player_autosync_result", fallback: "Result"),
                        report.result + (report.fromCache ? " · " + L10n.string("player_autosync_cached", fallback: "remembered") : ""))
                    ForEach(Array(report.parts.prefix(3).enumerated()), id: \.offset) { index, line in
                        row(index == 0 ? L10n.string("player_autosync_parts", fallback: "Parts") : "", line)
                    }
                    ForEach(Array(report.warnings.prefix(3).enumerated()), id: \.offset) { index, line in
                        row(index == 0 ? "⚠" : "", line, warning: true)
                    }
                    ForEach(Array(report.notes.prefix(3).enumerated()), id: \.offset) { index, line in
                        row(index == 0 ? L10n.string("player_autosync_notes", fallback: "Notes") : "", line, secondary: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        } else {
            Text(hasSubtitle && !checked
                 ? L10n.string("player_autosync_hint", fallback: "Sync Now compares the subtitle's timing with the subtitles embedded in the video (MKV) and switches to a synced copy.")
                 : "")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(4)
        }
    }

    private func row(_ label: String, _ value: String, secondary: Bool = false, warning: Bool = false, lines: Int = 1) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(label)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(warning ? Color(red: 1.0, green: 0.74, blue: 0.36) : .white.opacity(0.55))
                .frame(width: 104, alignment: .leading)
            Text(value.isEmpty ? "–" : value)
                .font(.system(size: secondary ? 15 : 17, weight: .regular).monospacedDigit())
                .foregroundStyle(warning ? Color(red: 1.0, green: 0.82, blue: 0.55) : .white.opacity(secondary ? 0.55 : 0.85))
                .lineLimit(lines)
                .truncationMode(.tail)
        }
    }
}
