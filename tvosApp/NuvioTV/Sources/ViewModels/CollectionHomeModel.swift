import Foundation
import Combine

/// Browsing identity only. Playback continues to use the profile's existing
/// title/episode progress keys, regardless of which collection opened it.
struct CollectionHomeID: Hashable {
    let profileID: String
    let collectionID: String
    let folderID: String

    var key: String {
        [profileID, collectionID, folderID]
            .map { "\($0.utf8.count):\($0)" }.joined()
    }
}

struct CollectionHomeDestination: Identifiable, Equatable {
    let id: CollectionHomeID
    let collectionTitle: String
    let folder: TVCollectionFolderItem

    /// Classify the folder's configured sources, never the genres attached to
    /// its movie metadata or its editable/localized display name.
    var isGenreDestination: Bool {
        let style = folder.presentationStyle?.uppercased()
        guard style != "STREAMING_SERVICE", style != "STUDIO_FRANCHISE",
              !folder.sources.isEmpty else { return false }
        var hasGenreFilter = false
        for source in folder.sources {
            if source.normalizedProvider == "addon" {
                guard let genre = source.genre,
                      !genre.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
                hasGenreFilter = true
                continue
            }
            guard source.normalizedProvider == "tmdb",
                  source.tmdbSourceType?.uppercased() == "DISCOVER",
                  let filters = source.filters else { return false }
            // A provider/company/network collection can also constrain genres;
            // those destinations must remain direct service/studio entries.
            let providerFilters = [filters.withWatchProviders, filters.withCompanies, filters.withNetworks]
            guard providerFilters.allSatisfy({
                $0?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
            }) else { return false }
            if let genres = filters.withGenres,
               !genres.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                hasGenreFilter = true
            } else if !["315058", "9840"].contains(filters.withKeywords ?? "") {
                // Horror and Romance use keyword-based TV discovery in the
                // built-in template, alongside their movie genre filters.
                return false
            }
        }
        return hasGenreFilter
    }

    /// Preserve source and presentation edits when the tab shell is rebuilt.
    /// This value is used as a SwiftUI identity, never a persisted setting.
    var revision: CollectionHomeRevision {
        CollectionHomeRevision(id: id, folder: folder, collectionTitle: collectionTitle)
    }

    static func configured(profileID: String) -> [Self] {
        guard CollectionsStore.activeProfileId == profileID else { return [] }
        let sidebarIDs = CollectionSidebarPreferences.collectionIDs(profileID: profileID)
        var seen = Set<CollectionHomeID>()
        return CollectionsStore.collections().flatMap { collection in
            collection.folders.compactMap { folder -> Self? in
                guard sidebarIDs.contains(collection.id) else { return nil }
                let id = CollectionHomeID(profileID: profileID, collectionID: collection.id, folderID: folder.id)
                guard seen.insert(id).inserted else { return nil }
                return Self(
                    id: id,
                    collectionTitle: collection.title,
                    folder: TVCollectionFolderItem(
                        collectionId: collection.id, folder: folder,
                        sources: folder.resolvedSources,
                        viewMode: .followLayout, showAllTab: false
                    )
                )
            }
        }
    }
}

/// Independent local placement per profile. Existing Home visibility remains in
/// TVHomeCatalogOrder; no custom fields are added to the synced collection JSON.
enum CollectionSidebarPreferences {
    static let changedNotification = Notification.Name("CollectionSidebarPreferencesChanged")
    private static let key = "collectionSidebarCollectionIDs"

    static func collectionIDs(profileID: String?) -> Set<String> {
        Set(ProfileSettings.store(for: profileID).stringArray(forKey: key) ?? [])
    }

    static func setEnabled(_ enabled: Bool, collectionID: String, profileID: String?) {
        guard let profileID, !profileID.isEmpty, !collectionID.isEmpty else { return }
        var ids = collectionIDs(profileID: profileID)
        if enabled { ids.insert(collectionID) } else { ids.remove(collectionID) }
        ProfileSettings.store(for: profileID).set(ids.sorted(), forKey: key)
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }
}

struct CollectionHomeRevision: Hashable {
    let id: CollectionHomeID
    let folder: TVCollectionFolderItem
    let collectionTitle: String
}

struct CollectionHomeFailure: Identifiable, Equatable {
    let id: String
    let title: String
}

/// Owns a single collection folder's data. It never calls the global Home loader and
/// never writes the user's Home order, visibility, progress or synced JSON.
@MainActor
final class CollectionHomeModel: ObservableObject {
    let destination: CollectionHomeDestination
    let store = TVHomeStore()
    @Published private(set) var failures: [CollectionHomeFailure] = []
    @Published private(set) var retryingRows: Set<String> = []
    private let repository: CatalogRepository
    private var generation: UInt = 0
    private var pageTasks: [String: Task<Void, Never>] = [:]
    private var sourcesByRow: [String: NuvioCollectionSource] = [:]
    private var sourceErrors: [String: String] = [:]
    private var lastInputSignature: String?
    private var rowOrder: [String: Int] = [:]

    init(destination: CollectionHomeDestination, repository: CatalogRepository) {
        self.destination = destination
        self.repository = repository
    }

    func cancel() {
        generation &+= 1
        pageTasks.values.forEach { $0.cancel() }
        pageTasks.removeAll()
        retryingRows = []
        for index in store.sections.indices { store.sections[index].isLoadingMore = false }
    }

    private func isCurrent(_ expected: UInt) -> Bool {
        !Task.isCancelled && generation == expected
            && CollectionsStore.activeProfileId == destination.id.profileID
    }

    func releaseCatalogs() {
        cancel()
        store.reset()
        sourcesByRow.removeAll()
        sourceErrors.removeAll()
        failures = []
        rowOrder.removeAll()
        lastInputSignature = nil
    }

    var requiresReload: Bool {
        lastInputSignature != nil && lastInputSignature != inputSignature
    }

    private var inputSignature: String {
        let settings = ProfileSettings.store(for: destination.id.profileID)
        return [
            TmdbDetailsService.preferredLanguage,
            String(settings.bool(forKey: SettingsKey.tmdbEnabled)),
            String(settings.bool(forKey: SettingsKey.tmdbUseArtwork)),
            String(settings.bool(forKey: SettingsKey.tmdbUseBasicInfo)),
            String(settings.bool(forKey: SettingsKey.tmdbApplyToHome)),
            repository.homeCatalogInputSignature
        ].joined(separator: "|")
    }

    /// Requests are sequential: no inactive platform fan-out and at most one
    /// initial catalog request at a time. Publish in configured source order.
    func load(identity: TVHomeContentIdentity, force: Bool) async -> String? {
        let signature = inputSignature
        if !force, store.isLoaded(for: identity), sourceErrors.isEmpty,
           lastInputSignature == signature {
            return store.sections.allSatisfy { $0.items.isEmpty }
                ? L10n.string("collection_folder_empty", fallback: "No titles found in this folder") : nil
        }
        cancel()
        let expected = generation
        failures = []
        let token = store.beginLoad(for: identity)
        let resolver = CollectionSourceResolver(
            repository: repository,
            settings: ProfileSettings.store(for: destination.id.profileID)
        )
        var rows: [TVHomeSection] = []
        var rowSources: [String: NuvioCollectionSource] = [:]
        var errors: [String: String] = [:]
        var order: [String: Int] = [:]
        for (index, source) in destination.folder.sources.enumerated() {
            guard isCurrent(expected) else {
                store.cancelLoad(token, for: identity)
                return nil
            }
            let rowID = "platform:\(destination.id.key):\(index)"
            rowSources[rowID] = source
            order[rowID] = index
            do {
                let page = try await resolver.browse(source)
                guard isCurrent(expected), store.isCurrentLoad(token, for: identity) else {
                    store.cancelLoad(token, for: identity)
                    return nil
                }
                let pagination = CollectionFolderBrowseView.calculatePagination(
                    page: page, source: source, requestedCursor: 0
                )
                var row = TVHomeSection(
                    id: rowID,
                    title: CollectionSourceResolver.label(for: source),
                    items: pagination.displayItems,
                    nextSkip: pagination.nextCursor,
                    hasMore: pagination.hasMore
                )
                row.isLoadingPlaceholder = false
                rows.append(row)
            } catch {
                guard isCurrent(expected) else {
                    store.cancelLoad(token, for: identity)
                    return nil
                }
                errors[rowID] = L10n.string("catalog_load_failed", fallback: "Catalog failed")
            }
        }
        guard isCurrent(expected), store.isCurrentLoad(token, for: identity) else {
            store.cancelLoad(token, for: identity)
            return nil
        }
        guard signature == inputSignature else {
            store.cancelLoad(token, for: identity)
            return L10n.string("account_error_generic_retry", fallback: "Something went wrong. Please try again.")
        }
        sourcesByRow = rowSources
        rowOrder = order
        sourceErrors = errors
        lastInputSignature = signature
        store.sections = rows
        store.hero = rows.lazy.flatMap { $0.items }.first
        store.finishLoad(token, for: identity)
        refreshFailures()
        if rows.allSatisfy({ $0.items.isEmpty }) {
            return errors.isEmpty
                ? L10n.string("collection_folder_empty", fallback: "No titles found in this folder")
                : L10n.string("account_error_generic_retry", fallback: "Something went wrong. Please try again.")
        }
        return nil
    }

    private func refreshFailures() {
        failures = sourceErrors.keys.sorted { (rowOrder[$0] ?? 0) < (rowOrder[$1] ?? 0) }
            .compactMap { id in
                sourcesByRow[id].map { CollectionHomeFailure(
                    id: id, title: CollectionSourceResolver.label(for: $0)
                ) }
            }
    }

    func source(for rowID: String) -> NuvioCollectionSource? {
        sourcesByRow[rowID]
    }

    func retry(rowID: String) {
        guard sourceErrors[rowID] != nil else { return }
        requestPage(rowID: rowID)
    }

    func loadMore(rowID: String, currentItem: NuvioMeta) {
        guard sourceErrors[rowID] == nil,
              let row = store.sections.first(where: { $0.id == rowID }),
              row.hasMore,
              let itemIndex = row.items.firstIndex(where: { $0.homeTitleIdentity == currentItem.homeTitleIdentity }),
              itemIndex >= max(0, row.items.count - 8) else { return }
        requestPage(rowID: rowID)
    }

    private func requestPage(rowID: String) {
        guard lastInputSignature == inputSignature,
              let source = sourcesByRow[rowID], pageTasks[rowID] == nil else { return }
        let expected = generation
        let initialRow = store.sections.first(where: { $0.id == rowID })
        let cursor = initialRow?.nextSkip ?? 0
        let replacingInitialFailure = initialRow == nil
        retryingRows.insert(rowID)
        if let index = store.sections.firstIndex(where: { $0.id == rowID }) {
            store.sections[index].isLoadingMore = true
        }
        pageTasks[rowID] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.generation == expected {
                    self.pageTasks[rowID] = nil
                    self.retryingRows.remove(rowID)
                    if let i = self.store.sections.firstIndex(where: { $0.id == rowID }) {
                        self.store.sections[i].isLoadingMore = false
                    }
                    self.refreshFailures()
                }
            }
            do {
                let page = try await CollectionSourceResolver(
                    repository: self.repository,
                    settings: ProfileSettings.store(for: self.destination.id.profileID)
                ).browse(source, cursor: cursor)
                guard self.isCurrent(expected), self.lastInputSignature == self.inputSignature else { return }
                let pagination = CollectionFolderBrowseView.calculatePagination(
                    page: page, source: source, requestedCursor: cursor
                )
                if replacingInitialFailure {
                    // A previously failed source takes its original position;
                    // retrying never appends a second occurrence of that row.
                    self.store.sections.append(TVHomeSection(
                        id: rowID, title: CollectionSourceResolver.label(for: source),
                        items: pagination.displayItems, nextSkip: pagination.nextCursor,
                        hasMore: pagination.hasMore
                    ))
                    self.store.sections.sort { (self.rowOrder[$0.id] ?? 0) < (self.rowOrder[$1.id] ?? 0) }
                    if self.store.hero == nil { self.store.hero = pagination.displayItems.first }
                } else if let i = self.store.sections.firstIndex(where: { $0.id == rowID }) {
                    let existing = Set(self.store.sections[i].items.map(\.homeTitleIdentity))
                    self.store.sections[i].items.append(contentsOf: pagination.displayItems.filter {
                        !existing.contains($0.homeTitleIdentity)
                    })
                    self.store.sections[i].nextSkip = pagination.nextCursor
                    // Duplicate-only pages may precede new titles. Require an
                    // advancing provider cursor instead of new display items.
                    self.store.sections[i].hasMore = pagination.hasMore && pagination.nextCursor > cursor
                }
                self.sourceErrors[rowID] = nil
            } catch {
                guard self.isCurrent(expected) else { return }
                // Preserve cards and cursor; retry is an explicit native button.
                self.sourceErrors[rowID] = L10n.string("catalog_load_failed", fallback: "Catalog failed")
            }
        }
    }
}
