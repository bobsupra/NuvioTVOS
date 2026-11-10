import Foundation

/// GraphQL queries sent to AniList. Each asks only for the fields Nuvio shows.
enum AniListQueries {
    /// What a card on Home or in Search needs.
    static let cardFields = """
    id idMal type format status episodes season seasonYear averageScore genres synonyms isAdult
    title { romaji english native }
    coverImage { extraLarge large color }
    bannerImage
    description(asHtml: false)
    startDate { year month day }
    trailer { id site }
    """

    /// What a card in a relations row needs.
    static let relationNodeFields = """
    id type format status episodes seasonYear
    title { romaji english native }
    coverImage { extraLarge large }
    startDate { year month day }
    """

    /// What one entry of a title needs: its own details, its episodes and its relations.
    static let entryFields = """
    \(cardFields)
    duration source countryOfOrigin
    endDate { year month day }
    nextAiringEpisode { episode airingAt }
    airingSchedule(perPage: 50) { nodes { episode airingAt } }
    streamingEpisodes { title thumbnail }
    studios(isMain: true) { nodes { name isAnimationStudio } }
    relations { edges { relationType node { \(relationNodeFields) } } }
    """

    /// Entries by id, with their episodes and relations. Following a series from season to
    /// season asks for the next ones the same way.
    static let entries = """
    query ($ids: [Int], $perPage: Int) {
      Page(perPage: $perPage) {
        media(id_in: $ids, type: ANIME) { \(entryFields) }
      }
    }
    """

    /// One page of a catalog.
    static let catalog = """
    query ($page: Int, $perPage: Int, $sort: [MediaSort], $season: MediaSeason, $seasonYear: Int, $genre: String, $isAdult: Boolean) {
      Page(page: $page, perPage: $perPage) {
        pageInfo { hasNextPage }
        media(type: ANIME, sort: $sort, season: $season, seasonYear: $seasonYear, genre: $genre, isAdult: $isAdult) { \(cardFields) }
      }
    }
    """

    static let search = """
    query ($search: String, $perPage: Int, $isAdult: Boolean) {
      Page(perPage: $perPage) {
        media(search: $search, type: ANIME, sort: [SEARCH_MATCH], isAdult: $isAdult) { \(cardFields) }
      }
    }
    """

    /// Characters with their Japanese voice actors, and recommendations, for a title's details.
    static let extras = """
    query ($id: Int) {
      Media(id: $id, type: ANIME) {
        id
        characters(sort: [ROLE, RELEVANCE, ID], perPage: 25) {
          edges {
            role
            node { id name { full } image { large } }
            voiceActors(language: JAPANESE, sort: [RELEVANCE, ID]) { id name { full } image { large } }
          }
        }
        recommendations(sort: [RATING_DESC, ID], perPage: 20) {
          nodes { rating mediaRecommendation { \(relationNodeFields) averageScore description(asHtml: false) bannerImage } }
        }
      }
    }
    """

    // MARK: The viewer's account (asked with their token)

    static let viewer = """
    query { Viewer { id name avatar { large } } }
    """

    /// The viewer's lists with these statuses, last changed first.
    static let lists = """
    query ($userId: Int, $statuses: [MediaListStatus]) {
      MediaListCollection(userId: $userId, type: ANIME, status_in: $statuses, sort: [UPDATED_TIME_DESC]) {
        lists { name status isCustomList entries { id mediaId status progress updatedAt media { \(cardFields) } } }
      }
    }
    """

    /// The viewer's entries of these anime, with their episode counts and whether they're favourites.
    static let entryStates = """
    query ($userId: Int, $ids: [Int], $perPage: Int) {
      Page(perPage: $perPage) {
        mediaList(userId: $userId, mediaId_in: $ids, type: ANIME) {
          id mediaId status progress repeat score(format: POINT_100)
          startedAt { year month day }
          media { id episodes isFavourite }
        }
      }
    }
    """

    /// Episode counts and favourites of anime the viewer may not have on a list yet.
    static let mediaStates = """
    query ($ids: [Int], $perPage: Int) {
      Page(perPage: $perPage) { media(id_in: $ids, type: ANIME) { id episodes isFavourite } }
    }
    """

    /// Changes one entry of the viewer's list. Variables left out stay as they are.
    static let saveEntry = """
    mutation ($mediaId: Int, $status: MediaListStatus, $progress: Int, $repeat: Int, $scoreRaw: Int, $startedAt: FuzzyDateInput, $completedAt: FuzzyDateInput) {
      SaveMediaListEntry(mediaId: $mediaId, status: $status, progress: $progress, repeat: $repeat, scoreRaw: $scoreRaw, startedAt: $startedAt, completedAt: $completedAt) {
        id mediaId status progress repeat score(format: POINT_100)
        startedAt { year month day }
      }
    }
    """

    static let deleteEntry = """
    mutation ($id: Int) { DeleteMediaListEntry(id: $id) { deleted } }
    """

    static let toggleFavourite = """
    mutation ($animeId: Int) { ToggleFavourite(animeId: $animeId) { anime(perPage: 1) { nodes { id } } } }
    """

    /// An entry's score, for a title shown without its details: Continue Watching keeps no ratings.
    static let score = """
    query ($id: Int) { Media(id: $id, type: ANIME) { id averageScore } }
    """

    /// An entry's earlier seasons, for its pictures when it has none of its own.
    static let prequels = """
    query ($id: Int) {
      Media(id: $id, type: ANIME) {
        id format startDate { year month day }
        relations { edges { relationType node { id type format startDate { year month day } } } }
      }
    }
    """

    /// The entries of a franchise by id, with their relations and airing dates, to find which
    /// entry and episode an episode of a Cinemeta series is.
    static let franchise = """
    query ($ids: [Int], $perPage: Int) {
      Page(perPage: $perPage) {
        media(id_in: $ids, type: ANIME) {
          id format status episodes seasonYear
          title { romaji english native }
          startDate { year month day } endDate { year month day }
          airingSchedule(perPage: 50) { nodes { episode airingAt } }
          relations { edges { relationType node { id type format } } }
        }
      }
    }
    """

    /// All Home rows in a single request.
    static func homeRows(_ rows: [AniListHomeRow]) -> String {
        let pages = rows.map { row in
            if let studio = row.studio {
                // A studio's main titles; Studio has no adult filter, so those are left out after.
                return "\(row.alias): Studio(search: \(quoted(studio))) { media(sort: [POPULARITY_DESC], isMain: true, perPage: $perPage) { nodes { \(cardFields) } } }"
            }
            return "\(row.alias): Page(perPage: $perPage) { media(type: ANIME, \(row.arguments), isAdult: $isAdult) { \(cardFields) } }"
        }
        // GraphQL refuses a declared variable that no row uses.
        var declarations = ["$perPage: Int"]
        if rows.contains(where: { $0.studio == nil }) {
            declarations.append("$isAdult: Boolean")
        }
        if rows.contains(where: \.usesSeason) {
            declarations += ["$season: MediaSeason", "$seasonYear: Int"]
        }
        if rows.contains(where: \.usesNextSeason) {
            declarations += ["$nextSeason: MediaSeason", "$nextSeasonYear: Int"]
        }
        return """
        query (\(declarations.joined(separator: ", "))) {
          \(pages.joined(separator: "\n  "))
        }
        """
    }

    /// One page of a row for See All; a studio row answers under the same `Page` name.
    static func rowPage(_ row: AniListHomeRow, withGenre: Bool) -> String {
        if let studio = row.studio {
            return """
            query ($page: Int, $perPage: Int) {
              Page: Studio(search: \(quoted(studio))) {
                media(sort: [POPULARITY_DESC], isMain: true, page: $page, perPage: $perPage) { pageInfo { hasNextPage } nodes { \(cardFields) } }
              }
            }
            """
        }
        var declarations = ["$page: Int", "$perPage: Int", "$isAdult: Boolean"]
        var arguments = row.arguments
        if row.usesSeason {
            declarations += ["$season: MediaSeason", "$seasonYear: Int"]
        }
        if row.usesNextSeason {
            declarations += ["$nextSeason: MediaSeason", "$nextSeasonYear: Int"]
        }
        if withGenre, !row.arguments.contains("genre:") {
            declarations.append("$genre: String")
            arguments += ", genre: $genre"
        }
        return """
        query (\(declarations.joined(separator: ", "))) {
          Page(page: $page, perPage: $perPage) {
            pageInfo { hasNextPage }
            media(type: ANIME, \(arguments), isAdult: $isAdult) { \(cardFields) }
          }
        }
        """
    }

    /// Every AniList tag with its category, for the catalog window.
    static let tags = "query { MediaTagCollection { name category isAdult isGeneralSpoiler } }"

    /// The viewer's favourite anime.
    static let favourites = """
    query ($userId: Int, $page: Int) {
      User(id: $userId) { favourites { anime(page: $page, perPage: 50) { nodes { \(cardFields) } } } }
    }
    """

    /// A string as a GraphQL literal.
    static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// An AniList row on Home: `arguments` go to `media(…)` beside the type and the adult filter; a
/// studio row lists that studio's main titles instead. Which rows there are is Settings → Anime
/// Integrations → AniList → AniList Catalogs (`AniListCatalogs`).
struct AniListHomeRow: Hashable {
    let id: String
    let title: String
    var arguments: String = ""
    var usesSeason = false
    var usesNextSeason = false
    var studio: String? = nil

    /// The id as a GraphQL alias (letters, digits and _).
    var alias: String {
        let cleaned = String(id.map { $0.isLetter || $0.isNumber ? $0 : "_" })
            .folding(options: .diacriticInsensitive, locale: nil)
            .filter { $0.isASCII }
        return "r_" + cleaned
    }

    /// The five rows Home had before the catalog window.
    static let standard: [AniListHomeRow] = [
        AniListHomeRow(id: "trending", title: "Trending Now", arguments: "sort: [TRENDING_DESC, POPULARITY_DESC]"),
        AniListHomeRow(id: "season", title: "Popular This Season", arguments: "season: $season, seasonYear: $seasonYear, sort: [POPULARITY_DESC]", usesSeason: true),
        AniListHomeRow(id: "nextseason", title: "Upcoming Next Season", arguments: "season: $nextSeason, seasonYear: $nextSeasonYear, sort: [POPULARITY_DESC]", usesNextSeason: true),
        AniListHomeRow(id: "popular", title: "All-Time Popular", arguments: "sort: [POPULARITY_DESC]"),
        AniListHomeRow(id: "top", title: "Top 100", arguments: "sort: [SCORE_DESC]"),
    ]

    /// The rows the viewer chose.
    static var all: [AniListHomeRow] { AniListCatalogs.chosenRows() }

    static func row(id: String) -> AniListHomeRow? {
        AniListCatalogs.row(id: id, title: nil)
    }
}

/// AniList's broadcast seasons: Winter (January–March), Spring, Summer, Fall.
enum AniListSeason {
    static func current(at date: Date = Date(), calendar: Calendar = Calendar(identifier: .gregorian)) -> (season: String, year: Int) {
        let month = calendar.component(.month, from: date)
        let year = calendar.component(.year, from: date)
        return (name(forMonth: month), year)
    }

    static func next(at date: Date = Date(), calendar: Calendar = Calendar(identifier: .gregorian)) -> (season: String, year: Int) {
        let month = calendar.component(.month, from: date)
        let year = calendar.component(.year, from: date)
        let nextMonth = month + 3
        return nextMonth > 12 ? (name(forMonth: nextMonth - 12), year + 1) : (name(forMonth: nextMonth), year)
    }

    static func previous(at date: Date = Date(), calendar: Calendar = Calendar(identifier: .gregorian)) -> (season: String, year: Int) {
        let month = calendar.component(.month, from: date)
        let year = calendar.component(.year, from: date)
        let earlier = month - 3
        return earlier < 1 ? (name(forMonth: earlier + 12), year - 1) : (name(forMonth: earlier), year)
    }

    private static func name(forMonth month: Int) -> String {
        switch month {
        case 1...3: return "WINTER"
        case 4...6: return "SPRING"
        case 7...9: return "SUMMER"
        default: return "FALL"
        }
    }
}
