import SwiftUI

/// The Chapters tab of the bottom panel: the file's chapters in a row, like the Apple TV
/// player's Chapters panel. Each card has a 16:9 still (the chapter number until it loads),
/// the name, the start time and an Opening / Ending badge; the playing chapter shows ▶, its
/// progress and the time left. Selecting a chapter jumps there and closes the panel.
struct PlayerChaptersRow: View {
    @ObservedObject var viewModel: PlayerViewModel
    /// The playhead, so the playing chapter and its progress stay current.
    @ObservedObject var clock: PlaybackClock
    /// Chapter stills as they load.
    @ObservedObject var thumbnails: ChapterThumbnailStore
    let focusedCardID: FocusState<String?>.Binding
    let focusContext: ScenePanelWatchPartyFocusContext
    /// After a chapter was selected (the jump is already on its way).
    let onSelect: () -> Void
    let onDismiss: () -> Void

    @AppStorage(SettingsKey.cardCornerRadius) private var cardCornerRadiusSetting = AppCardStyle.defaultCornerRadiusRaw

    static let cardWidth: CGFloat = 320
    static let stillHeight: CGFloat = 180

    static func focusID(of chapter: PlaybackChapter) -> String {
        "chapter-\(chapter.id)"
    }

    static func chapterID(fromFocusID id: String?) -> Int? {
        guard let id, id.hasPrefix("chapter-") else { return nil }
        return Int(id.dropFirst("chapter-".count))
    }

    private var stillCornerRadius: CGFloat {
        max(8, AppCardStyle.cornerRadius(for: cardCornerRadiusSetting, fallback: 16) * 0.75)
    }

    var body: some View {
        let chapters = viewModel.chapters
        let current = PlaybackChapters.index(at: clock.position, in: chapters)
        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                // Not lazy: the card the tab enters on must exist to take the focus.
                HStack(alignment: .top, spacing: 28) {
                    ForEach(Array(chapters.enumerated()), id: \.element.id) { index, chapter in
                        let id = Self.focusID(of: chapter)
                        let isFocused = focusedCardID.wrappedValue == id
                        Button {
                            viewModel.seekToChapter(chapter)
                            onSelect()
                        } label: {
                            card(chapter, index: index, isCurrent: index == current, isFocused: isFocused)
                        }
                        .buttonStyle(PosterCardButtonStyle())
                        .focused(focusedCardID, equals: id)
                        .disabled(focusContext.entryLocked && id != focusContext.entryFocusTarget)
                        .focusEffectDisabledIfAvailable()
                        .onExitCommand(perform: onDismiss)
                        .onMoveCommand { direction in
                            if direction == .up { focusContext.onMoveUpFromContent() }
                        }
                        .id(id)
                    }
                }
                .padding(.horizontal, 60)
                .padding(.top, 16)
                .padding(.bottom, 24)
            }
            .scrollClipDisabled()
            .onAppear {
                // The first open starts loading every chapter's still; it carries on after
                // the panel closes, so the next open has them.
                viewModel.startChapterThumbnails()
                let target = focusContext.entryFocusTarget
                DispatchQueue.main.async { proxy.scrollTo(target, anchor: .center) }
            }
            .onDisappear {
                viewModel.focusChapterThumbnail(id: nil)
            }
            .onChange(of: focusedCardID.wrappedValue) { _, id in
                focusContext.onFocusChanged(id)
                // The chapter under the focus loads next, then the ones around it.
                viewModel.focusChapterThumbnail(id: Self.chapterID(fromFocusID: id))
                if let id, Self.chapterID(fromFocusID: id) != nil {
                    withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }

    private func card(_ chapter: PlaybackChapter, index: Int, isCurrent: Bool, isFocused: Bool) -> some View {
        let kind = PlaybackChapters.kind(of: chapter, segments: viewModel.skipSegments)
        return VStack(alignment: .leading, spacing: 12) {
            still(chapter, index: index, isCurrent: isCurrent, isFocused: isFocused, kind: kind)

            VStack(alignment: .leading, spacing: 4) {
                Text(PlaybackChapters.displayName(chapter, index: index))
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white.opacity(isFocused ? 1 : 0.86))
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text(isCurrent
                         ? L10n.format(
                            "player_chapter_time_left",
                            fallback: "%@ left",
                            PlayerTimeFormat.clock(max(0, chapter.endSeconds - clock.position)))
                         : PlayerTimeFormat.clock(chapter.startSeconds))
                        .font(.system(size: 17, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.6))
                    if let kind {
                        Text(kind == .opening
                             ? L10n.string("player_chapter_opening", fallback: "Opening")
                             : L10n.string("player_chapter_ending", fallback: "Ending"))
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(kind.labelColor)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(kind.color))
                    }
                }
            }
            .padding(.horizontal, 4)
        }
        .frame(width: Self.cardWidth, alignment: .leading)
    }

    /// The 16:9 still, lifted when focused; the number stands in until it loads.
    private func still(
        _ chapter: PlaybackChapter,
        index: Int,
        isCurrent: Bool,
        isFocused: Bool,
        kind: PlaybackChapters.Kind?
    ) -> some View {
        let image = viewModel.canShowChapterThumbnails ? thumbnails.images[chapter.id] : nil
        let shape = RoundedRectangle(cornerRadius: stillCornerRadius, style: .continuous)
        return ZStack {
            Color.white.opacity(0.08)
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: Self.cardWidth, height: Self.stillHeight)
                    .transition(.opacity)
            } else {
                Text("\(index + 1)")
                    .font(.system(size: 56, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.28))
            }
        }
        .frame(width: Self.cardWidth, height: Self.stillHeight)
        .overlay(alignment: .topLeading) {
            if isCurrent || image != nil {
                Group {
                    if isCurrent {
                        Image(systemName: "play.fill")
                            .font(.system(size: 14, weight: .bold))
                    } else {
                        Text("\(index + 1)")
                            .font(.system(size: 16, weight: .bold).monospacedDigit())
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.black.opacity(0.6)))
                .padding(10)
            }
        }
        .overlay(alignment: .bottom) {
            if isCurrent, chapter.durationSeconds > 0 {
                let fraction = min(max((clock.position - chapter.startSeconds) / chapter.durationSeconds, 0), 1)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.black.opacity(0.35))
                        Rectangle()
                            .fill(kind?.color ?? Color.white)
                            .frame(width: geo.size.width * CGFloat(fraction))
                    }
                }
                .frame(height: 5)
            }
        }
        .clipShape(shape)
        .overlay(
            shape.strokeBorder(
                isFocused ? Color.white : (isCurrent ? Color.white.opacity(0.35) : Color.clear),
                lineWidth: isFocused ? 4 : 2)
        )
        .shadow(color: .black.opacity(isFocused ? 0.45 : 0.2), radius: isFocused ? 16 : 6, y: isFocused ? 8 : 3)
        .scaleEffect(isFocused ? 1.07 : 1)
        .animation(.easeOut(duration: 0.14), value: isFocused)
        .animation(.easeOut(duration: 0.2), value: image != nil)
    }
}
