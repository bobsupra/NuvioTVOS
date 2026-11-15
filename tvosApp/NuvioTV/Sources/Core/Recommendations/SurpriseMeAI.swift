import Foundation
import Security

/// Optional AI help for Surprise Me, with the viewer's own API key.
///
/// The AI never invents titles: it gets a numbered list of real candidates
/// (already filtered to movies the viewer hasn't watched) and answers with
/// the numbers it picks and a short reason. Anything else in the answer is
/// ignored. Without a key, or when a request fails, Surprise Me picks on its own.
enum SurpriseMeAIProvider: String, CaseIterable, Identifiable {
    case off = "Off"
    case gemini = "Gemini"
    case deepSeek = "DeepSeek"
    case openRouter = "OpenRouter"

    var id: String { rawValue }

    var defaultModel: String {
        switch self {
        case .off: return ""
        case .gemini: return "gemini-3.6-flash"
        case .deepSeek: return "deepseek-chat"
        case .openRouter: return "google/gemini-2.5-flash"
        }
    }

    var keyHint: String {
        switch self {
        case .off: return ""
        case .gemini: return L10n.string("surprise_me_ai_gemini_key_hint", fallback: "Create a free key in Google AI Studio")
        case .deepSeek: return L10n.string("surprise_me_ai_deepseek_key_hint", fallback: "Create a key at platform.deepseek.com")
        case .openRouter: return L10n.string("surprise_me_ai_openrouter_key_hint", fallback: "Use an OpenRouter API key")
        }
    }
}

/// Keys stay in this Apple TV's Keychain, per profile, and never sync. Gemini
/// and OpenRouter fall back to the key already saved for AI Subtitles.
enum SurpriseMeAIKeyStore {
    private static let service = "com.nuvio.tv.surprise-me-ai"

    static func apiKey(for provider: SurpriseMeAIProvider) -> String {
        guard provider != .off else { return "" }
        if let own = read(provider), !own.isEmpty { return own }
        switch provider {
        case .gemini: return AISubtitleKeyStore.apiKey(for: .gemini)
        case .openRouter: return AISubtitleKeyStore.apiKey(for: .openRouter)
        case .deepSeek, .off: return ""
        }
    }

    /// The key saved for Surprise Me itself, without the AI Subtitles fallback.
    static func ownKey(for provider: SurpriseMeAIProvider) -> String {
        read(provider) ?? ""
    }

    @discardableResult
    static func save(_ key: String, for provider: SurpriseMeAIProvider) -> Bool {
        guard provider != .off else { return false }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return remove(provider) }
        let data = Data(trimmed.utf8)
        var add = query(provider)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecValueData as String] = data
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            return SecItemUpdate(query(provider) as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecSuccess
        }
        return status == errSecSuccess
    }

    @discardableResult
    static func remove(_ provider: SurpriseMeAIProvider) -> Bool {
        let status = SecItemDelete(query(provider) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func read(_ provider: SurpriseMeAIProvider) -> String? {
        var request = query(provider)
        request[kSecReturnData as String] = kCFBooleanTrue
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func query(_ provider: SurpriseMeAIProvider) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "\(provider.rawValue.lowercased()).\(ProfileSettings.activeProfileScope)",
        ]
    }
}

struct SurpriseMeAIConfiguration: Equatable {
    let provider: SurpriseMeAIProvider
    let apiKey: String
    let model: String

    var isUsable: Bool { provider != .off && !apiKey.isEmpty }

    static func current(defaults: UserDefaults = ProfileSettings.current) -> Self {
        let provider = SurpriseMeAIProvider(rawValue: defaults.string(forKey: SettingsKey.surpriseMeAIProvider) ?? "") ?? .off
        let storedModel = (defaults.string(forKey: SettingsKey.surpriseMeAIModel) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Self(
            provider: provider,
            apiKey: SurpriseMeAIKeyStore.apiKey(for: provider),
            model: storedModel.isEmpty ? provider.defaultModel : storedModel
        )
    }
}

struct SurpriseMeAIPick: Equatable {
    let meta: NuvioMeta
    let reason: String?
}

/// A title the AI suggested outside the candidate list. It is only shown after
/// TMDB confirms it exists and it isn't something the viewer already watched.
struct SurpriseMeAISuggestion: Equatable {
    let title: String
    let year: Int?
    let reason: String?
}

/// What the AI learns from: the whole taste profile, compacted, and how the
/// viewer reacted to this session's suggestions.
struct SurpriseMeAIContext {
    let profile: TasteProfile
    let history: SurpriseMeHistory
    /// Suggestions the viewer opened in this session.
    var opened: [NuvioMeta] = []
    /// Suggestions the viewer skipped with Another one in this session.
    var skipped: [NuvioMeta] = []
}

enum SurpriseMeAI {
    static let maxCandidates = 40
    static let maxWatchedTitles = 120
    static let maxSavedTitles = 60
    static let maxInProgressTitles = 20
    static let maxSessionTitles = 15
    static let maxOutsideSuggestions = 5

    /// The prompt: the viewer's genre shares, everything they watched, saved
    /// and are watching (most recent first, capped so the request stays small),
    /// how they reacted to this session's suggestions, and the numbered
    /// candidates. Titles and years only, nothing else about the viewer.
    static func prompt(context: SurpriseMeAIContext, candidates: [NuvioMeta], language: String) -> String {
        func titles(_ metas: [NuvioMeta], limit: Int) -> String {
            let list = SurpriseMeHistory.unique(metas).prefix(limit).map(title(of:))
            return list.isEmpty ? "none" : list.joined(separator: "; ")
        }
        let genres = context.profile.weights
            .sorted { $0.value > $1.value }
            .prefix(8)
            .map { "\(context.profile.displayName(for: $0.key)) \(Int(($0.value * 100).rounded()))%" }
            .joined(separator: ", ")
        let list = candidates.prefix(maxCandidates).enumerated().map { index, meta in
            let genres = (meta.genres ?? []).prefix(3).joined(separator: ", ")
            return "\(index + 1). \(title(of: meta))\(genres.isEmpty ? "" : " — \(genres)")"
        }.joined(separator: "\n")
        return """
        You recommend movies to one viewer. Learn their taste from everything below: \
        directors, actors, eras, tone and themes, not only genres.

        Genre shares of what they watch: \(genres.isEmpty ? "unknown yet" : genres).
        Watched (most recent first): \(titles(context.history.watched, limit: maxWatchedTitles)).
        Saved to watch later: \(titles(context.history.library, limit: maxSavedTitles)).
        Watching now: \(titles(context.history.continueWatching, limit: maxInProgressTitles)).
        In this session they opened: \(titles(context.opened, limit: maxSessionTitles)).
        In this session they skipped (avoid similar ones): \(titles(context.skipped, limit: maxSessionTitles)).

        1. Choose the 5 movies from this numbered list they are most likely to enjoy, best first. \
        Only use numbers from the list.
        \(list)

        2. Then suggest up to \(maxOutsideSuggestions) other real movies, not in the list and not \
        already watched, that fit them even better. Give the exact original title and release year.

        Answer with JSON only: \
        {"picks":[{"number":1,"reason":"..."}],"others":[{"title":"...","year":2016,"reason":"..."}]}. \
        Each reason is one short sentence in \(language) that mentions what they watched when it helps.
        """
    }

    private static func title(of meta: NuvioMeta) -> String {
        meta.year.map { "\(meta.name) (\($0))" } ?? meta.name
    }

    private struct Answer: Decodable {
        struct Pick: Decodable {
            let number: Int
            let reason: String?
        }
        struct Other: Decodable {
            let title: String
            let year: Int?
            let reason: String?
        }
        let picks: [Pick]?
        let others: [Other]?
    }

    private static func answer(from text: String) -> Answer? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        return try? JSONDecoder().decode(Answer.self, from: Data(text[start...end].utf8))
    }

    private static func cleaned(_ reason: String?) -> String? {
        let trimmed = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    /// Reads the AI's choices from the list back into candidates. Numbers
    /// outside the list and repeats are dropped, so only real, checked titles come out.
    static func parse(_ text: String, candidates: [NuvioMeta]) -> [SurpriseMeAIPick] {
        guard let picks = answer(from: text)?.picks else { return [] }
        var used = Set<Int>()
        return picks.compactMap { pick in
            let index = pick.number - 1
            guard candidates.indices.contains(index), index < maxCandidates, used.insert(index).inserted else { return nil }
            return SurpriseMeAIPick(meta: candidates[index], reason: cleaned(pick.reason))
        }
    }

    /// The AI's own suggestions outside the list, still to be confirmed on TMDB.
    static func parseOthers(_ text: String) -> [SurpriseMeAISuggestion] {
        guard let others = answer(from: text)?.others else { return [] }
        var seen = Set<String>()
        return others.prefix(maxOutsideSuggestions).compactMap { other in
            let title = other.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, seen.insert(title.lowercased()).inserted else { return nil }
            return SurpriseMeAISuggestion(title: title, year: other.year, reason: cleaned(other.reason))
        }
    }

    /// Asks the AI and returns its picks: first the ones from the list, then
    /// its own suggestions that TMDB confirms and the viewer hasn't watched.
    static func rank(
        candidates: [NuvioMeta],
        context: SurpriseMeAIContext,
        configuration: SurpriseMeAIConfiguration,
        language: String,
        isWatched: @escaping (NuvioMeta) -> Bool,
        session: URLSession = .shared
    ) async -> [SurpriseMeAIPick] {
        guard configuration.isUsable, !candidates.isEmpty else { return [] }
        let shortlist = Array(candidates.prefix(maxCandidates))
        let text = prompt(context: context, candidates: shortlist, language: language)
        guard let request = request(for: text, configuration: configuration),
              let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let answer = responseText(from: data, provider: configuration.provider) else { return [] }
        var picks = parse(answer, candidates: shortlist)
        let confirmed = await confirm(parseOthers(answer))
        var seen = Set(picks.flatMap { SurpriseMeHistory.keys(for: $0.meta) })
        for pick in confirmed where !isWatched(pick.meta) && seen.isDisjoint(with: SurpriseMeHistory.keys(for: pick.meta)) {
            seen.formUnion(SurpriseMeHistory.keys(for: pick.meta))
            picks.append(pick)
        }
        return picks
    }

    /// Looks each suggestion up on TMDB; ones it can't find are dropped.
    static func confirm(_ suggestions: [SurpriseMeAISuggestion]) async -> [SurpriseMeAIPick] {
        guard !suggestions.isEmpty, TmdbDetailsService.isAvailableForSurpriseMe else { return [] }
        return await withTaskGroup(of: (Int, SurpriseMeAIPick?).self) { group in
            for (index, suggestion) in suggestions.enumerated() {
                group.addTask {
                    let meta = await TmdbDetailsService.surpriseMeFindMovie(title: suggestion.title, year: suggestion.year)
                    return (index, meta.map { SurpriseMeAIPick(meta: $0, reason: suggestion.reason) })
                }
            }
            var results: [(Int, SurpriseMeAIPick)] = []
            for await (index, pick) in group {
                if let pick { results.append((index, pick)) }
            }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    static func request(for prompt: String, configuration: SurpriseMeAIConfiguration) -> URLRequest? {
        let url: URL?
        var body: [String: Any]
        switch configuration.provider {
        case .off:
            return nil
        case .gemini:
            url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(configuration.model):generateContent")
            body = [
                "contents": [["parts": [["text": prompt]]]],
                "generationConfig": ["responseMimeType": "application/json", "temperature": 0.9],
            ]
        case .deepSeek, .openRouter:
            url = URL(string: configuration.provider == .deepSeek
                      ? "https://api.deepseek.com/chat/completions"
                      : "https://openrouter.ai/api/v1/chat/completions")
            body = [
                "model": configuration.model,
                "messages": [["role": "user", "content": prompt]],
                "temperature": 0.9,
                "response_format": ["type": "json_object"],
            ]
        }
        guard let url, let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if configuration.provider == .gemini {
            request.setValue(configuration.apiKey, forHTTPHeaderField: "x-goog-api-key")
        } else {
            request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = data
        return request
    }

    static func responseText(from data: Data, provider: SurpriseMeAIProvider) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        switch provider {
        case .off:
            return nil
        case .gemini:
            let candidate = (json["candidates"] as? [[String: Any]])?.first
            let parts = (candidate?["content"] as? [String: Any])?["parts"] as? [[String: Any]]
            return parts?.compactMap { $0["text"] as? String }.joined()
        case .deepSeek, .openRouter:
            let choice = (json["choices"] as? [[String: Any]])?.first
            return (choice?["message"] as? [String: Any])?["content"] as? String
        }
    }
}
