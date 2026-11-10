import XCTest
@testable import NuvioTV

/// MyAnimeList: catalogs from Tenrai, the phone login, writing watched episodes.
final class MALTests: XCTestCase {
    func testCatalogIdsBecomeTenraiAddresses() async {
        let top = await MALCatalogs.url(for: "mal-top-airing", page: 1, limit: 25)?.absoluteString
        XCTAssertTrue(top?.hasPrefix("https://api.tenrai.org/v1/top/anime?filter=airing&page=1&limit=25") == true, top ?? "nil")
        let movies = await MALCatalogs.url(for: "mal-top-movie", page: 2, limit: 25)?.absoluteString
        XCTAssertTrue(movies?.contains("type=movie&page=2") == true, movies ?? "nil")
        let genre = await MALCatalogs.url(for: "mal-genre-1", page: 1, limit: 25)?.absoluteString
        XCTAssertTrue(genre?.contains("anime?genres=1&order_by=members&sort=desc") == true, genre ?? "nil")
        let today = await MALCatalogs.url(for: "mal-day-today", page: 1, limit: 25)?.absoluteString
        XCTAssertTrue(today?.contains("broadcast_day=today&status=airing") == true, today ?? "nil")
        let now = await MALCatalogs.url(for: "mal-season-now", page: 1, limit: 25)?.absoluteString
        XCTAssertTrue(now?.hasPrefix("https://api.tenrai.org/v1/seasons/now?") == true, now ?? "nil")
        let recommended = await MALCatalogs.url(for: "mal-recommended", page: 3, limit: 25)?.absoluteString
        XCTAssertEqual(recommended, "https://api.tenrai.org/v1/recommendations/anime?page=3")
        let nothing = await MALCatalogs.url(for: "mal-top-nope", page: 1, limit: 25)
        XCTAssertNil(nothing)
        let notMAL = await MALCatalogs.url(for: "trending", page: 1, limit: 25)
        XCTAssertNil(notMAL)
    }

    func testTenraiTitlesAndScoresAreRead() throws {
        let json = Data("""
        {"pagination":{"has_next_page":true},"data":[{"mal_id":52991,"title":"Sousou no Frieren","title_english":"Frieren: Beyond Journey's End",
         "images":{"jpg":{"image_url":"a.jpg","large_image_url":"b.jpg"}},"type":"TV","score":9.3,"genres":[{"name":"Adventure"}],
         "aired":{"prop":{"from":{"year":2023}}},"trailer":{"youtube_id":"qgQ"}}]}
        """.utf8)
        let list = try JSONDecoder().decode(TenraiList.self, from: json)
        XCTAssertEqual(list.pagination?.hasNextPage, true)
        let item = try XCTUnwrap(list.data?.first)
        let card = MALCatalogs.card(item, aniListID: 154587, language: .english)
        XCTAssertEqual(card.id, "anilist:154587")
        XCTAssertEqual(card.name, "Frieren: Beyond Journey's End")
        XCTAssertEqual(card.posterUrl, "b.jpg")
        XCTAssertEqual(card.year, 2023)
        XCTAssertEqual(card.type, "series")
        XCTAssertEqual(MALCatalogs.score(fromDetails: Data(#"{"data":{"mal_id":1,"score":8.75}}"#.utf8)), 8.75)
        XCTAssertNil(MALCatalogs.score(fromDetails: Data(#"{"data":{"mal_id":1,"score":0}}"#.utf8)))
    }

    func testMALListsReadAsCards() {
        let json = Data("""
        {"data":[{"node":{"id":21,"title":"One Piece","main_picture":{"medium":"m.jpg","large":"l.jpg"},
          "alternative_titles":{"en":"One Piece","ja":""},"media_type":"tv","start_season":{"year":1999},"mean":8.7}}]}
        """.utf8)
        let items = MALAccount.listItems(from: json)
        XCTAssertEqual(items.map(\.malID), [21])
        XCTAssertEqual(items.first?.images?.jpg?.largeImageURL, "l.jpg")
        XCTAssertNil(items.first?.titleJapanese, "an empty alternative title is none")
        XCTAssertEqual(items.first?.year, 1999)
    }

    func testThePhoneLoginTakesMALsCode() {
        let request = Data("GET /mal?code=abc%2B1&state=xyz HTTP/1.1\r\nHost: tv\r\n\r\n".utf8)
        XCTAssertEqual(AniListLoginServer.parse(request), .code("abc+1", state: "xyz"))
        let refused = Data("GET /mal?error=access_denied&message=denied HTTP/1.1\r\nHost: tv\r\n\r\n".utf8)
        XCTAssertEqual(AniListLoginServer.parse(refused), .codeRefused("MyAnimeList: denied"))
        XCTAssertTrue(AniListLoginServer.resultPage(ok: false, message: "<b>").contains("&lt;b&gt;"))
    }

    func testTheLoginAddressAndTokens() throws {
        let redirect = URL(string: "http://192.168.1.5:47811/mal")!
        let url = try XCTUnwrap(MALAccount.authorizeURL(clientID: "client", verifier: "v123", state: "s", redirect: redirect))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "code_challenge" }?.value, "v123", "plain PKCE: the challenge is the verifier")
        XCTAssertEqual(items.first { $0.name == "code_challenge_method" }?.value, "plain")
        XCTAssertEqual(items.first { $0.name == "redirect_uri" }?.value, redirect.absoluteString)

        let verifier = MALAccount.makeVerifier()
        XCTAssertEqual(verifier.count, 96)
        XCTAssertNotEqual(verifier, MALAccount.makeVerifier())

        let now = Date(timeIntervalSince1970: 1_000)
        let tokens = MALAccount.tokens(from: Data(#"{"token_type":"Bearer","expires_in":3600,"access_token":"a","refresh_token":"r"}"#.utf8), now: now)
        XCTAssertEqual(tokens, MALAccount.Tokens(accessToken: "a", refreshToken: "r", expiresAt: now.addingTimeInterval(3600)))
        XCTAssertEqual(MALAccount.formBody(["b": "x y", "a": "1&2"]), "a=1%262&b=x%20y")
    }

    func testWatchedEpisodesOnlyGoForward() {
        let watching = MALAccount.ListStatus(status: "watching", watched: 5, episodes: 12)
        XCTAssertEqual(MALAccount.progress(watching, watched: 6), ["num_watched_episodes": "6", "status": "watching"])
        XCTAssertNil(MALAccount.progress(watching, watched: 3), "an earlier episode doesn't take progress back")
        XCTAssertEqual(MALAccount.progress(watching, watched: 12)?["status"], "completed")
        let planned = MALAccount.ListStatus(status: "plan_to_watch", watched: 0, episodes: 0)
        XCTAssertEqual(MALAccount.progress(planned, watched: 1), ["num_watched_episodes": "1", "status": "watching"])
    }

    func testTheDetailsButtonSaysWhereTheTitleIs() {
        XCTAssertEqual(MALAccount.buttonTitle(nil), "MAL")
        XCTAssertEqual(MALAccount.buttonTitle(.init(status: nil, watched: 0, episodes: 12)), "Add")
        XCTAssertEqual(MALAccount.buttonTitle(.init(status: "watching", watched: 5, episodes: 12)), "Watching 5/12")
        XCTAssertEqual(MALAccount.buttonTitle(.init(status: "on_hold", watched: 3, episodes: 0)), "On-Hold 3")
        XCTAssertEqual(MALAccount.buttonTitle(.init(status: "plan_to_watch", watched: 0, episodes: 12)), "Plan to Watch")
    }

    func testTopShelfTriesEarlierSeasonsForATrailer() {
        let entry = TopShelfEntry(
            contentId: "anilist:3", contentType: "series", title: "Season 3", subtitle: nil, imageURL: nil,
            progress: nil, imdbId: "tt0000003", trailerFallbackIMDbIds: ["tt0000002", "tt0000001", "tt0000003"]
        )
        XCTAssertEqual(TopShelfTrailerResolver.lookupURLs(for: entry).map(\.lastPathComponent), [
            "tt0000003.json", "tt0000002.json", "tt0000001.json",
        ])
        XCTAssertEqual(TopShelfTrailerResolver.lookupURL(for: entry)?.lastPathComponent, "tt0000003.json")
    }

    func testAnEmptyTopShelfRatingIsAskedAgainSoon() {
        let now = Date()
        let empty = TopShelfRatingsStore.Record(badges: [], fetchedAt: now.addingTimeInterval(-40 * 60))
        XCTAssertFalse(TopShelfRatingsStore.isFresh(empty, now: now))
        let fresh = TopShelfRatingsStore.Record(badges: [], fetchedAt: now.addingTimeInterval(-10 * 60))
        XCTAssertTrue(TopShelfRatingsStore.isFresh(fresh, now: now))
    }

    func testTopShelfTakesIMDbsOwnTrailerWhenTrailerioHasNone() throws {
        let json = Data("""
        {"data":{"title":{"latestTrailer":{"id":"vi1","name":{"value":"Official Trailer"},"playbackURLs":[
          {"url":"https://imdb-video.media-imdb.com/a/480.mp4","videoMimeType":"MP4","videoDefinition":"DEF_480p"},
          {"url":"https://imdb-video.media-imdb.com/a/1080.mp4","videoMimeType":"MP4","videoDefinition":"DEF_1080p"},
          {"url":"https://imdb-video.media-imdb.com/a/hls.m3u8","videoMimeType":"M3U8","videoDefinition":"DEF_AUTO"}]},
         "primaryVideos":{"edges":[{"node":{"id":"vi2","name":{"value":"Vertical clip"},"playbackURLs":[{"url":"https://x/v.mp4","videoMimeType":"MP4","videoDefinition":"DEF_1080p"}]}}]}}}}
        """.utf8)
        let link = try XCTUnwrap(TopShelfTrailerResolver.imdbLink(from: json))
        XCTAssertEqual(link.url, "https://imdb-video.media-imdb.com/a/1080.mp4")
        XCTAssertEqual(link.provider, "IMDb 1080p")
        XCTAssertNil(TopShelfTrailerResolver.imdbLink(from: Data(#"{"data":{"title":{}}}"#.utf8)))
    }
}
