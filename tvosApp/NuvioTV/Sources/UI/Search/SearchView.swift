import SwiftUI
import UIKit

struct SearchView: View {
    @StateObject private var viewModel: SearchViewModel
    let showDiscover: Bool
    let onContentClick: (String, String) -> Void

    @FocusState private var searchBarFocused: Bool
    @FocusState private var focusedResultID: String?
    @State private var searchTextInputActive = false
    @AppStorage(SettingsKey.amoled) private var amoled = false
    @AppStorage(SettingsKey.bodyColor) private var bodyColor = SettingsBackground.charcoal.rawValue

    init(viewModel: SearchViewModel, showDiscover: Bool = true, onContentClick: @escaping (String, String) -> Void) {
        _viewModel = StateObject(wrappedValue: viewModel)
        self.showDiscover = showDiscover
        self.onContentClick = onContentClick
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.nuvioBackground(amoled: amoled, body: bodyColor).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 24) {
                header

                if viewModel.hasQuery {
                    typeFilter
                    resultsContainer
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                } else {
                    if !viewModel.recentSearches.isEmpty {
                        recentRow
                    }
                    if showDiscover {
                        DiscoverSection(onContentClick: onContentClick)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    } else {
                        centeredState {
                            messageState(
                                icon: "rectangle.grid.2x2",
                                title: "Discover is hidden from Search"
                            )
                        }
                    }
                }
            }
            .padding(.horizontal, 80)
            .padding(.top, 56)
        }
        .onAppear {
            if !viewModel.hasQuery {
                DispatchQueue.main.async { searchBarFocused = true }
            }
        }
    }

    // MARK: - Header + glass search bar

    private var header: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Search")
                .font(.system(size: 46, weight: .bold))
                .foregroundColor(.white)

            searchBar
        }
    }

    private var searchBar: some View {
        ZStack(alignment: .leading) {
            HiddenSearchTextField(
                text: $viewModel.searchText,
                isEditing: $searchTextInputActive,
            )
            .frame(width: 1, height: 1)
            .offset(x: -4_000)
            .allowsHitTesting(false)

            Button {
                searchBarFocused = true
                searchTextInputActive = true
            } label: {
                Color.clear
                    .frame(width: 360, height: 86)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PosterCardButtonStyle())
            .focused($searchBarFocused)
            .focusEffectDisabledIfAvailable()

            // Glass overlay: magnifier + typed text / placeholder + clear.
            HStack(spacing: 18) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))

                Text(viewModel.searchText.isEmpty ? "Search movies & shows" : viewModel.searchText)
                    .font(.system(size: 30, weight: .regular))
                    .foregroundColor(viewModel.searchText.isEmpty ? .white.opacity(0.45) : .white)
                    .lineLimit(1)
                    .allowsHitTesting(false)

                Spacer(minLength: 0)

                if viewModel.hasQuery {
                    Button {
                        viewModel.clear()
                        searchBarFocused = true
                        searchTextInputActive = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 30))
                            .foregroundColor(.white.opacity(0.55))
                    }
                    .buttonStyle(PosterCardButtonStyle())
                    .focusEffectDisabledIfAvailable()
                }
            }
        }
        .padding(.horizontal, 34)
        .frame(height: 86)
        .frame(maxWidth: 1080, alignment: .leading)
        .modifier(GlassCapsule(focused: searchBarFocused || searchTextInputActive))
    }

    // MARK: - Type filter

    private var typeFilter: some View {
        HStack(spacing: 16) {
            ForEach(SearchContentType.allCases) { type in
                GlassChip(title: type.title, isSelected: viewModel.selectedType == type) {
                    viewModel.setType(type)
                }
            }

            Spacer()

            if !viewModel.results.isEmpty {
                Text("\(viewModel.results.count) result\(viewModel.results.count == 1 ? "" : "s")")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))
            }
        }
    }

    // MARK: - Results / states

    @ViewBuilder
    private var resultsContainer: some View {
        if viewModel.isLoading {
            centeredState {
                ProgressView()
                    .scaleEffect(1.6)
                    .tint(.white)
            }
        } else if let error = viewModel.error {
            centeredState {
                messageState(icon: "wifi.exclamationmark", title: error)
            }
        } else if viewModel.results.isEmpty {
            centeredState {
                messageState(icon: "magnifyingglass",
                             title: "No results for “\(viewModel.searchText)”")
            }
        } else {
            resultsGrid
        }
    }

    private var resultsGrid: some View {
        ScrollView {
            LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 44) {
                ForEach(viewModel.results) { item in
                    SearchResultCard(meta: item, externalFocus: $focusedResultID) {
                        onContentClick(item.id, item.type)
                    }
                }
            }
            .padding(.top, 16)
            .padding(.horizontal, 12)
            .padding(.bottom, 90)
        }
        .scrollClipDisabledIfAvailable()
        .focusSection()
        .defaultFocusIfAvailable($focusedResultID, viewModel.results.first?.id)
    }

    private var gridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 210, maximum: 230), spacing: 36, alignment: .top)]
    }

    // MARK: Recent searches (shown above Discover when idle)

    private var recentRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recent searches")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(.white.opacity(0.8))
                Spacer()
                Button("Clear") { viewModel.clearRecent() }
                    .buttonStyle(.plain)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(.white.opacity(0.55))
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(viewModel.recentSearches, id: \.self) { term in
                        GlassChip(title: term, isSelected: false, leadingSystemImage: "clock.arrow.circlepath") {
                            viewModel.applyRecent(term)
                        }
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 4)
                .padding(.trailing, 80)
            }
            .scrollClipDisabledIfAvailable()
        }
    }

    private func centeredState<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack {
            Spacer(minLength: 40)
            content()
            Spacer(minLength: 40)
        }
        .frame(maxWidth: .infinity)
    }

    private func messageState(icon: String, title: String, subtitle: String? = nil) -> some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 64, weight: .light))
                .foregroundColor(.white.opacity(0.4))
            Text(title)
                .font(.system(size: 28, weight: .semibold))
                .foregroundColor(.white.opacity(0.8))
                .multilineTextAlignment(.center)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 22))
                    .foregroundColor(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: 700)
    }
}

// MARK: - Result card

private struct SearchResultCard: View {
    let meta: NuvioMeta
    var externalFocus: FocusState<String?>.Binding? = nil
    let action: () -> Void
    @FocusState private var focused: Bool
    @AppStorage(SettingsKey.posterLabels) private var posterLabels = false
    @AppStorage(SettingsKey.smoothFocus) private var smoothFocus = true
    @AppStorage(SettingsKey.focusHighlighter) private var focusHighlighter = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                AsyncImage(url: URL(string: meta.posterUrl ?? "")) { phase in
                    if case .success(let image) = phase {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        ZStack {
                            Rectangle().fill(Color.white.opacity(0.07))
                            Image(systemName: meta.type == "series" ? "tv" : "film")
                                .font(.system(size: 40))
                                .foregroundColor(.white.opacity(0.25))
                        }
                    }
                }
                .frame(width: 210, height: 315)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    WatchedCheckmarkBadge(metaId: meta.id, type: meta.type)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(focused ? focusBorderColor : .clear, lineWidth: focusHighlighter ? 5 : 3)
                )
                .shadow(color: .black.opacity(focused ? 0.5 : 0.2), radius: focused ? 16 : 6)

                if posterLabels {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(meta.name)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(focused ? .white : .white.opacity(0.78))
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.white.opacity(0.45))
                            .lineLimit(1)
                    }
                    .frame(width: 210, alignment: .leading)
                }
            }
            .scaleEffect(focused ? 1.06 : 1.0)
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($focused)
        .modifier(ExternalFocusBinding(binding: externalFocus, id: meta.id))
        .focusEffectDisabledIfAvailable()
        .animation(smoothFocus ? .spring(response: 0.28, dampingFraction: 0.75) : nil, value: focused)
    }

    private var subtitle: String {
        var parts: [String] = [meta.type == "series" ? "Series" : "Movie"]
        if let year = meta.year { parts.append(String(year)) }
        if let rating = meta.rating, rating > 0 { parts.append(String(format: "★ %.1f", rating)) }
        return parts.joined(separator: "  ·  ")
    }

    private var focusBorderColor: Color {
        .white.opacity(0.86)
    }
}

// MARK: - Hidden text input

private struct HiddenSearchTextField: UIViewRepresentable {
    @Binding var text: String
    @Binding var isEditing: Bool

    func makeUIView(context: Context) -> HiddenSearchUITextField {
        let textField = HiddenSearchUITextField(frame: .zero)
        textField.delegate = context.coordinator
        textField.backgroundColor = .clear
        textField.textColor = .clear
        textField.tintColor = .clear
        textField.returnKeyType = .search
        textField.keyboardAppearance = .dark
        textField.autocorrectionType = .no
        textField.addTarget(
            context.coordinator,
            action: #selector(Coordinator.textDidChange(_:)),
            for: .editingChanged
        )
        return textField
    }

    func updateUIView(_ uiView: HiddenSearchUITextField, context: Context) {
        if uiView.text != text {
            uiView.text = text
        }

        if isEditing && !uiView.isFirstResponder {
            DispatchQueue.main.async {
                uiView.becomeFirstResponder()
            }
        } else if !isEditing && uiView.isFirstResponder {
            uiView.resignFirstResponder()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, isEditing: $isEditing)
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        private let text: Binding<String>
        private let isEditing: Binding<Bool>

        init(text: Binding<String>, isEditing: Binding<Bool>) {
            self.text = text
            self.isEditing = isEditing
        }

        @objc func textDidChange(_ sender: UITextField) {
            text.wrappedValue = sender.text ?? ""
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            isEditing.wrappedValue = false
            textField.resignFirstResponder()
            return true
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            isEditing.wrappedValue = false
        }
    }
}

private final class HiddenSearchUITextField: UITextField {
    override var canBecomeFocused: Bool { false }
}

// MARK: - Glass components

struct GlassChip: View {
    let title: String
    let isSelected: Bool
    var leadingSystemImage: String? = nil
    let action: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let leadingSystemImage {
                    Image(systemName: leadingSystemImage)
                        .font(.system(size: 20, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 24, weight: .semibold))
            }
            .foregroundColor(isSelected || focused ? .black : .white.opacity(0.85))
            .padding(.horizontal, 30)
            .frame(height: 60)
            .modifier(GlassChipBackground(filled: isSelected || focused))
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($focused)
        .focusEffectDisabledIfAvailable()
        .scaleEffect(focused ? 1.06 : 1.0)
        .animation(.easeOut(duration: 0.14), value: focused)
    }
}

/// Liquid Glass capsule for the search bar, with a material fallback for tvOS < 26.
struct GlassCapsule: ViewModifier {
    let focused: Bool

    func body(content: Content) -> some View {
        glassed(content)
            .overlay(
                Capsule().stroke(
                    Color.white.opacity(focused ? 0.86 : 0.18),
                    lineWidth: focused ? 3 : 1
                )
            )
            .scaleEffect(focused ? 1.012 : 1.0)
            .animation(.easeOut(duration: 0.18), value: focused)
    }

    @ViewBuilder
    private func glassed(_ content: Content) -> some View {
        if #available(tvOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content.background(.ultraThinMaterial, in: Capsule())
        }
    }
}

struct GlassChipBackground: ViewModifier {
    let filled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if filled {
            content.background(Color.white, in: Capsule())
        } else if #available(tvOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content.background(.ultraThinMaterial, in: Capsule())
        }
    }
}

extension View {
    /// Disables the system's default tvOS focus highlight (the bloated light
    /// "lift" card) so custom focus styling isn't drawn over. No-op below tvOS 17.
    @ViewBuilder
    func focusEffectDisabledIfAvailable() -> some View {
        if #available(tvOS 17.0, *) {
            focusEffectDisabled()
        } else {
            self
        }
    }

    /// Lets focused content (which scales up 1.06) spill outside the scroll
    /// view's bounds instead of being clipped. No-op below tvOS 17.
    @ViewBuilder
    func scrollClipDisabledIfAvailable() -> some View {
        if #available(tvOS 17.0, *) {
            scrollClipDisabled()
        } else {
            self
        }
    }
}
