import Foundation
import Security

/// The viewer's MyAnimeList account: logged in from a phone (OAuth with PKCE, MAL's only way),
/// with the viewer's own API client (myanimelist.net/apiconfig, type "other", no secret) whose
/// Redirect URL is this Apple TV (`AniListLoginServer.malPath`). The login is kept in the
/// Keychain per profile and renewed before it runs out; a month unused, it has to be done again.
enum MALAccount {
    struct Login: Codable, Equatable, Sendable {
        var accessToken: String
        var refreshToken: String
        var expiresAt: Date
        var userName: String
        var clientID: String
    }

    enum Failure: LocalizedError {
        case noClientID
        case refused(String)
        case noAnswer

        var errorDescription: String? {
            switch self {
            case .noClientID: return "Fill in your MAL API client's Client ID first."
            case .refused(let reason): return "MyAnimeList refused the login: \(reason)"
            case .noAnswer: return "MyAnimeList didn't answer. Try again."
            }
        }
    }

    static let authorizeAddress = "https://myanimelist.net/v1/oauth2/authorize"
    static let tokenURL = URL(string: "https://myanimelist.net/v1/oauth2/token")!
    static let apiBase = URL(string: "https://api.myanimelist.net/v2")!

    static var login: Login? { MALKeychain.login(for: ProfileSettings.activeProfileScope) }
    static var isLoggedIn: Bool { MALSettings.isEnabled && login != nil }

    // MARK: Logging in

    /// PKCE's code verifier (MAL takes only the "plain" method, so it is also the challenge).
    static func makeVerifier() -> String {
        let allowed = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var bytes = [UInt8](repeating: 0, count: 96)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = (0..<96).map { _ in UInt8.random(in: 0...255) }
        }
        return String(bytes.map { allowed[Int($0) % allowed.count] })
    }

    /// Where the phone logs in.
    static func authorizeURL(clientID: String, verifier: String, state: String, redirect: URL) -> URL? {
        var components = URLComponents(string: authorizeAddress)
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "code_challenge", value: verifier),
            URLQueryItem(name: "code_challenge_method", value: "plain"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "redirect_uri", value: redirect.absoluteString),
        ]
        return components?.url
    }

    /// Trades MAL's code for the login and keeps it; answers the MAL user name.
    static func logIn(code: String, verifier: String, redirect: URL, clientID: String, now: Date = Date()) async throws -> String {
        guard !clientID.isEmpty else { throw Failure.noClientID }
        let token = try await tokens([
            "client_id": clientID,
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirect.absoluteString,
            "code_verifier": verifier,
        ], now: now)
        let name = await userName(token: token.accessToken) ?? "your account"
        let login = Login(accessToken: token.accessToken, refreshToken: token.refreshToken, expiresAt: token.expiresAt, userName: name, clientID: clientID)
        MALKeychain.save(login, for: ProfileSettings.activeProfileScope)
        await lists.forget()
        AniListSettings.notifyHomeChanged()
        return name
    }

    static func logOut() {
        MALKeychain.remove(for: ProfileSettings.activeProfileScope)
        Task { await lists.forget() }
        AniListSettings.notifyHomeChanged()
    }

    struct Tokens: Equatable {
        let accessToken: String
        let refreshToken: String
        let expiresAt: Date
    }

    static func tokens(_ form: [String: String], now: Date) async throws -> Tokens {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(formBody(form).utf8)
        guard let reply = try? await URLSession.shared.data(for: request),
              let http = reply.1 as? HTTPURLResponse else { throw Failure.noAnswer }
        guard (200..<300).contains(http.statusCode) else {
            throw Failure.refused(errorText(reply.0) ?? "HTTP \(http.statusCode)")
        }
        guard let tokens = tokens(from: reply.0, now: now) else { throw Failure.refused("an unreadable answer") }
        return tokens
    }

    static func tokens(from data: Data, now: Date) -> Tokens? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = root["access_token"] as? String, !access.isEmpty,
              let refresh = root["refresh_token"] as? String else { return nil }
        let seconds = (root["expires_in"] as? Double) ?? (root["expires_in"] as? Int).map(Double.init) ?? 3600
        return Tokens(accessToken: access, refreshToken: refresh, expiresAt: now.addingTimeInterval(seconds))
    }

    static func errorText(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (root["hint"] as? String) ?? (root["message"] as? String) ?? (root["error_description"] as? String) ?? (root["error"] as? String)
    }

    static func formBody(_ form: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form.keys.sorted().map { key in
            let value = form[key] ?? ""
            return "\(key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&")
    }

    private static func userName(token: String) async -> String? {
        guard let data = await call("users/@me", token: token),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return root["name"] as? String
    }

    /// A current access token, renewed first when it runs out within five minutes.
    static func validToken(now: Date = Date()) async -> String? {
        guard MALSettings.isEnabled, let login else { return nil }
        if login.expiresAt.timeIntervalSince(now) > 300 { return login.accessToken }
        guard let renewed = try? await tokens([
            "client_id": login.clientID,
            "grant_type": "refresh_token",
            "refresh_token": login.refreshToken,
        ], now: now) else {
            return login.expiresAt > now ? login.accessToken : nil
        }
        var updated = login
        updated.accessToken = renewed.accessToken
        updated.refreshToken = renewed.refreshToken
        updated.expiresAt = renewed.expiresAt
        MALKeychain.save(updated, for: ProfileSettings.activeProfileScope)
        return renewed.accessToken
    }

    // MARK: Calls

    /// A call to MAL's API as the viewer.
    static func call(_ path: String, query: [String: String] = [:], method: String = "GET", form: [String: String]? = nil, token: String? = nil) async -> Data? {
        let bearer: String?
        if let token { bearer = token } else { bearer = await validToken() }
        guard let bearer, var components = URLComponents(url: apiBase.appendingPathComponent(path), resolvingAgainstBaseURL: false) else { return nil }
        if !query.isEmpty {
            components.queryItems = query.keys.sorted().map { URLQueryItem(name: $0, value: query[$0]) }
        }
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        if let form {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(formBody(form).utf8)
        }
        guard let reply = try? await URLSession.shared.data(for: request),
              let http = reply.1 as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        return reply.0
    }

    // MARK: Lists

    static let lists = MALListCache()

    /// The viewer's titles with this status (watching, completed, on_hold, dropped,
    /// plan_to_watch), last changed first.
    static func list(status: String) async -> [TenraiAnime] {
        guard isLoggedIn else { return [] }
        if let kept = await lists.items(status) { return kept }
        guard let data = await call("users/@me/animelist", query: [
            "status": status,
            "sort": "list_updated_at",
            "limit": "100",
            "fields": "alternative_titles,media_type,start_season,mean,synopsis",
            "nsfw": MALSettings.showsAdult ? "true" : "false",
        ]) else { return [] }
        let items = listItems(from: data)
        await lists.keep(items, for: status)
        return items
    }

    /// MAL's list answer as Tenrai's shape, to make the same cards.
    static func listItems(from data: Data) -> [TenraiAnime] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["data"] as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            guard let node = entry["node"] as? [String: Any], let id = node["id"] as? Int else { return nil }
            let picture = node["main_picture"] as? [String: Any]
            let alternative = node["alternative_titles"] as? [String: Any]
            let english = (alternative?["en"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let japanese = (alternative?["ja"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let season = node["start_season"] as? [String: Any]
            return TenraiAnime(
                malID: id,
                title: node["title"] as? String,
                titleEnglish: english,
                titleJapanese: japanese,
                images: TenraiAnime.Images(jpg: TenraiAnime.Picture(
                    imageURL: picture?["medium"] as? String, largeImageURL: picture?["large"] as? String
                )),
                synopsis: node["synopsis"] as? String,
                type: (node["media_type"] as? String) == "movie" ? "Movie" : "TV",
                year: season?["year"] as? Int,
                score: node["mean"] as? Double
            )
        }
    }

    // MARK: Writing to the list

    struct ListStatus: Equatable, Sendable {
        var status: String?
        var watched: Int
        var episodes: Int
        var score: Int = 0
    }

    /// Posted after Nuvio changed the viewer's MAL list.
    static let changedNotification = Notification.Name("nuvio.mal.listChanged")

    static let statuses = ["watching", "completed", "on_hold", "dropped", "plan_to_watch"]

    static func statusLabel(_ status: String?) -> String {
        switch status {
        case "watching": return "Watching"
        case "completed": return "Completed"
        case "on_hold": return "On-Hold"
        case "dropped": return "Dropped"
        case "plan_to_watch": return "Plan to Watch"
        default: return "MAL"
        }
    }

    /// The details button's title: "Watching 5/12", "Plan to Watch", "Add" when not listed.
    static func buttonTitle(_ status: ListStatus?) -> String {
        guard let status else { return "MAL" }
        guard let current = status.status else { return "Add" }
        let label = statusLabel(current)
        if current == "plan_to_watch" || current == "completed" { return label }
        return status.episodes > 0 ? "\(label) \(status.watched)/\(status.episodes)" : "\(label) \(status.watched)"
    }

    static func setStatus(_ status: String, mal: Int, current: ListStatus?) async {
        var fields = ["status": status]
        if status == "completed", let episodes = current?.episodes, episodes > 0 {
            fields["num_watched_episodes"] = String(episodes)
        }
        await update(mal: mal, fields)
    }

    /// 1–10; 0 takes the score away.
    static func setScore(_ score: Int, mal: Int) async {
        await update(mal: mal, ["score": String(min(max(score, 0), 10))])
    }

    static func remove(mal: Int) async {
        if await call("anime/\(mal)/my_list_status", method: "DELETE", form: [:]) != nil {
            await lists.forget()
            NotificationCenter.default.post(name: changedNotification, object: nil)
        }
    }

    static func listStatus(mal: Int) async -> ListStatus? {
        guard let data = await call("anime/\(mal)", query: ["fields": "my_list_status,num_episodes"]),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let mine = root["my_list_status"] as? [String: Any]
        return ListStatus(
            status: mine?["status"] as? String,
            watched: mine?["num_episodes_watched"] as? Int ?? 0,
            episodes: root["num_episodes"] as? Int ?? 0,
            score: mine?["score"] as? Int ?? 0
        )
    }

    @discardableResult
    static func update(mal: Int, _ fields: [String: String]) async -> Bool {
        let done = await call("anime/\(mal)/my_list_status", method: "PATCH", form: fields) != nil
        if done {
            await lists.forget()
            NotificationCenter.default.post(name: changedNotification, object: nil)
        }
        return done
    }

    /// "+" in details: Plan to Watch when it isn't on the list; taken off only while still there.
    static func libraryChanged(aniListID: Int, added: Bool) async {
        // Settings → MyAnimeList → "+" in Details: Plan to Watch, Watching or nothing.
        let wanted = MALSettings.plusStatus
        guard isLoggedIn, wanted != .off, let mal = await MALEpisodeRatings.malID(aniListID: aniListID),
              let current = await listStatus(mal: mal) else { return }
        if added {
            guard current.status == nil else { return }
            await update(mal: mal, ["status": wanted.rawValue])
        } else if current.status == wanted.rawValue {
            await remove(mal: mal)
        }
    }

    /// Watched up to `episode` (never back): Watching, or Completed at the last episode.
    static func watched(aniListID: Int, episode: Int) async {
        guard MALSettings.scrobbles, let mal = await MALEpisodeRatings.malID(aniListID: aniListID),
              let current = await listStatus(mal: mal) else { return }
        guard let fields = progress(current, watched: episode) else { return }
        await update(mal: mal, fields)
    }

    /// Unwatched from `episode` on: the count goes back to the episode before.
    static func unwatched(aniListID: Int, episode: Int) async {
        guard MALSettings.scrobbles, let mal = await MALEpisodeRatings.malID(aniListID: aniListID),
              let current = await listStatus(mal: mal), current.watched >= episode else { return }
        await update(mal: mal, ["num_watched_episodes": String(max(0, episode - 1)), "status": "watching"])
    }

    /// What to write after watching `episode`; nil when the list is already that far.
    static func progress(_ current: ListStatus, watched episode: Int) -> [String: String]? {
        guard episode > current.watched || current.status == nil || current.status == "plan_to_watch" else { return nil }
        let count = max(episode, current.watched)
        let finished = current.episodes > 0 && count >= current.episodes
        return ["num_watched_episodes": String(count), "status": finished ? "completed" : "watching"]
    }
}

/// The viewer's MAL lists, kept five minutes and dropped whenever Nuvio changes one.
actor MALListCache {
    private var kept: [String: (items: [TenraiAnime], until: Date)] = [:]

    func items(_ status: String, now: Date = Date()) -> [TenraiAnime]? {
        guard let hit = kept[status], hit.until > now else { return nil }
        return hit.items
    }

    func keep(_ items: [TenraiAnime], for status: String, now: Date = Date()) {
        kept[status] = (items, now.addingTimeInterval(5 * 60))
    }

    func forget() { kept = [:] }
}

/// The MAL login in the Keychain, one per profile, never synced.
enum MALKeychain {
    private static let service = "com.nuvio.tv.mal.auth"

    static func login(for profileScope: String) -> MALAccount.Login? {
        var query = base(profileScope)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(MALAccount.Login.self, from: data)
    }

    static func save(_ login: MALAccount.Login, for profileScope: String) {
        guard let data = try? JSONEncoder().encode(login) else { return }
        let query = base(profileScope)
        let attributes: [String: Any] = [kSecValueData as String: data]
        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    static func remove(for profileScope: String) {
        SecItemDelete(base(profileScope) as CFDictionary)
    }

    private static func base(_ profileScope: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileScope,
            kSecAttrSynchronizable as String: false,
        ]
    }
}
