import SwiftUI

public struct LibraryView: View {
    @StateObject private var viewModel: LibraryViewModel
    let onContentClick: (String, String) -> Void
    @AppStorage(SettingsKey.amoled) private var amoled = false
    @AppStorage(SettingsKey.bodyColor) private var bodyColor = SettingsBackground.charcoal.rawValue

    public init(viewModel: LibraryViewModel, onContentClick: @escaping (String, String) -> Void) {
        _viewModel = StateObject(wrappedValue: viewModel)
        self.onContentClick = onContentClick
    }
    
    public var body: some View {
        ZStack(alignment: .top) {
            Color.nuvioBackground(amoled: amoled, body: bodyColor).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 24) {
                Text("Library")
                    .font(.system(size: 46, weight: .bold))
                    .foregroundColor(.white)

                // Controls
                HStack(spacing: 16) {
                    FilterMenu(label: "Sort: \(viewModel.sortOption.rawValue)") {
                        ForEach(LibraryViewModel.SortOption.allCases) { option in
                            Button { viewModel.sortOption = option } label: {
                                menuItem(option.rawValue, selected: viewModel.sortOption == option)
                            }
                        }
                    }

                    FilterMenu(label: "Group: \(viewModel.groupOption.rawValue)") {
                        ForEach(LibraryViewModel.GroupOption.allCases) { option in
                            Button { viewModel.groupOption = option } label: {
                                menuItem(option.rawValue, selected: viewModel.groupOption == option)
                            }
                        }
                    }
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(viewModel.sortedAndGroupedItems.keys.sorted(), id: \.self) { group in
                            if viewModel.groupOption != .none {
                                Text(group.capitalized)
                                    .font(.system(size: 28, weight: .semibold))
                                    .foregroundColor(.white.opacity(0.85))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }

                            LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 44) {
                                ForEach(viewModel.sortedAndGroupedItems[group] ?? [], id: \.id) { item in
                                    LibraryItemButton(item: item) {
                                        onContentClick(item.id, item.contentType)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 90)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 80)
            .padding(.top, 56)
        }
    }

    @ViewBuilder
    private func menuItem(_ title: String, selected: Bool) -> some View {
        if selected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    private var gridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 230, maximum: 250), spacing: 28, alignment: .top)]
    }
}

struct LibraryItemButton: View {
    let item: StremioMeta
    let action: () -> Void
    
    @FocusState private var isFocused: Bool
    @AppStorage(SettingsKey.posterLabels) private var posterLabels = false
    @AppStorage(SettingsKey.smoothFocus) private var smoothFocus = true
    @AppStorage(SettingsKey.focusHighlighter) private var focusHighlighter = false
    
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                AsyncImage(url: URL(string: item.poster ?? "")) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    default:
                        ZStack {
                            Rectangle()
                                .fill(Color.white.opacity(0.08))
                            Image(systemName: "photo")
                                .font(.title)
                                .foregroundColor(.white.opacity(0.3))
                        }
                    }
                }
                .frame(width: 210, height: 315)
                .clipShape(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    WatchedCheckmarkBadge(metaId: item.id, type: item.contentType)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                        .stroke(isFocused ? focusBorderColor : Color.clear, lineWidth: focusHighlighter ? 5 : 3)
                )
                .shadow(color: .black.opacity(isFocused ? 0.5 : 0.2), radius: isFocused ? 12 : 4)
                .scaleEffect(isFocused ? 1.06 : 1.0)
                .animation(smoothFocus ? .spring(response: 0.28, dampingFraction: 0.72) : nil, value: isFocused)
                
                if posterLabels {
                    Text(item.name)
                        .font(.system(size: 18, weight: isFocused ? .semibold : .medium))
                        .foregroundColor(isFocused ? .white : .white.opacity(0.6))
                        .lineLimit(1)
                        .frame(width: 210, alignment: .leading)
                        .animation(smoothFocus ? .spring(response: 0.28, dampingFraction: 0.72) : nil, value: isFocused)
                }
            }
            .frame(width: 210, alignment: .topLeading)
            .padding(.horizontal, 10)
            .padding(.vertical, 14)
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($isFocused)
        .focusEffectDisabledIfAvailable()
        .zIndex(isFocused ? 1 : 0)
    }

    private var focusBorderColor: Color {
        .white.opacity(0.86)
    }

    private var cardCornerRadius: CGFloat {
        16
    }
}
