import Foundation

/// Links to fonts: a sharing page becomes its direct download, a Google Fonts page its family.
enum SubtitleFontLinks {
    enum Target: Equatable {
        case file(URL)
        case googleFonts(String)
    }

    /// The user agent Google Fonts answers with TrueType files (others get WOFF2).
    static let trueTypeUserAgent = "Mozilla/5.0 (Unknown; Linux x86_64) AppleWebKit/538.1 (KHTML, like Gecko) Safari/538.1 Daum/4.1"

    static func target(for text: String) -> Target? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        let lowered = text.lowercased()
        if !lowered.hasPrefix("http://") && !lowered.hasPrefix("https://") {
            text = "https://" + text
        }
        guard var components = URLComponents(string: text),
              let host = components.host?.lowercased(), host.contains(".") else { return nil }
        let parts = components.percentEncodedPath.split(separator: "/").map(String.init)

        switch host {
        case "github.com", "www.github.com":
            // owner/repo/blob/ref/path… → raw.githubusercontent.com/owner/repo/ref/path…
            if parts.count >= 5, parts[2] == "blob" || parts[2] == "raw" {
                let path = ([parts[0], parts[1]] + parts[3...]).joined(separator: "/")
                if let url = URL(string: "https://raw.githubusercontent.com/" + path) { return .file(url) }
            }
        case "dropbox.com", "www.dropbox.com":
            var items = (components.queryItems ?? []).filter { $0.name != "dl" && $0.name != "raw" }
            items.append(URLQueryItem(name: "dl", value: "1"))
            components.queryItems = items
            if let url = components.url { return .file(url) }
        case "drive.google.com":
            if let id = driveFileID(parts: parts, query: components.queryItems),
               let url = URL(string: "https://drive.usercontent.google.com/download?id=\(id)&export=download&confirm=t") {
                return .file(url)
            }
        case "fonts.google.com":
            let decoded = components.path.split(separator: "/").map(String.init)
            if decoded.count >= 2, decoded[0] == "specimen" {
                let family = decoded[1].replacingOccurrences(of: "+", with: " ").trimmingCharacters(in: .whitespaces)
                if !family.isEmpty { return .googleFonts(family) }
            }
        default:
            break
        }
        return components.url.map(Target.file)
    }

    private static func driveFileID(parts: [String], query: [URLQueryItem]?) -> String? {
        if let index = parts.firstIndex(of: "d"), index > 0, parts[index - 1] == "file", index + 1 < parts.count {
            return parts[index + 1]
        }
        return query?.first(where: { $0.name == "id" })?.value.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Downloads a file of at most `limit` bytes.
    static func download(_ url: URL, limit: Int = SubtitleFontLimits.downloadBytes) async throws -> Data {
        let request = URLRequest(url: url, timeoutInterval: 60)
        let (file, response) = try await URLSession.shared.download(for: request)
        defer { try? FileManager.default.removeItem(at: file) }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw SubtitleFontError.download(http.statusCode)
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size <= limit else { throw SubtitleFontError.tooLarge(limit) }
        return try Data(contentsOf: file)
    }

    /// The TrueType files of a Google Fonts family: regular, italic, bold and bold italic, as far
    /// as the family has them.
    static func googleFontsFiles(family: String) async throws -> [URL] {
        guard var components = URLComponents(string: "https://fonts.googleapis.com/css") else {
            throw SubtitleFontError.badLink
        }
        components.queryItems = [URLQueryItem(name: "family", value: family + ":400,400italic,700,700italic")]
        guard let url = components.url else { throw SubtitleFontError.badLink }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue(trueTypeUserAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw SubtitleFontError.googleFontsFamily(family)
        }
        let links = googleFontsLinks(in: String(decoding: data, as: UTF8.self))
        guard !links.isEmpty else { throw SubtitleFontError.googleFontsFamily(family) }
        return links
    }

    /// The `url(…)` addresses of a stylesheet, each once.
    static func googleFontsLinks(in css: String) -> [URL] {
        var seen = Set<String>()
        var urls: [URL] = []
        var rest = Substring(css)
        while let start = rest.range(of: "url(") {
            let after = rest[start.upperBound...]
            guard let end = after.firstIndex(of: ")") else { break }
            let link = after[..<end].trimmingCharacters(in: CharacterSet(charactersIn: "'\" "))
            rest = after[after.index(after: end)...]
            guard link.hasPrefix("https://"), seen.insert(link).inserted, let url = URL(string: link) else { continue }
            urls.append(url)
        }
        return urls
    }
}
