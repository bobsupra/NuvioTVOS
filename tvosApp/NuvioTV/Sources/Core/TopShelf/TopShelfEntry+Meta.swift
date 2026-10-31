import Foundation

// App-only: builds shelf entries from the app's metadata. The extension target
// compiles only TopShelfFeed.swift and TopShelfLayout.swift, which stay free of
// app model types.

extension TopShelfEntry {
    /// A shelf entry for `meta`, carrying what the carousel details show.
    init(meta: NuvioMeta, subtitle: String?, progress: Double?, action: TopShelfEntryAction) {
        self.init(
            contentId: meta.id,
            contentType: meta.type,
            title: meta.name,
            subtitle: subtitle,
            imageURL: meta.posterUrl,
            backdropURL: meta.backdropUrl,
            progress: progress,
            action: action,
            summary: Self.nonEmpty(meta.description),
            genres: meta.genres.map { Array($0.prefix(3)) }.flatMap { $0.isEmpty ? nil : $0 },
            year: meta.year,
            releaseDate: Self.nonEmpty(meta.released),
            runtimeMinutes: Self.runtimeMinutes(meta.runtime),
            logoURL: Self.nonEmpty(meta.logoUrl),
            cast: meta.cast.map { Array($0.prefix(4)) }.flatMap { $0.isEmpty ? nil : $0 },
            directors: meta.director.map { Array($0.prefix(2)) }.flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    /// Minutes from the metadata's runtime text: "142 min", "2h 22m",
    /// "2 hr 22 min", "1:58" or a bare number of minutes.
    static func runtimeMinutes(_ runtime: String?) -> Int? {
        guard let text = runtime?.lowercased(), !text.isEmpty else { return nil }
        let numbers = text.components(separatedBy: CharacterSet.decimalDigits.inverted)
            .filter { !$0.isEmpty }
            .compactMap(Int.init)
        guard let first = numbers.first else { return nil }
        let hasHours = text.contains("h") || text.contains(":")
        let minutes = hasHours ? first * 60 + (numbers.dropFirst().first ?? 0) : first
        return minutes > 0 ? minutes : nil
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
