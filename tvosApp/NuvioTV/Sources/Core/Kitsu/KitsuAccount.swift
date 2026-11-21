import Foundation
import Security

/// The viewer's Kitsu account: logged in with their Kitsu email (or name) and password (Kitsu has
/// no other way for an app), kept in the Keychain per profile. Their library on Kitsu takes what
/// they watch, "+" in details, and the status they choose in details' Kitsu menu; their lists can
/// be Home rows.
enum KitsuAccount {
    static let changedNotification = Notification.Name("nuvio.kitsu.accountChanged")
    static let tokenURL = URL(string: "https://kitsu.app/api/oauth/token")!

    struct Login: Codable, Equatable, Sendable {
        var accessToken: String
        var refreshToken: String
        var expiresAt: Date
        var userID: String
        var userName: String
    }

    /// One of the viewer's library entries.
    struct Entry: Equatable, Sendable {
        var id: String?
        var status: String?
        var progress: Int
        var episodes: Int
        var rating: Int?
    }

    static let statuses = ["current", "planned", "completed", "on_hold", "dropped"]

    static func statusLabel(_ status: String) -> String {
        switch status {
        case "current": return "Watching"
        case "planned": return "Plan to Watch"
        case "completed": return "Completed"
        case "on_hold": return "On Hold"
        case "dropped": return "Dropped"
        default: return status
        }
    }

    static var login: Login? { KitsuKeychain.login(for: ProfileSettings.activeProfileScope) }
    static var isLoggedIn: Bool { KitsuSettings.isEnabled && login != nil }

    // MARK: Logging in

    enum LoginError: Error, LocalizedError {
        case wrongCredentials
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .wrongCredentials: return "Wrong email or password"
            case .failed(let message): return message
            }
        }
    }

    /// Logs in with the viewer's Kitsu email (or name) and password; the password isn't kept.
    @discardableResult
    static func logIn(user: String, password: String) async throws -> Login {
        let tokens = try await Self.tokens(form: [
            "grant_type": "password",
            "username": user.trimmingCharacters(in: .whitespacesAndNewlines),
            "password": password,
        ])
        let me = try await currentUser(token: tokens.accessToken)
        let login = Login(
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken,
            expiresAt: tokens.expiresAt,
            userID: me.id,
            userName: me.name
        )
        KitsuKeychain.save(login, for: ProfileSettings.activeProfileScope)
        await lists.forget()
        NotificationCenter.default.post(name: changedNotification, object: nil)
        AniListSettings.notifyHomeChanged()
        return login
    }

    static func logOut() {
        KitsuKeychain.remove(for: ProfileSettings.activeProfileScope)
        Task { await lists.forget() }
        NotificationCenter.default.post(name: changedNotification, object: nil)
        AniListSettings.notifyHomeChanged()
    }

    struct Tokens {
        var accessToken: String
        var refreshToken: String
        var expiresAt: Date
    }

    static func tokens(form: [String: String]) async throws -> Tokens {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody(form)
        let reply: (Data, URLResponse)
        do {
            reply = try await URLSession.shared.data(for: request)
        } catch {
            throw LoginError.failed("No answer from Kitsu: \(error.localizedDescription)")
        }
        let code = (reply.1 as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw code == 400 || code == 401 ? LoginError.wrongCredentials : LoginError.failed("Kitsu answered \(code)")
        }
        return try parseTokens(reply.0)
    }

    static func parseTokens(_ data: Data, now: Date = Date()) throws -> Tokens {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = root["access_token"] as? String, !access.isEmpty else {
            throw LoginError.failed("Kitsu's answer had no token")
        }
        let lifetime = (root["expires_in"] as? Double) ?? (root["expires_in"] as? Int).map(Double.init) ?? 30 * 24 * 3600
        return Tokens(
            accessToken: access,
            refreshToken: root["refresh_token"] as? String ?? "",
            expiresAt: now.addingTimeInterval(lifetime)
        )
    }

    static func formBody(_ form: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return Data(form.sorted { $0.key < $1.key }.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&").utf8)
    }

    static func currentUser(token: String) async throws -> (id: String, name: String) {
        let data: Data
        do {
            data = try await KitsuClient.shared.get("users", query: [("filter[self]", "true")], ttl: 0, token: token)
        } catch {
            throw LoginError.failed("Kitsu didn't say who is logged in: \(MALSource.describe(error))")
        }
        guard let user = KitsuSource.document(data)?.first else { throw LoginError.failed("Kitsu didn't say who is logged in") }
        return (user.id, user.attributes?.name ?? user.id)
    }

    /// A token that still works: refreshed a day before it ends; nil when logged out (or Kitsu
    /// no longer takes the refresh token).
    static func validToken() async -> (token: String, userID: String)? {
        guard KitsuSettings.isEnabled, let login else { return nil }
        if login.expiresAt.timeIntervalSinceNow > 24 * 3600 { return (login.accessToken, login.userID) }
        guard !login.refreshToken.isEmpty,
              let fresh = try? await tokens(form: ["grant_type": "refresh_token", "refresh_token": login.refreshToken]) else {
            return login.expiresAt > Date() ? (login.accessToken, login.userID) : nil
        }
        var renewed = login
        renewed.accessToken = fresh.accessToken
        if !fresh.refreshToken.isEmpty { renewed.refreshToken = fresh.refreshToken }
        renewed.expiresAt = fresh.expiresAt
        KitsuKeychain.save(renewed, for: ProfileSettings.activeProfileScope)
        return (renewed.accessToken, renewed.userID)
    }

    // MARK: Library

    /// The viewer's entry for a Kitsu anime (nil when Kitsu couldn't be asked).
    static func entry(kitsu: Int) async -> Entry? {
        guard let auth = await validToken(),
              let data = try? await KitsuClient.shared.get(
                  "library-entries",
                  query: [("filter[userId]", auth.userID), ("filter[animeId]", String(kitsu)), ("include", "anime")],
                  ttl: 0,
                  token: auth.token
              ),
              let document = KitsuSource.document(data) else { return nil }
        let episodes = document.included.first { $0.type == "anime" }?.attributes?.episodeCount ?? 0
        guard let found = document.first else {
            let count = await episodeCount(kitsu: kitsu)
            return Entry(id: nil, status: nil, progress: 0, episodes: count, rating: nil)
        }
        return Entry(
            id: found.id,
            status: found.attributes?.status,
            progress: found.attributes?.progress ?? 0,
            episodes: episodes,
            rating: found.attributes?.ratingTwenty
        )
    }

    static func episodeCount(kitsu: Int) async -> Int {
        (try? await KitsuSource.entry(kitsu))?.episodes ?? 0
    }

    /// Writes `attributes` to the viewer's entry, making one when there is none. True when done.
    @discardableResult
    static func write(kitsu: Int, entry: Entry?, attributes: [String: Any]) async -> Bool {
        guard let auth = await validToken() else { return false }
        var data: [String: Any] = ["type": "libraryEntries", "attributes": attributes]
        let method: String
        let path: String
        if let id = entry?.id {
            data["id"] = id
            method = "PATCH"
            path = "library-entries/\(id)"
        } else {
            data["relationships"] = [
                "user": ["data": ["type": "users", "id": auth.userID]],
                "anime": ["data": ["type": "anime", "id": String(kitsu)]],
            ]
            method = "POST"
            path = "library-entries"
        }
        guard let body = try? JSONSerialization.data(withJSONObject: ["data": data]),
              (try? await KitsuClient.shared.change(path, method: method, body: body, token: auth.token)) != nil else { return false }
        await changed()
        return true
    }

    static func remove(kitsu: Int) async {
        guard let auth = await validToken(), let id = await entry(kitsu: kitsu)?.id else { return }
        if (try? await KitsuClient.shared.change("library-entries/\(id)", method: "DELETE", body: nil, token: auth.token)) != nil {
            await changed()
        }
    }

    private static func changed() async {
        await lists.forget()
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }

    /// Watched up to `episode` (never back): Watching, or Completed at the last episode.
    static func watched(kitsu: Int, episode: Int) async {
        guard KitsuSettings.scrobbles, isLoggedIn, let current = await entry(kitsu: kitsu) else { return }
        guard current.status != "completed", episode > current.progress else { return }
        let done = current.episodes > 0 && episode >= current.episodes
        await write(kitsu: kitsu, entry: current, attributes: ["progress": episode, "status": done ? "completed" : "current"])
    }

    /// Unwatched from `episode` on: progress goes back to the episode before.
    static func unwatched(kitsu: Int, episode: Int) async {
        guard KitsuSettings.scrobbles, isLoggedIn, let current = await entry(kitsu: kitsu), current.id != nil,
              current.progress >= episode else { return }
        await write(kitsu: kitsu, entry: current, attributes: ["progress": max(0, episode - 1), "status": "current"])
    }

    /// "+" in details: Plan to Watch when it isn't in the library; taken off only while planned.
    static func libraryChanged(kitsu: Int, added: Bool) async {
        guard isLoggedIn, let current = await entry(kitsu: kitsu) else { return }
        if added {
            guard current.status == nil else { return }
            await write(kitsu: kitsu, entry: current, attributes: ["status": "planned"])
        } else if current.status == "planned" {
            await remove(kitsu: kitsu)
        }
    }

    static func setStatus(_ status: String, kitsu: Int, current: Entry?) async {
        var attributes: [String: Any] = ["status": status]
        if status == "completed", let episodes = current?.episodes, episodes > 0 {
            attributes["progress"] = episodes
        }
        await write(kitsu: kitsu, entry: current, attributes: attributes)
    }

    /// A score out of 10 (Kitsu keeps it out of 20); 0 takes it off.
    static func setScore(_ score: Int, kitsu: Int, current: Entry?) async {
        var attributes: [String: Any] = [:]
        if score > 0 {
            attributes["ratingTwenty"] = score * 2
        } else {
            attributes["ratingTwenty"] = NSNull()
        }
        await write(kitsu: kitsu, entry: current, attributes: attributes)
    }

    static func buttonTitle(_ entry: Entry?) -> String {
        guard let entry else { return "Kitsu" }
        guard let status = entry.status else { return L10n.string("action_add", fallback: "Add") }
        let label = statusLabel(status)
        if status == "planned" || status == "completed" { return label }
        return entry.episodes > 0 ? "\(label) \(entry.progress)/\(entry.episodes)" : "\(label) \(entry.progress)"
    }

    // MARK: Lists

    static let lists = KitsuLists()

    /// The anime of one of the viewer's lists, last updated first.
    static func list(status: String) async -> [KitsuResource] {
        guard isLoggedIn else { return [] }
        if let kept = await lists.items(status) { return kept }
        guard let auth = await validToken(),
              let data = try? await KitsuClient.shared.get(
                  "library-entries",
                  query: [
                      ("filter[userId]", auth.userID), ("filter[status]", status), ("filter[kind]", "anime"),
                      ("include", "anime"), ("sort", "-updatedAt"), ("page[limit]", "20"),
                  ],
                  ttl: 0,
                  token: auth.token
              ),
              let document = KitsuSource.document(data) else { return [] }
        let lookup = document.lookup
        let anime = document.data.compactMap { lookup.related($0, "anime").first }
        await lists.store(status, anime)
        return anime
    }
}

/// The viewer's lists, kept ten minutes.
actor KitsuLists {
    private var kept: [String: (items: [KitsuResource], until: Date)] = [:]

    func items(_ status: String) -> [KitsuResource]? {
        guard let found = kept[status], found.until > Date() else { return nil }
        return found.items
    }

    func store(_ status: String, _ items: [KitsuResource]) {
        kept[status] = (items, Date().addingTimeInterval(600))
    }

    func forget() {
        kept = [:]
    }
}

/// The Kitsu login in the Keychain, one per profile, never synced.
enum KitsuKeychain {
    private static let service = "com.nuvio.tv.kitsu.auth"

    static func login(for profileScope: String) -> KitsuAccount.Login? {
        var query = base(profileScope)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(KitsuAccount.Login.self, from: data)
    }

    static func save(_ login: KitsuAccount.Login, for profileScope: String) {
        guard let data = try? JSONEncoder().encode(login) else { return }
        SecItemDelete(base(profileScope) as CFDictionary)
        var item = base(profileScope)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }

    static func remove(for profileScope: String) {
        SecItemDelete(base(profileScope) as CFDictionary)
    }

    private static func base(_ profileScope: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileScope,
        ]
    }
}
