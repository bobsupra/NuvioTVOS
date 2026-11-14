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

enum SurpriseMeAI {
    static let maxCandidates = 40
    static let maxHistoryTitles = 30

    /// The prompt: the viewer's favourite genres and recent titles, then the
    /// numbered candidates. Titles and years only, nothing else about the viewer.
    static func prompt(profile: TasteProfile, recentTitles: [NuvioMeta], candidates: [NuvioMeta], language: String) -> String {
        let history = recentTitles.prefix(maxHistoryTitles).map { title(of: $0) }.joined(separator: "; ")
        let list = candidates.prefix(maxCandidates).enumerated().map { index, meta in
            let genres = (meta.genres ?? []).prefix(3).joined(separator: ", ")
            return "\(index + 1). \(title(of: meta))\(genres.isEmpty ? "" : " — \(genres)")"
        }.joined(separator: "\n")
        return """
        You recommend movies. The viewer's favourite genres: \(profile.topGenres.joined(separator: ", ")).
        Titles they watched or saved recently: \(history.isEmpty ? "none yet" : history).

        Choose the 5 movies from this numbered list they are most likely to enjoy, best first. \
        Only use numbers from the list.
        \(list)

        Answer with JSON only: {"picks":[{"number":1,"reason":"..."}]}. \
        Each reason is one short sentence in \(language) that mentions what they watched when it helps.
        """
    }

    private static func title(of meta: NuvioMeta) -> String {
        meta.year.map { "\(meta.name) (\($0))" } ?? meta.name
    }

    /// Reads the AI's answer back into candidates. Numbers outside the list and
    /// repeats are dropped, so only real, checked titles come out.
    static func parse(_ text: String, candidates: [NuvioMeta]) -> [SurpriseMeAIPick] {
        struct Answer: Decodable {
            struct Pick: Decodable {
                let number: Int
                let reason: String?
            }
            let picks: [Pick]
        }
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let answer = try? JSONDecoder().decode(Answer.self, from: Data(text[start...end].utf8)) else { return [] }
        var used = Set<Int>()
        return answer.picks.compactMap { pick in
            let index = pick.number - 1
            guard candidates.indices.contains(index), index < maxCandidates, used.insert(index).inserted else { return nil }
            let reason = pick.reason?.trimmingCharacters(in: .whitespacesAndNewlines)
            return SurpriseMeAIPick(meta: candidates[index], reason: reason?.isEmpty == false ? reason : nil)
        }
    }

    static func rank(
        candidates: [NuvioMeta],
        profile: TasteProfile,
        recentTitles: [NuvioMeta],
        configuration: SurpriseMeAIConfiguration,
        language: String,
        session: URLSession = .shared
    ) async -> [SurpriseMeAIPick] {
        guard configuration.isUsable, !candidates.isEmpty else { return [] }
        let text = prompt(profile: profile, recentTitles: recentTitles, candidates: candidates, language: language)
        guard let request = request(for: text, configuration: configuration),
              let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let answer = responseText(from: data, provider: configuration.provider) else { return [] }
        return parse(answer, candidates: Array(candidates.prefix(maxCandidates)))
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
