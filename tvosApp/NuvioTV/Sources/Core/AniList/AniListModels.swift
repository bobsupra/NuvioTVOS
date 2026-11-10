import Foundation

/// The parts of AniList's GraphQL `Media` that Nuvio reads. Every field is optional: a query
/// asks only for what it needs, and AniList leaves out what it doesn't know.
struct AniListMedia: Decodable, Hashable {
    let id: Int
    var idMal: Int? = nil
    var type: String? = nil
    var format: String? = nil
    var status: String? = nil
    var episodes: Int? = nil
    var duration: Int? = nil
    var season: String? = nil
    var seasonYear: Int? = nil
    var averageScore: Int? = nil
    var genres: [String]? = nil
    var synonyms: [String]? = nil
    var isAdult: Bool? = nil
    var countryOfOrigin: String? = nil
    var source: String? = nil
    var title: AniListTitle? = nil
    var coverImage: AniListCoverImage? = nil
    var bannerImage: String? = nil
    var description: String? = nil
    var startDate: AniListDate? = nil
    var endDate: AniListDate? = nil
    var nextAiringEpisode: AniListAiring? = nil
    var airingSchedule: AniListAiringConnection? = nil
    var streamingEpisodes: [AniListStreamingEpisode]? = nil
    var trailer: AniListTrailer? = nil
    var studios: AniListStudioConnection? = nil
    var relations: AniListRelationConnection? = nil
    var characters: AniListCharacterConnection? = nil
    var recommendations: AniListRecommendationConnection? = nil
    var tags: [AniListTag]? = nil
    /// The viewer's favourite (asked with their token).
    var isFavourite: Bool? = nil

    static func == (lhs: AniListMedia, rhs: AniListMedia) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct AniListTitle: Decodable, Hashable {
    var romaji: String? = nil
    var english: String? = nil
    var native: String? = nil
}

struct AniListCoverImage: Decodable, Hashable {
    var extraLarge: String? = nil
    var large: String? = nil
    var color: String? = nil
}

struct AniListDate: Decodable, Hashable {
    var year: Int? = nil
    var month: Int? = nil
    var day: Int? = nil
}

struct AniListAiring: Decodable, Hashable {
    let episode: Int
    let airingAt: Int
}

struct AniListAiringConnection: Decodable, Hashable {
    var nodes: [AniListAiring]? = nil
}

struct AniListStreamingEpisode: Decodable, Hashable {
    var title: String? = nil
    var thumbnail: String? = nil
}

struct AniListTrailer: Decodable, Hashable {
    var id: String? = nil
    var site: String? = nil
}

struct AniListStudioConnection: Decodable, Hashable {
    var nodes: [AniListStudio]? = nil
}

struct AniListStudio: Decodable, Hashable {
    let name: String
    var isAnimationStudio: Bool? = nil
}

struct AniListRelationConnection: Decodable, Hashable {
    var edges: [AniListRelationEdge]? = nil
}

struct AniListRelationEdge: Decodable, Hashable {
    var relationType: String? = nil
    var node: AniListMedia? = nil
}

struct AniListCharacterConnection: Decodable, Hashable {
    var edges: [AniListCharacterEdge]? = nil
}

struct AniListCharacterEdge: Decodable, Hashable {
    var role: String? = nil
    var node: AniListPerson? = nil
    var voiceActors: [AniListPerson]? = nil
}

struct AniListPerson: Decodable, Hashable {
    var id: Int? = nil
    var name: AniListName? = nil
    var image: AniListImage? = nil
}

struct AniListName: Decodable, Hashable {
    var full: String? = nil
}

struct AniListImage: Decodable, Hashable {
    var large: String? = nil
}

struct AniListRecommendationConnection: Decodable, Hashable {
    var nodes: [AniListRecommendation]? = nil
}

struct AniListRecommendation: Decodable, Hashable {
    var rating: Int? = nil
    var mediaRecommendation: AniListMedia? = nil
}

struct AniListTag: Decodable, Hashable {
    let name: String
    var rank: Int? = nil
    var isMediaSpoiler: Bool? = nil
}

struct AniListPage: Decodable {
    var pageInfo: AniListPageInfo? = nil
    var media: [AniListMedia]? = nil

    init(pageInfo: AniListPageInfo? = nil, media: [AniListMedia]? = nil) {
        self.pageInfo = pageInfo
        self.media = media
    }

    private enum CodingKeys: String, CodingKey { case pageInfo, media }

    /// `media` as a list (a Page), or as a connection with `nodes` (a studio's titles).
    private struct Connection: Decodable {
        var pageInfo: AniListPageInfo? = nil
        var nodes: [AniListMedia]? = nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pageInfo = try container.decodeIfPresent(AniListPageInfo.self, forKey: .pageInfo)
        if let list = try? container.decodeIfPresent([AniListMedia].self, forKey: .media) {
            media = list
        } else if let connection = try? container.decodeIfPresent(Connection.self, forKey: .media) {
            media = connection.nodes
            pageInfo = pageInfo ?? connection.pageInfo
        }
    }
}

struct AniListPageInfo: Decodable {
    var hasNextPage: Bool? = nil
}

/// `{ "data": { "Media": … } }`
struct AniListMediaResponse: Decodable {
    struct DataField: Decodable {
        let Media: AniListMedia?
    }
    let data: DataField?
}

/// `{ "data": { "Page": … } }`
struct AniListPageResponse: Decodable {
    struct DataField: Decodable {
        let Page: AniListPage?
    }
    let data: DataField?
}

/// `{ "data": { "<alias>": { "media": … }, … } }` for several pages in one request.
struct AniListAliasedPagesResponse: Decodable {
    let data: [String: AniListPage]?
}

/// One episode from api.ani.zip: titles, picture and summary that AniList itself lacks.
struct AniZipEpisode: Decodable, Hashable {
    var title: [String: String?]? = nil
    var image: String? = nil
    var overview: String? = nil
    var summary: String? = nil
    var airDateUtc: String? = nil
    /// The day it aired ("2016-01-14"); ani.zip writes it both ways.
    var airdate: String? = nil
    var airDate: String? = nil
    /// TheTVDB's season and episode of this AniList episode, and its absolute number.
    var seasonNumber: Int? = nil
    var episodeNumber: Int? = nil
    var absoluteEpisodeNumber: Int? = nil

    enum CodingKeys: String, CodingKey {
        case title, image, overview, summary, airDateUtc, airdate, airDate
        case seasonNumber, episodeNumber, absoluteEpisodeNumber
    }

    init(
        title: [String: String?]? = nil, image: String? = nil, overview: String? = nil, summary: String? = nil,
        airDateUtc: String? = nil, airdate: String? = nil, airDate: String? = nil,
        seasonNumber: Int? = nil, episodeNumber: Int? = nil, absoluteEpisodeNumber: Int? = nil
    ) {
        self.title = title
        self.image = image
        self.overview = overview
        self.summary = summary
        self.airDateUtc = airDateUtc
        self.airdate = airdate
        self.airDate = airDate
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
        self.absoluteEpisodeNumber = absoluteEpisodeNumber
    }

    /// Each field on its own: one written differently (a number as text) costs only that field,
    /// not every episode of the title.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) -> String? { try? container.decodeIfPresent(String.self, forKey: key) }
        func number(_ key: CodingKeys) -> Int? {
            if let value = try? container.decodeIfPresent(Int.self, forKey: key) { return value }
            return text(key).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        title = try? container.decodeIfPresent([String: String?].self, forKey: .title)
        image = text(.image)
        overview = text(.overview)
        summary = text(.summary)
        airDateUtc = text(.airDateUtc)
        airdate = text(.airdate)
        airDate = text(.airDate)
        seasonNumber = number(.seasonNumber)
        episodeNumber = number(.episodeNumber)
        absoluteEpisodeNumber = number(.absoluteEpisodeNumber)
    }

    /// The day it aired, as "yyyy-MM-dd".
    var airDay: String? {
        for value in [airdate, airDate, airDateUtc] {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), value.count >= 10 else { continue }
            return String(value.prefix(10))
        }
        return nil
    }

    var englishTitle: String? {
        guard let title else { return nil }
        for key in ["en", "x-jat"] {
            if let value = title[key] ?? nil {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }
}

/// One picture of the whole series from api.ani.zip, taken from TheTVDB: "Fanart" (16:9),
/// "Clearlogo", "Poster" or "Banner".
struct AniZipImage: Decodable, Hashable {
    var coverType: String? = nil
    var url: String? = nil
}

/// The other ids api.ani.zip knows for an AniList entry. They are read only to find pictures of
/// the title (TMDB by id, Metahub by IMDb id); streams and progress keep the AniList id.
struct AniZipMappings: Decodable, Hashable {
    var themoviedbID: Int? = nil
    var imdbID: String? = nil
    var kitsuID: Int? = nil

    enum CodingKeys: String, CodingKey {
        case themoviedbID = "themoviedb_id"
        case imdbID = "imdb_id"
        case kitsuID = "kitsu_id"
    }

    init(themoviedbID: Int? = nil, imdbID: String? = nil, kitsuID: Int? = nil) {
        self.themoviedbID = themoviedbID
        self.imdbID = imdbID
        self.kitsuID = kitsuID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // A number, or the same number as text.
        func number(_ key: CodingKeys) -> Int? {
            if let value = try? container.decode(Int.self, forKey: key) { return value }
            if let text = try? container.decode(String.self, forKey: key) {
                return Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return nil
        }
        themoviedbID = number(.themoviedbID)
        kitsuID = number(.kitsuID)
        // Only a whole IMDb id ("tt" and digits) is kept.
        if let text = try? container.decode(String.self, forKey: .imdbID) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if trimmed.hasPrefix("tt"), trimmed.count > 2, trimmed.dropFirst(2).allSatisfy(\.isNumber) {
                imdbID = trimmed
            }
        }
    }
}

struct AniZipMappingsResponse: Decodable {
    var episodes: [String: AniZipEpisode]? = nil
    var images: [AniZipImage]? = nil
    var mappings: AniZipMappings? = nil

    enum CodingKeys: String, CodingKey {
        case episodes, images, mappings
    }

    init(episodes: [String: AniZipEpisode]? = nil, images: [AniZipImage]? = nil, mappings: AniZipMappings? = nil) {
        self.episodes = episodes
        self.images = images
        self.mappings = mappings
    }

    /// A part ani.zip answers differently from what is expected costs only that part.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        episodes = try? container.decodeIfPresent([String: AniZipEpisode].self, forKey: .episodes)
        images = try? container.decodeIfPresent([AniZipImage].self, forKey: .images)
        mappings = try? container.decodeIfPresent(AniZipMappings.self, forKey: .mappings)
    }

    /// The first picture of a kind, as an https address.
    func image(_ coverType: String) -> String? {
        for image in images ?? [] where image.coverType?.caseInsensitiveCompare(coverType) == .orderedSame {
            guard let url = image.url?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty else { continue }
            return url.hasPrefix("http://") ? "https://" + url.dropFirst("http://".count) : url
        }
        return nil
    }

    /// TheTVDB's 16:9 background, which AniList doesn't have (its banner is a thin strip).
    var fanart: String? { image("Fanart") }

    /// TheTVDB's title logo.
    var clearLogo: String? { image("Clearlogo") }
}

// MARK: The viewer's account

struct AniListViewer: Decodable, Equatable {
    let id: Int
    let name: String
    var avatar: AniListImage? = nil
}

/// `{ "data": { "Viewer": … } }`
struct AniListViewerResponse: Decodable {
    struct DataField: Decodable {
        let Viewer: AniListViewer?
    }
    let data: DataField?
}

/// One anime on the viewer's list: its status (CURRENT, PLANNING, COMPLETED, DROPPED, PAUSED,
/// REPEATING), how many episodes they have watched, how many times they rewatched it, and
/// their score out of 100. AniList keeps nothing finer: no positions, no per-episode history.
struct AniListListEntry: Decodable, Equatable {
    let id: Int
    let mediaId: Int
    var status: String? = nil
    var progress: Int? = nil
    var repeatCount: Int? = nil
    var score: Double? = nil
    var startedAt: AniListDate? = nil
    var updatedAt: Int? = nil
    var media: AniListMedia? = nil

    enum CodingKeys: String, CodingKey {
        case id, mediaId, status, progress, score, startedAt, updatedAt, media
        case repeatCount = "repeat"
    }

    init(id: Int, mediaId: Int, status: String? = nil, progress: Int? = nil, repeatCount: Int? = nil,
         score: Double? = nil, startedAt: AniListDate? = nil, updatedAt: Int? = nil, media: AniListMedia? = nil) {
        self.id = id
        self.mediaId = mediaId
        self.status = status
        self.progress = progress
        self.repeatCount = repeatCount
        self.score = score
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.media = media
    }
}

/// `{ "data": { "Page": { "mediaList": [...] } } }`
struct AniListEntryPageResponse: Decodable {
    struct PageField: Decodable {
        var mediaList: [AniListListEntry]? = nil
    }
    struct DataField: Decodable {
        let Page: PageField?
    }
    let data: DataField?
}

/// `{ "data": { "SaveMediaListEntry": … } }`
struct AniListSavedEntryResponse: Decodable {
    struct DataField: Decodable {
        let SaveMediaListEntry: AniListListEntry?
    }
    let data: DataField?
}

/// `{ "data": { "MediaListCollection": { "lists": [...] } } }`
struct AniListListCollectionResponse: Decodable {
    struct List: Decodable {
        var name: String? = nil
        var status: String? = nil
        var isCustomList: Bool? = nil
        var entries: [AniListListEntry]? = nil
    }
    struct Collection: Decodable {
        var lists: [List]? = nil
    }
    struct DataField: Decodable {
        let MediaListCollection: Collection?
    }
    let data: DataField?
}
