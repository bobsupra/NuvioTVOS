import Foundation
import AetherEngineSMB

/// One scanned SMB file that passed the extension/size filters, with its
/// parsed name when `MediaFilenameParser` could make sense of it. Feeds
/// `SMBLibraryResolver`; a `nil` `parsed` goes straight to the unmatched list
/// without a Cinemeta search.
struct SMBMediaFile: Equatable {
    let share: String
    /// Share-relative path, e.g. `"Movies/Foo (2020)/Foo.mkv"`.
    let path: String
    let filename: String
    let size: Int64
    let parsed: ParsedMediaName?
}

/// Result of one scan pass: files worth resolving, plus how many entries were
/// filtered before that (too small, or a listing the server refused).
struct SMBScanResult {
    var files: [SMBMediaFile]
    var skippedCount: Int
}

/// Breadth-first walk of a server's selected shares, over `SMBBrowser`.
/// Depth-capped, cancellable, and permission-error-tolerant: a subdirectory
/// the server refuses to list is skipped rather than failing the whole scan.
enum SMBLibraryScanner {
    private static let videoExtensions: Set<String> = [
        "mkv", "mp4", "m4v", "avi", "mov", "ts", "m2ts", "wmv", "webm", "iso"
    ]

    /// `onProgress` is called after each directory listing with the running
    /// found-file count and the share-qualified path just visited, for the
    /// share-selection sheet's live progress view.
    static func scan(
        server: SMBServerConfig,
        browser: SMBBrowser,
        onProgress: @escaping (Int, String) -> Void
    ) async throws -> SMBScanResult {
        var files: [SMBMediaFile] = []
        var skippedCount = 0
        for share in server.selectedShares {
            try Task.checkCancellation()
            try await scanShare(
                share,
                browser: browser,
                maxDepth: server.maxDepth,
                files: &files,
                skippedCount: &skippedCount,
                onProgress: onProgress
            )
        }
        return SMBScanResult(files: files, skippedCount: skippedCount)
    }

    private static func scanShare(
        _ share: String,
        browser: SMBBrowser,
        maxDepth: Int,
        files: inout [SMBMediaFile],
        skippedCount: inout Int,
        onProgress: (Int, String) -> Void
    ) async throws {
        var queue: [(path: String, depth: Int)] = [("", 0)]

        while !queue.isEmpty {
            try Task.checkCancellation()
            let (path, depth) = queue.removeFirst()

            let entries: [SMBEntry]
            do {
                entries = try await browser.list(share: share, path: path)
            } catch {
                // A subdirectory the server refuses to list (permissions, a
                // stale junction) must not abort the rest of the scan.
                skippedCount += 1
                continue
            }
            onProgress(files.count, path.isEmpty ? share : "\(share)/\(path)")

            for entry in entries {
                guard !entry.isHidden else { continue }

                if entry.isDirectory {
                    if depth < maxDepth {
                        queue.append((entry.path, depth + 1))
                    }
                    continue
                }

                guard let ext = entry.name.split(separator: ".").last.map({ String($0).lowercased() }),
                      videoExtensions.contains(ext) else { continue }
                guard entry.size >= MediaFilenameParser.minimumFileSizeBytes else {
                    skippedCount += 1
                    continue
                }

                let parentPath = (entry.path as NSString).deletingLastPathComponent
                let parsed = MediaFilenameParser.parse(filename: entry.name, parentPath: parentPath)
                files.append(
                    SMBMediaFile(share: share, path: entry.path, filename: entry.name, size: entry.size, parsed: parsed)
                )
            }
        }
    }
}
