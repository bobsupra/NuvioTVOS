import SwiftUI

/// Full catalog of titles from a production company or network.
struct ProductionBrowseView: View {
    let company: MetaCompany
    let onSelect: (RelatedTitle) -> Void
    let onBack: () -> Void

    @State private var titles: [RelatedTitle] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @FocusState private var focusedId: String?

    private let columns = [
        GridItem(.adaptive(minimum: 200, maximum: 220), spacing: 28)
    ]

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 28) {
                header

                if isLoading {
                    Spacer()
                    ProgressView()
                        .scaleEffect(1.6)
                        .frame(maxWidth: .infinity)
                    Spacer()
                } else if let errorMessage {
                    Spacer()
                    Text(errorMessage)
                        .font(.system(size: 30, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                        .frame(maxWidth: .infinity)
                    Spacer()
                } else if titles.isEmpty {
                    Spacer()
                    Text("No titles found for \(company.name)")
                        .font(.system(size: 30, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                        .frame(maxWidth: .infinity)
                    Spacer()
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 36) {
                            ForEach(titles) { title in
                                ProductionBrowseCard(title: title) {
                                    onSelect(title)
                                }
                                .focused($focusedId, equals: title.id)
                            }
                        }
                        .padding(.horizontal, 80)
                        .padding(.bottom, 80)
                    }
                }
            }
            .padding(.top, 48)
        }
        .onExitCommand(perform: onBack)
        .task(id: company.id) {
            await load()
        }
    }

    private var header: some View {
        HStack(spacing: 28) {
            if let logo = company.logoURL, let url = URL(string: logo) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                            .padding(12)
                            .frame(width: 160, height: 80)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    default:
                        companyNameFallback
                    }
                }
            } else {
                companyNameFallback
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(company.name)
                    .font(.system(size: 42, weight: .bold))
                    .foregroundColor(.white)
                Text(company.kind == .network ? "Network catalog" : "Production catalog")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundColor(.white.opacity(0.55))
                if !isLoading {
                    Text("\(titles.count) titles")
                        .font(.system(size: 24, weight: .regular))
                        .foregroundColor(.white.opacity(0.4))
                }
            }
            Spacer()
        }
        .padding(.horizontal, 80)
    }

    private var companyNameFallback: some View {
        Text(company.name)
            .font(.system(size: 28, weight: .semibold))
            .foregroundColor(.black)
            .padding(.horizontal, 20)
            .frame(width: 160, height: 80)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        let results = await TmdbDetailsService.discoverTitles(company: company)
        titles = results
        isLoading = false
        if focusedId == nil {
            focusedId = results.first?.id
        }
    }
}

private struct ProductionBrowseCard: View {
    let title: RelatedTitle
    let onSelect: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                    if let poster = title.posterURL, let url = URL(string: poster) {
                        AsyncImage(url: url) { phase in
                            if case .success(let image) = phase {
                                image
                                    .resizable()
                                    .scaledToFill()
                            }
                        }
                        .frame(width: 200, height: 300)
                        .clipped()
                    } else {
                        Image(systemName: "film")
                            .font(.system(size: 40, weight: .medium))
                            .foregroundColor(.white.opacity(0.4))
                    }
                }
                .frame(width: 200, height: 300)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(
                            isFocused ? AppFocusOutline.color : Color.white.opacity(0.12),
                            lineWidth: isFocused ? AppFocusOutline.width : 1
                        )
                )

                Text(title.name)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .frame(width: 200, alignment: .leading)

                if let year = title.year {
                    Text(year)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))
                }
            }
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($isFocused)
        .focusEffectDisabledIfAvailable()
        .scaleEffect(isFocused ? 1.05 : 1)
        .animation(.easeOut(duration: 0.14), value: isFocused)
    }
}
