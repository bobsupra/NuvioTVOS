//
//  TVCatalogRow.swift
//  NuvioTV
//
//  Created for NuvioTVOS modularization.
//

import SwiftUI
import Foundation

/// Shared Home vertical rhythm for catalog *and* collection folder rows.
enum TVHomeLayout {
    static let sectionSpacing: CGFloat = 28
    /// Keep the first catalog heading close to the hero description.
    static let heroBottomPadding: CGFloat = 20
    static let rowsTopPadding: CGFloat = 4
    /// Extra scroll room so the last row can reach the same fixed anchor as
    /// earlier rows instead of being clamped to the viewport bottom.
    static let finalRowScrollRunway: CGFloat = 24
    /// Focus breathing room above/below cards inside a strip.
    static let stripVerticalPadding: CGFloat = 24
    /// Section title line (~30pt) + VStack spacing under the title (~10pt) + slack.
    static let rowTitleBlock: CGFloat = 46

    /// Horizontal strip motion with no spring settling.
    static let scrollAnimation = Animation.easeOut(duration: 0.22)
    /// Keep successive remote presses from stacking long-running vertical
    /// transactions while retaining a visible native scroll transition.
    static let verticalScrollAnimation = Animation.easeOut(duration: 0.22)
}

enum TVLayout {
    static let contentLeading: CGFloat = 150
    static let rowLeading: CGFloat = 48
}

/// Grid metrics matching Search / Library poster cards (Tabs view mode).
enum CollectionFolderGridMetrics {
    static let posterWidth: CGFloat = 210
    static let posterHeight: CGFloat = 315
    static let posterGap: CGFloat = 28
}

/// A row whose catalog is still in flight: its real title over a lightweight
/// skeleton strip, sized exactly like `TVCatalogRow` so the row keeps its height
/// and the rows below it do not jump when the real cards arrive.
struct TVLoadingCatalogRow: View {
    let title: String
    var addonName: String? = nil

    @AppStorage(SettingsKey.homeLayout) private var homeLayout = "Modern"
    @AppStorage(SettingsKey.posterLabels) private var posterLabels = false
    @AppStorage(SettingsKey.liquidGlassCards) private var liquidGlassCards = true
    @AppStorage(SettingsKey.catalogAddonNames) private var catalogAddonNames = true
    @AppStorage(SettingsKey.theme) private var theme = SettingsAccent.white.rawValue

    private var cardWidth: CGFloat { homeLayout == "Compact" ? 170 : 210 }
    private var cardHeight: CGFloat { homeLayout == "Compact" ? 255 : 315 }
    private var cardSpacing: CGFloat { homeLayout == "Compact" ? 22 : 28 }

    /// Matches `TVCatalogRow.stripHeight`, so swapping a skeleton for the real
    /// row changes nothing about the rows below it.
    private var stripHeight: CGFloat {
        cardHeight + (posterLabels ? 48 : 0) + TVHomeLayout.stripVerticalPadding * 2
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 14) {
                Text(title)
                    .font(.custom("Inter-Bold", size: 30))
                    .foregroundColor(.white)

                if catalogAddonNames, let addonName = addonName, !addonName.isEmpty {
                    Text(addonName)
                        .font(.custom("Inter-SemiBold", size: 16))
                        .foregroundColor(SettingsAccent.color(for: theme))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(SettingsAccent.color(for: theme).opacity(0.18), in: Capsule())
                        .overlay(
                            Capsule()
                                .strokeBorder(SettingsAccent.color(for: theme).opacity(0.35), lineWidth: 1)
                        )
                }
            }
            .padding(.leading, TVLayout.rowLeading)
            .frame(maxWidth: .infinity, alignment: .leading)

            GeometryReader { geo in
                HStack(alignment: .bottom, spacing: cardSpacing) {
                    ForEach(0..<9, id: \.self) { _ in
                        LoadingPosterCard(
                            width: cardWidth,
                            height: cardHeight,
                            isLiquidGlassEnabled: liquidGlassCards
                        )
                    }
                }
                .padding(.leading, TVLayout.rowLeading)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
                .clipped()
            }
            .frame(height: stripHeight)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TVCatalogRow: View {
    let id: String
    let title: String
    var addonName: String? = nil
    let horizontalEdgeInset: CGFloat
    let items: [NuvioMeta]
    var progressByItemId: [String: ContinueWatchingItem] = [:]
    var watchedTitleKeys: Set<String> = []
    var initialScrollIndex: Int = 0
    var onScrollIndexChange: (Int) -> Void = { _ in }
    let initialFocusCardKey: String?
    let landscapeFocusedId: String?
    var externalFocus: FocusState<String?>.Binding? = nil
    var restrictFocusToCardKey: String? = nil
    var retainFocusAppearanceForCardKey: String? = nil
    var suppressFocusAnimations: Bool = false
    var isRowFocused: Bool = false
    let onInitialFocusRequested: () -> Void
    let onFocus: (NuvioMeta) -> Void
    let onBlur: (NuvioMeta) -> Void
    let onApproachEnd: (NuvioMeta) -> Void
    let onSelect: (NuvioMeta) -> Void
    var onLongPress: ((NuvioMeta) -> Void)? = nil
    var onOpenDetails: ((NuvioMeta) -> Void)? = nil
    var onPlayContinueWatchingManually: ((ContinueWatchingItem) -> Void)? = nil
    var onStartContinueWatchingFromBeginning: ((ContinueWatchingItem) -> Void)? = nil
    var onRemoveFromContinueWatching: ((ContinueWatchingItem) -> Void)? = nil

    @State private var scrollIndex: Int?
    @AppStorage(SettingsKey.homeLayout) private var homeLayout = "Modern"
    @AppStorage(SettingsKey.posterLabels) private var posterLabels = false
    @AppStorage(SettingsKey.catalogAddonNames) private var catalogAddonNames = true
    @AppStorage(SettingsKey.theme) private var theme = SettingsAccent.white.rawValue
    @AppStorage(SettingsKey.smoothFocus) private var smoothFocus = true
    @AppStorage(SettingsKey.focusHighlighter) private var focusHighlighter = false

    private var compactPosterWidth: CGFloat {
        homeLayout == "Compact" ? 170 : 210
    }

    private var rowSpacing: CGFloat {
        homeLayout == "Compact" ? 22 : 28
    }

    private var step: CGFloat { compactPosterWidth + rowSpacing }

    private var effectiveScrollIndex: Int {
        let raw = scrollIndex ?? initialScrollIndex
        guard !items.isEmpty else { return 0 }
        return min(max(raw, 0), items.count - 1)
    }

    private func materializedCardIndices(visibleCardCount: Int) -> [Int] {
        guard !items.isEmpty else { return [] }
        let focusIndex = effectiveScrollIndex
        var lowerBound = max(0, focusIndex - 4)
        var upperBound = min(items.count - 1, focusIndex + visibleCardCount)

        let rowPrefix = "\(id)\u{1}"
        for key in [initialFocusCardKey, restrictFocusToCardKey] {
            guard let key, key.hasPrefix(rowPrefix) else { continue }
            let itemID = String(key.dropFirst(rowPrefix.count))
            if let targetIndex = items.firstIndex(where: { $0.id == itemID }) {
                lowerBound = min(lowerBound, targetIndex)
                upperBound = max(upperBound, targetIndex)
            }
        }

        return Array(lowerBound...upperBound)
    }

    private var stripHeight: CGFloat {
        let imageHeight: CGFloat = homeLayout == "Compact" ? 255 : 315
        return imageHeight + (posterLabels ? 48 : 0) + TVHomeLayout.stripVerticalPadding * 2
    }

    private func isWatched(_ item: NuvioMeta) -> Bool? {
        let normalizedType = item.type.lowercased()
        let titleWatched = !watchedTitleKeys.isDisjoint(
            with: WatchedStore.catalogTitleIdentityKeys(for: item)
        )
        guard ["series", "tv", "show", "tvshow"].contains(normalizedType) else {
            return titleWatched
        }
        return titleWatched ? true : nil
    }

    private var defaultFocusCardKey: String? {
        guard !items.isEmpty else { return nil }
        let idx = effectiveScrollIndex
        return "\(id)\u{1}\(items[idx].id)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 14) {
                Text(title)
                    .font(.custom("Inter-Bold", size: 30))
                    .foregroundColor(.white)

                if catalogAddonNames, let addonName = addonName, !addonName.isEmpty {
                    Text(addonName)
                        .font(.custom("Inter-SemiBold", size: 16))
                        .foregroundColor(SettingsAccent.color(for: theme))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(SettingsAccent.color(for: theme).opacity(0.18), in: Capsule())
                        .overlay(
                            Capsule()
                                .strokeBorder(SettingsAccent.color(for: theme).opacity(0.35), lineWidth: 1)
                        )
                }
            }
            .padding(.leading, TVLayout.rowLeading)
            .offset(y: 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .zIndex(1)

            cardStrip
                .zIndex(0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
        .defaultFocusIfAvailable(externalFocus, defaultFocusCardKey)
    }

    private var cardStrip: some View {
        GeometryReader { geo in
            #if DEBUG
            let rowLayoutStarted = TVHomeDebugTrace.now()
            #endif
            let stripWidth = max(1920, geo.size.width + horizontalEdgeInset * 2)
            let rowHomeLayout = homeLayout
            let rowPosterLabels = posterLabels
            let rowSmoothFocus = smoothFocus
            let rowFocusHighlighter = focusHighlighter
            let rowCardFocusAnimations = rowSmoothFocus && !suppressFocusAnimations
            let rowPosterWidth: CGFloat = rowHomeLayout == "Compact" ? 170 : 210
            let rowCardSpacing: CGFloat = rowHomeLayout == "Compact" ? 22 : 28
            let visibleCardCount = max(1, Int(ceil(stripWidth / (rowPosterWidth + rowCardSpacing))) + 1)
            let materializedIndices = materializedCardIndices(visibleCardCount: visibleCardCount)

            #if DEBUG
            if TVHomeDebugTrace.enabled {
                traceRowLayout(
                    enabled: true,
                    rowID: id,
                    itemCount: items.count,
                    mountedCount: materializedIndices.count,
                    guideEntries: 0,
                    index: effectiveScrollIndex
                )
            }
            #endif

            HStack(alignment: .top, spacing: rowCardSpacing) {
                ForEach(materializedIndices, id: \.self) { itemIndex in
                    let item = items[itemIndex]
                    let cardKey = "\(id)\u{1}\(item.id)"
                    let shouldRequestInitialFocus = cardKey == initialFocusCardKey
                    let progressItem = progressByItemId[item.id]
                    let handleFocus: (NuvioMeta) -> Void = { focused in
                        let focusStarted = TVHomeDebugTrace.now()
                        TVHomeDebugTrace.log(
                            "focus.begin row=\(id) index=\(itemIndex) items=\(items.count) "
                                + "mounted=\(materializedIndices.count) meta=\(focused.id)"
                        )
                        if effectiveScrollIndex != itemIndex {
                            let updateScrollPosition = {
                                scrollIndex = itemIndex
                                onScrollIndexChange(itemIndex)
                            }
                            if rowSmoothFocus && !suppressFocusAnimations {
                                withAnimation(TVHomeLayout.scrollAnimation) {
                                    updateScrollPosition()
                                }
                            } else {
                                var transaction = Transaction()
                                transaction.animation = nil
                                withTransaction(transaction) {
                                    updateScrollPosition()
                                }
                            }
                        }
                        let approachStarted = TVHomeDebugTrace.now()
                        onApproachEnd(focused)
                        TVHomeDebugTrace.log(
                            "focus.approach row=\(id) index=\(itemIndex) "
                                + "elapsedMs=\(TVHomeDebugTrace.elapsedMilliseconds(since: approachStarted))"
                        )
                        let parentStarted = TVHomeDebugTrace.now()
                        onFocus(focused)
                        TVHomeDebugTrace.log(
                            "focus.end row=\(id) index=\(itemIndex) "
                                + "parentMs=\(TVHomeDebugTrace.elapsedMilliseconds(since: parentStarted)) "
                                + "totalMs=\(TVHomeDebugTrace.elapsedMilliseconds(since: focusStarted))"
                        )
                    }
                    PosterCard(
                        meta: item,
                        isLandscape: rowHomeLayout == "Modern" && landscapeFocusedId == cardKey,
                        continueProgress: progressItem?.progress,
                        continueRemainingText: progressItem?.remainingText,
                        continueEpisodeText: progressItem?.episodeLabel,
                        continueEpisodeTitleText: progressItem?.episodeDisplayTitle,
                        continueEpisodeArtworkURL: progressItem?.episodeArtworkURL,
                        continueIsUpNext: progressItem?.isUpNextEntry == true,
                        continueUpNextBadgeText: progressItem?.upNextBadgeText,
                        showsWatchedBadge: id != TVHomeSection.continueWatchingId && id != TVHomeSection.upcomingId,
                        shouldRequestInitialFocus: shouldRequestInitialFocus,
                        onInitialFocusRequested: shouldRequestInitialFocus ? onInitialFocusRequested : nil,
                        onFocus: handleFocus,
                        onBlur: onBlur,
                        externalFocus: externalFocus,
                        externalFocusValue: cardKey,
                        onLongPress: onLongPress,
                        onOpenDetails: onOpenDetails != nil ? { onOpenDetails?(item) } : nil,
                        onPlayManually: ((id == TVHomeSection.continueWatchingId || id == TVHomeSection.upcomingId) && progressItem != nil) ? {
                            if let p = progressItem { onPlayContinueWatchingManually?(p) }
                        } : nil,
                        onStartFromBeginning: ((id == TVHomeSection.continueWatchingId || id == TVHomeSection.upcomingId) && progressItem != nil) ? {
                            if let p = progressItem { onStartContinueWatchingFromBeginning?(p) }
                        } : nil,
                        onRemoveFromContinueWatching: ((id == TVHomeSection.continueWatchingId || id == TVHomeSection.upcomingId) && progressItem != nil) ? {
                            if let p = progressItem { onRemoveFromContinueWatching?(p) }
                        } : nil,
                        layoutMode: rowHomeLayout,
                        showPosterLabels: rowPosterLabels,
                        smoothFocusAnimations: rowCardFocusAnimations,
                        focusHighlighterEnabled: rowFocusHighlighter,
                        retainFocusAppearance: retainFocusAppearanceForCardKey == cardKey,
                        allowsFocus: true,
                        isWatched: isWatched(item)
                    ) {
                        onSelect(item)
                    }
                    .disabled(
                        (restrictFocusToCardKey != nil && restrictFocusToCardKey != cardKey)
                            || (!isRowFocused && itemIndex != effectiveScrollIndex)
                    )
                }
            }
            .padding(.leading, CGFloat(materializedIndices.first ?? 0) * (rowPosterWidth + rowCardSpacing))
            .padding(.vertical, TVHomeLayout.stripVerticalPadding)
            .offset(
                x: horizontalEdgeInset + TVLayout.rowLeading
                    - CGFloat(effectiveScrollIndex) * (rowPosterWidth + rowCardSpacing)
            )
            .frame(
                width: stripWidth,
                height: stripHeight,
                alignment: .topLeading
            )
            .clipped()
            .offset(x: -horizontalEdgeInset)
            .animation(rowCardFocusAnimations ? TVHomeLayout.scrollAnimation : nil, value: landscapeFocusedId)
            .onAppear {
                #if DEBUG
                if TVHomeDebugTrace.enabled {
                    TVHomeDebugTrace.log(
                        "row.layout.appear row=\(id) ms=\(TVHomeDebugTrace.elapsedMilliseconds(since: rowLayoutStarted))"
                    )
                }
                #endif
            }
        }
        .frame(height: stripHeight)
    }

    private func traceRowLayout(
        enabled: Bool,
        rowID: String,
        itemCount: Int,
        mountedCount: Int,
        guideEntries: Int,
        index: Int
    ) {
        TVHomeDebugTrace.log("row.layout row=\(rowID) items=\(itemCount) mounted=\(mountedCount) index=\(index)")
    }
}

extension TVCatalogRow: Equatable {
    static func == (lhs: TVCatalogRow, rhs: TVCatalogRow) -> Bool {
        let lhsTargetInRow = lhs.restrictFocusToCardKey?.hasPrefix("\(lhs.id)\u{1}") == true
        let rhsTargetInRow = rhs.restrictFocusToCardKey?.hasPrefix("\(rhs.id)\u{1}") == true
        let restrictEqual = (lhs.restrictFocusToCardKey != nil) == (rhs.restrictFocusToCardKey != nil)
            && (lhsTargetInRow == rhsTargetInRow)
            && (!lhsTargetInRow || lhs.restrictFocusToCardKey == rhs.restrictFocusToCardKey)

        let lhsRetainInRow = lhs.retainFocusAppearanceForCardKey?.hasPrefix("\(lhs.id)\u{1}") == true
        let rhsRetainInRow = rhs.retainFocusAppearanceForCardKey?.hasPrefix("\(rhs.id)\u{1}") == true
        let retainEqual = (lhsRetainInRow == rhsRetainInRow)
            && (!lhsRetainInRow || lhs.retainFocusAppearanceForCardKey == rhs.retainFocusAppearanceForCardKey)

        return lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.addonName == rhs.addonName
            && lhs.horizontalEdgeInset == rhs.horizontalEdgeInset
            && lhs.items == rhs.items
            && lhs.watchedTitleKeys == rhs.watchedTitleKeys
            && lhs.initialScrollIndex == rhs.initialScrollIndex
            && lhs.initialFocusCardKey == rhs.initialFocusCardKey
            && lhs.landscapeFocusedId == rhs.landscapeFocusedId
            && restrictEqual
            && retainEqual
            && lhs.suppressFocusAnimations == rhs.suppressFocusAnimations
            && lhs.isRowFocused == rhs.isRowFocused
    }
}

enum TVHomeGridLayout {
    static let columns = 7
    static let rows = 3
    static let previewItemCount = columns * rows - 1
    static let posterWidth: CGFloat = 210
    static let posterHeight: CGFloat = 315
    static let itemSpacing: CGFloat = 28
    static let sectionSpacing: CGFloat = 54
    static let heroPageLimit = 7
    static let seeAllID = "__see_all__"

    static var gridColumns: [GridItem] {
        Array(
            repeating: GridItem(.fixed(posterWidth), spacing: itemSpacing, alignment: .top),
            count: columns
        )
    }

    static func isWatched(_ item: NuvioMeta, watchedTitleKeys: Set<String>) -> Bool? {
        let type = item.type.lowercased()
        let titleWatched = !watchedTitleKeys.isDisjoint(
            with: WatchedStore.catalogTitleIdentityKeys(for: item)
        )
        guard ["series", "tv", "show", "tvshow"].contains(type) else {
            return titleWatched
        }
        return titleWatched ? true : nil
    }
}

struct TVHomeCatalogGridSection: View {
    let section: TVHomeSection
    let watchedTitleKeys: Set<String>
    let initialFocusCardKey: String?
    var externalFocus: FocusState<String?>.Binding? = nil
    var restrictFocusToCardKey: String? = nil
    var suppressFocusAnimations = false
    let onInitialFocusRequested: () -> Void
    let onFocus: (NuvioMeta) -> Void
    let onSelect: (NuvioMeta) -> Void
    var onLongPress: ((NuvioMeta) -> Void)? = nil
    let onSeeAllFocus: () -> Void
    let onSeeAll: () -> Void

    @AppStorage(SettingsKey.catalogAddonNames) private var catalogAddonNames = true
    @AppStorage(SettingsKey.theme) private var theme = SettingsAccent.white.rawValue

    private var previewItems: [NuvioMeta] {
        Array(section.items.prefix(TVHomeGridLayout.previewItemCount))
    }

    private var seeAllKey: String {
        "\(section.id)\u{1}\(TVHomeGridLayout.seeAllID)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 14) {
                Text(section.title)
                    .font(.custom("Inter-Bold", size: 30))
                    .foregroundColor(.white)

                if catalogAddonNames, let addonName = section.addonName, !addonName.isEmpty {
                    Text(addonName)
                        .font(.custom("Inter-SemiBold", size: 16))
                        .foregroundColor(SettingsAccent.color(for: theme))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(SettingsAccent.color(for: theme).opacity(0.18), in: Capsule())
                        .overlay(
                            Capsule()
                                .strokeBorder(SettingsAccent.color(for: theme).opacity(0.35), lineWidth: 1)
                        )
                }
            }

            LazyVGrid(
                columns: TVHomeGridLayout.gridColumns,
                alignment: .leading,
                spacing: TVHomeGridLayout.itemSpacing
            ) {
                ForEach(previewItems) { item in
                    let cardKey = "\(section.id)\u{1}\(item.id)"
                    let shouldRequestInitialFocus = cardKey == initialFocusCardKey
                    PosterGridCard(
                        meta: item,
                        width: TVHomeGridLayout.posterWidth,
                        height: TVHomeGridLayout.posterHeight,
                        externalFocus: externalFocus,
                        focusValue: cardKey,
                        retainFocusAppearance: restrictFocusToCardKey == cardKey,
                        isWatched: TVHomeGridLayout.isWatched(item, watchedTitleKeys: watchedTitleKeys),
                        shouldRequestInitialFocus: shouldRequestInitialFocus,
                        onInitialFocusRequested: shouldRequestInitialFocus ? onInitialFocusRequested : nil,
                        onFocus: { onFocus($0) },
                        onLongPress: onLongPress.map { cb in { cb(item) } }
                    ) {
                        onSelect(item)
                    }
                    .disabled(restrictFocusToCardKey != nil && restrictFocusToCardKey != cardKey)
                }

                TVHomeSeeAllCard(
                    title: section.title,
                    externalFocus: externalFocus,
                    externalFocusValue: seeAllKey,
                    retainFocusAppearance: restrictFocusToCardKey == seeAllKey,
                    onFocus: onSeeAllFocus,
                    action: onSeeAll
                )
                .disabled(restrictFocusToCardKey != nil && restrictFocusToCardKey != seeAllKey)
            }
        }
        .padding(.horizontal, TVLayout.rowLeading)
    }
}

struct TVHomeSeeAllCard: View {
    let title: String
    var externalFocus: FocusState<String?>.Binding? = nil
    let externalFocusValue: String
    var retainFocusAppearance = false
    let onFocus: () -> Void
    let action: () -> Void

    @FocusState private var isFocused: Bool
    @AppStorage(SettingsKey.smoothFocus) private var smoothFocus = true
    @AppStorage(SettingsKey.focusHighlighter) private var focusHighlighter = false
    @AppStorage(SettingsKey.cardCornerRadius) private var cardCornerRadiusSetting = AppCardStyle.defaultCornerRadiusRaw

    private var showsFocusedAppearance: Bool { isFocused || retainFocusAppearance }

    private var cardCornerRadius: CGFloat {
        AppCardStyle.cornerRadius(for: cardCornerRadiusSetting, fallback: 16)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 18) {
                Image(systemName: "rectangle.grid.3x2.fill")
                    .font(.system(size: 48, weight: .medium))
                Text(L10n.string("action_see_all", fallback: "See All"))
                    .font(.system(size: 24, weight: .bold))
                Text(title)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(.white.opacity(0.58))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
            }
            .foregroundColor(.white)
            .frame(width: TVHomeGridLayout.posterWidth, height: TVHomeGridLayout.posterHeight)
            .modifier(LiquidGlassSurface(cornerRadius: cardCornerRadius, prominent: showsFocusedAppearance))
            .overlay(
                shape.stroke(
                    showsFocusedAppearance ? AppFocusOutline.color : .clear,
                    lineWidth: focusHighlighter ? AppFocusOutline.emphasizedWidth : AppFocusOutline.width
                )
            )
            .shadow(
                color: .black.opacity(showsFocusedAppearance ? 0.5 : 0.2),
                radius: showsFocusedAppearance ? 16 : 6
            )
            .scaleEffect(showsFocusedAppearance ? 1.06 : 1)
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($isFocused)
        .modifier(ExternalFocusBinding(binding: externalFocus, id: externalFocusValue))
        .focusEffectDisabledIfAvailable()
        .onChange(of: isFocused) { _, focused in
            if focused { onFocus() }
        }
        .animation(smoothFocus ? .spring(response: 0.28, dampingFraction: 0.75) : nil, value: showsFocusedAppearance)
    }
}

struct TVHomeCatalogBrowseView: View {
    let section: TVHomeSection
    let repository: CatalogRepository
    let watchedTitleKeys: Set<String>
    let onDismiss: () -> Void
    let onSelect: (NuvioMeta) -> Void
    var onLongPress: ((NuvioMeta) -> Void)? = nil

    @State private var items: [NuvioMeta]
    @State private var pendingItems: [NuvioMeta]
    @State private var nextSkip: Int
    @State private var hasMore: Bool
    @State private var isLoadingMore = false
    @FocusState private var focusedItemID: String?
    @AppStorage(SettingsKey.amoled) private var amoled = false
    @AppStorage(SettingsKey.bodyColor) private var bodyColor = SettingsBackground.charcoal.rawValue
    @AppStorage(SettingsKey.posterLabels) private var posterLabels = false
    @AppStorage(SettingsKey.smoothFocus) private var smoothFocus = true
    @AppStorage(SettingsKey.focusHighlighter) private var focusHighlighter = false

    init(
        section: TVHomeSection,
        repository: CatalogRepository,
        watchedTitleKeys: Set<String>,
        onDismiss: @escaping () -> Void,
        onSelect: @escaping (NuvioMeta) -> Void,
        onLongPress: ((NuvioMeta) -> Void)?
    ) {
        self.section = section
        self.repository = repository
        self.watchedTitleKeys = watchedTitleKeys
        self.onDismiss = onDismiss
        self.onSelect = onSelect
        self.onLongPress = onLongPress
        _items = State(initialValue: section.items)
        _pendingItems = State(initialValue: section.pendingItems)
        _nextSkip = State(initialValue: section.nextSkip ?? section.items.count)
        _hasMore = State(initialValue: section.hasMore || !section.pendingItems.isEmpty)
    }

    var body: some View {
        ZStack {
            Color.nuvioBackground(amoled: amoled, body: bodyColor).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(section.title)
                        .font(.system(size: 42, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text("1 catalog")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(.white.opacity(0.55))
                }
                .padding(.horizontal, 60)
                .padding(.top, 48)

                ScrollView(.vertical) {
                    LazyVGrid(
                        columns: [GridItem(
                            .adaptive(
                                minimum: CollectionFolderGridMetrics.posterWidth,
                                maximum: CollectionFolderGridMetrics.posterWidth
                            ),
                            spacing: CollectionFolderGridMetrics.posterGap,
                            alignment: .top
                        )],
                        alignment: .leading,
                        spacing: CollectionFolderGridMetrics.posterGap
                    ) {
                        ForEach(items) { item in
                            CollectionFolderResultCard(
                                meta: item,
                                externalFocus: $focusedItemID
                            ) {
                                onSelect(item)
                            }
                            .onAppear {
                                loadMoreIfNeeded(currentItem: item)
                            }
                        }

                        if isLoadingMore {
                            ProgressView()
                                .tint(.white)
                                .scaleEffect(1.25)
                                .frame(
                                    width: CollectionFolderGridMetrics.posterWidth,
                                    height: CollectionFolderGridMetrics.posterHeight
                                )
                        }
                    }
                    .padding(.top, 16)
                    .padding(.horizontal, 60)

                    Color.clear.frame(height: 60)
                }
                .scrollIndicators(.hidden)
                .focusSection()
                .defaultFocusIfAvailable($focusedItemID, items.first?.id)
            }
        }
        .onExitCommand(perform: onDismiss)
    }

    @MainActor
    private func loadMoreIfNeeded(currentItem: NuvioMeta) {
        guard hasMore,
              !isLoadingMore,
              let index = items.firstIndex(where: { $0.id == currentItem.id }),
              index >= max(items.count - TVHomeRowPrefetchThreshold, 0) else { return }

        if !pendingItems.isEmpty {
            let batchCount = min(50, pendingItems.count)
            let batch = Array(pendingItems.prefix(batchCount))
            pendingItems.removeFirst(batchCount)
            let currentIDs = Set(items.map(\.id))
            items.append(contentsOf: batch.filter { !currentIDs.contains($0.id) })
            hasMore = !pendingItems.isEmpty || (section.contentType != nil && section.catalogId != nil)
            isLoadingMore = true
            Task { @MainActor in
                defer { isLoadingMore = false }
                let enrichedBatch = await TmdbDetailsService.localizedMetadata(for: batch)
                let enrichedById = Dictionary(uniqueKeysWithValues: enrichedBatch.map { ($0.id, $0) })
                items = items.map { enrichedById[$0.id] ?? $0 }
            }
            return
        }

        guard let contentType = section.contentType,
              let catalogId = section.catalogId else {
            hasMore = false
            return
        }

        isLoadingMore = true
        let requestedSkip = nextSkip
        Task { @MainActor in
            defer { isLoadingMore = false }
            do {
                let page = try await repository.browseCatalog(
                    addonId: section.addonId,
                    contentType: contentType,
                    catalogId: catalogId,
                    skip: requestedSkip,
                    genre: section.catalogGenre
                )
                let existingIDs = Set(items.map(\.id))
                let newItems = page.items.filter { !existingIDs.contains($0.id) }
                items.append(contentsOf: newItems)
                nextSkip = page.nextSkip ?? (requestedSkip + page.items.count)
                hasMore = page.hasMore && !newItems.isEmpty
            } catch {
                hasMore = false
            }
        }
    }
}

enum TVCollectionFolderCardLayout {
    static func cardHeight(layoutMode: String) -> CGFloat {
        layoutMode == "Compact" ? 255 : 315
    }

    static func cardWidth(shape: CollectionTileShape, layoutMode: String) -> CGFloat {
        let height = cardHeight(layoutMode: layoutMode)
        switch shape {
        case .poster:
            return layoutMode == "Compact" ? 170 : 210
        case .landscape:
            return layoutMode == "Compact" ? (height * CGFloat(shape.aspectRatio)).rounded() : 560
        case .square:
            return (height * CGFloat(shape.aspectRatio)).rounded()
        }
    }

    static func rowSpacing(layoutMode: String) -> CGFloat {
        layoutMode == "Compact" ? 22 : 28
    }

    static func scrollOffset(
        to index: Int,
        folders: [TVCollectionFolderItem],
        layoutMode: String
    ) -> CGFloat {
        guard index > 0 else { return 0 }
        let spacing = rowSpacing(layoutMode: layoutMode)
        var offset: CGFloat = 0
        let end = min(index, folders.count)
        for i in 0..<end {
            offset += cardWidth(shape: folders[i].tileShape, layoutMode: layoutMode) + spacing
        }
        return offset
    }
}

struct TVCollectionFolderRow: View {
    let id: String
    let title: String
    let horizontalEdgeInset: CGFloat
    let folders: [TVCollectionFolderItem]
    let initialScrollIndex: Int
    let onScrollIndexChange: (Int) -> Void
    let initialFocusCardKey: String?
    var externalFocus: FocusState<String?>.Binding? = nil
    var restrictFocusToCardKey: String? = nil
    var retainFocusAppearanceForCardKey: String? = nil
    var suppressFocusAnimations = false
    var isRowFocused = false
    let onInitialFocusRequested: () -> Void
    let onFocus: (TVCollectionFolderItem) -> Void
    let onSelect: (TVCollectionFolderItem) -> Void

    @State private var scrollIndex: Int?
    @AppStorage(SettingsKey.homeLayout) private var homeLayout = "Modern"
    @AppStorage(SettingsKey.posterLabels) private var posterLabels = false
    @AppStorage(SettingsKey.smoothFocus) private var smoothFocus = true
    @AppStorage(SettingsKey.focusHighlighter) private var focusHighlighter = false

    private var effectiveScrollIndex: Int {
        let raw = scrollIndex ?? initialScrollIndex
        guard !folders.isEmpty else { return 0 }
        return min(max(raw, 0), folders.count - 1)
    }

    private var rowSpacing: CGFloat {
        TVCollectionFolderCardLayout.rowSpacing(layoutMode: homeLayout)
    }

    private var imageHeight: CGFloat {
        TVCollectionFolderCardLayout.cardHeight(layoutMode: homeLayout)
    }

    private var stripHeight: CGFloat {
        imageHeight + (showsAnyLabels ? 48 : 0) + TVHomeLayout.stripVerticalPadding * 2
    }

    private var showsAnyLabels: Bool {
        posterLabels && folders.contains { !$0.hideTitle }
    }

    private func materializedCardIndices(
        stripWidth: CGFloat,
        layoutMode: String
    ) -> [Int] {
        guard !folders.isEmpty else { return [] }

        let focusIndex = effectiveScrollIndex
        var lowerBound = max(0, focusIndex - 4)
        var upperBound = focusIndex
        let spacing = TVCollectionFolderCardLayout.rowSpacing(layoutMode: layoutMode)
        var coveredWidth: CGFloat = 0

        for index in focusIndex..<folders.count {
            coveredWidth += TVCollectionFolderCardLayout.cardWidth(
                shape: folders[index].tileShape,
                layoutMode: layoutMode
            ) + spacing
            upperBound = index
            if coveredWidth >= stripWidth { break }
        }

        let rowPrefix = "\(id)\u{1}"
        for key in [initialFocusCardKey, restrictFocusToCardKey] {
            guard let key, key.hasPrefix(rowPrefix) else { continue }
            let folderID = String(key.dropFirst(rowPrefix.count))
            if let targetIndex = folders.firstIndex(where: { $0.id == folderID }) {
                lowerBound = min(lowerBound, targetIndex)
                upperBound = max(upperBound, targetIndex)
            }
        }

        return Array(lowerBound...upperBound)
    }

    private var defaultFocusFolderKey: String? {
        guard !folders.isEmpty else { return nil }
        let idx = effectiveScrollIndex
        return "\(id)\u{1}\(folders[idx].id)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.custom("Inter-Bold", size: 30))
                .foregroundColor(.white)
                .padding(.leading, TVLayout.rowLeading)
                .offset(y: 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .zIndex(2)

            cardStrip
                .zIndex(0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
        .defaultFocusIfAvailable(externalFocus, defaultFocusFolderKey)
    }

    private var cardStrip: some View {
        GeometryReader { geo in
            let stripWidth = max(1920, geo.size.width + horizontalEdgeInset * 2)
            let rowHomeLayout = homeLayout
            let rowPosterLabels = posterLabels
            let rowSmoothFocus = smoothFocus
            let rowFocusHighlighter = focusHighlighter
            let rowSpacing = TVCollectionFolderCardLayout.rowSpacing(layoutMode: rowHomeLayout)
            let scrollX = TVCollectionFolderCardLayout.scrollOffset(
                to: effectiveScrollIndex,
                folders: folders,
                layoutMode: rowHomeLayout
            )
            let materializedIndices = materializedCardIndices(
                stripWidth: stripWidth,
                layoutMode: rowHomeLayout
            )

            HStack(alignment: .top, spacing: rowSpacing) {
                ForEach(materializedIndices, id: \.self) { index in
                    let folder = folders[index]
                    let cardKey = "\(id)\u{1}\(folder.id)"
                    let shouldRequestInitialFocus = cardKey == initialFocusCardKey
                    TVCollectionFolderCard(
                        folder: folder,
                        shouldRequestInitialFocus: shouldRequestInitialFocus,
                        onInitialFocusRequested: shouldRequestInitialFocus ? onInitialFocusRequested : nil,
                        externalFocus: externalFocus,
                        externalFocusValue: cardKey,
                        onFocus: {
                            if effectiveScrollIndex != index {
                                scrollIndex = index
                                onScrollIndexChange(index)
                            }
                            onFocus(folder)
                        },
                        layoutMode: rowHomeLayout,
                        showPosterLabels: rowPosterLabels,
                        smoothFocusAnimations: rowSmoothFocus,
                        focusHighlighterEnabled: rowFocusHighlighter,
                        retainFocusAppearance: retainFocusAppearanceForCardKey == cardKey,
                        allowsFocus: true,
                        onSelect: { onSelect(folder) }
                    )
                    .disabled(
                        (restrictFocusToCardKey != nil && restrictFocusToCardKey != cardKey)
                            || (!isRowFocused && index != effectiveScrollIndex)
                    )
                }
            }
            .padding(
                .leading,
                TVCollectionFolderCardLayout.scrollOffset(
                    to: materializedIndices.first ?? 0,
                    folders: folders,
                    layoutMode: rowHomeLayout
                )
            )
            .padding(.vertical, TVHomeLayout.stripVerticalPadding)
            .offset(x: horizontalEdgeInset + TVLayout.rowLeading - scrollX)
            .frame(
                width: stripWidth,
                height: stripHeight,
                alignment: .topLeading
            )
            .clipped()
            .offset(x: -horizontalEdgeInset)
            .animation(
                rowSmoothFocus && !suppressFocusAnimations ? TVHomeLayout.scrollAnimation : nil,
                value: effectiveScrollIndex
            )
        }
        .frame(height: stripHeight)
    }
}

extension TVCollectionFolderRow: Equatable {
    static func == (lhs: TVCollectionFolderRow, rhs: TVCollectionFolderRow) -> Bool {
        let lhsRestrictInRow = lhs.restrictFocusToCardKey?.hasPrefix("\(lhs.id)\u{1}") == true
        let rhsRestrictInRow = rhs.restrictFocusToCardKey?.hasPrefix("\(rhs.id)\u{1}") == true
        let restrictEqual = (lhsRestrictInRow == rhsRestrictInRow)
            && (!lhsRestrictInRow || lhs.restrictFocusToCardKey == rhs.restrictFocusToCardKey)

        let lhsRetainInRow = lhs.retainFocusAppearanceForCardKey?.hasPrefix("\(lhs.id)\u{1}") == true
        let rhsRetainInRow = rhs.retainFocusAppearanceForCardKey?.hasPrefix("\(rhs.id)\u{1}") == true
        let retainEqual = (lhsRetainInRow == rhsRetainInRow)
            && (!lhsRetainInRow || lhs.retainFocusAppearanceForCardKey == rhs.retainFocusAppearanceForCardKey)

        return lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.horizontalEdgeInset == rhs.horizontalEdgeInset
            && lhs.folders == rhs.folders
            && lhs.initialScrollIndex == rhs.initialScrollIndex
            && lhs.initialFocusCardKey == rhs.initialFocusCardKey
            && restrictEqual
            && retainEqual
            && lhs.suppressFocusAnimations == rhs.suppressFocusAnimations
            && lhs.isRowFocused == rhs.isRowFocused
    }
}

struct TVCollectionFolderCard: View {
    let folder: TVCollectionFolderItem
    var shouldRequestInitialFocus: Bool = false
    var onInitialFocusRequested: (() -> Void)? = nil
    var externalFocus: FocusState<String?>.Binding? = nil
    var externalFocusValue: String? = nil
    var onFocus: (() -> Void)? = nil
    var layoutMode: String = "Modern"
    var showPosterLabels: Bool = false
    var smoothFocusAnimations: Bool = true
    var focusHighlighterEnabled: Bool = false
    var retainFocusAppearance: Bool = false
    var allowsFocus = true
    let onSelect: () -> Void

    @FocusState private var isFocused: Bool
    @State private var didRequestInitialFocus = false
    @AppStorage(SettingsKey.cardCornerRadius) private var cardCornerRadiusSetting = AppCardStyle.defaultCornerRadiusRaw

    private var showFocus: Bool { isFocused || retainFocusAppearance }

    private var cardWidth: CGFloat {
        TVCollectionFolderCardLayout.cardWidth(shape: folder.tileShape, layoutMode: layoutMode)
    }

    private var cardHeight: CGFloat {
        TVCollectionFolderCardLayout.cardHeight(layoutMode: layoutMode)
    }

    private var layoutWidth: CGFloat { cardWidth }

    private var totalCardHeight: CGFloat {
        cardHeight + (showPosterLabels && !folder.hideTitle ? 48 : 0)
    }

    private var displayTitle: String {
        let t = folder.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "Folder" : t
    }

    private var subtitle: String {
        let count = folder.sources.count
        return count == 1 ? "1 catalog" : "\(count) catalogs"
    }

    private var cardCornerRadius: CGFloat {
        AppCardStyle.cornerRadius(for: cardCornerRadiusSetting, fallback: 16)
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
    }

    private var coverImageURL: URL? {
        guard let raw = folder.coverImageUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    private var usesEmojiCover: Bool {
        coverImageURL == nil && folder.coverEmoji != nil
    }

    private var usesLogoCoverPresentation: Bool {
        let style = folder.presentationStyle?.uppercased()
        return style == "STREAMING_SERVICE"
            || style == "STUDIO_FRANCHISE"
            || style == "BRAND_COLLECTION"
    }

    private var emojiText: String? {
        let t = folder.coverEmoji?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return t.isEmpty ? nil : t
    }

    private var emojiFontSize: CGFloat {
        min(cardWidth, cardHeight) * 0.28
    }

    private var focusedBorderColor: Color {
        guard showFocus else { return .clear }
        return AppFocusOutline.color
    }

    private var focusedBorderWidth: CGFloat {
        showFocus ? (focusHighlighterEnabled ? AppFocusOutline.emphasizedWidth : AppFocusOutline.width) : 0
    }

    private var shadowOpacity: Double { showFocus ? 0.5 : 0.2 }
    private var shadowRadius: CGFloat { showFocus ? 16 : 6 }

    private var focusGifURLString: String? {
        folder.activeFocusGifURLString
    }

    var body: some View {
        Button(action: onSelect) {
            cardContent
        }
        .buttonStyle(PosterCardButtonStyle())
        .disabled(!allowsFocus)
        .focused($isFocused)
        .modifier(ExternalFocusBinding(binding: externalFocus, id: externalFocusValue ?? folder.id))
        .focusEffectDisabledIfAvailable()
        .onChange(of: isFocused) { _, focused in
            if focused { onFocus?() }
        }
        .onAppear {
            guard shouldRequestInitialFocus, !didRequestInitialFocus else { return }
            didRequestInitialFocus = true
            onInitialFocusRequested?()
            DispatchQueue.main.async {
                isFocused = true
            }
        }
        .frame(width: cardWidth, height: totalCardHeight, alignment: .topLeading)
        .zIndex(showFocus ? 1 : 0)
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            artTile

            if showPosterLabels && !folder.hideTitle {
                VStack(alignment: .leading, spacing: 3) {
                    Text(displayTitle)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.white.opacity(0.86))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.white.opacity(0.45))
                        .lineLimit(1)
                }
                .frame(width: cardWidth, alignment: .leading)
                .animation(nil, value: showFocus)
            }
        }
        .frame(width: layoutWidth, height: totalCardHeight, alignment: .topLeading)
    }

    @ViewBuilder
    private var artTile: some View {
        if let url = coverImageURL {
            imageCover(url: url)
        } else if usesEmojiCover {
            emojiGlassCover
        } else {
            emptyCover
        }
    }

    @ViewBuilder
    private var focusGifOverlay: some View {
        if let gifURL = focusGifURLString {
            AnimatedRemoteGIFView(urlString: gifURL, isActive: showFocus)
                .frame(width: cardWidth, height: cardHeight)
                .clipped()
                .opacity(1)
                .allowsHitTesting(false)
        }
    }

    private func imageCover(url: URL) -> some View {
        ZStack {
            if usesLogoCoverPresentation {
                Color.clear
                    .frame(width: cardWidth, height: cardHeight)
                    .modifier(
                        LiquidGlassSurface(
                            cornerRadius: cardCornerRadius,
                            prominent: showFocus
                        )
                    )
            }
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    if usesLogoCoverPresentation {
                        image
                            .resizable()
                            .scaledToFit()
                            .padding(.horizontal, cardWidth * 0.10)
                            .padding(.vertical, cardHeight * 0.10)
                    } else {
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    }
                default:
                    emptyCoverFill
                }
            }
            focusGifOverlay
        }
        .frame(width: cardWidth, height: cardHeight)
        .clipped()
        .clipShape(cardShape)
        .overlay(cardShape.stroke(focusedBorderColor, lineWidth: focusedBorderWidth))
        .shadow(color: .black.opacity(shadowOpacity), radius: shadowRadius)
    }

    private var emojiGlassCover: some View {
        ZStack {
            ZStack {
                coverGlyph
            }
            .frame(width: cardWidth, height: cardHeight)
            .modifier(LiquidGlassSurface(cornerRadius: cardCornerRadius, prominent: showFocus))

            focusGifOverlay
                .clipShape(cardShape)
        }
        .frame(width: cardWidth, height: cardHeight)
        .overlay(cardShape.stroke(focusedBorderColor, lineWidth: focusedBorderWidth))
        .shadow(color: .black.opacity(shadowOpacity), radius: shadowRadius)
    }

    private var emptyCover: some View {
        ZStack {
            emptyCoverFill
            coverGlyph
            focusGifOverlay
        }
        .frame(width: cardWidth, height: cardHeight)
        .clipShape(cardShape)
        .overlay(cardShape.stroke(focusedBorderColor, lineWidth: focusedBorderWidth))
        .shadow(color: .black.opacity(shadowOpacity), radius: shadowRadius)
    }

    private var emptyCoverFill: some View {
        Rectangle()
            .fill(Color.white.opacity(0.07))
    }

    @ViewBuilder
    private var coverGlyph: some View {
        if let emojiText {
            Text(emojiText)
                .font(.system(size: emojiFontSize))
        } else {
            Image(systemName: "folder")
                .font(.system(size: 40))
                .foregroundColor(.white.opacity(0.25))
        }
    }
}
