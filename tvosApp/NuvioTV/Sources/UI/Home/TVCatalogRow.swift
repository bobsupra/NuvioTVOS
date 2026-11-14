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
    static let rowTitleBlock: CGFloat = 56

    /// Horizontal strip motion preserving momentum across continuous remote presses.
    static let scrollAnimation = Animation.interactiveSpring(response: 0.24, dampingFraction: 0.86, blendDuration: 0.18)
    /// Fluid vertical row transition preserving momentum with critically damped bounce-free settle.
    static let verticalScrollAnimation = Animation.interactiveSpring(response: 0.28, dampingFraction: 1.0, blendDuration: 0.20)
    /// High-speed vertical tracking curve when holding remote direction buttons to match key-repeat cadence.
    static let fastVerticalScrollAnimation = Animation.interactiveSpring(response: 0.18, dampingFraction: 1.0, blendDuration: 0.12)
}

enum TVLayout {
    static let contentLeading: CGFloat = 150
    static let rowLeading: CGFloat = 48
}

/// Materialized cards retain their array position for layout math while
/// exposing a content-derived SwiftUI identity. This prevents a card view from
/// being reused for another title when a catalog inserts or reorders items.
struct TVCatalogMaterializedCard: Identifiable {
    let id: String
    let index: Int
    let item: NuvioMeta
}

private struct TVFolderMaterializedCard: Identifiable {
    let id: String
    let index: Int
    let folder: TVCollectionFolderItem
}

/// A title is unique within a source row by its provider type and id. Provider
/// duplicates represent the same selectable title and are collapsed before
/// layout. Different types and different source rows remain distinct.
enum TVHomeCardIdentity {
    static func titleID(_ item: NuvioMeta) -> String {
        let type = item.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "title:\(type.utf8.count):\(type)\(item.id)"
    }

    static func key(rowID: String, item: NuvioMeta) -> String {
        "\(rowID)\u{1}\(titleID(item))"
    }

    static func folderKey(rowID: String, folder: TVCollectionFolderItem) -> String {
        "\(rowID)\u{1}folder:\(folder.id)"
    }

    static func placeholderKey(rowID: String, index: Int) -> String {
        "\(rowID)\u{1}placeholder:\(index)"
    }

    static func uniqueTitles(_ items: [NuvioMeta]) -> [NuvioMeta] {
        var seen = Set<String>()
        return items.filter { seen.insert(titleID($0)).inserted }
    }

    static func uniqueFolders(_ folders: [TVCollectionFolderItem]) -> [TVCollectionFolderItem] {
        var seen = Set<String>()
        return folders.filter { seen.insert($0.id).inserted }
    }

    static func materializedTitles(rowID: String, items: [NuvioMeta], indices: [Int]) -> [TVCatalogMaterializedCard] {
        indices.filter { items.indices.contains($0) }.map {
            TVCatalogMaterializedCard(id: key(rowID: rowID, item: items[$0]), index: $0, item: items[$0])
        }
    }
}

extension NuvioMeta {
    var homeTitleIdentity: String { TVHomeCardIdentity.titleID(self) }
}

struct TVHomeFocusRow: Equatable {
    let id: String
    let keys: [String]
}

enum TVHomeFocusRestoration {
    static func target(saved: String, rows: [TVHomeFocusRow], preferredIndex: Int) -> String? {
        if rows.contains(where: { $0.keys.contains(saved) }) { return saved }
        // Match the complete row prefix instead of splitting IDs that may
        // themselves contain separators. Longest match handles nested prefixes.
        if let row = rows.filter({ saved.hasPrefix("\($0.id)\u{1}") })
            .max(by: { $0.id.count < $1.id.count }), !row.keys.isEmpty {
            return row.keys[min(max(preferredIndex, 0), row.keys.count - 1)]
        }
        return rows.lazy.compactMap { $0.keys.first }.first
    }
}

/// Which card may conclude an overlay return. While the one-card lock is
/// held, only the restored card is an eligible focus target, so a neighbouring
/// card that wins native focus during the return transition must never be
/// accepted as the restored card.
enum TVHomeOverlayFocusRestore {
    static func isTarget(
        _ cardKey: String,
        restoringCardID: String?,
        lockedCardID: String?
    ) -> Bool {
        restoringCardID == cardKey || lockedCardID == cardKey
    }

    static func canComplete(
        _ cardKey: String,
        restoringCardID: String?,
        lockedCardID: String?,
        acknowledgedNativeCardID: String? = nil
    ) -> Bool {
        restoringCardID == cardKey
            && acknowledgedNativeCardID == cardKey
            && isTarget(cardKey, restoringCardID: restoringCardID, lockedCardID: lockedCardID)
    }
}

enum TVHomeBackAction: Equatable {
    case returnToRowBeginning(sectionID: String, cardKey: String)
    case moveToContinueWatchingOrTop(sectionID: String, cardKey: String)
    case focusGridHero
    case exitToSidebar
}

enum TVHomeBackNavigation {
    static func determineAction(
        focusedCardID: String?,
        currentSectionID: String?,
        currentRowFirstCardKey: String?,
        currentRowScrollIndex: Int,
        isGridHeroFocused: Bool,
        hasGridHero: Bool,
        continueWatchingOrTopSectionID: String?,
        continueWatchingOrTopTargetCardKey: String?
    ) -> TVHomeBackAction {
        if hasGridHero && isGridHeroFocused {
            return .exitToSidebar
        }

        // Determine if focus is at the beginning (index 0) of the currently active row
        let isAtBeginningOfCurrentRow: Bool
        if let focusedCardID, let currentRowFirstCardKey {
            isAtBeginningOfCurrentRow = (focusedCardID == currentRowFirstCardKey)
        } else if isGridHeroFocused {
            isAtBeginningOfCurrentRow = true
        } else {
            isAtBeginningOfCurrentRow = (currentRowScrollIndex == 0)
        }

        // Step 1: If not at the beginning of the current row, return to the first item of this row
        if !isAtBeginningOfCurrentRow,
           let currentSectionID,
           let currentRowFirstCardKey {
            return .returnToRowBeginning(sectionID: currentSectionID, cardKey: currentRowFirstCardKey)
        }

        // Step 2: User is already at the beginning of the current row.
        guard let topSectionID = continueWatchingOrTopSectionID,
              let topTargetCardKey = continueWatchingOrTopTargetCardKey else {
            if hasGridHero {
                return .focusGridHero
            }
            return .exitToSidebar
        }

        // If the current row is already Continue Watching / Top AND we are at the beginning:
        if currentSectionID == topSectionID {
            if hasGridHero {
                return .focusGridHero
            }
            return .exitToSidebar
        }

        return .moveToContinueWatchingOrTop(sectionID: topSectionID, cardKey: topTargetCardKey)
    }
}

/// Grid metrics matching Search / Library poster cards (Tabs view mode).
enum CollectionFolderGridMetrics {
    static let posterWidth: CGFloat = 210
    static let posterHeight: CGFloat = 315
    static let posterGap: CGFloat = 28
}

/// Whether a row is being built a few cards at a time (`TVCatalogRow.stagesCardBuild`), decided
/// by its first build. Not observed: the row redraws as its count of built cards changes.
final class TVRowCardStaging {
    var isDecided = false
    var isActive = false
}

/// Home asking a row (which holds its cards' focus, `TVCatalogRow.ownsCardFocus`) to put focus
/// on one of its cards. A new request (another generation) is applied by the row it is for at
/// once; one that a row only now coming on screen finds is applied if it is under a second old,
/// so a row built later never takes focus for a request that has long been dealt with.
struct TVHomeRowFocusRequest: Equatable {
    var cardKey: String?
    var generation = 0
    var issuedAt = ProcessInfo.processInfo.systemUptime

    var isFresh: Bool { ProcessInfo.processInfo.systemUptime - issuedAt < 1 }

    /// The request as row `rowID` sees it: nil unless it is for one of its cards.
    func forRow(_ rowID: String) -> TVHomeRowFocusRequest? {
        guard let cardKey, cardKey.hasPrefix("\(rowID)\u{1}") else { return nil }
        return self
    }
}

/// A row whose catalog is still in flight: its real title over a lightweight
/// skeleton strip, sized exactly like `TVCatalogRow` so the row keeps its height
/// and the rows below it do not jump when the real cards arrive.
struct TVLoadingCatalogRow: View {
    let id: String
    let title: String
    var tileShape: CollectionTileShape = .poster
    var requestsFocus: Bool = false
    var addonName: String? = nil
    var showAddonName: Bool = true
    var horizontalEdgeInset: CGFloat = 0
    var initialScrollIndex: Int = 0
    var onScrollIndexChange: ((Int) -> Void)? = nil
    var externalFocus: FocusState<String?>.Binding? = nil
    var onFocus: ((Int) -> Void)? = nil
    var onMove: ((MoveCommandDirection) -> Void)? = nil

    @FocusState private var focusedPlaceholderIndex: Int?
    @State private var scrollIndex: Int = 0
    @AppStorage(SettingsKey.homeLayout) private var homeLayout = "Modern"
    @AppStorage(SettingsKey.posterLabels) private var posterLabels = false
    @AppStorage(SettingsKey.liquidGlassCards) private var liquidGlassCards = true
    @AppStorage(SettingsKey.theme) private var theme = SettingsAccent.white.rawValue
    @AppStorage(SettingsKey.smoothFocus) private var smoothFocus = true
    @AppStorage(SettingsKey.fastNavigation) private var fastNavigation = false

    init(
        id: String = "",
        title: String,
        tileShape: CollectionTileShape = .poster,
        requestsFocus: Bool = false,
        addonName: String? = nil,
        showAddonName: Bool = true,
        horizontalEdgeInset: CGFloat = 0,
        initialScrollIndex: Int = 0,
        onScrollIndexChange: ((Int) -> Void)? = nil,
        externalFocus: FocusState<String?>.Binding? = nil,
        onFocus: ((Int) -> Void)? = nil,
        onMove: ((MoveCommandDirection) -> Void)? = nil
    ) {
        self.id = id
        self.title = title
        self.tileShape = tileShape
        self.requestsFocus = requestsFocus
        self.addonName = addonName
        self.showAddonName = showAddonName
        self.horizontalEdgeInset = horizontalEdgeInset
        self.initialScrollIndex = initialScrollIndex
        self.onScrollIndexChange = onScrollIndexChange
        self.externalFocus = externalFocus
        self.onFocus = onFocus
        self.onMove = onMove
        _scrollIndex = State(initialValue: initialScrollIndex)
    }

    private var cardWidth: CGFloat {
        TVCollectionFolderCardLayout.cardWidth(shape: tileShape, layoutMode: homeLayout)
    }
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
                    .font(.appFont(size: 30, weight: .bold))
                    .foregroundColor(.white)

                if showAddonName, let addonName = addonName, !addonName.isEmpty {
                    Text(addonName)
                        .font(.appFont(size: 16, weight: .semibold))
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

            let stripWidth = max(1920, UIScreen.main.bounds.width + horizontalEdgeInset * 2)
            let step = cardWidth + cardSpacing
            let visibleCardCount = max(12, Int(ceil(stripWidth / step)) + 4)

            HStack(alignment: .top, spacing: cardSpacing) {
                // Keep real focus targets in the row while its catalog is
                // in flight. A plain skeleton has geometry but is absent
                // from tvOS's focus graph, so moving down from the row
                // above is rejected or snaps focus back to the top.
                ForEach(0..<visibleCardCount, id: \.self) { index in
                    let placeholderKey = TVHomeCardIdentity.placeholderKey(rowID: id, index: index)
                    Button(action: {}) {
                        LoadingPosterCard(
                            width: cardWidth,
                            height: cardHeight,
                            isFocused: focusedPlaceholderIndex == index,
                            isLiquidGlassEnabled: liquidGlassCards
                        )
                    }
                    .buttonStyle(PosterCardButtonStyle())
                    .focusable(true)
                    .focused($focusedPlaceholderIndex, equals: index)
                    .modifier(ExternalFocusBinding(binding: externalFocus, id: placeholderKey))
                    .accessibilityLabel("\(title), loading")
                    .modifier(OptionalMoveCommandHandler(handler: onMove))
                }
            }
            .padding(.vertical, TVHomeLayout.stripVerticalPadding)
            .offset(
                x: horizontalEdgeInset + TVLayout.rowLeading
                    - CGFloat(scrollIndex) * step
            )
            .frame(
                width: stripWidth,
                height: stripHeight,
                alignment: .topLeading
            )
            .clipped()
            .offset(x: -horizontalEdgeInset)
            .onChange(of: focusedPlaceholderIndex) { _, newIndex in
                guard let newIndex else { return }
                if smoothFocus && !fastNavigation {
                    withAnimation(TVHomeLayout.scrollAnimation) {
                        scrollIndex = newIndex
                    }
                } else {
                    var transaction = Transaction()
                    transaction.animation = nil
                    withTransaction(transaction) {
                        scrollIndex = newIndex
                    }
                }
                onScrollIndexChange?(newIndex)
                onFocus?(newIndex)
            }
            .onChange(of: requestsFocus, initial: true) { _, requested in
                guard requested else { return }
                focusedPlaceholderIndex = min(max(scrollIndex, 0), visibleCardCount - 1)
            }
            .frame(height: stripHeight)
            .zIndex(0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
        .defaultFocusIfAvailable($focusedPlaceholderIndex, scrollIndex)
        .defaultFocusIfAvailable(externalFocus, TVHomeCardIdentity.placeholderKey(rowID: id, index: scrollIndex))
        .modifier(OptionalMoveCommandHandler(handler: onMove))
    }
}

extension TVLoadingCatalogRow: Equatable {
    static func == (lhs: TVLoadingCatalogRow, rhs: TVLoadingCatalogRow) -> Bool {
        lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.tileShape == rhs.tileShape
            && lhs.requestsFocus == rhs.requestsFocus
            && lhs.addonName == rhs.addonName
            && lhs.showAddonName == rhs.showAddonName
            && lhs.horizontalEdgeInset == rhs.horizontalEdgeInset
            && lhs.initialScrollIndex == rhs.initialScrollIndex
    }
}

struct TVCatalogRow: View {
    let id: String
    var customPosterScreen: CustomPosterScreen = .home
    let title: String
    var addonName: String? = nil
    var showAddonName: Bool = true
    var showsSectionTitle: Bool = true
    let horizontalEdgeInset: CGFloat
    let items: [NuvioMeta]
    var progressByItemId: [String: ContinueWatchingItem] = [:]
    /// The Today row's episode, time and picture per card, shown
    /// like Up Next cards.
    var calendarLabelsByItemId: [String: CalendarHomeToday.CardLabel] = [:]
    /// Supplied only by the main Home's Continue Watching row.
    var collectionOriginsByItemId: [String: CollectionOriginPresentation] = [:]
    var watchedTitleKeys: Set<String> = []
    var initialScrollIndex: Int = 0
    var onScrollIndexChange: (Int) -> Void = { _ in }
    let initialFocusCardKey: String?
    let landscapeFocusedId: String?
    var explicitTileShape: CollectionTileShape? = nil
    var externalFocus: FocusState<String?>.Binding? = nil
    /// The row holds its cards' focus itself (`externalFocus` is nil), and puts it where Home
    /// asks (`focusRequest`): a move from card to card redraws only this row, not all of Home.
    var ownsCardFocus = false
    var focusRequest: TVHomeRowFocusRequest? = nil
    /// The row, as it is first built, gets its cards a few at a time, from where it is scrolled,
    /// instead of all in one frame: a row Home builds ahead, off screen (as focus settles, the
    /// row three away came in one go, the 60-160 ms frame half a second after a move down), and
    /// any row but the focused one in a fast run of moves (rows came faster than one frame could
    /// build them, a 340 ms stall). Read as the row first appears; it then finishes at its pace,
    /// or at once when focus comes into it.
    var stagesCardBuild = false
    var restrictFocusToCardKey: String? = nil
    var retainFocusAppearanceForCardKey: String? = nil
    var suppressFocusAnimations: Bool = false
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
    var onRefreshCatalog: (() -> Void)? = nil
    var onMove: ((MoveCommandDirection) -> Void)? = nil

    @State private var scrollIndex: Int?
    @FocusState private var ownCardFocus: String?
    @State private var stagedCardCount = 0
    @State private var cardStaging = TVRowCardStaging()
    @AppStorage(SettingsKey.homeLayout) private var homeLayout = "Modern"
    @AppStorage(SettingsKey.posterLabels) private var posterLabels = false
    @AppStorage(SettingsKey.theme) private var theme = SettingsAccent.white.rawValue
    @AppStorage(SettingsKey.smoothFocus) private var smoothFocus = true
    @AppStorage(SettingsKey.focusHighlighter) private var focusHighlighter = false
    @AppStorage(SettingsKey.fastNavigation) private var fastNavigation = false
    @AppStorage(SettingsKey.landscapePosters) private var landscapePosters = false
    @AppStorage(SettingsKey.continueWatchingLandscape) private var continueWatchingLandscape = false

    var rowTileShape: CollectionTileShape {
        if let explicitTileShape {
            return explicitTileShape
        }
        if id == TVHomeSection.continueWatchingId || id == TVHomeSection.upcomingId
            || id == TVHomeSection.calendarTodayId {
            return continueWatchingLandscape ? .landscape : .poster
        }
        if landscapePosters {
            return .landscape
        }
        return items.first(where: { $0.tileShape != .poster })?.tileShape ?? .poster
    }

    private var rowPosterWidth: CGFloat {
        TVCollectionFolderCardLayout.cardWidth(shape: rowTileShape, layoutMode: homeLayout)
    }

    private var rowSpacing: CGFloat {
        homeLayout == "Compact" ? 22 : 28
    }

    private var step: CGFloat { rowPosterWidth + rowSpacing }

    private var effectiveScrollIndex: Int {
        if let restrictedFocusIndex {
            return restrictedFocusIndex
        }
        let raw = scrollIndex ?? initialScrollIndex
        guard !items.isEmpty else { return 0 }
        return min(max(raw, 0), items.count - 1)
    }

    private var restrictedFocusIndex: Int? {
        guard let restrictFocusToCardKey,
              restrictFocusToCardKey.hasPrefix("\(id)\u{1}")
        else { return nil }
        return items.firstIndex {
            TVHomeCardIdentity.key(rowID: id, item: $0) == restrictFocusToCardKey
        }
    }

    private var stripHeight: CGFloat {
        let imageHeight: CGFloat = homeLayout == "Compact" ? 255 : 315
        return imageHeight + (posterLabels ? 48 : 0) + TVHomeLayout.stripVerticalPadding * 2
    }

    private var defaultFocusCardKey: String? {
        if let initialFocusCardKey {
            if initialFocusCardKey.hasPrefix("\(id)\u{1}") {
                return initialFocusCardKey
            }
            return nil
        }
        guard !items.isEmpty else { return nil }
        let idx = effectiveScrollIndex
        return TVHomeCardIdentity.key(rowID: id, item: items[idx])
    }

    var body: some View {
        Group {
            if showsSectionTitle {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .center, spacing: 14) {
                        Text(title)
                            .font(.appFont(size: 30, weight: .bold))
                            .foregroundColor(.white)

                        if showAddonName, let addonName = addonName, !addonName.isEmpty {
                            Text(addonName)
                                .font(.appFont(size: 16, weight: .semibold))
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
            } else {
                cardStrip
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
        .defaultFocusIfAvailable(cardFocusBinding, defaultFocusCardKey)
        .modifier(OptionalMoveCommandHandler(handler: onMove))
        .onChange(of: focusRequest) { _, request in
            applyFocusRequest(request)
        }
        .onAppear {
            if let focusRequest, focusRequest.isFresh {
                applyFocusRequest(focusRequest)
            }
        }
        .task {
            decideCardStaging()
            guard cardStaging.isActive else { return }
            while stagedCardCount < Self.stagedCardTarget {
                try? await Task.sleep(nanoseconds: 40_000_000)
                guard !Task.isCancelled, cardStaging.isActive else { return }
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) { stagedCardCount += Self.stagedCardStep }
            }
            finishCardStaging()
        }
    }

    /// Decided once, by the row's first build (its first body reads it), as `stagesCardBuild` said
    /// then.
    private func decideCardStaging() {
        guard !cardStaging.isDecided else { return }
        cardStaging.isDecided = true
        cardStaging.isActive = stagesCardBuild
    }

    /// The rest of the row's cards, now.
    private func finishCardStaging() {
        guard cardStaging.isActive else { return }
        cardStaging.isActive = false
        stagedCardCount = Int.max / 2
    }

    /// Cards an off-screen row adds every 40 ms, and how many it is done at (a screen's width).
    private static let stagedCardStep = 3
    private static let stagedCardTarget = 12

    /// Whether card `index` waits its turn in an off-screen row built a few cards at a time:
    /// the cards from just before where the row is scrolled come first.
    private func isCardBuildDeferred(_ index: Int) -> Bool {
        decideCardStaging()
        guard cardStaging.isActive else { return false }
        let start = max(0, effectiveScrollIndex - 1)
        return index < start || index >= start + max(2, stagedCardCount)
    }

    /// What the cards bind their focus to: the row's own, or Home's (Grid View).
    private var cardFocusBinding: FocusState<String?>.Binding? {
        ownsCardFocus ? $ownCardFocus : externalFocus
    }

    private func applyFocusRequest(_ request: TVHomeRowFocusRequest?) {
        guard ownsCardFocus, let key = request?.cardKey, ownCardFocus != key else { return }
        ownCardFocus = key
    }

    /// One card of the row.
    @ViewBuilder
    private func catalogCard(_ card: TVCatalogMaterializedCard, mountedCount: Int) -> some View {
        let rowHomeLayout = homeLayout
        let rowPosterLabels = posterLabels
        let rowSmoothFocus = smoothFocus
        let rowFocusHighlighter = focusHighlighter
        let rowFastNavigation = fastNavigation
        let rowCardFocusAnimations = rowSmoothFocus && !suppressFocusAnimations && !rowFastNavigation
        let rowTileShape = rowTileShape
        let itemIndex = card.index
        let item = card.item
        let cardKey = card.id
        let shouldRequestInitialFocus = cardKey == initialFocusCardKey
        let progressItem = progressByItemId[item.id]
        let calendarLabel = calendarLabelsByItemId[item.id]
        // Worked out once a minute, not each time the row is built.
        let progressLabels: TVContinueWatchingCardLabels.Labels? = progressItem.map {
            TVContinueWatchingCardLabels.labels(for: $0)
        }
        // Explicit types keep the card's long initializer quick to type-check.
        let episodeText: String? = progressItem?.episodeLabel ?? calendarLabel?.episode
        let episodeTitleText: String? = progressItem?.episodeDisplayTitle ?? calendarLabel?.episodeTitle
        let upcomingArtworkURL: String? = id == TVHomeSection.upcomingId ? progressItem?.meta.backdropUrl : nil
        let episodeArtworkURL: String? = progressItem?.episodeArtworkURL ?? upcomingArtworkURL ?? calendarLabel?.artworkURL
        let isUpNext: Bool = progressItem?.isUpNextEntry == true || calendarLabel != nil
        let upNextBadgeText: String? = progressLabels?.badge ?? calendarLabel?.badge
        let handleFocus: (NuvioMeta) -> Void = { focused in
            // Focus came into a row still being built a few cards at a time: the rest now.
            finishCardStaging()
            let focusStarted = TVHomeDebugTrace.now()
            let targetIndex = items.firstIndex(where: {
                TVHomeCardIdentity.key(rowID: id, item: $0) == cardKey
            }) ?? items.firstIndex(where: { $0.id == focused.id }) ?? itemIndex

            TVHomeDebugTrace.log(
                "focus.begin row=\(id) index=\(targetIndex) items=\(items.count) "
                    + "mounted=\(mountedCount) meta=\(focused.id)"
            )
            // tvOS scrolls the row itself; only remember where it is.
            if let restrictFocusToCardKey, restrictFocusToCardKey != cardKey { return }
            if scrollIndex != targetIndex {
                scrollIndex = targetIndex
                onScrollIndexChange(targetIndex)
            }
            onFocus(focused)
            if !suppressFocusAnimations {
                onApproachEnd(focused)
            }
            let approachStarted = TVHomeDebugTrace.now()
            TVHomeDebugTrace.log(
                "focus.approach row=\(id) index=\(targetIndex) "
                    + "elapsedMs=\(TVHomeDebugTrace.elapsedMilliseconds(since: approachStarted))"
            )
            TVHomeDebugTrace.log(
                "focus.end row=\(id) index=\(targetIndex) "
                    + "parentMs=\(TVHomeDebugTrace.elapsedMilliseconds(since: focusStarted)) "
                    + "totalMs=\(TVHomeDebugTrace.elapsedMilliseconds(since: focusStarted))"
            )
        }

        PosterCard(
            meta: item,
            customPosterScreen: customPosterScreen,
            isLandscape: rowTileShape == .landscape || (rowHomeLayout == "Modern" && landscapeFocusedId == cardKey),
            isAlwaysLandscape: rowTileShape == .landscape || item.tileShape == .landscape,
            tileShape: item.tileShape != .poster ? item.tileShape : rowTileShape,
            continueProgress: progressItem?.progress,
            continueRemainingText: progressLabels?.remaining,
            continueEpisodeText: episodeText,
            continueEpisodeTitleText: episodeTitleText,
            continueEpisodeArtworkURL: episodeArtworkURL,
            continueIsUpNext: isUpNext,
            continueUpNextBadgeText: upNextBadgeText,
            collectionOrigin: id == TVHomeSection.continueWatchingId && progressItem?.isUpNextEntry == false
                ? collectionOriginsByItemId[item.id] : nil,
            showsAniListOrigin: id == TVHomeSection.continueWatchingId,
            sourceBadge: AniListService.sourceBadge(rowID: id),
            showsWatchedBadge: id != TVHomeSection.continueWatchingId && id != TVHomeSection.upcomingId
                && id != TVHomeSection.calendarTodayId,
            shouldRequestInitialFocus: shouldRequestInitialFocus,
            onInitialFocusRequested: shouldRequestInitialFocus ? onInitialFocusRequested : nil,
            onFocus: handleFocus,
            onBlur: onBlur,
            externalFocus: cardFocusBinding,
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
            onRefreshCatalog: onRefreshCatalog,
            cardIndex: itemIndex,
            layoutMode: rowHomeLayout,
            showPosterLabels: rowPosterLabels,
            smoothFocusAnimations: rowCardFocusAnimations,
            focusHighlighterEnabled: rowFocusHighlighter,
            retainFocusAppearance: retainFocusAppearanceForCardKey == cardKey,
            allowsFocus: restrictFocusToCardKey == nil || restrictFocusToCardKey == cardKey,
            focusCallbackContext: TVCardFocusCallbackContext(
                restrictFocusToCardKey: restrictFocusToCardKey,
                suppressFocusAnimations: suppressFocusAnimations
            ),
            onMove: onMove,
            buildsLater: isCardBuildDeferred(itemIndex)
        ) {
            onSelect(item)
        }
    }

    /// The row as a system scroll view. tvOS scrolls it as focus moves (outside the main
    /// thread), instead of the row moving its cards by an animated offset on each move; only
    /// cards near the screen are built.
    private var cardStrip: some View {
        let stripWidth = max(1920, UIScreen.main.bounds.width + horizontalEdgeInset * 2)
        let rowHomeLayout = homeLayout
        let rowCardFocusAnimations = smoothFocus && !suppressFocusAnimations && !fastNavigation
        let rowCardSpacing: CGFloat = rowHomeLayout == "Compact" ? 22 : 28
        let cards = TVHomeCardIdentity.materializedTitles(rowID: id, items: items, indices: Array(items.indices))
        // Where the cards start, under the row's title, in the strip's own coordinates.
        let titleLeading = horizontalEdgeInset + TVLayout.rowLeading
        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: rowCardSpacing) {
                    ForEach(cards) { card in
                        catalogCard(card, mountedCount: cards.count)
                            .id(card.id)
                    }
                }
                .scrollTargetLayout()
                .padding(.vertical, TVHomeLayout.stripVerticalPadding)
                .animation(
                    rowCardFocusAnimations && restrictFocusToCardKey == nil
                        ? TVHomeLayout.scrollAnimation : nil,
                    value: landscapeFocusedId
                )
            }
            // The focused card stays under the row's title, as in the rows before the system
            // scroll view, and tvOS still does the scrolling: the room left for the focused card
            // is one card wide, under the title, so tvOS scrolls the row on each move to keep it
            // there, and the scroll comes to rest with a card's leading edge there.
            .contentMargins(.leading, titleLeading, for: .scrollContent)
            .contentMargins(
                .trailing,
                max(titleLeading, stripWidth - titleLeading - rowPosterWidth),
                for: .scrollContent
            )
            .scrollTargetBehavior(.viewAligned(limitBehavior: .never))
            .scrollClipDisabled()
            .frame(width: stripWidth, height: stripHeight, alignment: .topLeading)
            .offset(x: -horizontalEdgeInset)
            .onAppear {
                // Where the row was left (or the card focus goes back to), without animation.
                let index = effectiveScrollIndex
                guard index > 0, cards.indices.contains(index) else { return }
                proxy.scrollTo(cards[index].id, anchor: .leading)
            }
            .onChange(of: restrictedFocusIndex) { _, index in
                guard let index, cards.indices.contains(index) else { return }
                // Back to the row's first card (Home's Back) from a card further along: the row
                // slides back, so the cards between come on screen, and are built, a few at a
                // time. Jumped there at once, all of them were built in one frame (a 250 ms stall
                // after Back). Focus waits for the first card meanwhile (the restore lock).
                let from = scrollIndex ?? initialScrollIndex
                if index == 0, (1...Self.backSlideLimit).contains(from) {
                    withAnimation(.easeOut(duration: 0.3)) {
                        proxy.scrollTo(cards[0].id, anchor: .leading)
                    }
                } else {
                    proxy.scrollTo(cards[index].id, anchor: .leading)
                }
            }
        }
        .frame(height: stripHeight)
    }

    /// How far along a row Back still slides back to its first card (further, it jumps).
    private static let backSlideLimit = 24

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

/// A Continue Watching card's badge and time left, worked out once a minute instead of each
/// time its row is built. The badge reads the episode's air date ("New
/// Episode", "Airs Fri"), which parses and formats dates for every card, every time.
/// (Main thread only: the rows' bodies.)
enum TVContinueWatchingCardLabels {
    struct Labels {
        let badge: String
        let remaining: String

        init(_ item: ContinueWatchingItem) {
            badge = item.upNextBadgeText
            remaining = item.remainingText
        }
    }

    nonisolated(unsafe) private static var cache: [String: (labels: Labels, at: TimeInterval)] = [:]
    private static let lifetime: TimeInterval = 60

    static func labels(for item: ContinueWatchingItem) -> Labels {
        let key = [
            item.id,
            item.season.map(String.init) ?? "",
            item.episode.map(String.init) ?? "",
            item.released ?? "",
            item.episodeVideo?.released ?? "",
            String(item.position),
            String(item.duration),
            String(item.lastWatchedAt.timeIntervalSinceReferenceDate),
            item.isUpNext == true ? "u" : "",
            item.upNextSeedSeason.map(String.init) ?? "",
        ].joined(separator: "\u{1f}")
        let now = ProcessInfo.processInfo.systemUptime
        if let cached = cache[key], now - cached.at < lifetime {
            return cached.labels
        }
        if cache.count > 400 { cache.removeAll() }
        let labels = Labels(item)
        cache[key] = (labels, now)
        return labels
    }
}

extension TVCatalogRow: Equatable {
    static func == (lhs: TVCatalogRow, rhs: TVCatalogRow) -> Bool {
        guard lhs.id == rhs.id,
              lhs.initialScrollIndex == rhs.initialScrollIndex,
              lhs.customPosterScreen == rhs.customPosterScreen,
              lhs.landscapeFocusedId == rhs.landscapeFocusedId,
              lhs.suppressFocusAnimations == rhs.suppressFocusAnimations,
              lhs.horizontalEdgeInset == rhs.horizontalEdgeInset,
              lhs.title == rhs.title,
              lhs.addonName == rhs.addonName,
              lhs.showAddonName == rhs.showAddonName,
              lhs.showsSectionTitle == rhs.showsSectionTitle,
              lhs.explicitTileShape == rhs.explicitTileShape,
              lhs.initialFocusCardKey == rhs.initialFocusCardKey,
              lhs.ownsCardFocus == rhs.ownsCardFocus,
              lhs.focusRequest == rhs.focusRequest,
              lhs.items.count == rhs.items.count,
              lhs.progressByItemId.count == rhs.progressByItemId.count,
              lhs.calendarLabelsByItemId == rhs.calendarLabelsByItemId
        else {
            return false
        }

        let lhsTargetInRow = lhs.restrictFocusToCardKey?.hasPrefix("\(lhs.id)\u{1}") == true
        let rhsTargetInRow = rhs.restrictFocusToCardKey?.hasPrefix("\(rhs.id)\u{1}") == true
        guard (lhs.restrictFocusToCardKey != nil) == (rhs.restrictFocusToCardKey != nil),
              lhsTargetInRow == rhsTargetInRow,
              !lhsTargetInRow || lhs.restrictFocusToCardKey == rhs.restrictFocusToCardKey
        else {
            return false
        }

        let lhsRetainInRow = lhs.retainFocusAppearanceForCardKey?.hasPrefix("\(lhs.id)\u{1}") == true
        let rhsRetainInRow = rhs.retainFocusAppearanceForCardKey?.hasPrefix("\(rhs.id)\u{1}") == true
        guard (lhsRetainInRow == rhsRetainInRow),
              !lhsRetainInRow || lhs.retainFocusAppearanceForCardKey == rhs.retainFocusAppearanceForCardKey
        else {
            return false
        }

        guard lhs.progressByItemId == rhs.progressByItemId,
              lhs.collectionOriginsByItemId == rhs.collectionOriginsByItemId
        else {
            return false
        }

        // Fast item comparison without deep recursion into large nested video arrays
        return lhs.items.elementsEqual(rhs.items, by: { a, b in
            a.id == b.id
                && a.name == b.name
                && a.posterUrl == b.posterUrl
                && a.backgroundUrl == b.backgroundUrl
                && a.landscapePosterUrl == b.landscapePosterUrl
                && a.type == b.type
                && a.posterShape == b.posterShape
        })
    }
}

enum TVHomeGridLayout {
    static let columns = 7
    static let defaultRows = 3
    static let rows = defaultRows
    static let minRows = 1
    static let maxRows = 10

    static func previewItemCount(rows: Int = defaultRows) -> Int {
        let effectiveRows = max(minRows, min(maxRows, rows))
        return effectiveRows * columns - 1
    }

    static var previewItemCount: Int {
        previewItemCount(rows: defaultRows)
    }

    static let posterWidth: CGFloat = 210
    static let posterHeight: CGFloat = 315
    static let itemSpacing: CGFloat = 28
    static let sectionSpacing: CGFloat = 54
    static let heroPageLimit = 7
    static let seeAllID = "__see_all__"
    /// Inset inside tvOS's 80pt safe area (80 + 61 = 141pt from screen edges) to center the 7-column grid symmetrically.
    static let horizontalPadding: CGFloat = 61

    static var gridColumns: [GridItem] {
        Array(
            repeating: GridItem(.fixed(posterWidth), spacing: itemSpacing, alignment: .top),
            count: columns
        )
    }

}

struct TVHomeCatalogGridSection: View {
    let section: TVHomeSection
    var customPosterScreen: CustomPosterScreen = .home
    let watchedTitleKeys: Set<String>
    let initialFocusCardKey: String?
    var externalFocus: FocusState<String?>.Binding? = nil
    var restrictFocusToCardKey: String? = nil
    var retainFocusAppearanceForCardKey: String? = nil
    var suppressFocusAnimations = false
    var showAddonName: Bool = true
    let onInitialFocusRequested: () -> Void
    let onFocus: (NuvioMeta) -> Void
    var onBlur: ((NuvioMeta) -> Void)? = nil
    let onSelect: (NuvioMeta) -> Void
    var onLongPress: ((NuvioMeta) -> Void)? = nil
    var onRefreshCatalog: (() -> Void)? = nil
    let onSeeAllFocus: () -> Void
    let onSeeAll: () -> Void

    @AppStorage(SettingsKey.theme) private var theme = SettingsAccent.white.rawValue
    @AppStorage(SettingsKey.gridRows) private var gridRows = TVHomeGridLayout.defaultRows

    private var previewItems: [NuvioMeta] {
        Array(section.items.prefix(TVHomeGridLayout.previewItemCount(rows: gridRows)))
    }

    private var seeAllKey: String {
        "\(section.id)\u{1}\(TVHomeGridLayout.seeAllID)"
    }

    private var defaultFocusCardKey: String? {
        guard let first = previewItems.first else { return nil }
        if let initialFocusCardKey, previewItems.contains(where: { TVHomeCardIdentity.key(rowID: section.id, item: $0) == initialFocusCardKey }) {
            return initialFocusCardKey
        }
        return TVHomeCardIdentity.key(rowID: section.id, item: first)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 14) {
                Text(section.title)
                    .font(.appFont(size: 30, weight: .bold))
                    .foregroundColor(.white)

                if showAddonName, let addonName = section.addonName, !addonName.isEmpty {
                    Text(addonName)
                        .font(.appFont(size: 16, weight: .semibold))
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
                ForEach(previewItems, id: \.homeTitleIdentity) { item in
                    let cardKey = TVHomeCardIdentity.key(rowID: section.id, item: item)
                    let shouldRequestInitialFocus = cardKey == initialFocusCardKey
                    PosterGridCard(
                        meta: item,
                        customPosterScreen: customPosterScreen,
                        sourceBadge: AniListService.sourceBadge(rowID: section.id),
                        width: TVHomeGridLayout.posterWidth,
                        height: TVHomeGridLayout.posterHeight,
                        externalFocus: externalFocus,
                        focusValue: cardKey,
                        retainFocusAppearance: (retainFocusAppearanceForCardKey ?? restrictFocusToCardKey) == cardKey,
                        shouldRequestInitialFocus: shouldRequestInitialFocus,
                        onInitialFocusRequested: shouldRequestInitialFocus ? onInitialFocusRequested : nil,
                        onFocus: { onFocus($0) },
                        onBlur: onBlur,
                        onLongPress: onLongPress.map { cb in { cb(item) } },
                        onRefreshCatalog: onRefreshCatalog
                    ) {
                        onSelect(item)
                    }
                    .disabled(restrictFocusToCardKey != nil && restrictFocusToCardKey != cardKey)
                }

                TVHomeSeeAllCard(
                    title: section.title,
                    externalFocus: externalFocus,
                    externalFocusValue: seeAllKey,
                    retainFocusAppearance: (retainFocusAppearanceForCardKey ?? restrictFocusToCardKey) == seeAllKey,
                    shouldRequestInitialFocus: seeAllKey == initialFocusCardKey,
                    onInitialFocusRequested: seeAllKey == initialFocusCardKey
                        ? onInitialFocusRequested
                        : nil,
                    onFocus: onSeeAllFocus,
                    action: onSeeAll
                )
                .disabled(restrictFocusToCardKey != nil && restrictFocusToCardKey != seeAllKey)
            }
        }
        .padding(.horizontal, TVHomeGridLayout.horizontalPadding)
        .defaultFocusIfAvailable(externalFocus, defaultFocusCardKey)
    }
}

struct TVHomeSeeAllCard: View {
    let title: String
    var externalFocus: FocusState<String?>.Binding? = nil
    let externalFocusValue: String
    var retainFocusAppearance = false
    var shouldRequestInitialFocus = false
    var onInitialFocusRequested: (() -> Void)? = nil
    let onFocus: () -> Void
    var onBlur: (() -> Void)? = nil
    let action: () -> Void

    @FocusState private var isFocused: Bool
    @State private var didRequestInitialFocus = false
    @Environment(\.cardAppearance) private var cardAppearance
    private var smoothFocus: Bool { cardAppearance.smoothFocus }
    private var focusHighlighter: Bool { cardAppearance.focusHighlighter }
    private var cardCornerRadiusSetting: String { cardAppearance.cardCornerRadius }

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
            // Only the focused card casts a shadow (see PosterCard).
            .shadow(
                color: .black.opacity(showsFocusedAppearance ? 0.5 : 0),
                radius: showsFocusedAppearance ? 16 : 0
            )
            .scaleEffect(showsFocusedAppearance ? 1.06 : 1)
        }
        .buttonStyle(PosterCardButtonStyle(onNativeFocusChange: { focused in
            if focused { onFocus() } else { onBlur?() }
        }))
        .focused($isFocused)
        .modifier(ExternalFocusBinding(binding: externalFocus, id: externalFocusValue))
        .focusEffectDisabledIfAvailable()
        .onAppear {
            guard shouldRequestInitialFocus, !didRequestInitialFocus else { return }
            didRequestInitialFocus = true
            onInitialFocusRequested?()
            DispatchQueue.main.async { isFocused = true }
        }
        .onChange(of: shouldRequestInitialFocus) { _, shouldRequest in
            if shouldRequest {
                guard !didRequestInitialFocus else { return }
                didRequestInitialFocus = true
                onInitialFocusRequested?()
                DispatchQueue.main.async { isFocused = true }
            } else {
                didRequestInitialFocus = false
            }
        }
        .animation(smoothFocus ? .spring(response: 0.28, dampingFraction: 0.75) : nil, value: showsFocusedAppearance)
    }
}

struct TVHomeCatalogBrowseView: View {
    let section: TVHomeSection
    let repository: CatalogRepository
    let watchedTitleKeys: Set<String>
    let collectionSource: NuvioCollectionSource?
    let collectionProfileID: String?
    let onDismiss: () -> Void
    let onSelect: (NuvioMeta) -> Void
    var onLongPress: ((NuvioMeta) -> Void)? = nil

    @State private var items: [NuvioMeta]
    @State private var pendingItems: [NuvioMeta]
    @State private var nextSkip: Int
    @State private var hasMore: Bool
    @State private var isLoadingMore = false
    @State private var collectionPageFailed = false
    @State private var collectionPageTask: Task<Void, Never>?
    @State private var collectionPageGeneration: UInt = 0
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
        collectionSource: NuvioCollectionSource? = nil,
        collectionProfileID: String? = nil,
        onDismiss: @escaping () -> Void,
        onSelect: @escaping (NuvioMeta) -> Void,
        onLongPress: ((NuvioMeta) -> Void)?
    ) {
        self.section = section
        self.repository = repository
        self.watchedTitleKeys = watchedTitleKeys
        self.collectionSource = collectionSource
        self.collectionProfileID = collectionProfileID
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
                .padding(.horizontal, 128)
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

                        if collectionPageFailed {
                            Button {
                                guard let collectionSource, let collectionProfileID else { return }
                                loadMoreCollection(source: collectionSource, profileID: collectionProfileID)
                            } label: {
                                Label(L10n.string("action_retry", fallback: "Retry"), systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(PosterCardButtonStyle())
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
                    .padding(.horizontal, 128)

                    Color.clear.frame(height: 60)
                }
                .scrollIndicators(.hidden)
                .focusSection()
                .defaultFocusIfAvailable($focusedItemID, items.first?.id)
            }
        }
        .onExitCommand(perform: onDismiss)
        .onDisappear {
            guard collectionSource != nil else { return }
            collectionPageGeneration &+= 1
            collectionPageTask?.cancel()
            collectionPageTask = nil
            isLoadingMore = false
        }
    }

    @MainActor
    private func loadMoreIfNeeded(currentItem: NuvioMeta) {
        guard hasMore,
              !isLoadingMore,
              let index = items.firstIndex(where: { $0.id == currentItem.id }),
              index >= max(items.count - TVHomeRowPrefetchThreshold, 0) else { return }

        if let collectionSource {
            guard !collectionPageFailed, let collectionProfileID else { return }
            loadMoreCollection(source: collectionSource, profileID: collectionProfileID)
            return
        }

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

    /// Collection rows may be TMDB, Trakt or custom add-on sources. Their
    /// provider cursor cannot be reconstructed from Home catalog identifiers.
    @MainActor
    private func loadMoreCollection(source: NuvioCollectionSource, profileID: String) {
        guard !isLoadingMore, hasMore,
              CollectionsStore.activeProfileId == profileID else { return }
        isLoadingMore = true
        let cursor = nextSkip
        collectionPageGeneration &+= 1
        let generation = collectionPageGeneration
        collectionPageTask = Task { @MainActor in
            defer {
                if collectionPageGeneration == generation { isLoadingMore = false }
            }
            do {
                let page = try await CollectionSourceResolver(
                    repository: repository,
                    settings: ProfileSettings.store(for: profileID)
                ).browse(source, cursor: cursor)
                guard !Task.isCancelled, collectionPageGeneration == generation,
                      CollectionsStore.activeProfileId == profileID else { return }
                let pagination = CollectionFolderBrowseView.calculatePagination(
                    page: page, source: source, requestedCursor: cursor
                )
                var seen = Set(items.map(\.homeTitleIdentity))
                items.append(contentsOf: pagination.displayItems.filter {
                    seen.insert($0.homeTitleIdentity).inserted
                })
                nextSkip = pagination.nextCursor
                hasMore = pagination.hasMore && pagination.nextCursor > cursor
                collectionPageFailed = false
            } catch {
                guard !Task.isCancelled, collectionPageGeneration == generation,
                      CollectionsStore.activeProfileId == profileID else { return }
                // Keep the cursor and existing posters so Retry fetches only
                // the failed page. Its focus target remains mounted in flight.
                collectionPageFailed = true
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
    var showsSectionTitle: Bool = true
    let horizontalEdgeInset: CGFloat
    let folders: [TVCollectionFolderItem]
    let initialScrollIndex: Int
    let onScrollIndexChange: (Int) -> Void
    let initialFocusCardKey: String?
    var externalFocus: FocusState<String?>.Binding? = nil
    /// As in `TVCatalogRow`.
    var ownsCardFocus = false
    var focusRequest: TVHomeRowFocusRequest? = nil
    var restrictFocusToCardKey: String? = nil
    var retainFocusAppearanceForCardKey: String? = nil
    var suppressFocusAnimations = false
    let onInitialFocusRequested: () -> Void
    let onFocus: (TVCollectionFolderItem) -> Void
    var onBlur: ((TVCollectionFolderItem) -> Void)? = nil
    let onSelect: (TVCollectionFolderItem) -> Void
    var onMove: ((MoveCommandDirection) -> Void)? = nil

    @State private var scrollIndex: Int?
    @FocusState private var ownCardFocus: String?
    @AppStorage(SettingsKey.homeLayout) private var homeLayout = "Modern"
    @AppStorage(SettingsKey.posterLabels) private var posterLabels = false
    @AppStorage(SettingsKey.smoothFocus) private var smoothFocus = true
    @AppStorage(SettingsKey.focusHighlighter) private var focusHighlighter = false
    @AppStorage(SettingsKey.fastNavigation) private var fastNavigation = false

    private var cardFocusBinding: FocusState<String?>.Binding? {
        ownsCardFocus ? $ownCardFocus : externalFocus
    }

    private func applyFocusRequest(_ request: TVHomeRowFocusRequest?) {
        guard ownsCardFocus, let key = request?.cardKey, ownCardFocus != key else { return }
        ownCardFocus = key
    }

    private var effectiveScrollIndex: Int {
        if let restrictedFocusIndex {
            return restrictedFocusIndex
        }
        let raw = scrollIndex ?? initialScrollIndex
        guard !folders.isEmpty else { return 0 }
        return min(max(raw, 0), folders.count - 1)
    }

    private var restrictedFocusIndex: Int? {
        guard let restrictFocusToCardKey,
              restrictFocusToCardKey.hasPrefix("\(id)\u{1}")
        else { return nil }
        return folders.firstIndex {
            TVHomeCardIdentity.folderKey(rowID: id, folder: $0) == restrictFocusToCardKey
        }
    }

    private func alignScrollIndexToRestrictedFocus() {
        guard let restrictedFocusIndex else { return }
        withTransaction(Transaction(animation: nil)) {
            scrollIndex = restrictedFocusIndex
            onScrollIndexChange(restrictedFocusIndex)
        }
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
            if let targetIndex = folders.firstIndex(where: { TVHomeCardIdentity.folderKey(rowID: id, folder: $0) == key }) {
                lowerBound = min(lowerBound, targetIndex)
                upperBound = max(upperBound, targetIndex)
            }
        }

        return Array(lowerBound...upperBound)
    }

    private func materializedCardItems(
        stripWidth: CGFloat,
        layoutMode: String
    ) -> [TVFolderMaterializedCard] {
        return materializedCardIndices(stripWidth: stripWidth, layoutMode: layoutMode).map { index in
            let folder = folders[index]
            return TVFolderMaterializedCard(id: TVHomeCardIdentity.folderKey(rowID: id, folder: folder), index: index, folder: folder)
        }
    }

    private var defaultFocusFolderKey: String? {
        if let initialFocusCardKey {
            if initialFocusCardKey.hasPrefix("\(id)\u{1}") {
                return initialFocusCardKey
            }
            return nil
        }
        guard !folders.isEmpty else { return nil }
        let idx = effectiveScrollIndex
        return TVHomeCardIdentity.folderKey(rowID: id, folder: folders[idx])
    }

    var body: some View {
        Group {
            if showsSectionTitle {
                VStack(alignment: .leading, spacing: 10) {
                    Text(title)
                        .font(.appFont(size: 30, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.leading, TVLayout.rowLeading)
                        .offset(y: 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .zIndex(2)

                    cardStrip
                        .zIndex(0)
                }
            } else {
                cardStrip
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
        .defaultFocusIfAvailable(cardFocusBinding, defaultFocusFolderKey)
        .modifier(OptionalMoveCommandHandler(handler: onMove))
        .onChange(of: focusRequest) { _, request in
            applyFocusRequest(request)
        }
        .onAppear {
            if let focusRequest, focusRequest.isFresh {
                applyFocusRequest(focusRequest)
            }
        }
    }

    private var cardStrip: some View {
        let stripWidth = max(1920, UIScreen.main.bounds.width + horizontalEdgeInset * 2)
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
        let materializedCards = materializedCardItems(
            stripWidth: stripWidth,
            layoutMode: rowHomeLayout
        )

        return HStack(alignment: .top, spacing: rowSpacing) {
            ForEach(materializedCards) { card in
                let index = card.index
                let folder = card.folder
                let cardKey = card.id
                let shouldRequestInitialFocus = cardKey == initialFocusCardKey
                TVCollectionFolderCard(
                    folder: folder,
                    cardIndex: index,
                    shouldRequestInitialFocus: shouldRequestInitialFocus,
                    onInitialFocusRequested: shouldRequestInitialFocus ? onInitialFocusRequested : nil,
                    externalFocus: cardFocusBinding,
                    externalFocusValue: cardKey,
                    onFocus: {
                        let targetIndex = folders.firstIndex(where: {
                            TVHomeCardIdentity.folderKey(rowID: id, folder: $0) == cardKey
                        }) ?? folders.firstIndex(where: { $0.id == folder.id }) ?? index

                        if let restrictFocusToCardKey {
                            guard restrictFocusToCardKey == cardKey else { return }
                            alignScrollIndexToRestrictedFocus()
                        } else if effectiveScrollIndex != targetIndex {
                            scrollIndex = targetIndex
                            onScrollIndexChange(targetIndex)
                        } else if scrollIndex != targetIndex {
                            scrollIndex = targetIndex
                            onScrollIndexChange(targetIndex)
                        }
                        onFocus(folder)
                    },
                    onBlur: { onBlur?(folder) },
                    layoutMode: rowHomeLayout,
                    showPosterLabels: rowPosterLabels,
                    smoothFocusAnimations: rowSmoothFocus && !fastNavigation,
                    focusHighlighterEnabled: rowFocusHighlighter,
                    retainFocusAppearance: retainFocusAppearanceForCardKey == cardKey,
                    allowsFocus: restrictFocusToCardKey == nil || restrictFocusToCardKey == cardKey,
                    focusCallbackContext: TVCardFocusCallbackContext(
                        restrictFocusToCardKey: restrictFocusToCardKey,
                        suppressFocusAnimations: suppressFocusAnimations
                    ),
                    onMove: onMove,
                    onSelect: { onSelect(folder) }
                )
                .equatable()
            }
        }
        .padding(
            .leading,
            TVCollectionFolderCardLayout.scrollOffset(
                to: materializedCards.first?.index ?? 0,
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
            rowSmoothFocus && !suppressFocusAnimations && !fastNavigation ? TVHomeLayout.scrollAnimation : nil,
            value: effectiveScrollIndex
        )
        .onAppear {
            alignScrollIndexToRestrictedFocus()
        }
        .onChange(of: restrictedFocusIndex) { _, _ in
            alignScrollIndexToRestrictedFocus()
        }
        .frame(height: stripHeight)
    }
}

extension TVCollectionFolderRow: Equatable {
    static func == (lhs: TVCollectionFolderRow, rhs: TVCollectionFolderRow) -> Bool {
        guard lhs.id == rhs.id,
              lhs.initialScrollIndex == rhs.initialScrollIndex,
              lhs.suppressFocusAnimations == rhs.suppressFocusAnimations,
              lhs.horizontalEdgeInset == rhs.horizontalEdgeInset,
              lhs.title == rhs.title,
              lhs.showsSectionTitle == rhs.showsSectionTitle,
              lhs.initialFocusCardKey == rhs.initialFocusCardKey,
              lhs.ownsCardFocus == rhs.ownsCardFocus,
              lhs.focusRequest == rhs.focusRequest,
              lhs.folders.count == rhs.folders.count
        else {
            return false
        }

        let lhsRestrictInRow = lhs.restrictFocusToCardKey?.hasPrefix("\(lhs.id)\u{1}") == true
        let rhsRestrictInRow = rhs.restrictFocusToCardKey?.hasPrefix("\(rhs.id)\u{1}") == true
        guard (lhs.restrictFocusToCardKey != nil) == (rhs.restrictFocusToCardKey != nil),
              (lhsRestrictInRow == rhsRestrictInRow),
              !lhsRestrictInRow || lhs.restrictFocusToCardKey == rhs.restrictFocusToCardKey
        else {
            return false
        }

        let lhsRetainInRow = lhs.retainFocusAppearanceForCardKey?.hasPrefix("\(lhs.id)\u{1}") == true
        let rhsRetainInRow = rhs.retainFocusAppearanceForCardKey?.hasPrefix("\(rhs.id)\u{1}") == true
        guard (lhsRetainInRow == rhsRetainInRow),
              !lhsRetainInRow || lhs.retainFocusAppearanceForCardKey == rhs.retainFocusAppearanceForCardKey
        else {
            return false
        }

        return lhs.folders == rhs.folders
    }
}

struct TVCollectionFolderCard: View {
    let folder: TVCollectionFolderItem
    var cardIndex: Int? = nil
    var shouldRequestInitialFocus: Bool = false
    var onInitialFocusRequested: (() -> Void)? = nil
    var externalFocus: FocusState<String?>.Binding? = nil
    var externalFocusValue: String? = nil
    var onFocus: (() -> Void)? = nil
    var onBlur: (() -> Void)? = nil
    var layoutMode: String = "Modern"
    var showPosterLabels: Bool = false
    var smoothFocusAnimations: Bool = true
    var focusHighlighterEnabled: Bool = false
    var retainFocusAppearance: Bool = false
    var allowsFocus = true
    var focusCallbackContext: TVCardFocusCallbackContext = TVCardFocusCallbackContext()
    var onMove: ((MoveCommandDirection) -> Void)? = nil
    let onSelect: () -> Void

    @FocusState private var isFocused: Bool
    @State private var didRequestInitialFocus = false
    @Environment(\.cardAppearance) private var cardAppearance
    private var cardCornerRadiusSetting: String { cardAppearance.cardCornerRadius }

    private var showFocus: Bool { isFocused || retainFocusAppearance }

    private var cardWidth: CGFloat {
        TVCollectionFolderCardLayout.cardWidth(shape: folder.tileShape, layoutMode: layoutMode)
    }

    private var cardHeight: CGFloat {
        TVCollectionFolderCardLayout.cardHeight(layoutMode: layoutMode)
    }

    /// Keep the focusable surface aligned with the standard portrait column
    /// when a landscape folder is displayed. The artwork remains landscape,
    /// but tvOS should use the leading edge for vertical row matching.
    private var layoutWidth: CGFloat {
        folder.tileShape == .landscape ? (layoutMode == "Compact" ? 170 : 210) : cardWidth
    }

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
        let candidate: String?
        if !folder.focusGifEnabled,
           let gifUrl = folder.focusGifUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
           !gifUrl.isEmpty {
            candidate = gifUrl
        } else {
            candidate = folder.coverImageUrl?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let raw = candidate, !raw.isEmpty, let url = URL(string: raw) else { return nil }
        return url
    }

    private func isCoverGifURL(_ url: URL) -> Bool {
        let lower = url.absoluteString.lowercased()
        return lower.hasSuffix(".gif") || lower.contains(".gif?") || lower.contains("/gif")
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

    // Only the focused card casts a shadow (see PosterCard).
    private var shadowOpacity: Double { showFocus ? 0.5 : 0 }
    private var shadowRadius: CGFloat { showFocus ? 16 : 0 }

    private var focusGifURLString: String? {
        folder.activeFocusGifURLString
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Button(action: onSelect) {
                cardContent
            }
            .buttonStyle(PosterCardButtonStyle(onNativeFocusChange: { focused in
                if focused { onFocus?() } else { onBlur?() }
            }))
            .disabled(!allowsFocus)
            .focused($isFocused)
            .modifier(ExternalFocusBinding(binding: externalFocus, id: externalFocusValue ?? folder.id))
            .focusEffectDisabledIfAvailable()
            .modifier(OptionalMoveCommandHandler(handler: onMove))
            .onAppear {
                if let raw = focusGifURLString, let url = URL(string: raw) {
                    AnimatedGIFCache.shared.preload(url: url)
                }
                guard shouldRequestInitialFocus, !didRequestInitialFocus else { return }
                didRequestInitialFocus = true
                onInitialFocusRequested?()
                DispatchQueue.main.async {
                    isFocused = true
                }
            }
            .frame(width: layoutWidth, height: totalCardHeight, alignment: .topLeading)
        }
        .frame(width: cardWidth, height: totalCardHeight, alignment: .topLeading)
        .zIndex(showFocus ? 1 : 0)
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 9) {
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
            if isCoverGifURL(url) {
                AnimatedRemoteGIFView(urlString: url.absoluteString, isActive: showFocus)
                    .frame(width: cardWidth, height: cardHeight)
                    .clipped()
            } else {
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

extension TVCollectionFolderCard: Equatable {
    static func == (lhs: TVCollectionFolderCard, rhs: TVCollectionFolderCard) -> Bool {
        lhs.folder == rhs.folder &&
        lhs.cardIndex == rhs.cardIndex &&
        lhs.shouldRequestInitialFocus == rhs.shouldRequestInitialFocus &&
        lhs.externalFocusValue == rhs.externalFocusValue &&
        lhs.layoutMode == rhs.layoutMode &&
        lhs.showPosterLabels == rhs.showPosterLabels &&
        lhs.smoothFocusAnimations == rhs.smoothFocusAnimations &&
        lhs.focusHighlighterEnabled == rhs.focusHighlighterEnabled &&
        lhs.retainFocusAppearance == rhs.retainFocusAppearance &&
        lhs.allowsFocus == rhs.allowsFocus &&
        lhs.focusCallbackContext == rhs.focusCallbackContext
    }
}
