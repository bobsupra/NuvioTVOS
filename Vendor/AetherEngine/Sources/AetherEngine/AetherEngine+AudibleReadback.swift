import AVFoundation
import Foundation

extension AetherEngine {

    /// AE#458: read back what AVFoundation resolved from the audio this load served, once per load.
    ///
    /// Read-only by construction: it never selects an option. The audible group is AVKit's own source for
    /// the audio menu, so touching the selection here would change what a viewer hears in order to log it.
    ///
    /// Waits for readiness before reading. The group is usually populated once the master is parsed, but on
    /// some OS versions `loadMediaSelectionGroup(for:)` returns an empty group until `readyToPlay` (measured
    /// on the legible side, AE#154 / jihongboo), and an early read would report a loss AVFoundation had not
    /// taken. An item that never gets ready produces no line, which is correct: there is nothing to read,
    /// and the failure has its own lines.
    func logAudibleReadback(host: NativeAVPlayerHost) {
        audibleReadbackTask?.cancel()
        guard let item = host.avPlayer.currentItem else { return }
        let servingMaster = nativeVideoSession?.servingMasterPlaylist ?? false
        let served = nativeVideoSession?.provider?.masterAudioRendition?.language
        audibleReadbackTask = Task { @MainActor [weak self] in
            for await ready in host.$isReady.values where ready { break }
            guard !Task.isCancelled, let self,
                  self.currentAVPlayer?.currentItem === item else { return }
            let group = try? await item.asset.loadMediaSelectionGroup(for: .audible)
            guard !Task.isCancelled, self.currentAVPlayer?.currentItem === item else { return }
            let options = (group?.options ?? []).map {
                AudibleSelectionReadback.Option(
                    displayName: $0.displayName, languageTag: $0.extendedLanguageTag)
            }
            let selected = group
                .flatMap { item.currentMediaSelection.selectedMediaOption(in: $0) }
                .map { AudibleSelectionReadback.Option(
                    displayName: $0.displayName, languageTag: $0.extendedLanguageTag) }
            EngineLog.emit(
                AudibleSelectionReadback.line(
                    served: served,
                    servingMaster: servingMaster,
                    groupPresent: group != nil,
                    options: options,
                    selected: selected),
                category: .session)
        }
    }
}
