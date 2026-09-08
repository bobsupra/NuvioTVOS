import Foundation
import Network
import OSLog

let torrentLog = Logger(subsystem: "com.pyksel.nuviotvos", category: "torrent")

struct ParsedTorrentSource: Equatable, Sendable {
    let directURL: String?
    let infoHash: String?
    let fileIdx: Int?
}

/// Normalizes the torrent forms used by Stremio add-ons before they reach the
/// player. Android accepts both explicit fields and transport URLs; keeping
/// that normalization here means every tvOS entry point uses the same hash,
/// file index, and tracker values.
enum TorrentSourceParser {
    static func parse(
        url: String?,
        infoHash: String?,
        fileIdx: Int?
    ) -> ParsedTorrentSource {
        let rawURL = cleaned(url)
        let normalizedHash = normalizedInfoHash(infoHash) ?? infoHashFromURL(infoHash)
        let hash = normalizedHash ?? infoHashFromURL(rawURL)
        let index = fileIdx ?? fileIndexFromURL(rawURL)
        let directURL = rawURL.flatMap { isTorrentURL($0) ? nil : $0 }
        return ParsedTorrentSource(
            directURL: directURL,
            infoHash: hash,
            fileIdx: index
        )
    }

    static func parse(
        urls: [String?],
        infoHash: String?,
        fileIdx: Int?
    ) -> ParsedTorrentSource {
        let candidates = urls.compactMap(cleaned)
        let directURL = candidates.first { !isTorrentURL($0) }
        let torrentURL = candidates.first(where: isTorrentURL)
        let parsed = parse(
            url: torrentURL ?? directURL,
            infoHash: infoHash,
            fileIdx: fileIdx
        )
        return ParsedTorrentSource(
            directURL: directURL,
            infoHash: parsed.infoHash,
            fileIdx: parsed.fileIdx
        )
    }

    static func normalizedTrackers(_ sources: [String]) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for source in sources {
            guard let tracker = normalizedTracker(source), seen.insert(tracker).inserted else {
                continue
            }
            result.append(tracker)
        }
        return result
    }

    static func normalizedTracker(_ source: String) -> String? {
        var tracker = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tracker.isEmpty else { return nil }

        if tracker.lowercased().hasPrefix("tracker:") {
            tracker = String(tracker.dropFirst("tracker:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let scheme = URL(string: tracker)?.scheme?.lowercased(),
              ["udp", "http", "https"].contains(scheme) else {
            return nil
        }
        return tracker
    }

    static func isTorrentURL(_ value: String) -> Bool {
        let lowercased = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lowercased.hasPrefix("magnet:") || lowercased.hasPrefix("torrent:")
    }

    static func normalizedInfoHash(_ value: String?) -> String? {
        guard var value = cleaned(value) else { return nil }
        if value.lowercased().hasPrefix("urn:btih:") {
            value = String(value.dropFirst("urn:btih:".count))
        }
        guard (value.count == 40 || value.count == 32),
              value.unicodeScalars.allSatisfy({ scalar in
                  scalar.isASCII && (scalar.value >= 48 && scalar.value <= 57
                      || scalar.value >= 65 && scalar.value <= 90
                      || scalar.value >= 97 && scalar.value <= 122)
              }) else {
            return nil
        }
        return value.lowercased()
    }

    private static func infoHashFromURL(_ value: String?) -> String? {
        guard let value = cleaned(value) else { return nil }
        let decoded = value.removingPercentEncoding ?? value
        let lowercased = decoded.lowercased()

        if lowercased.hasPrefix("magnet:"),
           let marker = decoded.range(of: "urn:btih:", options: .caseInsensitive) {
            let suffix = decoded[marker.upperBound...]
            let rawHash = suffix.split(whereSeparator: { $0 == "&" || $0 == "?" || $0 == "#" }).first
            return normalizedInfoHash(rawHash.map(String.init))
        }

        guard lowercased.hasPrefix("torrent:") else { return nil }
        let payload: String
        if lowercased.hasPrefix("torrent://") {
            payload = String(decoded.dropFirst("torrent://".count))
        } else {
            payload = String(decoded.dropFirst("torrent:".count))
        }
        let hash = payload.split(separator: "?", maxSplits: 1).first?
            .split(separator: "/", maxSplits: 1).first
        return normalizedInfoHash(hash.map(String.init))
    }

    private static func fileIndexFromURL(_ value: String?) -> Int? {
        guard let value = cleaned(value) else { return nil }
        if let components = URLComponents(string: value),
           let item = components.queryItems?.first(where: {
               ["index", "fileidx", "file_idx"].contains($0.name.lowercased())
           }),
           let rawIndex = item.value,
           let index = Int(rawIndex) {
            return index
        }

        let decoded = value.removingPercentEncoding ?? value
        let lowercased = decoded.lowercased()
        guard lowercased.hasPrefix("torrent:") else { return nil }
        let prefix = lowercased.hasPrefix("torrent://") ? "torrent://" : "torrent:"
        let payload = String(decoded.dropFirst(prefix.count))
        let path = payload.split(separator: "?", maxSplits: 1).first ?? ""
        let parts = path.split(separator: "/")
        guard parts.count > 1 else { return nil }
        return Int(parts[1])
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct SwarmStats: Sendable {
    var downloadedBytes: Int64 = 0
    var downloadRate: Double = 0
    var connectedPeers: Int = 0
    var connectedSeeds: Int = 0
    var progress: Double = 0
    var isComplete: Bool = false
    var uploadedBytes: Int64 = 0

    var downloadRateFormatted: String {
        let bytesPerSec = downloadRate
        if bytesPerSec >= 1_048_576 {
            return String(format: "%.1f MB/s", bytesPerSec / 1_048_576)
        } else if bytesPerSec >= 1024 {
            return String(format: "%.0f KB/s", bytesPerSec / 1024)
        } else {
            return String(format: "%.0f B/s", bytesPerSec)
        }
    }
}

enum TorrentEngineError: LocalizedError {
    case failedToStart
    case metadataTimeout
    case noPlayableFile
    case bufferTimeout
    case sessionCancelled

    var errorDescription: String? {
        switch self {
        case .failedToStart: return "Failed to initialize torrent engine"
        case .metadataTimeout: return "Timeout connecting to peers / finding metadata"
        case .noPlayableFile: return "No playable video file in torrent"
        case .bufferTimeout: return "Buffering timed out"
        case .sessionCancelled: return "Playback was cancelled"
        }
    }
}

final class PieceWaiterRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [Int: [CheckedContinuation<Void, Never>]] = [:]

    func wait(_ index: Int, hasPiece: @Sendable (Int) -> Bool) async {
        if hasPiece(index) { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if hasPiece(index) {
                lock.unlock()
                continuation.resume()
                return
            }
            waiters[index, default: []].append(continuation)
            lock.unlock()
        }
    }

    func fulfill(_ index: Int) {
        lock.lock()
        let continuations = waiters.removeValue(forKey: index)
        lock.unlock()
        continuations?.forEach { $0.resume() }
    }

    func fulfillAll() {
        lock.lock()
        let all = waiters
        waiters.removeAll()
        lock.unlock()
        all.values.forEach { $0.forEach { $0.resume() } }
    }
}

enum NetworkIO {
    enum Failure: Error {
        case closed
        case notReady
    }

    static func start(_ connection: NWConnection, on queue: DispatchQueue) async throws {
        let states = AsyncStream<NWConnection.State> { continuation in
            connection.stateUpdateHandler = { continuation.yield($0) }
            continuation.onTermination = { _ in connection.stateUpdateHandler = nil }
        }

        try await withTaskCancellationHandler {
            connection.start(queue: queue)
            for await state in states {
                switch state {
                case .ready:
                    return
                case .failed(let error):
                    throw error
                case .cancelled:
                    throw Failure.notReady
                default:
                    continue
                }
            }
            throw Failure.notReady
        } onCancel: {
            connection.cancel()
        }
    }

    static func send(_ connection: NWConnection, _ data: Data) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                })
            }
        } onCancel: {
            connection.cancel()
        }
    }

    static func receive(_ connection: NWConnection, atLeast minimum: Int = 1, atMost maximum: Int) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                connection.receive(minimumIncompleteLength: minimum, maximumLength: maximum) { data, _, _, error in
                    if let error { continuation.resume(throwing: error); return }
                    if let data, !data.isEmpty { continuation.resume(returning: data); return }
                    continuation.resume(throwing: Failure.closed)
                }
            }
        } onCancel: {
            connection.cancel()
        }
    }
}
