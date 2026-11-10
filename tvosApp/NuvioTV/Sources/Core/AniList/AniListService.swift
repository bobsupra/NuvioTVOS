import Foundation

/// AniList inside Nuvio: Home rows, See All, Search and the details of `anilist:` titles,
/// all asked from this Apple TV. See `AniListMetaBuilder` for how entries become titles.
enum AniListService {
    static let addonID = "anilist"
    static let addonName = "AniList"
    /// Content type of the Home rows ("Trending Now - Anime").
    static let homeContentType = "anime"

    /// The round AniList mark on Search's cards, drawn like the service logos on Home's cards.
    static let searchBadge = CollectionOriginPresentation(
        reference: CollectionOriginReference(collectionID: addonID, folderID: addonID),
        title: addonName,
        imageURLs: [AniListMetaBuilder.ratingIcon],
        emoji: nil
    )

    /// MyAnimeList's mark on cards of MAL's rows.
    static let malBadge = CollectionOriginPresentation(
        reference: CollectionOriginReference(collectionID: "myanimelist", folderID: "myanimelist"),
        title: "MyAnimeList",
        imageURLs: ["asset:\(MALEpisodeRatings.assetName)"],
        emoji: nil
    )

    /// The mark a Home row's cards carry: AniList's on AniList's rows (its catalogs and the
    /// viewer's lists), MyAnimeList's on MAL's; nil on any other row.
    static func sourceBadge(rowID: String) -> CollectionOriginPresentation? {
        let prefix = "addon_\(addonID)_\(homeContentType)_"
        guard rowID.hasPrefix(prefix) else { return nil }
        return rowID.dropFirst(prefix.count).hasPrefix(MALCatalogs.idPrefix) ? malBadge : searchBadge
    }

    static let catalogTTL: TimeInterval = 6 * 3600
    static let searchTTL: TimeInterval = 3600
    /// Entries still airing (or not yet) are asked again after an hour, finished ones after a week.
    static let airingTTL: TimeInterval = 3600
    static let finishedTTL: TimeInterval = 7 * 24 * 3600
    static let aniZipTTL: TimeInterval = 24 * 3600
    static let pageSize = 50
    static let homeRowSize = 30

    private static let decoder = JSONDecoder()

    static func isAniListTitle(_ id: String) -> Bool {
        AniListSettings.opensTitles && AniListMetaBuilder.isAniListID(id)
    }

    private static var isAdultVariable: Bool? {
        AniListSettings.showsAdult ? nil : false
    }

    // MARK: Home

    static func catalogSettingsKey(_ row: AniListHomeRow) -> String {
        TVHomeCatalogOrder.catalogSettingsKey(addonId: addonID, contentType: homeContentType, catalogId: row.id)
    }

    static func catalogRowID(_ row: AniListHomeRow) -> String {
        "addon_\(addonID)_\(homeContentType)_\(row.id)"
    }

    static func catalogDisplayTitle(_ row: AniListHomeRow) -> String {
        let showType = ProfileSettings.current.object(forKey: SettingsKey.homeCatalogShowType) as? Bool ?? true
        return TVHomeCatalogOrder.catalogDisplayTitle(
            row.title,
            contentType: homeContentType,
            showType: showType,
            addonName: addonName,
            customTitle: TVHomeCatalogOrder.customCatalogTitles()[catalogSettingsKey(row)]
        )
    }

    /// The viewer's lists first (when logged in), then the AniList rows that Layout doesn't hide,
    /// then MyAnimeList's (MAL Catalogs), which open as AniList titles.
    static func homeCatalogs() async -> [NuvioCatalog] {
        guard AniListSettings.opensTitles else { return [] }
        // The offline tables, downloaded when missing or a week old (in the background).
        Task.detached(priority: .background) { await AniListOfflineMaps.shared.refreshIfStale() }
        async let mal = MALCatalogs.homeCatalogs()
        guard AniListSettings.isEnabled else { return await mal }
        guard !AniListCatalogs.chosen().isEmpty else {
            AniListDiagnostics.note(.home, "Off: no AniList catalog is chosen")
            return await mal
        }
        async let lists = listCatalogs()
        let rows = await browseCatalogs()
        return await lists + rows + mal
    }

    static func listSettingsKey(_ rowID: String) -> String {
        TVHomeCatalogOrder.catalogSettingsKey(addonId: addonID, contentType: homeContentType, catalogId: rowID)
    }

    /// The viewer's AniList lists on Home ("My Watching"…): their cards carry AniList's mark,
    /// as in Continue Watching.
    static func isListRow(_ homeRowID: String) -> Bool {
        homeRowID.hasPrefix(listRowID("list-"))
    }

    static func listRowID(_ rowID: String) -> String {
        "addon_\(addonID)_\(homeContentType)_\(rowID)"
    }

    static func listDisplayTitle(_ rowID: String, title: String) -> String {
        let showType = ProfileSettings.current.object(forKey: SettingsKey.homeCatalogShowType) as? Bool ?? true
        return TVHomeCatalogOrder.catalogDisplayTitle(
            "My \(title)",
            contentType: homeContentType,
            showType: showType,
            addonName: addonName,
            customTitle: TVHomeCatalogOrder.customCatalogTitles()[listSettingsKey(rowID)]
        )
    }

    /// The viewer's Watching, Planning and Paused lists, one request (kept five minutes).
    static func listCatalogs() async -> [NuvioCatalog] {
        guard AniListSettings.showsListRows else { return [] }
        let disabled = TVHomeCatalogOrder.disabledCatalogKeys()
        let rows = AniListAccount.listRows.filter { !disabled.contains(listSettingsKey($0.id)) }
        guard !rows.isEmpty, let byRow = await AniListAccount.listEntries() else { return [] }
        let language = AniListSettings.titleLanguage
        return rows.compactMap { row in
            let items = (byRow[row.id] ?? []).compactMap(\.media).map { AniListMetaBuilder.card($0, language: language) }
            guard !items.isEmpty else { return nil }
            let title = listDisplayTitle(row.id, title: row.title)
            return NuvioCatalog(
                id: listRowID(row.id),
                name: title,
                description: title,
                itemIds: items.map(\.id),
                items: items,
                contentType: homeContentType,
                catalogId: row.id,
                addonId: addonID,
                addonName: addonName
            )
        }
    }

    /// Rows asked together: AniList refuses a query that asks too much at once.
    static let rowsPerRequest = 3

    /// The AniList rows that Layout doesn't hide, a few per request.
    private static func browseCatalogs() async -> [NuvioCatalog] {
        let disabled = TVHomeCatalogOrder.disabledCatalogKeys()
        let rows = AniListHomeRow.all.filter { !disabled.contains(catalogSettingsKey($0)) }
        guard !rows.isEmpty else {
            AniListDiagnostics.note(.home, "No AniList row to show (AniList Catalogs, Layout)")
            return []
        }

        var pages: [String: AniListPage] = [:]
        var lastAnswer: AniListClient.Answer?
        var failure: String?
        var failedRows: [String] = []
        func ask(_ chunk: [AniListHomeRow]) async -> Bool {
            do {
                let answer = try await AniListClient.shared.answer(
                    AniListQueries.homeRows(chunk), variables: homeVariables(for: chunk), ttl: catalogTTL
                )
                lastAnswer = answer
                let decoded = try decoder.decode(AniListAliasedPagesResponse.self, from: answer.data).data ?? [:]
                pages.merge(decoded) { _, new in new }
                return true
            } catch {
                failure = AniListDiagnostics.describe(error)
                return false
            }
        }
        for start in stride(from: 0, to: rows.count, by: rowsPerRequest) {
            let chunk = Array(rows[start..<min(start + rowsPerRequest, rows.count)])
            let answered = await ask(chunk)
            if answered { continue }
            if chunk.count == 1 {
                failedRows.append(chunk[0].title)
                continue
            }
            // One row AniList refuses doesn't take the others with it.
            for row in chunk {
                let alone = await ask([row])
                if !alone { failedRows.append(row.title) }
            }
        }
        if pages.isEmpty, let failure {
            AniListDiagnostics.note(.home, "Failed: \(failure)")
            return []
        }

        let language = AniListSettings.titleLanguage
        let adult = AniListSettings.showsAdult
        let catalogs: [NuvioCatalog] = rows.compactMap { row in
            var media = pages[row.alias]?.media ?? []
            if row.studio != nil, !adult { media = media.filter { $0.isAdult != true } }
            let items = media.map { AniListMetaBuilder.card($0, language: language) }
            guard !items.isEmpty else { return nil }
            let title = catalogDisplayTitle(row)
            return NuvioCatalog(
                id: catalogRowID(row),
                name: title,
                description: title,
                itemIds: items.map(\.id),
                items: items,
                contentType: homeContentType,
                catalogId: row.id,
                addonId: addonID,
                addonName: addonName
            )
        }
        let titles = catalogs.reduce(0) { $0 + ($1.items?.count ?? 0) }
        let source = lastAnswer.map { AniListDiagnostics.source($0) } ?? "no answer"
        let refused = failedRows.isEmpty ? "" : " · not answered: \(failedRows.joined(separator: ", ")) (\(failure ?? "?"))"
        AniListDiagnostics.note(
            .home,
            catalogs.isEmpty
                ? "AniList answered with no titles · \(source)\(refused)"
                : "\(catalogs.count) of \(rows.count) rows, \(titles) titles · \(source)\(refused)"
        )
        return catalogs
    }

    /// The variables the rows of one request use, and no others.
    static func homeVariables(for rows: [AniListHomeRow]) -> [String: Any?] {
        var variables: [String: Any?] = ["perPage": homeRowSize]
        if rows.contains(where: { $0.studio == nil }) {
            variables["isAdult"] = isAdultVariable
        }
        if rows.contains(where: \.usesSeason) {
            let current = AniListSeason.current()
            variables["season"] = current.season
            variables["seasonYear"] = current.year
        }
        if rows.contains(where: \.usesNextSeason) {
            let next = AniListSeason.next()
            variables["nextSeason"] = next.season
            variables["nextSeasonYear"] = next.year
        }
        return variables
    }

    /// See All for an AniList row (or a MAL one).
    static func browse(catalogId: String, skip: Int, genre: String? = nil) async -> CatalogPage {
        if catalogId.hasPrefix(MALCatalogs.idPrefix) {
            return await MALCatalogs.browse(catalogId: catalogId, skip: skip)
        }
        if let listRow = AniListAccount.listRows.first(where: { $0.id == catalogId }) {
            // One of the viewer's lists: all of it at once.
            guard skip == 0, let byRow = await AniListAccount.listEntries() else {
                return CatalogPage(items: [], hasMore: false, page: 1)
            }
            let language = AniListSettings.titleLanguage
            let items = (byRow[listRow.id] ?? []).compactMap(\.media).map { AniListMetaBuilder.card($0, language: language) }
            return CatalogPage(items: items, hasMore: false, page: 1, nextSkip: items.count)
        }
        guard AniListSettings.isEnabled, let row = AniListHomeRow.row(id: catalogId) else {
            return CatalogPage(items: [], hasMore: false, page: 1)
        }
        let page = max(skip, 0) / pageSize + 1
        let usesGenre = genre != nil && row.studio == nil && !row.arguments.contains("genre:")
        var variables: [String: Any?] = ["page": page, "perPage": pageSize]
        if row.studio == nil {
            variables.merge(homeVariables(for: [row]).filter { $0.key != "perPage" }) { _, new in new }
        }
        if usesGenre {
            variables["genre"] = genre
        }
        guard let data = try? await AniListClient.shared.query(AniListQueries.rowPage(row, withGenre: usesGenre), variables: variables, ttl: catalogTTL),
              let result = try? decoder.decode(AniListPageResponse.self, from: data).data?.Page else {
            return CatalogPage(items: [], hasMore: false, page: page)
        }
        let language = AniListSettings.titleLanguage
        var media = result.media ?? []
        if row.studio != nil, !AniListSettings.showsAdult { media = media.filter { $0.isAdult != true } }
        let items = media.map { AniListMetaBuilder.card($0, language: language) }
        return CatalogPage(
            items: items,
            hasMore: result.pageInfo?.hasNextPage ?? false,
            page: page,
            nextSkip: skip + items.count
        )
    }

    // MARK: Search

    struct SearchResult {
        let items: [NuvioMeta]
        /// Every title of every result (romaji, English, native, synonyms) and its year,
        /// to recognise the same anime among Cinemeta's results.
        let names: [(name: String, year: Int?)]
        /// AniList was asked and didn't answer. Search then doesn't keep the results it shows,
        /// so the same search asks again instead of showing them without AniList.
        var failed = false

        static let empty = SearchResult(items: [], names: [])
        static let failure = SearchResult(items: [], names: [], failed: true)

        func matches(_ meta: NuvioMeta) -> Bool {
            let name = AniListService.matchKey(meta.name)
            guard !name.isEmpty else { return false }
            return names.contains { candidate in
                guard candidate.name == name else { return false }
                guard let year = candidate.year, let other = meta.year else { return true }
                return abs(year - other) <= 1
            }
        }
    }

    static func search(_ query: String) async -> SearchResult {
        guard AniListSettings.isEnabled else { return .empty }
        guard AniListSettings.searchesAniList else {
            AniListDiagnostics.note(.search, "Off: Search AniList is off")
            return .empty
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        let quoted = "“\(trimmed)”"
        let answer: AniListClient.Answer
        do {
            answer = try await AniListClient.shared.answer(
                AniListQueries.search,
                variables: ["search": trimmed, "perPage": 30, "isAdult": isAdultVariable],
                ttl: searchTTL
            )
        } catch {
            AniListDiagnostics.note(.search, "\(quoted): failed: \(AniListDiagnostics.describe(error))")
            return .failure
        }
        let media: [AniListMedia]
        do {
            media = try decoder.decode(AniListPageResponse.self, from: answer.data).data?.Page?.media ?? []
        } catch {
            await AniListClient.shared.noteFailure("Unreadable search answer: \(error)")
            AniListDiagnostics.note(.search, "\(quoted): unreadable answer · \(AniListDiagnostics.source(answer))")
            return .failure
        }
        let films = media.filter(AniListMetaBuilder.isMovie).count
        AniListDiagnostics.note(
            .search,
            "\(quoted): \(media.count) results (\(media.count - films) series, \(films) films) · \(AniListDiagnostics.source(answer))"
        )
        let language = AniListSettings.titleLanguage
        var names: [(name: String, year: Int?)] = []
        for entry in media {
            let year = AniListMetaBuilder.year(entry)
            for title in [entry.title?.romaji, entry.title?.english, entry.title?.native] + (entry.synonyms ?? []).map(Optional.some) {
                let key = matchKey(title ?? "")
                if !key.isEmpty { names.append((name: key, year: year)) }
            }
        }
        return SearchResult(items: media.map { AniListMetaBuilder.card($0, language: language) }, names: names)
    }

    static func matchKey(_ name: String) -> String {
        let folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        var key = ""
        for scalar in folded.unicodeScalars where CharacterSet.alphanumerics.contains(scalar) {
            key.unicodeScalars.append(scalar)
        }
        return key
    }

    // MARK: Details

    enum DetailsError: Error {
        case notFound
    }

    /// The whole title for `anilist:ID`. With "One Title", an entry inside a series gives the
    /// series under its first entry's id.
    static func metadata(id: String) async throws -> NuvioMeta? {
        guard AniListSettings.opensTitles, let startID = AniListMetaBuilder.aniListID(from: id) else { return nil }
        let merge = AniListSettings.seasonMode == .merged
        let language = AniListSettings.titleLanguage

        var entries: [Int: AniListMedia] = [:]
        var pending = [startID]
        var chainIDs = [startID]
        var rounds = 0
        while !pending.isEmpty, rounds < 16 {
            rounds += 1
            for media in try await fetchEntries(pending) {
                entries[media.id] = media
            }
            guard entries[startID] != nil else { throw DetailsError.notFound }
            guard merge else { break }
            let chain = AniListMetaBuilder.chain(from: startID, entries: entries)
            chainIDs = chain.ids
            pending = chain.missing.filter { entries[$0] == nil }
        }

        let tabs = (merge ? chainIDs : [startID]).compactMap { entries[$0] }
        guard !tabs.isEmpty else { throw DetailsError.notFound }

        // api.ani.zip: titles and pictures of episodes, and TheTVDB's background and logo of
        // the series. It has no AniList rate limit.
        var aniZip: [Int: AniZipMappingsResponse] = [:]
        if AniListSettings.usesEpisodeDetails {
            await withTaskGroup(of: (Int, AniZipMappingsResponse?).self) { group in
                for tab in tabs {
                    group.addTask {
                        let response = await Self.aniZipMappings(entryID: tab.id, finished: tab.status == "FINISHED")
                        return (tab.id, response)
                    }
                }
                for await (id, response) in group {
                    aniZip[id] = response
                }
            }
        }

        var episodes: [Int: [NuvioVideo]] = [:]
        for (index, tab) in tabs.enumerated() {
            episodes[tab.id] = AniListMetaBuilder.episodes(of: tab, season: index + 1, aniZip: aniZip[tab.id]?.episodes ?? [:])
        }

        // Pictures of the first entry that has them, in tab order; with "Each Entry", a second
        // season without pictures takes its first season's.
        let isFilm = tabs.count == 1 && AniListMetaBuilder.isMovie(tabs[0])
        var artwork = AniListMetaBuilder.Artwork.empty
        if AniListSettings.usesEpisodeDetails {
            for tab in tabs where !artwork.isComplete {
                artwork = artwork.filled(by: await Self.entryArtwork(entryID: tab.id, aniZip: aniZip[tab.id], isFilm: isFilm))
            }
            if !isFilm {
                artwork = await Self.borrowingFromEarlierSeasons(artwork, entryID: tabs[0].id, known: tabs[0])
            }
        }

        guard let meta = AniListMetaBuilder.meta(tabs: tabs, episodes: episodes, language: language, artwork: artwork) else {
            throw DetailsError.notFound
        }
        let tabTitles = AniListMetaBuilder.tabTitles(tabs, language: language)
        let seasonByEntry = Dictionary(uniqueKeysWithValues: tabs.enumerated().map { ($1.id, $0 + 1) })
        let related = AniListMetaBuilder.related(tabs: tabs, language: language)
        // Under the series' id and its entries' too, however the title was opened.
        for key in Set([meta.id, id] + tabs.map { AniListMetaBuilder.metaID($0.id) }) {
            AniListTitleIndex.store(metaID: key, tabTitles: tabTitles, seasonByEntry: seasonByEntry, related: related)
        }
        return meta
    }

    /// Entries by id, from disk while they are fresh: finished ones keep a week, airing ones an hour.
    private static func fetchEntries(_ ids: [Int]) async throws -> [AniListMedia] {
        let variables: [String: Any?] = ["ids": ids, "perPage": max(ids.count, 1)]
        if let cached = await AniListClient.shared.cached(AniListQueries.entries, variables: variables),
           let media = try? decoder.decode(AniListPageResponse.self, from: cached.data).data?.Page?.media,
           !media.isEmpty {
            let finished = media.allSatisfy { $0.status == "FINISHED" || $0.status == "CANCELLED" }
            if cached.age < (finished ? finishedTTL : airingTTL) {
                return media
            }
        }
        let data = try await AniListClient.shared.query(AniListQueries.entries, variables: variables, ttl: 0)
        return try decoder.decode(AniListPageResponse.self, from: data).data?.Page?.media ?? []
    }

    /// What api.ani.zip knows about one AniList entry: its episodes, TheTVDB's pictures of the
    /// series and its TMDB id. Kept a week for finished entries, a day for the rest.
    static func aniZipMappings(entryID: Int, finished: Bool) async -> AniZipMappingsResponse? {
        guard let url = URL(string: "https://api.ani.zip/mappings?anilist_id=\(entryID)"),
              let data = try? await AniListClient.shared.get(url, ttl: finished ? finishedTTL : aniZipTTL) else { return nil }
        return try? decoder.decode(AniZipMappingsResponse.self, from: data)
    }

    // MARK: Pictures

    /// The pictures of one entry: TheTVDB's by way of ani.zip, then what is missing from TMDB
    /// (with TMDB on in Settings, its key and artwork) and from Metahub, where Cinemeta takes
    /// its pictures. Both are found by ids, never by name: ani.zip's, or arm-server's IMDb id
    /// when ani.zip has none. A logo is taken only when it is one (`AniListClient.isLogo`), so
    /// a still never stands in the hero's title; with no logo, the title's name stays.
    static func entryArtwork(
        entryID: Int,
        aniZip: AniZipMappingsResponse?,
        isFilm: Bool
    ) async -> AniListMetaBuilder.Artwork {
        var artwork = AniListMetaBuilder.Artwork(background: aniZip?.fanart)
        artwork.logo = await checkedLogo(aniZip?.clearLogo)
        guard !artwork.isComplete else { return artwork }

        // Ids from the offline tables first, then ani.zip's, then arm-server's.
        let offline = await AniListOfflineMaps.shared.entry(aniListID: entryID)
        let mappings = aniZip?.mappings
        let tmdbID = (isFilm ? offline?.tmdbMovie : offline?.tmdbTV) ?? mappings?.themoviedbID
        if let tmdbID,
           let found = await TmdbDetailsService.artwork(tmdbId: tmdbID, mediaType: isFilm ? "movie" : "tv") {
            artwork.background = artwork.background ?? found.background
            if artwork.logo == nil { artwork.logo = await checkedLogo(found.logo) }
        }
        guard !artwork.isComplete else { return artwork }

        var imdbID = offline?.imdb ?? mappings?.imdbID
        if imdbID == nil { imdbID = await armIMDbID(aniListID: entryID) }
        guard let imdbID, let metahub = metahubArtwork(imdbID: imdbID) else { return artwork }
        if artwork.logo == nil { artwork.logo = await checkedLogo(metahub.logo.absoluteString) }
        if artwork.background == nil, await AniListClient.shared.imageExists(metahub.background) {
            artwork.background = metahub.background.absoluteString
        }
        return artwork
    }

    private static func checkedLogo(_ candidate: String?) async -> String? {
        guard let candidate, let url = URL(string: candidate), await AniListClient.shared.isLogo(url) else { return nil }
        return candidate
    }

    /// What an entry still lacks, from its earlier seasons, at most three back: a second season
    /// new on ani.zip has no pictures yet, but its first has. `known` is the entry when its
    /// relations are at hand; otherwise each step asks AniList once and keeps the answer a week.
    static func borrowingFromEarlierSeasons(
        _ artwork: AniListMetaBuilder.Artwork,
        entryID: Int,
        known: AniListMedia?
    ) async -> AniListMetaBuilder.Artwork {
        var artwork = artwork
        var current = known?.id == entryID ? known : nil
        var currentID = entryID
        var seen: Set<Int> = [entryID]
        var steps = 0
        while steps < 3, !artwork.isComplete, !Task.isCancelled {
            steps += 1
            let media: AniListMedia?
            if let current, current.relations != nil {
                media = current
            } else {
                media = await prequels(of: currentID)
            }
            guard let media, let previousID = AniListMetaBuilder.previousSeason(of: media),
                  seen.insert(previousID).inserted else { break }
            let zip = await aniZipMappings(entryID: previousID, finished: true)
            artwork = artwork.filled(by: await entryArtwork(entryID: previousID, aniZip: zip, isFilm: false))
            current = nil
            currentID = previousID
        }
        return artwork
    }

    /// IMDb ids of an AniList season's earlier seasons, the nearest first, back to the first:
    /// a trailer to show when the season has none (Top Shelf). Unlike add-on ids, a different
    /// TheTVDB show is fine here.
    static func earlierSeasonIMDbIDs(metaID: String, limit: Int = 5) async -> [String] {
        guard AniListSettings.opensTitles, let id = AniListMetaBuilder.aniListID(from: metaID),
              var current = await prequels(of: id) else { return [] }
        var found: [String] = []
        for _ in 0..<limit {
            guard let previous = AniListMetaBuilder.previousSeason(of: current) else { break }
            if let imdb = await AniListOfflineMaps.shared.imdb(aniListID: previous), !found.contains(imdb) {
                found.append(imdb)
            }
            guard let next = await prequels(of: previous) else { break }
            current = next
        }
        return found
    }

    static func prequels(of id: Int) async -> AniListMedia? {
        guard let data = try? await AniListClient.shared.query(
            AniListQueries.prequels, variables: ["id": id], ttl: finishedTTL, notesStatus: false
        ) else { return nil }
        return try? decoder.decode(AniListMediaResponse.self, from: data).data?.Media
    }

    /// The IMDb id of an AniList title, for Trailerio's and IMDb's trailers only: the offline
    /// tables', else ani.zip's, else arm-server's. It is never written to the title, whose streams and ratings go by its
    /// AniList id.
    static func trailerIMDbID(metaID: String) async -> String? {
        guard AniListSettings.opensTitles, let id = AniListMetaBuilder.aniListID(from: metaID) else { return nil }
        if let imdbID = await AniListOfflineMaps.shared.imdb(aniListID: id) { return imdbID }
        if let imdbID = await aniZipMappings(entryID: id, finished: false)?.mappings?.imdbID {
            return imdbID
        }
        if let imdbID = await armIMDbID(aniListID: id) { return imdbID }
        // A season too new for all of them: the earlier seasons' show.
        return await AniListStreamIds.inherited(entryID: id)?.imdb
    }

    /// The IMDb id arm-server has for an AniList entry. Kept a week.
    static func armIMDbID(aniListID: Int) async -> String? {
        guard let url = URL(string: "https://arm.haglund.dev/api/v2/ids?source=anilist&id=\(aniListID)"),
              let data = try? await AniListClient.shared.get(url, ttl: finishedTTL) else { return nil }
        return armIMDbID(in: data)
    }

    static func armIMDbID(in data: Data) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let imdb = object["imdb"] as? String else { return nil }
        let id = imdb.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard id.hasPrefix("tt"), id.count > 2, id.dropFirst(2).allSatisfy(\.isNumber) else { return nil }
        return id
    }

    /// Metahub's logo and background of an IMDb title, as Cinemeta gives them.
    static func metahubArtwork(imdbID: String) -> (logo: URL, background: URL)? {
        let id = imdbID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard id.hasPrefix("tt"), id.count > 2, id.dropFirst(2).allSatisfy(\.isNumber),
              let logo = URL(string: "https://images.metahub.space/logo/medium/\(id)/img"),
              let background = URL(string: "https://images.metahub.space/background/medium/\(id)/img") else { return nil }
        return (logo, background)
    }

    /// The background and logo for Home's hero while an AniList card is focused, from ani.zip,
    /// TMDB and Metahub only, so moving along a row costs no AniList requests.
    static func heroArtwork(for card: NuvioMeta) async -> AniListMetaBuilder.Artwork? {
        guard AniListSettings.opensTitles, AniListSettings.usesEpisodeDetails,
              let entryID = AniListMetaBuilder.aniListID(from: card.id) else { return nil }
        let isFilm = card.type == "movie"
        let response = await aniZipMappings(entryID: entryID, finished: card.status == AniListMetaBuilder.status("FINISHED"))
        var artwork = await entryArtwork(entryID: entryID, aniZip: response, isFilm: isFilm)
        if !isFilm {
            artwork = await borrowingFromEarlierSeasons(artwork, entryID: entryID, known: nil)
        }
        return artwork == .empty ? nil : artwork
    }

    /// AniList's score of a title, next to the other ratings:
    /// - an AniList title: the card's own when it has it (Continue Watching keeps no ratings);
    /// - a Cinemeta/TMDB anime the offline tables know: the film, or the first season (the
    ///   franchise's main entry; one IMDb title stands for every season).
    /// One small request, kept a day.
    static func ratings(for meta: NuvioMeta) async -> [NuvioExternalRating] {
        guard AniListSettings.showsScore, AddonRatingsService.isSourceEnabled(AniListMetaBuilder.ratingSource) else { return [] }
        let id: Int
        if let own = AniListMetaBuilder.aniListID(from: meta.id) {
            let carried = (meta.externalRatings ?? []).filter { $0.source == AniListMetaBuilder.ratingSource }
            guard carried.isEmpty else { return carried }
            id = own
        } else if let mapped = await mappedEntry(for: meta) {
            id = mapped
        } else {
            return []
        }
        guard let data = try? await AniListClient.shared.query(
                AniListQueries.score, variables: ["id": id], ttl: scoreTTL, notesStatus: false
              ),
              let media = try? decoder.decode(AniListMediaResponse.self, from: data).data?.Media,
              let rating = AniListMetaBuilder.rating(media) else { return [] }
        return [rating]
    }

    static let scoreTTL: TimeInterval = 24 * 3600

    /// The AniList entry a Cinemeta/TMDB title stands for, by the offline tables only (no
    /// request): the film, or the entry with TheTVDB's first episode, or the only entry.
    static func mappedEntry(for meta: NuvioMeta) async -> Int? {
        guard !AniListMetaBuilder.isAniListID(meta.id) else { return nil }
        let imdb = NuvioMeta.canonicalImdbID(from: meta.imdbId ?? meta.id)
        let tmdb = meta.tmdbId ?? (meta.id.hasPrefix("tmdb:") ? Int(meta.id.dropFirst(5).prefix { $0 != ":" }) : nil)
        guard imdb != nil || tmdb != nil else { return nil }
        let maps = AniListOfflineMaps.shared
        guard meta.isSeries else { return await maps.film(imdb: imdb, tmdbMovie: tmdb) }
        if let first = await maps.aniListEpisode(imdb: imdb, tmdbTV: tmdb, season: 1, episode: 1) {
            return first.aniListID
        }
        let all = await maps.aniListIDs(tmdbTV: tmdb, imdb: imdb)
        return all.count == 1 ? all.first : nil
    }

    /// The title as the library services (Trakt, Simkl, MDBList, WeTrakr) know it: an AniList
    /// title with the IMDb and TMDB ids it maps to (they keep the whole show; Simkl also takes the
    /// `anilist:` id itself, so it keeps the season). Anything else as it is.
    static func libraryMeta(for meta: NuvioMeta) async -> NuvioMeta {
        guard let id = AniListMetaBuilder.aniListID(from: meta.id), meta.imdbId == nil || meta.tmdbId == nil else { return meta }
        let imdb: String?
        if let known = meta.imdbId {
            imdb = known
        } else {
            imdb = await trailerIMDbID(metaID: meta.id)
        }
        let entry = await AniListOfflineMaps.shared.entry(aniListID: id)
        let tmdb = meta.tmdbId ?? (meta.isSeries ? entry?.tmdbTV : entry?.tmdbMovie)
        guard imdb != nil || tmdb != nil else { return meta }
        return meta.withLibraryIDs(imdbId: imdb, tmdbId: tmdb)
    }

    /// The title MDBList and the rating add-ons are asked about: an AniList title by the IMDb id
    /// it maps to (their ratings are the whole show's), anything else as it is. nil = an AniList
    /// title nothing maps.
    static func ratingsMeta(for meta: NuvioMeta) async -> NuvioMeta? {
        guard AniListMetaBuilder.isAniListID(meta.id) else { return meta }
        guard let imdb = await trailerIMDbID(metaID: meta.id) else { return nil }
        return NuvioMeta(id: imdb, name: meta.name, imdbId: imdb, type: meta.isSeries ? "series" : "movie")
    }

    /// Characters with their Japanese voice actors, and AniList's recommendations.
    static func extras(metaID: String) async -> (people: [TmdbPersonMetadata], recommendations: [RelatedTitle]) {
        guard AniListSettings.opensTitles, let id = AniListMetaBuilder.aniListID(from: metaID),
              let data = try? await AniListClient.shared.query(AniListQueries.extras, variables: ["id": id], ttl: finishedTTL),
              let media = try? decoder.decode(AniListMediaResponse.self, from: data).data?.Media else {
            return ([], [])
        }
        let language = AniListSettings.titleLanguage
        let people = (media.characters?.edges ?? []).compactMap { edge -> TmdbPersonMetadata? in
            guard let name = edge.node?.name?.full, !name.isEmpty else { return nil }
            let voice = edge.voiceActors?.first?.name?.full
            let role = voice ?? (edge.role == "MAIN" ? "Main" : edge.role == "SUPPORTING" ? "Supporting" : nil)
            return TmdbPersonMetadata(name: name, role: role, profileURL: edge.node?.image?.large, tmdbId: nil)
        }
        let recommendations = (media.recommendations?.nodes ?? [])
            .filter { ($0.rating ?? 0) > 0 }
            .compactMap { $0.mediaRecommendation }
            .filter { $0.type == nil || $0.type == "ANIME" }
            .map { AniListMetaBuilder.relatedTitle($0, relation: nil, language: language) }
        return (people, recommendations)
    }

    static func clearCache() async {
        await AniListClient.shared.clearCache()
    }

    /// Asks AniList for "Frieren" right now, past the saved answers: "OK · 5 results" or why not.
    /// It leaves the status alone, so an earlier failure stays readable there.
    static func testConnection() async -> String {
        let variables: [String: Any?] = ["search": "Frieren", "perPage": 5, "isAdult": false]
        do {
            let answer = try await AniListClient.shared.answer(AniListQueries.search, variables: variables, ttl: 0, notesStatus: false)
            let media = try decoder.decode(AniListPageResponse.self, from: answer.data).data?.Page?.media ?? []
            let result = media.isEmpty ? "AniList answered with no results" : "OK · \(media.count) results"
            return answer.isSaved ? "\(result) · saved answer, AniList didn't answer now" : result
        } catch let error as DecodingError {
            return "Unreadable answer: \(error)"
        } catch {
            return "Failed: \(AniListDiagnostics.describe(error))"
        }
    }

    /// What Home's AniList rows last did, for Settings.
    static func homeStatusText() -> String {
        AniListSettings.isEnabled ? AniListDiagnostics.text(.home) : "Off"
    }

    /// What the last search did with AniList, for Settings.
    static func searchStatusText() -> String {
        AniListSettings.isEnabled ? AniListDiagnostics.text(.search) : "Off"
    }

    /// The service's own view, for Settings: is it on, and the last answer from AniList.
    static func statusText() async -> String {
        guard AniListSettings.isEnabled else { return "Off" }
        let status = await AniListClient.shared.status
        let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
        func at(_ date: Date) -> String {
            DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short)
        }
        if let failure = status.lastFailure, failure > (status.lastSuccess ?? .distantPast) {
            return "Error at \(at(failure)): \(status.lastFailureMessage ?? "unknown")"
        }
        if let success = status.lastSuccess {
            return "OK · last answer at \(at(success))"
        }
        return "On · no request yet (\(time))"
    }
}

/// What the details screen needs about an AniList title beyond `NuvioMeta`: the names of its
/// tabs, the tab of each entry, and its Related row. Filled when the title loads.
enum AniListTitleIndex {
    private struct Entry {
        let tabTitles: [Int: String]
        let seasonByEntry: [Int: Int]
        let related: [RelatedTitle]
    }

    private static let lock = NSLock()
    private static var entries: [String: Entry] = [:]

    static func store(metaID: String, tabTitles: [Int: String], seasonByEntry: [Int: Int], related: [RelatedTitle]) {
        lock.lock()
        defer { lock.unlock() }
        entries[metaID.lowercased()] = Entry(tabTitles: tabTitles, seasonByEntry: seasonByEntry, related: related)
    }

    static func tabTitle(metaID: String, season: Int) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return entries[metaID.lowercased()]?.tabTitles[season]
    }

    /// The tab an entry opened from a card shows first: `anilist:182255` inside `anilist:154587`.
    static func season(ofEntry entryID: String, inMeta metaID: String) -> Int? {
        guard let entry = AniListMetaBuilder.aniListID(from: entryID) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return entries[metaID.lowercased()]?.seasonByEntry[entry]
    }

    static func related(metaID: String) -> [RelatedTitle] {
        lock.lock()
        defer { lock.unlock() }
        return entries[metaID.lowercased()]?.related ?? []
    }
}

extension NuvioMeta {
    /// The same title with these IMDb and TMDB ids (for the library services).
    func withLibraryIDs(imdbId: String?, tmdbId: Int?) -> NuvioMeta {
        NuvioMeta(
            id: id,
            name: name,
            description: description,
            posterUrl: posterUrl,
            backgroundUrl: backgroundUrl,
            logoUrl: logoUrl,
            imdbId: imdbId,
            tmdbId: tmdbId,
            type: type,
            year: year,
            genres: genres,
            rating: rating,
            releaseInfo: releaseInfo,
            runtime: runtime,
            cast: cast,
            director: director,
            writer: writer,
            certification: certification,
            country: country,
            language: language,
            released: released,
            status: status,
            videos: videos,
            trailerYtIds: trailerYtIds,
            externalRatings: externalRatings,
            posterShape: posterShape,
            isFromAddon: isFromAddon,
            landscapePosterUrl: landscapePosterUrl
        )
    }
}
