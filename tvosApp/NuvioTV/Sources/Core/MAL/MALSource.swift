import Foundation

// MARK: - Which source a title comes from

/// Where an anime title's details come from: AniList (`anilist:ID`) or MyAnimeList (`mal:ID`).
/// Both are built by the same engine (`AniListService`, `AniListMetaBuilder`), which reads
/// `current` for the ids it makes and reads: the work on a `mal:` title runs inside
/// `AnimeSource.$current.withValue(.mal)`, where `mal:ID` and MAL's entry ids are what
/// `metaID`, `episodeID` and `aniListID(from:)` make and read.
enum AnimeSource: String, Sendable {
    case anilist
    case mal

    @TaskLocal static var current: AnimeSource = .anilist

    var prefix: String {
        switch self {
        case .anilist: return "anilist:"
        case .mal: return "mal:"
        }
    }

    var name: String {
        switch self {
        case .anilist: return "AniList"
        case .mal: return "MyAnimeList"
        }
    }

    /// The source and entry id of `anilist:123`, `MAL:456:7`…; nil for any other id.
    static func entry(from id: String) -> (source: AnimeSource, id: Int)? {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for source in [AnimeSource.anilist, .mal] where trimmed.hasPrefix(source.prefix) {
            let rest = trimmed.dropFirst(source.prefix.count)
            guard let first = rest.split(separator: ":", omittingEmptySubsequences: false).first,
                  let value = Int(first), value > 0 else { return nil }
            return (source, value)
        }
        return nil
    }

    /// The MAL id in `mal:123` or `mal:123:4`.
    static func malID(from id: String) -> Int? {
        guard let found = entry(from: id), found.source == .mal else { return nil }
        return found.id
    }

    /// A `mal:` title built here from MyAnimeList (MyAnimeList → MAL Titles on).
    static func isMALTitle(_ id: String) -> Bool {
        MALSettings.opensTitles && malID(from: id) != nil
    }

    /// A title this engine builds: an AniList one, or a MyAnimeList one with MAL Titles on.
    /// Wherever it is asked from: it doesn't read `current`.
    static func isAnimeTitleID(_ id: String) -> Bool {
        guard let found = entry(from: id) else { return false }
        return found.source == .anilist || MALSettings.opensTitles
    }

    /// The source of a title id; `current` for any other id.
    static func of(_ id: String) -> AnimeSource {
        entry(from: id)?.source ?? current
    }

    /// The badge a card of this title carries in Search and on Home.
    static func badge(for id: String) -> CollectionOriginPresentation? {
        switch entry(from: id)?.source {
        case .anilist: return AniListService.searchBadge
        case .mal: return MALSettings.opensTitles ? AniListService.malBadge : nil
        case nil: return nil
        }
    }

    /// The offline tables' entry of an entry of the current source (a MAL entry by the AniList
    /// entry it maps to).
    static func offlineEntry(_ entryID: Int) async -> AniListOfflineMaps.Entry? {
        guard let aniList = await aniListEntry(entryID) else { return nil }
        return await AniListOfflineMaps.shared.entry(aniListID: aniList)
    }

    /// The IMDb id the offline tables give an entry of the current source.
    static func offlineIMDb(_ entryID: Int) async -> String? {
        guard let aniList = await aniListEntry(entryID) else { return nil }
        return await AniListOfflineMaps.shared.imdb(aniListID: aniList)
    }

    /// The AniList entry of an entry of the current source, by the offline tables only.
    static func aniListEntry(_ entryID: Int) async -> Int? {
        guard current == .mal else { return entryID }
        return await AniListOfflineMaps.shared.aniListID(mal: entryID)
    }

    /// The MAL entry of an entry of the current source.
    static func malEntry(_ entryID: Int) async -> Int? {
        guard current != .mal else { return entryID }
        return await MALEpisodeRatings.malID(aniListID: entryID)
    }
}

// MARK: - Settings

extension SettingsKey {
    static let malTitles = "nuvio.tv.settings.integrations.malTitles"
    static let malSearch = "nuvio.tv.settings.integrations.malSearch"
}

extension MALSettings {
    /// MAL's titles open with MyAnimeList's own data (`mal:ID`, from Tenrai, else MAL's own
    /// API): catalogs, search, details, seasons, episodes, cast, recommendations, streams and
    /// the MAL account. Off, they open as the AniList titles they map to.
    static var opensTitles: Bool { opensTitles(in: ProfileSettings.current) }

    static func opensTitles(in store: UserDefaults) -> Bool {
        isEnabled(in: store) && (store.object(forKey: SettingsKey.malTitles) == nil || store.bool(forKey: SettingsKey.malTitles))
    }

    /// Anime from MyAnimeList among the search results.
    static var searchesMAL: Bool {
        let store = ProfileSettings.current
        return opensTitles(in: store) && (store.object(forKey: SettingsKey.malSearch) == nil || store.bool(forKey: SettingsKey.malSearch))
    }
}

// MARK: - Tenrai's answers (Jikan v4), read with snake_case keys

struct TenraiOne<Value: Decodable>: Decodable {
    var data: Value? = nil
}

struct TenraiMany<Value: Decodable>: Decodable {
    var data: [Value]? = nil
    var pagination: TenraiPagination? = nil
}

struct TenraiPagination: Decodable {
    var hasNextPage: Bool? = nil
}

struct TenraiImages: Decodable {
    var jpg: TenraiPicture? = nil
    var webp: TenraiPicture? = nil
}

struct TenraiPicture: Decodable {
    var imageUrl: String? = nil
    var smallImageUrl: String? = nil
    var largeImageUrl: String? = nil
}

struct TenraiNamed: Decodable {
    var malId: Int? = nil
    var name: String? = nil
}

struct TenraiDay: Decodable {
    var day: Int? = nil
    var month: Int? = nil
    var year: Int? = nil
}

/// `anime/{id}/full`, and each result of a search.
struct TenraiDetails: Decodable {
    let malId: Int
    var title: String? = nil
    var titleEnglish: String? = nil
    var titleJapanese: String? = nil
    var titleSynonyms: [String]? = nil
    var images: TenraiImages? = nil
    var trailer: Trailer? = nil
    var type: String? = nil
    var source: String? = nil
    var episodes: Int? = nil
    var status: String? = nil
    var aired: Aired? = nil
    var duration: String? = nil
    var rating: String? = nil
    var score: Double? = nil
    var synopsis: String? = nil
    var season: String? = nil
    var year: Int? = nil
    var studios: [TenraiNamed]? = nil
    var genres: [TenraiNamed]? = nil
    var explicitGenres: [TenraiNamed]? = nil
    var relations: [Relation]? = nil

    struct Trailer: Decodable {
        var youtubeId: String? = nil
    }

    struct Aired: Decodable {
        var prop: Prop? = nil

        struct Prop: Decodable {
            var from: TenraiDay? = nil
            var to: TenraiDay? = nil
        }
    }

    struct Relation: Decodable {
        var relation: String? = nil
        var entry: [Entry]? = nil
    }

    struct Entry: Decodable {
        let malId: Int
        var type: String? = nil
        var name: String? = nil
    }
}

/// An anime as people, characters and recommendations name it.
struct TenraiAnimeRef: Decodable {
    let malId: Int
    var title: String? = nil
    var images: TenraiImages? = nil
}

struct TenraiPersonRef: Decodable {
    let malId: Int
    var name: String? = nil
    var images: TenraiImages? = nil
}

/// One character of `anime/{id}/characters`.
struct TenraiCharacterRole: Decodable {
    var character: TenraiPersonRef? = nil
    var role: String? = nil
    var voiceActors: [VoiceActor]? = nil

    struct VoiceActor: Decodable {
        var person: TenraiPersonRef? = nil
        var language: String? = nil
    }
}

struct TenraiRecommendation: Decodable {
    var entry: TenraiAnimeRef? = nil
}

/// `people/{id}/full`.
struct TenraiPersonFull: Decodable {
    let malId: Int
    var name: String? = nil
    var givenName: String? = nil
    var familyName: String? = nil
    var images: TenraiImages? = nil
    var birthday: String? = nil
    var about: String? = nil
    var voices: [Voice]? = nil

    struct Voice: Decodable {
        var role: String? = nil
        var anime: TenraiAnimeRef? = nil
        var character: TenraiPersonRef? = nil
    }
}

/// `characters/{id}/full`.
struct TenraiCharacterFull: Decodable {
    let malId: Int
    var name: String? = nil
    var nameKanji: String? = nil
    var images: TenraiImages? = nil
    var about: String? = nil
    var anime: [Appearance]? = nil

    struct Appearance: Decodable {
        var role: String? = nil
        var anime: TenraiAnimeRef? = nil
    }
}

// MARK: - MAL's own API (v2), read with snake_case keys

struct MALOfficialAnime: Decodable {
    let id: Int
    var title: String? = nil
    var mainPicture: MALOfficialPicture? = nil
    var alternativeTitles: AlternativeTitles? = nil
    var startDate: String? = nil
    var endDate: String? = nil
    var synopsis: String? = nil
    var mean: Double? = nil
    var mediaType: String? = nil
    var status: String? = nil
    var genres: [MALOfficialNamed]? = nil
    var numEpisodes: Int? = nil
    var averageEpisodeDuration: Int? = nil
    var rating: String? = nil
    var startSeason: Season? = nil
    var studios: [MALOfficialNamed]? = nil
    var source: String? = nil
    var relatedAnime: [Related]? = nil
    var recommendations: [Recommendation]? = nil

    struct AlternativeTitles: Decodable {
        var synonyms: [String]? = nil
        var en: String? = nil
        var ja: String? = nil
    }

    struct Season: Decodable {
        var year: Int? = nil
        var season: String? = nil
    }

    struct Related: Decodable {
        var node: MALOfficialNode? = nil
        var relationType: String? = nil
    }

    struct Recommendation: Decodable {
        var node: MALOfficialNode? = nil
        var numRecommendations: Int? = nil
    }
}

struct MALOfficialNode: Decodable {
    let id: Int
    var title: String? = nil
    var mainPicture: MALOfficialPicture? = nil
}

struct MALOfficialPicture: Decodable {
    var medium: String? = nil
    var large: String? = nil
}

struct MALOfficialNamed: Decodable {
    var id: Int? = nil
    var name: String? = nil
}

struct MALOfficialList: Decodable {
    var data: [Item]? = nil

    struct Item: Decodable {
        var node: MALOfficialAnime? = nil
    }
}

// MARK: - MyAnimeList as a source

/// MyAnimeList's titles for the engine: MAL entries read from Tenrai (else MAL's own API, with
/// the viewer's Client ID) and turned into the same media AniList answers with, so seasons,
/// episodes (ani.zip by MAL id), pictures, streams and the account work as for AniList.
enum MALSource {
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    /// What MAL's own API is asked for an entry.
    static let officialFields = [
        "id", "title", "main_picture", "alternative_titles", "start_date", "end_date", "synopsis", "mean",
        "media_type", "status", "genres", "num_episodes", "average_episode_duration", "rating", "start_season",
        "studios", "source", "related_anime", "recommendations",
    ].joined(separator: ",")

    /// What MAL's own API is asked for a card (catalogs, search).
    static let officialCardFields = "alternative_titles,synopsis,media_type,start_season,mean,genres,num_episodes,status"

    static let peopleTTL: TimeInterval = 24 * 3600

    // MARK: Entries

    /// MAL entries by id as media, for the engine, one after another (Tenrai takes two a
    /// second). Throws when none could be read.
    static func entries(_ ids: [Int]) async throws -> [AniListMedia] {
        var found: [AniListMedia] = []
        var failure: Error?
        var seen = Set<Int>()
        for id in ids where seen.insert(id).inserted {
            if Task.isCancelled { break }
            do {
                found.append(try await entry(id))
            } catch {
                failure = error
            }
        }
        if found.isEmpty, let failure { throw failure }
        return found
    }

    /// One MAL entry: Tenrai's saved answer while fresh (a week for a finished entry, an hour
    /// for the rest), else Tenrai, else MAL's own API.
    static func entry(_ id: Int) async throws -> AniListMedia {
        let path = "anime/\(id)/full"
        if let saved = await TenraiClient.shared.saved(path),
           let details = try? decoder.decode(TenraiOne<TenraiDetails>.self, from: saved.data).data {
            let built = media(details, hints: await formatHints(relationIDs(details)))
            let finished = built.status == "FINISHED" || built.status == "CANCELLED"
            if saved.age < (finished ? AniListService.finishedTTL : AniListService.airingTTL) {
                SourceLog.record(id, "Tenrai (saved)")
                return built
            }
        }
        do {
            let data = try await TenraiClient.shared.get(path, ttl: 0)
            guard let details = try? decoder.decode(TenraiOne<TenraiDetails>.self, from: data).data else {
                throw TenraiClient.Failure.status(0)
            }
            SourceLog.record(id, "Tenrai")
            return media(details, hints: await formatHints(relationIDs(details)))
        } catch {
            guard MALOfficialClient.isAvailable else { throw error }
            let data = try await MALOfficialClient.shared.get("anime/\(id)", query: [("fields", officialFields)], ttl: AniListService.airingTTL)
            guard let anime = try? decoder.decode(MALOfficialAnime.self, from: data) else { throw error }
            SourceLog.record(id, "MAL API")
            let related = (anime.relatedAnime ?? []).compactMap { $0.node?.id }
            return media(anime, hints: await formatHints(related))
        }
    }

    static func relationIDs(_ details: TenraiDetails) -> [Int] {
        (details.relations ?? []).flatMap { relation in
            (relation.entry ?? []).filter { $0.type?.lowercased() == "anime" }.map(\.malId)
        }
    }

    /// The formats the offline tables give MAL entries ("TV", "MOVIE"…): MyAnimeList names an
    /// entry's relations without their formats, and the season chain needs them to tell a
    /// season from a film or a special without asking for each.
    static func formatHints(_ ids: [Int]) async -> [Int: String] {
        var hints: [Int: String] = [:]
        let maps = AniListOfflineMaps.shared
        for id in Set(ids) {
            guard let aniList = await maps.aniListID(mal: id),
                  let format = normalizedFormat(await maps.entry(aniListID: aniList)?.type) else { continue }
            hints[id] = format
        }
        return hints
    }

    static func normalizedFormat(_ type: String?) -> String? {
        guard let type = type?.uppercased().replacingOccurrences(of: " ", with: "_"), !type.isEmpty else { return nil }
        switch type {
        case "TV", "TV_SHORT", "MOVIE", "OVA", "ONA", "SPECIAL", "MUSIC": return type
        case "TV_SPECIAL": return "SPECIAL"
        default: return nil
        }
    }

    // MARK: Into AniList's shape

    /// Tenrai's type ("TV", "Movie", "TV Special"…) as an AniList format.
    static func format(tenraiType type: String?) -> String? {
        switch type?.lowercased() {
        case "tv": return "TV"
        case "movie": return "MOVIE"
        case "ova": return "OVA"
        case "ona": return "ONA"
        case "special", "tv special": return "SPECIAL"
        case "music", "cm", "pv": return "MUSIC"
        default: return nil
        }
    }

    /// MAL's media type ("tv", "tv_special"…) as an AniList format.
    static func format(officialType type: String?) -> String? {
        format(tenraiType: type?.replacingOccurrences(of: "_", with: " "))
    }

    /// "Finished Airing" or "finished_airing" as AniList's status.
    static func status(_ text: String?) -> String? {
        switch text?.lowercased().replacingOccurrences(of: "_", with: " ") {
        case "finished airing": return "FINISHED"
        case "currently airing": return "RELEASING"
        case "not yet aired": return "NOT_YET_RELEASED"
        default: return nil
        }
    }

    /// "Sequel", "Side story", "parent_story"… as AniList's relation types.
    static func relationType(_ text: String?) -> String {
        let key = (text ?? "").lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
        switch key {
        case "sequel": return "SEQUEL"
        case "prequel": return "PREQUEL"
        case "alternative_setting", "alternative_version": return "ALTERNATIVE"
        case "side_story": return "SIDE_STORY"
        case "parent_story", "full_story": return "PARENT"
        case "summary": return "SUMMARY"
        case "spin_off": return "SPIN_OFF"
        case "character": return "CHARACTER"
        case "adaptation": return "ADAPTATION"
        default: return "OTHER"
        }
    }

    /// "24 min per ep", "1 hr 45 min" → minutes.
    static func minutes(_ duration: String?) -> Int? {
        guard let duration = duration?.lowercased() else { return nil }
        var total = 0
        let words = duration.split(separator: " ").map(String.init)
        for (index, word) in words.enumerated() {
            guard let value = Int(word), index + 1 < words.count else { continue }
            let unit = words[index + 1]
            if unit.hasPrefix("hr") || unit.hasPrefix("hour") { total += value * 60 }
            if unit.hasPrefix("min") { total += value }
        }
        return total > 0 ? total : nil
    }

    /// "2017-01-11", "2017-01" or "2017", also at the start of "2017-01-11T00:00:00+00:00".
    static func date(_ text: String?) -> AniListDate? {
        guard let text, !text.isEmpty else { return nil }
        let parts = text.prefix(10).split(separator: "-").map { Int($0) }
        guard let year = parts.first ?? nil, year > 0 else { return nil }
        return AniListDate(
            year: year,
            month: parts.count > 1 ? parts[1] : nil,
            day: parts.count > 2 ? parts[2] : nil
        )
    }

    static func date(_ day: TenraiDay?) -> AniListDate? {
        guard let year = day?.year else { return nil }
        return AniListDate(year: year, month: day?.month, day: day?.day)
    }

    /// MAL's synopsis without its credit line.
    static func synopsis(_ text: String?) -> String? {
        guard var text = text else { return nil }
        text = text.replacingOccurrences(of: "[Written by MAL Rewrite]", with: "")
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func picture(_ images: TenraiImages?) -> String? {
        images?.jpg?.largeImageUrl ?? images?.jpg?.imageUrl ?? images?.webp?.largeImageUrl ?? images?.webp?.imageUrl
    }

    /// "Kamado, Tanjirou" → "Tanjirou Kamado", as AniList writes names.
    static func personName(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let parts = raw.components(separatedBy: ", ")
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return raw }
        return "\(parts[1]) \(parts[0])"
    }

    /// An entry from Tenrai's full answer.
    static func media(_ anime: TenraiDetails, hints: [Int: String] = [:]) -> AniListMedia {
        var media = AniListMedia(id: anime.malId)
        media.idMal = anime.malId
        media.type = "ANIME"
        media.format = format(tenraiType: anime.type)
        media.status = status(anime.status)
        media.episodes = anime.episodes.flatMap { $0 > 0 ? $0 : nil }
        media.duration = minutes(anime.duration)
        media.season = anime.season?.uppercased()
        media.seasonYear = anime.year
        media.malScore = anime.score.flatMap { $0 > 0 ? $0 : nil }
        media.averageScore = media.malScore.map { Int(($0 * 10).rounded()) }
        let genres = ((anime.genres ?? []) + (anime.explicitGenres ?? [])).compactMap(\.name)
        media.genres = genres.isEmpty ? nil : genres
        media.synonyms = anime.titleSynonyms
        media.isAdult = anime.rating?.hasPrefix("Rx") == true
        media.source = anime.source.map { $0.uppercased().replacingOccurrences(of: " ", with: "_") }
        media.title = AniListTitle(romaji: anime.title, english: anime.titleEnglish, native: anime.titleJapanese)
        media.coverImage = AniListCoverImage(large: picture(anime.images))
        media.description = synopsis(anime.synopsis)
        media.startDate = date(anime.aired?.prop?.from)
        media.endDate = date(anime.aired?.prop?.to)
        media.trailer = anime.trailer?.youtubeId.map { AniListTrailer(id: $0, site: "youtube") }
        let studios = (anime.studios ?? []).compactMap(\.name)
        if !studios.isEmpty {
            media.studios = AniListStudioConnection(nodes: studios.map { AniListStudio(name: $0, isAnimationStudio: true) })
        }
        if let relations = anime.relations {
            var edges: [AniListRelationEdge] = []
            for relation in relations {
                let type = relationType(relation.relation)
                for entry in relation.entry ?? [] {
                    let isAnime = entry.type?.lowercased() == "anime"
                    var node = AniListMedia(id: entry.malId)
                    node.type = isAnime ? "ANIME" : "MANGA"
                    node.idMal = isAnime ? entry.malId : nil
                    node.format = isAnime ? hints[entry.malId] : nil
                    node.title = AniListTitle(romaji: entry.name)
                    edges.append(AniListRelationEdge(relationType: type, node: node))
                }
            }
            media.relations = AniListRelationConnection(edges: edges)
        }
        return media
    }

    /// An entry from MAL's own API.
    static func media(_ anime: MALOfficialAnime, hints: [Int: String] = [:]) -> AniListMedia {
        var media = AniListMedia(id: anime.id)
        media.idMal = anime.id
        media.type = "ANIME"
        media.format = format(officialType: anime.mediaType)
        media.status = status(anime.status)
        media.episodes = anime.numEpisodes.flatMap { $0 > 0 ? $0 : nil }
        media.duration = anime.averageEpisodeDuration.flatMap { $0 > 0 ? max(1, $0 / 60) : nil }
        media.season = anime.startSeason?.season?.uppercased()
        media.seasonYear = anime.startSeason?.year
        media.malScore = anime.mean.flatMap { $0 > 0 ? $0 : nil }
        media.averageScore = media.malScore.map { Int(($0 * 10).rounded()) }
        let genres = (anime.genres ?? []).compactMap(\.name)
        media.genres = genres.isEmpty ? nil : genres
        media.synonyms = anime.alternativeTitles?.synonyms
        media.isAdult = anime.rating == "rx"
        media.source = anime.source?.uppercased()
        media.title = AniListTitle(
            romaji: anime.title,
            english: anime.alternativeTitles?.en.flatMap { $0.isEmpty ? nil : $0 },
            native: anime.alternativeTitles?.ja.flatMap { $0.isEmpty ? nil : $0 }
        )
        media.coverImage = AniListCoverImage(large: anime.mainPicture?.large ?? anime.mainPicture?.medium)
        media.description = synopsis(anime.synopsis)
        media.startDate = date(anime.startDate)
        media.endDate = date(anime.endDate)
        let studios = (anime.studios ?? []).compactMap(\.name)
        if !studios.isEmpty {
            media.studios = AniListStudioConnection(nodes: studios.map { AniListStudio(name: $0, isAnimationStudio: true) })
        }
        if let related = anime.relatedAnime {
            media.relations = AniListRelationConnection(edges: related.compactMap { item in
                guard let node = item.node else { return nil }
                var built = card(node)
                built.format = hints[node.id]
                return AniListRelationEdge(relationType: relationType(item.relationType), node: built)
            })
        }
        if let recommendations = anime.recommendations {
            media.recommendations = AniListRecommendationConnection(nodes: recommendations.compactMap { item in
                guard let node = item.node else { return nil }
                return AniListRecommendation(rating: max(item.numRecommendations ?? 1, 1), mediaRecommendation: card(node))
            })
        }
        return media
    }

    /// An entry MAL's own API names (a relation, a recommendation).
    static func card(_ node: MALOfficialNode) -> AniListMedia {
        var media = AniListMedia(id: node.id)
        media.idMal = node.id
        media.type = "ANIME"
        media.title = AniListTitle(romaji: node.title)
        media.coverImage = AniListCoverImage(large: node.mainPicture?.large ?? node.mainPicture?.medium)
        return media
    }

    /// An entry a person, character or recommendation names.
    static func media(ref: TenraiAnimeRef, hints: [Int: String] = [:]) -> AniListMedia {
        var media = AniListMedia(id: ref.malId)
        media.idMal = ref.malId
        media.type = "ANIME"
        media.format = hints[ref.malId]
        media.title = AniListTitle(romaji: ref.title)
        media.coverImage = AniListCoverImage(large: picture(ref.images))
        return media
    }

    /// A card of MAL's catalogs and lists.
    static func media(card item: TenraiAnime) -> AniListMedia {
        var media = AniListMedia(id: item.malID)
        media.idMal = item.malID
        media.type = "ANIME"
        media.format = format(tenraiType: item.type)
        media.seasonYear = item.year ?? item.aired?.prop?.from?.year
        media.malScore = item.score.flatMap { $0 > 0 ? $0 : nil }
        media.averageScore = media.malScore.map { Int(($0 * 10).rounded()) }
        let genres = (item.genres ?? []).compactMap(\.name)
        media.genres = genres.isEmpty ? nil : genres
        media.title = AniListTitle(romaji: item.title, english: item.titleEnglish, native: item.titleJapanese)
        media.coverImage = AniListCoverImage(large: item.images?.jpg?.largeImageURL ?? item.images?.jpg?.imageURL)
        media.description = synopsis(item.synopsis)
        media.trailer = item.trailer?.youtubeID.map { AniListTrailer(id: $0, site: "youtube") }
        return media
    }

    /// MAL cards (catalogs, lists), in their order, each title once.
    static func cards(_ anime: [TenraiAnime], language: AniListSettings.TitleLanguage) -> [NuvioMeta] {
        var seen = Set<Int>()
        let unique = anime.filter { seen.insert($0.malID).inserted }
        return AnimeSource.$current.withValue(.mal) {
            unique.map { AniListMetaBuilder.card(media(card: $0), language: language) }
        }
    }

    // MARK: Cast and recommendations

    /// Characters with their Japanese voice actors, and MAL's recommendations: Tenrai's, else
    /// the recommendations of MAL's own API.
    static func extras(entryID id: Int, language: AniListSettings.TitleLanguage) async -> (people: [TmdbPersonMetadata], recommendations: [RelatedTitle]) {
        let answers = await AniListClient.$isInteractive.withValue(true) { () async -> (Data?, Data?) in
            let characters = try? await TenraiClient.shared.get("anime/\(id)/characters", ttl: peopleTTL)
            let recommended = try? await TenraiClient.shared.get("anime/\(id)/recommendations", ttl: peopleTTL)
            return (characters, recommended)
        }
        let cast = answers.0.map { Self.people(from: $0) } ?? []
        var refs = answers.1.map { Self.recommendationRefs(from: $0) } ?? []
        if refs.isEmpty, MALOfficialClient.isAvailable,
           let data = try? await MALOfficialClient.shared.get("anime/\(id)", query: [("fields", officialFields)], ttl: AniListService.airingTTL),
           let anime = try? decoder.decode(MALOfficialAnime.self, from: data) {
            refs = (anime.recommendations ?? []).compactMap(\.node).map {
                TenraiAnimeRef(malId: $0.id, title: $0.title, images: TenraiImages(jpg: TenraiPicture(imageUrl: $0.mainPicture?.medium, largeImageUrl: $0.mainPicture?.large)))
            }
        }
        let hints = await formatHints(refs.map(\.malId))
        let recommendations = AnimeSource.$current.withValue(.mal) {
            refs.prefix(20).map { AniListMetaBuilder.relatedTitle(media(ref: $0, hints: hints), relation: nil, language: language) }
        }
        return (cast, recommendations)
    }

    /// The cast of `anime/{id}/characters`: main characters first, each with their Japanese
    /// voice actor, whose MAL page the card opens.
    static func people(from data: Data) -> [TmdbPersonMetadata] {
        guard let roles = try? decoder.decode(TenraiMany<TenraiCharacterRole>.self, from: data).data else { return [] }
        let main = roles.filter { $0.role == "Main" }
        let rest = roles.filter { $0.role != "Main" }
        return (main + rest).prefix(40).compactMap { role -> TmdbPersonMetadata? in
            guard let character = role.character, let name = personName(character.name) else { return nil }
            let actor = role.voiceActors?.first { $0.language == "Japanese" } ?? role.voiceActors?.first
            let voice = personName(actor?.person?.name)
            var person = TmdbPersonMetadata(
                name: name,
                role: voice ?? role.role,
                profileURL: picture(character.images),
                tmdbId: nil,
                aniListCharacterID: character.malId,
                aniListStaffID: voice == nil ? nil : actor?.person?.malId,
                aniListStaffImage: picture(actor?.person?.images)
            )
            person.peopleSource = AnimeSource.mal.rawValue
            return person
        }
    }

    static func recommendationRefs(from data: Data) -> [TenraiAnimeRef] {
        let items = (try? decoder.decode(TenraiMany<TenraiRecommendation>.self, from: data).data) ?? []
        var seen = Set<Int>()
        return items.compactMap(\.entry).filter { seen.insert($0.malId).inserted }
    }

    // MARK: Related row pictures

    /// Pictures of a title's related entries, which MyAnimeList names without one. With a MAL
    /// Client ID, MAL's own API gives the pictures of all of an entry's related entries in one
    /// request (one per season tab); what it doesn't give, Tenrai is asked for one by one, in the
    /// row's order and ahead of the Home rows, at most 40. `found` is called as pictures come in
    /// (at most once a second, and at the end) to draw the row again; they are kept for the
    /// session, and the answers on disk.
    static func fillRelatedPictures(metaID: String, entryIDs: [Int], found: @escaping @MainActor () -> Void) async {
        var missing = missingPictures(metaID: metaID)
        guard !missing.isEmpty else { return }
        var unshown = false
        var shownAt = Date.distantPast

        if MALOfficialClient.isAvailable {
            for id in entryIDs {
                if Task.isCancelled || missing.isEmpty { break }
                guard let data = try? await MALOfficialClient.shared.get("anime/\(id)", query: [("fields", officialFields)], ttl: AniListService.airingTTL),
                      let anime = try? decoder.decode(MALOfficialAnime.self, from: data) else { continue }
                for related in anime.relatedAnime ?? [] {
                    guard let node = related.node, missing.contains(node.id),
                          let poster = node.mainPicture?.large ?? node.mainPicture?.medium else { continue }
                    RelatedPictures.store(node.id, poster: poster, year: nil)
                    missing.removeAll { $0 == node.id }
                    unshown = true
                }
                if unshown, Date().timeIntervalSince(shownAt) >= 1 {
                    unshown = false
                    shownAt = Date()
                    await found()
                }
            }
        }

        for id in missing.prefix(40) {
            if Task.isCancelled { break }
            let data = try? await AniListClient.$isInteractive.withValue(true) {
                try await TenraiClient.shared.get("anime/\(id)", ttl: AniListService.finishedTTL)
            }
            guard let data, let details = try? decoder.decode(TenraiOne<TenraiDetails>.self, from: data).data,
                  let poster = picture(details.images) else { continue }
            RelatedPictures.store(id, poster: poster, year: details.year ?? details.aired?.prop?.from?.year)
            unshown = true
            if Date().timeIntervalSince(shownAt) >= 1 {
                unshown = false
                shownAt = Date()
                await found()
            }
        }
        if unshown { await found() }
    }

    /// The MAL entries of the Related row still without a picture, in the row's order.
    static func missingPictures(metaID: String) -> [Int] {
        AniListTitleIndex.related(metaID: metaID)
            .filter { $0.posterURL == nil }
            .compactMap { AnimeSource.malID(from: $0.id) }
    }

    /// A MyAnimeList title's entries, tab by tab: its episodes' MAL entries, then its own.
    static func entryIDs(of meta: NuvioMeta) -> [Int] {
        var seen = Set<Int>()
        let ids = (meta.videos ?? []).compactMap { AnimeSource.malID(from: $0.id) } + [AnimeSource.malID(from: meta.id)].compactMap { $0 }
        return ids.filter { seen.insert($0).inserted }
    }

    /// Pictures found for related MAL entries, for the session.
    enum RelatedPictures {
        private static let lock = NSLock()
        private static var known: [Int: (poster: String, year: Int?)] = [:]

        static func store(_ id: Int, poster: String, year: Int?) {
            lock.lock()
            defer { lock.unlock() }
            if known.count > 2000 { known.removeAll() }
            known[id] = (poster, year)
        }

        static func picture(_ id: Int) -> (poster: String, year: Int?)? {
            lock.lock()
            defer { lock.unlock() }
            return known[id]
        }

        /// The row's titles with the pictures found since it was built.
        static func filled(_ titles: [RelatedTitle]) -> [RelatedTitle] {
            titles.map { title in
                guard title.posterURL == nil, let id = AnimeSource.malID(from: title.id), let found = picture(id) else { return title }
                let year = title.year ?? found.year.map { String($0) }
                return RelatedTitle(
                    id: title.id,
                    type: title.type,
                    name: title.name,
                    posterURL: found.poster,
                    year: year,
                    rating: title.rating,
                    overview: title.overview,
                    backdropURL: title.backdropURL,
                    caption: title.caption
                )
            }
        }
    }

    // MARK: Search

    /// MAL's results for Search: Tenrai's, else MAL's own API's. Also the MAL ids found, so
    /// AniList's results can leave out the same anime.
    static func search(_ query: String) async -> AniListService.SearchResult {
        guard MALSettings.searchesMAL else { return .empty }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        let quoted = "“\(trimmed)”"
        var parameters: [(String, String)] = [("q", trimmed), ("limit", "25")]
        if !MALSettings.showsAdult { parameters.append(("sfw", "true")) }
        var media: [AniListMedia] = []
        var answeredBy = "Tenrai"
        do {
            let data = try await AniListClient.$isInteractive.withValue(true) {
                try await TenraiClient.shared.get("anime", query: parameters, ttl: AniListService.searchTTL)
            }
            let list = try decoder.decode(TenraiMany<TenraiDetails>.self, from: data).data ?? []
            media = list.map { Self.media($0) }
        } catch {
            guard MALOfficialClient.isAvailable, trimmed.count >= 3,
                  let data = try? await MALOfficialClient.shared.get(
                      "anime",
                      query: [("q", trimmed), ("limit", "25"), ("fields", officialCardFields), ("nsfw", MALSettings.showsAdult ? "true" : "false")],
                      ttl: AniListService.searchTTL
                  ),
                  let list = try? decoder.decode(MALOfficialList.self, from: data) else {
                AniListDiagnostics.note(.mal, "Search \(quoted): failed · \(describe(error))")
                return .failure
            }
            media = (list.data ?? []).compactMap(\.node).map { Self.media($0) }
            answeredBy = "MAL API"
        }
        if !MALSettings.showsAdult { media = media.filter { $0.isAdult != true } }
        AniListDiagnostics.note(.mal, "Search \(quoted): \(media.count) results · \(answeredBy)")
        let language = AniListSettings.titleLanguage
        var names: [(name: String, year: Int?)] = []
        for entry in media {
            let year = AniListMetaBuilder.year(entry)
            for title in [entry.title?.romaji, entry.title?.english, entry.title?.native] + (entry.synonyms ?? []).map(Optional.some) {
                let key = AniListService.matchKey(title ?? "")
                if !key.isEmpty { names.append((name: key, year: year)) }
            }
        }
        let items = AnimeSource.$current.withValue(.mal) {
            media.map { AniListMetaBuilder.card($0, language: language) }
        }
        return AniListService.SearchResult(items: items, names: names)
    }

    // MARK: Catalogs from MAL's own API

    /// A top list or a season from MAL's own API, when Tenrai doesn't answer; nil for catalogs
    /// it has no list for.
    static func officialCatalog(_ catalogId: String, page: Int, limit: Int) async -> [TenraiAnime]? {
        guard MALOfficialClient.isAvailable, catalogId.hasPrefix(MALCatalogs.idPrefix) else { return nil }
        let id = String(catalogId.dropFirst(MALCatalogs.idPrefix.count))
        let parts = id.split(separator: "-", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let path: String
        var query: [(String, String)] = [("limit", String(limit)), ("offset", String(max(page - 1, 0) * limit)), ("fields", officialCardFields)]
        switch parts[0] {
        case "top":
            let rankings: Set<String> = ["all", "airing", "upcoming", "bypopularity", "favorite", "tv", "movie", "ova", "ona", "special"]
            guard rankings.contains(parts[1]) else { return nil }
            let ranking = parts[1]
            path = "anime/ranking"
            query.append(("ranking_type", ranking))
        case "season":
            let season: (season: String, year: Int)
            switch parts[1] {
            case "now": season = AniListSeason.current()
            case "next": season = AniListSeason.next()
            case "last": season = AniListSeason.previous()
            default: return nil
            }
            path = "anime/season/\(season.year)/\(season.season.lowercased())"
            query.append(("sort", "anime_num_list_users"))
        default:
            return nil
        }
        if MALSettings.showsAdult { query.append(("nsfw", "true")) }
        guard let data = try? await MALOfficialClient.shared.get(path, query: query, ttl: MALCatalogs.keepFor) else { return nil }
        return MALAccount.listItems(from: data)
    }

    // MARK: People

    /// A voice actor as AniList's people page reads one, from `people/{id}/full`.
    static func staff(_ id: Int) async -> AniListStaff? {
        guard let data = try? await AniListClient.$isInteractive.withValue(true, operation: {
            try await TenraiClient.shared.get("people/\(id)/full", ttl: peopleTTL)
        }), let person = try? decoder.decode(TenraiOne<TenraiPersonFull>.self, from: data).data else { return nil }
        var order: [Int] = []
        var byAnime: [Int: (anime: TenraiAnimeRef, characters: [String])] = [:]
        for voice in person.voices ?? [] {
            guard let anime = voice.anime else { continue }
            if byAnime[anime.malId] == nil {
                guard order.count < 150 else { continue }
                order.append(anime.malId)
                byAnime[anime.malId] = (anime, [])
            }
            if let name = personName(voice.character?.name), byAnime[anime.malId]?.characters.contains(name) == false {
                byAnime[anime.malId]?.characters.append(name)
            }
        }
        let hints = await formatHints(order)
        let edges = order.compactMap { id -> AniListRoleEdge? in
            guard let found = byAnime[id] else { return nil }
            return AniListRoleEdge(
                characterRole: nil,
                characters: found.characters.map { AniListPerson(name: AniListName(full: $0)) },
                node: media(ref: found.anime, hints: hints)
            )
        }
        let native = [person.familyName, person.givenName].compactMap { $0 }.joined()
        return AniListStaff(
            id: person.malId,
            name: AniListName(full: personName(person.name), native: native.isEmpty ? nil : native),
            image: AniListImage(large: picture(person.images)),
            description: person.about,
            dateOfBirth: date(person.birthday),
            characterMedia: AniListRoleConnection(edges: edges)
        )
    }

    /// A character as AniList's people page reads one, from `characters/{id}/full`.
    static func character(_ id: Int) async -> AniListCharacter? {
        guard let data = try? await AniListClient.$isInteractive.withValue(true, operation: {
            try await TenraiClient.shared.get("characters/\(id)/full", ttl: peopleTTL)
        }), let character = try? decoder.decode(TenraiOne<TenraiCharacterFull>.self, from: data).data else { return nil }
        let appearances = (character.anime ?? []).filter { $0.anime != nil }
        let hints = await formatHints(appearances.compactMap { $0.anime?.malId })
        let edges = appearances.compactMap { appearance -> AniListRoleEdge? in
            guard let anime = appearance.anime else { return nil }
            return AniListRoleEdge(characterRole: appearance.role?.uppercased(), characters: nil, node: media(ref: anime, hints: hints))
        }
        return AniListCharacter(
            id: character.malId,
            name: AniListName(full: personName(character.name), native: character.nameKanji),
            image: AniListImage(large: picture(character.images)),
            description: character.about,
            media: AniListRoleConnection(edges: edges)
        )
    }

    // MARK: Status

    static func describe(_ error: Error) -> String {
        switch error {
        case TenraiClient.Failure.rateLimited: return "rate limit, waiting"
        case TenraiClient.Failure.status(let code): return "HTTP \(code)"
        case TenraiClient.Failure.network: return "no answer"
        case TenraiClient.Failure.noClientID: return "no MAL Client ID"
        case is DecodingError: return "unreadable answer"
        default: return error.localizedDescription
        }
    }

    /// Where the last MAL titles' entries came from, for Settings.
    enum SourceLog {
        private static let lock = NSLock()
        private static var sources: [Int: String] = [:]

        static func record(_ id: Int, _ source: String) {
            lock.lock()
            defer { lock.unlock() }
            if sources.count > 500 { sources.removeAll() }
            sources[id] = source
        }

        /// "Tenrai ×3, MAL API ×1" for these entries.
        static func summary(_ ids: [Int]) -> String {
            lock.lock()
            let known = ids.compactMap { sources[$0] }
            lock.unlock()
            var counts: [String: Int] = [:]
            for source in known { counts[source, default: 0] += 1 }
            guard !counts.isEmpty else { return "kept in memory" }
            return counts.sorted { $0.key < $1.key }.map { "\($0.key) ×\($0.value)" }.joined(separator: ", ")
        }
    }

    /// Tenrai's and MAL's own API's counts and last errors, for Settings.
    static func statusText() async -> String {
        let tenrai = await TenraiClient.shared.status
        let official = await MALOfficialClient.shared.requests
        let officialFailure = await MALOfficialClient.shared.lastFailureMessage
        func at(_ date: Date) -> String {
            DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short)
        }
        var parts = ["Tenrai: \(tenrai.requests) requests"]
        if tenrai.savedAnswers > 0 { parts.append("\(tenrai.savedAnswers) saved answers used") }
        if let success = tenrai.lastSuccess { parts.append("last answer \(at(success))") }
        if let failure = tenrai.lastFailure, failure > (tenrai.lastSuccess ?? .distantPast) {
            parts.append("error at \(at(failure)): \(tenrai.lastFailureMessage ?? "?")")
        }
        parts.append(MALOfficialClient.isAvailable ? "MAL API: \(official) requests" : "MAL API: no Client ID")
        if let officialFailure { parts.append(officialFailure) }
        return parts.joined(separator: " · ")
    }

    /// Asks Tenrai, then MAL's own API, for Frieren right now, past the saved answers.
    static func testConnection() async -> String {
        var lines: [String] = []
        do {
            let data = try await AniListClient.$isInteractive.withValue(true) {
                try await TenraiClient.shared.get("anime", query: [("q", "Frieren"), ("limit", "5"), ("sfw", "true")], ttl: 0)
            }
            let count = (try? decoder.decode(TenraiMany<TenraiDetails>.self, from: data).data?.count) ?? 0
            lines.append("Tenrai OK · \(count) results")
        } catch {
            lines.append("Tenrai failed: \(describe(error))")
        }
        if MALOfficialClient.isAvailable {
            do {
                let data = try await MALOfficialClient.shared.get("anime", query: [("q", "Frieren"), ("limit", "5")], ttl: 0)
                let count = (try? decoder.decode(MALOfficialList.self, from: data).data?.count) ?? 0
                lines.append("MAL API OK · \(count) results")
            } catch {
                lines.append("MAL API failed: \(describe(error))")
            }
        } else {
            lines.append("MAL API: no Client ID")
        }
        return lines.joined(separator: " · ")
    }

    static func clearCache() async {
        await TenraiClient.shared.clearCache()
        await MALOfficialClient.shared.clearCache()
    }
}
