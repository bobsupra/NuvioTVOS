import Foundation

/// What Surprise Me learned from the viewer's reactions to its suggestions,
/// kept per profile across launches:
///
/// - liked: they opened the suggestion (View),
/// - skipped: they asked for Another one without opening it,
/// - watched: a suggestion that later shows up in their history, the strongest signal.
///
/// It feeds both sides of Surprise Me: the AI is told what landed and what
/// didn't, and the on-device taste profile leans towards liked genres and
/// away from skipped ones. Only titles, years and genres are kept.
struct SurpriseMeFeedbackEntry: Codable, Equatable {
    enum Verdict: String, Codable {
        case liked
        case skipped
    }

    let id: String
    let title: String
    let year: Int?
    let genres: [String]
    /// "movie" or "series". Missing in entries saved before series were
    /// suggested, which were all movies.
    let type: String?
    let verdict: Verdict
    let date: Date

    init(meta: NuvioMeta, verdict: Verdict, date: Date = Date()) {
        id = meta.id
        title = meta.name
        year = meta.year
        genres = meta.genres ?? []
        type = meta.type
        self.verdict = verdict
        self.date = date
    }

    var meta: NuvioMeta {
        NuvioMeta(id: id, name: title, type: type ?? "movie", year: year, genres: genres)
    }
}

struct SurpriseMeFeedback: Equatable {
    static let storageKey = "nuvio.tv.surpriseMe.feedback"
    /// Enough to learn from, small enough for the AI prompt and the settings store.
    static let maxEntries = 150

    private(set) var entries: [SurpriseMeFeedbackEntry]

    init(entries: [SurpriseMeFeedbackEntry] = []) {
        self.entries = entries
    }

    /// Newest first. A title keeps only its latest verdict: opening something
    /// once skipped counts as liked.
    mutating func record(_ meta: NuvioMeta, _ verdict: SurpriseMeFeedbackEntry.Verdict, date: Date = Date()) {
        entries.removeAll { $0.id == meta.id }
        entries.insert(SurpriseMeFeedbackEntry(meta: meta, verdict: verdict, date: date), at: 0)
        if entries.count > Self.maxEntries { entries.removeLast(entries.count - Self.maxEntries) }
    }

    var liked: [NuvioMeta] { entries.filter { $0.verdict == .liked }.map(\.meta) }
    var skipped: [NuvioMeta] { entries.filter { $0.verdict == .skipped }.map(\.meta) }

    /// Liked suggestions the viewer then watched.
    func watched(in history: SurpriseMeHistory) -> [NuvioMeta] {
        liked.filter(history.contains)
    }

    func verdict(for meta: NuvioMeta) -> SurpriseMeFeedbackEntry.Verdict? {
        entries.first { $0.id == meta.id }?.verdict
    }

    // MARK: Storage

    static func load(from defaults: UserDefaults = ProfileSettings.current) -> SurpriseMeFeedback {
        guard let data = defaults.data(forKey: storageKey),
              let entries = try? JSONDecoder().decode([SurpriseMeFeedbackEntry].self, from: data) else {
            return SurpriseMeFeedback()
        }
        return SurpriseMeFeedback(entries: entries)
    }

    func save(to defaults: UserDefaults = ProfileSettings.current) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    static func clear(in defaults: UserDefaults = ProfileSettings.current) {
        defaults.removeObject(forKey: storageKey)
    }
}
