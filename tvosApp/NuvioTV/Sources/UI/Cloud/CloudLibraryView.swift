import SwiftUI

/// Browses the user's debrid cloud (Premiumize / TorBox) and plays a chosen
/// file through the built-in player. Two levels: a list of saved items, then the
/// playable files inside a multi-file item.
struct CloudLibraryView: View {
    @StateObject private var viewModel: CloudLibraryViewModel
    let onPlay: (URL, NuvioMeta) -> Void
    let onBack: () -> Void

    /// The item whose files are being shown; `nil` at the top level.
    @State private var openItem: CloudItem?
    @FocusState private var focused: String?
    @FocusState private var isLoadingFocusActive: Bool

    init(store: UserDefaults, onPlay: @escaping (URL, NuvioMeta) -> Void, onBack: @escaping () -> Void) {
        _viewModel = StateObject(wrappedValue: CloudLibraryViewModel(store: store))
        self.onPlay = onPlay
        self.onBack = onBack
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 24) {
                header

                if viewModel.isLoading {
                    centeredMessage { ProgressView().progressViewStyle(.circular).tint(.white).scaleEffect(1.6) }
                } else if let openItem {
                    fileList(for: openItem)
                } else if let error = viewModel.errorMessage, viewModel.items.isEmpty {
                    centeredMessage {
                        Text(error)
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundColor(.white.opacity(0.7))
                            .multilineTextAlignment(.center)
                    }
                } else {
                    itemList
                }
            }
            .padding(.horizontal, 80)
            .padding(.top, 56)

            if viewModel.isLoading || (viewModel.errorMessage != nil && viewModel.items.isEmpty) {
                Color.clear
                    .frame(width: 1, height: 1)
                    .focusable(true)
                    .focused($isLoadingFocusActive)
            }
        }
        .alert(
            L10n.string("cloud_library_play_failed_title", fallback: "Playback Error"),
            isPresented: Binding(
                get: { viewModel.playbackErrorMessage != nil },
                set: { if !$0 { viewModel.clearPlaybackError() } }
            )
        ) {
            Button(L10n.string("common_ok", fallback: "OK"), role: .cancel) {
                viewModel.clearPlaybackError()
            }
        } message: {
            Text(viewModel.playbackErrorMessage ?? "")
        }
        .onExitCommand {
            viewModel.cancelResolving()
            if openItem == nil {
                onBack()
            } else {
                closeItem()
            }
        }
        .onAppear {
            TVHomeDebugTrace.log("cloudLibrary.appear")
            if let saved = viewModel.openItem {
                openItem = saved
            }
            if let savedKey = viewModel.focusedKey {
                focused = savedKey
            }
            if viewModel.isLoading {
                DispatchQueue.main.async {
                    isLoadingFocusActive = true
                }
            }
        }
        .onDisappear {
            TVHomeDebugTrace.log("cloudLibrary.disappear")
            viewModel.cancelResolving()
        }
        .onChange(of: focused) { _, newFocus in
            if let newFocus {
                viewModel.focusedKey = newFocus
            }
        }
        .task { await viewModel.load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.string("debrid_cloud_library", fallback: "Cloud Library"))
                .font(.system(size: 46, weight: .bold))
                .foregroundColor(.white)
            Text(openItem?.name ?? viewModel.providerName)
                .font(.system(size: 26, weight: .medium))
                .foregroundColor(.white.opacity(0.6))
                .lineLimit(1)
        }
    }

    private var itemList: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                ForEach(viewModel.items, id: \.stableKey) { item in
                    CloudRow(
                        title: item.name,
                        subtitle: subtitle(for: item),
                        externalFocus: $focused,
                        focusId: item.stableKey,
                        isBusy: false
                    ) {
                        viewModel.focusedKey = item.stableKey
                        focused = item.stableKey
                        open(item)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 90)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollClipDisabledIfAvailable()
        .focusSection()
        .defaultFocusIfAvailable($focused, viewModel.focusedKey ?? viewModel.items.first?.stableKey)
    }

    private func fileList(for item: CloudItem) -> some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                ForEach(item.playableFiles) { file in
                    let key = "\(item.stableKey):\(file.id)"
                    CloudRow(
                        title: file.name,
                        subtitle: Self.sizeText(file.sizeBytes),
                        externalFocus: $focused,
                        focusId: key,
                        isBusy: viewModel.resolvingKey == key
                    ) {
                        viewModel.focusedKey = key
                        focused = key
                        viewModel.play(item: item, file: file, onResolved: onPlay)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 90)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollClipDisabledIfAvailable()
        .focusSection()
        .defaultFocusIfAvailable($focused, viewModel.focusedKey ?? item.playableFiles.first.map { "\(item.stableKey):\($0.id)" })
    }

    private func centeredMessage<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func open(_ item: CloudItem) {
        let playable = item.playableFiles
        // A single playable file plays straight away; otherwise drill in.
        if playable.count == 1 {
            viewModel.focusedKey = item.stableKey
            focused = item.stableKey
            viewModel.play(item: item, file: playable[0], onResolved: onPlay)
        } else if !playable.isEmpty {
            openItem = item
            viewModel.openItem = item
            let firstKey = "\(item.stableKey):\(playable[0].id)"
            focused = firstKey
            viewModel.focusedKey = firstKey
        }
    }

    private func closeItem() {
        let key = openItem?.stableKey
        openItem = nil
        viewModel.openItem = nil
        focused = key
        viewModel.focusedKey = key
    }

    // MARK: - Formatting

    private func subtitle(for item: CloudItem) -> String {
        var parts: [String] = []
        let count = item.playableFiles.count
        if count > 1 { parts.append("\(count) files") }
        if let size = Self.sizeText(item.sizeBytes) { parts.append(size) }
        if let status = item.status, !status.isEmpty { parts.append(status.capitalized) }
        return parts.joined(separator: "  ·  ")
    }

    static func sizeText(_ bytes: Int64?) -> String? {
        guard let bytes, bytes > 0 else { return nil }
        return byteFormatter.string(fromByteCount: bytes)
    }

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useGB, .useMB]
        f.countStyle = .file
        return f
    }()
}

/// One focusable cloud row (item or file).
struct CloudRow: View {
    let title: String
    let subtitle: String?
    var externalFocus: FocusState<String?>.Binding? = nil
    var focusId: String = ""
    var retainFocusAppearance = false
    let isBusy: Bool
    let action: () -> Void

    @FocusState private var isFocused: Bool

    private var showsFocusedAppearance: Bool {
        isFocused || retainFocusAppearance
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 20) {
                Image(systemName: isBusy ? "arrow.triangle.2.circlepath" : "play.rectangle.on.rectangle")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundColor(.white.opacity(0.8))
                    .frame(width: 44)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 22, weight: .regular))
                            .foregroundColor(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                if isBusy {
                    ProgressView().progressViewStyle(.circular).tint(.white)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.white.opacity(showsFocusedAppearance ? 0.18 : 0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(showsFocusedAppearance ? AppFocusOutline.color : .clear, lineWidth: showsFocusedAppearance ? AppFocusOutline.width : 0)
            )
            .scaleEffect(showsFocusedAppearance ? 1.015 : 1)
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($isFocused)
        .modifier(ExternalFocusBinding(binding: externalFocus, id: focusId))
        .focusEffectDisabledIfAvailable()
        .animation(.easeOut(duration: 0.15), value: showsFocusedAppearance)
    }
}
