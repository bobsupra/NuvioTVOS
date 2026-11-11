import Foundation
import CryptoKit

/// `NUVIO.files`: a plugin's own text files, per scraper and profile, up to
/// ``maxBytes`` together — for indexes, cached lists and other data too big
/// for `localStorage`. They live in Caches on this Apple TV, so the system
/// may purge them when space runs low; a plugin must be able to rebuild them.
/// An Apple TV extension.
final class PluginFileStore {
    static let maxBytes = 50 * 1024 * 1024
    static let maxFiles = 500
    /// UTF-8 bytes; the encoded file name stays under the 255-byte limit.
    static let maxNameLength = 180
    private static let rootName = "NuvioPluginFiles"

    private let directory: URL?
    private var sizes: [String: Int]?

    init(scraperID: String, scope: String) {
        directory = Self.directory(scraperID: scraperID, scope: scope)
    }

    func read(_ name: String) -> String? {
        guard let url = url(for: name), let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// False when the name is not allowed or the files would grow past the limit.
    func write(_ name: String, _ text: String) -> Bool {
        guard let directory, let url = url(for: name) else { return false }
        let data = Data(text.utf8)
        var current = loadedSizes()
        let old = current[name] ?? 0
        if current.values.reduce(0, +) - old + data.count > Self.maxBytes { return false }
        if current[name] == nil, current.count >= Self.maxFiles { return false }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic])
        } catch {
            return false
        }
        current[name] = data.count
        sizes = current
        return true
    }

    func remove(_ name: String) {
        guard let url = url(for: name) else { return }
        try? FileManager.default.removeItem(at: url)
        if sizes != nil { sizes?[name] = nil }
    }

    func names() -> [String] {
        loadedSizes().keys.sorted()
    }

    func usage() -> Int {
        loadedSizes().values.reduce(0, +)
    }

    /// The provider was removed.
    static func removeAll(scraperID: String, scope: String) {
        guard let directory = directory(scraperID: scraperID, scope: scope) else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Names

    /// A file name for any plugin name: base64url of its UTF-8, so `list()`
    /// gives back exactly what the plugin wrote and no name can leave the folder.
    static func fileName(for name: String) -> String? {
        guard !name.isEmpty, name.utf8.count <= maxNameLength else { return nil }
        let encoded = Data(name.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "f-" + encoded
    }

    static func name(forFileName fileName: String) -> String? {
        guard fileName.hasPrefix("f-") else { return nil }
        var base64 = String(fileName.dropFirst(2))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func url(for name: String) -> URL? {
        guard let directory, let fileName = Self.fileName(for: name) else { return nil }
        return directory.appendingPathComponent(fileName, isDirectory: false)
    }

    private func loadedSizes() -> [String: Int] {
        if let sizes { return sizes }
        var found: [String: Int] = [:]
        if let directory,
           let urls = try? FileManager.default.contentsOfDirectory(
               at: directory,
               includingPropertiesForKeys: [.fileSizeKey],
               options: [.skipsHiddenFiles]
           ) {
            for url in urls {
                guard let name = Self.name(forFileName: url.lastPathComponent) else { continue }
                found[name] = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            }
        }
        sizes = found
        return found
    }

    private static func directory(scraperID: String, scope: String) -> URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let digest = SHA256.hash(data: Data(scraperID.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        let safeScope = scope.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
        return caches
            .appendingPathComponent(rootName, isDirectory: true)
            .appendingPathComponent(safeScope.isEmpty ? "default" : safeScope, isDirectory: true)
            .appendingPathComponent(digest, isDirectory: true)
    }
}
