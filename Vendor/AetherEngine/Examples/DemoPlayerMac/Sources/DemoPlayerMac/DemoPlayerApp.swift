// DemoPlayerMac, standalone macOS demonstrator app for AetherEngine.
//
// Single window, drop a video file onto it, video plays. No menus,
// no transport bar, no settings, the entire UI surface is one
// AetherPlayerSurface plus a placeholder for the empty state.
// Click or press space to toggle play/pause; press escape to stop.
//
// Intended audience: testers who want to exercise the engine against
// their own media without writing a host app, and developers who want
// to see the smallest viable AetherEngine integration on macOS.
//
// Universal binary: arm64 + x86_64 via the FFmpegBuild xcframeworks.

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AetherEngine

@main
struct DemoPlayerApp: App {

    /// Engine is created once for the app lifetime. AetherEngine is
    /// designed to be a long-lived instance: every dropped file calls
    /// `load(url:)` against this same engine instead of building a
    /// fresh audio session + display-criteria controller each time.
    let engine: AetherEngine = {
        do {
            return try AetherEngine()
        } catch {
            fatalError("AetherEngine init failed: \(error)")
        }
    }()

    var body: some Scene {
        Window("AetherEngine Demo", id: "main") {
            ContentView(engine: engine)
                .frame(minWidth: 640, minHeight: 360)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

struct ContentView: View {
    let engine: AetherEngine

    @State private var loadedURL: URL?
    @State private var loadError: String?
    @State private var isLoading: Bool = false
    @State private var playerState: PlaybackState = .idle
    @State private var isDropTargeted: Bool = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if loadedURL != nil {
                AetherPlayerSurface(engine: engine)
                    .ignoresSafeArea()
                    .onTapGesture { togglePlayPause() }
            } else {
                placeholderView
            }

            if isLoading {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.large)
                    .tint(.white)
            }

            if let err = loadError {
                VStack {
                    Spacer()
                    Text(err)
                        .font(.callout)
                        .foregroundStyle(.white)
                        .padding(12)
                        .background(.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
                        .padding(.bottom, 24)
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
        .background(KeyHandlerView { event in
            handleKey(event: event)
        })
        .onReceive(engine.$state) { playerState = $0 }
        .overlay(alignment: .topTrailing) {
            // Tiny corner indicator showing which backend rendered the
            // current video. Useful for repro reports, "did this play
            // on the native or software path?".
            if loadedURL != nil {
                Text(backendBadge)
                    .font(.system(.caption2, design: .monospaced))
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(.black.opacity(0.55), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(8)
            }
        }
    }

    private var placeholderView: some View {
        VStack(spacing: 16) {
            Image(systemName: "film.stack")
                .font(.system(size: 64))
                .foregroundStyle(.white.opacity(isDropTargeted ? 0.95 : 0.45))
            Text(isDropTargeted ? "Release to load" : "Drop a video file here")
                .font(.title2)
                .foregroundStyle(.white.opacity(isDropTargeted ? 0.95 : 0.65))
            Text("MKV, MP4, WebM, MPEG-TS, AVI, OGG, FLV")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.35))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }

    private var backendBadge: String {
        switch engine.playbackBackend {
        case .native: return "native"
        case .software: return "sw"
        case .aether: return "aether"
        case .audio: return "audio"
        case .none: return ""
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url = url else { return }
            Task { @MainActor in
                await load(url: url)
            }
        }
        return true
    }

    private func handleKey(event: NSEvent) -> Bool {
        switch event.keyCode {
        case 49: // Space
            togglePlayPause()
            return true
        case 53: // Escape
            stop()
            return true
        default:
            return false
        }
    }

    private func load(url: URL) async {
        loadError = nil
        isLoading = true
        defer { isLoading = false }
        do {
            try await engine.load(url: url)
            engine.play()
            loadedURL = url
        } catch {
            loadError = "Load failed: \(error.localizedDescription)"
            loadedURL = nil
        }
    }

    private func togglePlayPause() {
        switch playerState {
        case .playing:
            engine.pause()
        case .paused:
            engine.play()
        default:
            break
        }
    }

    private func stop() {
        engine.stop()
        loadedURL = nil
        loadError = nil
    }
}

/// AppKit-bridging NSView that captures key events at the window level
/// and forwards them through the closure. SwiftUI's `.onKeyPress` on
/// macOS requires the view to be focused, which our full-bleed video
/// area can't reliably claim; an `NSView` in the window's responder
/// chain gets keyDown events for free.
private struct KeyHandlerView: NSViewRepresentable {
    let onKey: (NSEvent) -> Bool

    func makeNSView(context: Context) -> _KeyView {
        let view = _KeyView()
        view.onKey = onKey
        return view
    }

    func updateNSView(_ nsView: _KeyView, context: Context) {
        nsView.onKey = onKey
    }

    final class _KeyView: NSView {
        var onKey: ((NSEvent) -> Bool)?
        override var acceptsFirstResponder: Bool { true }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.makeFirstResponder(self)
        }
        override func keyDown(with event: NSEvent) {
            if onKey?(event) == true { return }
            super.keyDown(with: event)
        }
    }
}
