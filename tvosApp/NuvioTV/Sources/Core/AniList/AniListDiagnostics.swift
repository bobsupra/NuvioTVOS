import Foundation

/// What Home and Search last did with AniList, for Settings → Integrations → AniList → Status.
/// Kept apart from the client's own status, so Test Connection can't hide what went wrong.
enum AniListDiagnostics {
    enum Area: Hashable {
        case home
        case search
        /// The viewer's account: logging in, and what Nuvio last wrote to their list.
        case account
    }

    struct Entry: Equatable {
        let date: Date
        let text: String
    }

    private static let lock = NSLock()
    private static var entries: [Area: Entry] = [:]
    /// AniList rows Home had on screen when its last load finished.
    private static var homeOnScreen: (date: Date, rows: Int)?

    static func note(_ area: Area, _ text: String, at date: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        entries[area] = Entry(date: date, text: text)
    }

    static func noteHomeOnScreen(rows: Int, at date: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        homeOnScreen = (date, rows)
    }

    static func entry(_ area: Area) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        return entries[area]
    }

    /// "21:38 · 5 rows, 150 titles · from AniList · 5 on screen", or that nothing was asked yet.
    static func text(_ area: Area, timeStyle: (Date) -> String = AniListDiagnostics.time) -> String {
        lock.lock()
        let entry = entries[area]
        let onScreen = homeOnScreen
        lock.unlock()
        guard let entry else { return "Not asked yet" }
        var text = "\(timeStyle(entry.date)) · \(entry.text)"
        if area == .home, let onScreen, onScreen.date >= entry.date {
            text += " · \(onScreen.rows) on screen"
        }
        return text
    }

    /// Where an answer came from, for the texts above.
    static func source(_ answer: AniListClient.Answer) -> String {
        answer.isSaved ? "saved answer" : "from AniList"
    }

    /// A failure in a few words.
    static func describe(_ error: Error) -> String {
        switch error {
        case AniListClient.ClientError.rateLimited:
            return "AniList's rate limit (30 a minute)"
        case AniListClient.ClientError.badResponse(let code):
            return "HTTP \(code)"
        case AniListClient.ClientError.refused(let code, let message):
            return "HTTP \(code) · \(message)"
        case AniListClient.ClientError.answeredWithError(let message):
            return "AniList: \(message)"
        case is DecodingError:
            return "unreadable answer"
        default:
            return error.localizedDescription
        }
    }

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        entries = [:]
        homeOnScreen = nil
    }

    static func time(_ date: Date) -> String {
        DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short)
    }
}
