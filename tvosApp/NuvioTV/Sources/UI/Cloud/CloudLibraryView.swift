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
        }
        .onExitCommand { openItem == nil ? onBack() : closeItem() }
        .task { await viewModel.load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Cloud Library")
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
                    ) { open(item) }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 90)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollClipDisabledIfAvailable()
        .focusSection()
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
                    ) { viewModel.play(item: item, file: file, onResolved: onPlay) }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 90)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollClipDisabledIfAvailable()
        .focusSection()
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
            viewModel.play(item: item, file: playable[0], onResolved: onPlay)
        } else if !playable.isEmpty {
            openItem = item
            focused = "\(item.stableKey):\(playable[0].id)"
        }
    }

    private func closeItem() {
        let key = openItem?.stableKey
        openItem = nil
        focused = key
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
