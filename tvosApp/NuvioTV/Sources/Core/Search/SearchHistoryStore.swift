import Foundation

/// Manages recent search history persistence, deduplication, and substring pruning.
///
/// Prevents intermediate typing prefixes and substrings (e.g., "S", "Si", "Sil" when typing "Silo")
/// from polluting recent search history, while preserving distinct search terms.
enum SearchHistoryStore {
    static let storageKey = "nuvio.search.recent"
    static let maxRecentSearches = 8
    static let minQueryLength = 2

    /// Sanitizes an array of queries by trimming whitespace, discarding entries shorter than `minQueryLength`,
    /// deduplicating case-insensitively, and removing any query that is a substring/prefix of a longer query
    /// in the list.
    static func sanitize(_ searches: [String], maxCount: Int = maxRecentSearches) -> [String] {
        var result: [String] = []
        for raw in searches {
            let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard term.count >= minQueryLength else { continue }

            // If already in result (case-insensitive), skip
            if result.contains(where: { $0.caseInsensitiveCompare(term) == .orderedSame }) {
                continue
            }

            // If a previously accepted entry is a longer string that has prefix or contains `term`,
            // then `term` is an older/redundant substring or prefix.
            if result.contains(where: { existing in
                existing.count > term.count && isPrefixOrSubstring(needle: term, haystack: existing)
            }) {
                continue
            }

            // If `term` is longer and has prefix or contains any existing entries in `result`,
            // remove those existing shorter entries.
            result.removeAll { existing in
                term.count > existing.count && isPrefixOrSubstring(needle: existing, haystack: term)
            }

            result.append(term)
            if result.count >= maxCount {
                break
            }
        }
        return Array(result.prefix(maxCount))
    }

    /// Loads and sanitizes recent searches from UserDefaults.
    static func load(defaults: UserDefaults = .standard) -> [String] {
        let stored = defaults.stringArray(forKey: storageKey) ?? []
        let sanitized = sanitize(stored)
        if sanitized != stored {
            defaults.set(sanitized, forKey: storageKey)
        }
        return sanitized
    }

    /// Records a new search term into `current`, pruning any precursor substrings/prefixes
    /// and accounting for the active typing session (e.g. user backspacing).
    ///
    /// - Parameters:
    ///   - term: The query being searched.
    ///   - current: The current list of recent searches.
    ///   - sessionQuery: The query previously committed during this editing session (if any).
    ///   - maxCount: Maximum number of recent searches to retain.
    /// - Returns: A tuple of the updated recent searches list and the new session committed query.
    static func commit(
        _ term: String,
        current: [String],
        sessionQuery: String? = nil,
        maxCount: Int = maxRecentSearches
    ) -> (updated: [String], newSessionQuery: String?) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minQueryLength else {
            return (current, sessionQuery)
        }

        var list = current

        // If the user backspaced from a longer query committed in the same typing session
        // (e.g., committed "Silo", then backspaced to "Sil"), replace the longer precursor.
        if let session = sessionQuery,
           session.count > trimmed.count,
           isPrefixOrSubstring(needle: trimmed, haystack: session) {
            list.removeAll { $0.caseInsensitiveCompare(session) == .orderedSame }
        }

        // Remove exact duplicate
        list.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }

        // Remove any existing entries that are shorter prefixes or substrings of `trimmed`.
        // (e.g., existing "Si" or "Sil" when user searches "Silo", or "The" / "Bat" when searching "The Batman").
        list.removeAll { existing in
            trimmed.count > existing.count && isPrefixOrSubstring(needle: existing, haystack: trimmed)
        }

        // Insert new term at the top
        list.insert(trimmed, at: 0)

        let result = Array(list.prefix(maxCount))
        return (result, trimmed)
    }

    /// Helper checking whether `needle` is a prefix or substring of `haystack` (case and diacritic insensitive).
    static func isPrefixOrSubstring(needle: String, haystack: String) -> Bool {
        let needleFolded = needle.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let haystackFolded = haystack.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)

        if haystackFolded.hasPrefix(needleFolded) {
            return true
        }

        // For non-prefix substrings, require at least 3 characters to avoid aggressive single/two-character
        // matching across unrelated words.
        if needleFolded.count >= 3 && haystackFolded.contains(needleFolded) {
            return true
        }

        return false
    }

    /// Saves the recent searches to UserDefaults.
    static func save(_ searches: [String], defaults: UserDefaults = .standard) {
        defaults.set(searches, forKey: storageKey)
    }
}
