import Foundation

struct LocalDebridCachedItem: Sendable {
    let name: String?
    let size: Int64?
}

enum LocalDebridCacheStatus: Sendable {
    case cached(LocalDebridCachedItem)
    case notCached
    case unknown
}

private actor RealDebridAvailabilityCache {
    static let shared = RealDebridAvailabilityCache()
    private var cache: [String: (item: LocalDebridCachedItem?, expiresAt: Date)] = [:]
    private var lastRequestTime = Date.distantPast
    private let minimumRequestInterval: TimeInterval = 1.0 // Real-Debrid rate limit: 1 req/sec
    private var isEndpointDisabled = false
    private var disabledUntil = Date.distantPast

    func isAvailable() -> Bool {
        if isEndpointDisabled && Date() < disabledUntil {
            return false
        }
        return true
    }

    func markEndpointDisabled(duration: TimeInterval = 3600) {
        isEndpointDisabled = true
        disabledUntil = Date().addingTimeInterval(duration)
    }

    func lookup(hashes: [String]) -> (statuses: [String: LocalDebridCacheStatus], missing: [String]) {
        let now = Date()
        var statuses: [String: LocalDebridCacheStatus] = [:]
        var missing: [String] = []
        for hash in hashes {
            let lower = hash.lowercased()
            if let entry = cache[lower], entry.expiresAt > now {
                if let item = entry.item {
                    statuses[lower] = .cached(item)
                } else {
                    statuses[lower] = .notCached
                }
            } else {
                missing.append(lower)
            }
        }
        return (statuses, missing)
    }

    func store(items: [String: LocalDebridCachedItem], checkedHashes: [String], ttl: TimeInterval = 300) {
        let expires = Date().addingTimeInterval(ttl)
        for hash in checkedHashes {
            let lower = hash.lowercased()
            cache[lower] = (items[lower], expires)
        }
    }

    func waitPacer() async {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastRequestTime)
        if elapsed < minimumRequestInterval {
            let delay = minimumRequestInterval - elapsed
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        lastRequestTime = Date()
    }
}

struct LocalDebridService: Sendable {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Queries the given debrid provider to determine which of the provided
    /// torrent hashes are already cached on their servers.
    func checkCached(
        provider: DebridProviderKind,
        apiKey: String,
        hashes: [String]
    ) async -> [String: LocalDebridCacheStatus] {
        let normalized = hashes
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        guard !normalized.isEmpty else { return [:] }

        switch provider {
        case .torbox:
            return await checkTorboxCached(apiKey: apiKey, hashes: normalized)
                ?? unknownStatuses(for: normalized)
        case .realDebrid:
            return await checkRealDebridCached(apiKey: apiKey, hashes: normalized)
        case .premiumize:
            return await checkPremiumizeCached(apiKey: apiKey, hashes: normalized)
                ?? unknownStatuses(for: normalized)
        default:
            return unknownStatuses(for: normalized)
        }
    }

    private func unknownStatuses(for hashes: [String]) -> [String: LocalDebridCacheStatus] {
        Dictionary(uniqueKeysWithValues: hashes.map { ($0, .unknown) })
    }

    // MARK: - TorBox

    private func checkTorboxCached(apiKey: String, hashes: [String]) async -> [String: LocalDebridCacheStatus]? {
        guard let url = URL(string: "https://api.torbox.app/v1/api/torrents/checkcached?format=object") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload = ["hashes": hashes]
        guard let httpBody = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        request.httpBody = httpBody

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else { return nil }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let success = json["success"] as? Bool, success,
                  let dataDict = json["data"] as? [String: Any] else {
                return nil
            }

            var items: [String: LocalDebridCachedItem] = [:]
            for (hash, itemVal) in dataDict {
                if let itemDict = itemVal as? [String: Any] {
                    let name = itemDict["name"] as? String
                    let size = (itemDict["size"] as? NSNumber)?.int64Value
                    items[hash.lowercased()] = LocalDebridCachedItem(name: name, size: size)
                }
            }
            var result = Dictionary(uniqueKeysWithValues: hashes.map { ($0, LocalDebridCacheStatus.notCached) })
            for (hash, item) in items {
                result[hash] = .cached(item)
            }
            return result
        } catch {
            return nil
        }
    }

    // MARK: - Real-Debrid

    private func checkRealDebridCached(apiKey: String, hashes: [String]) async -> [String: LocalDebridCacheStatus] {
        guard await RealDebridAvailabilityCache.shared.isAvailable() else {
            return [:]
        }
        let (cachedStatuses, missing) = await RealDebridAvailabilityCache.shared.lookup(hashes: hashes)
        if missing.isEmpty {
            return cachedStatuses
        }

        var merged = cachedStatuses
        for batchStart in stride(from: 0, to: missing.count, by: 50) {
            guard !Task.isCancelled else { break }
            let batchEnd = min(batchStart + 50, missing.count)
            let batch = Array(missing[batchStart..<batchEnd])
            await RealDebridAvailabilityCache.shared.waitPacer()
            guard !Task.isCancelled else { break }

            let hashPath = batch.joined(separator: "/")
            guard let url = URL(string: "https://api.real-debrid.com/rest/1.0/torrents/instantAvailability/\(hashPath)") else {
                continue
            }
            var request = URLRequest(url: url)
            request.setValue(
                "Bearer \(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))",
                forHTTPHeaderField: "Authorization"
            )

            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { continue }
                if http.statusCode == 429 {
                    print("[LocalDebridService] Real-Debrid instantAvailability returned 429 (rate limited)")
                    break
                }
                if http.statusCode == 403 {
                    print("[LocalDebridService] Real-Debrid instantAvailability returned 403 (endpoint disabled or forbidden)")
                    await RealDebridAvailabilityCache.shared.markEndpointDisabled()
                    break
                }
                guard 200..<300 ~= http.statusCode,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continue
                }

                var fetched: [String: LocalDebridCacheStatus] = [:]
                var fetchedItems: [String: LocalDebridCachedItem] = [:]
                for hash in batch {
                    guard let value = json.first(where: { $0.key.lowercased() == hash })?.value as? [String: Any],
                          let rdArray = value["rd"] as? [[String: Any]] else {
                        continue
                    }
                    guard !rdArray.isEmpty else {
                        fetched[hash] = .notCached
                        continue
                    }
                    var firstName: String?
                    var totalSize: Int64?
                    for (_, fileInfoVal) in rdArray[0] {
                        if let fileInfo = fileInfoVal as? [String: Any] {
                            firstName = fileInfo["filename"] as? String
                            totalSize = (fileInfo["filesize"] as? NSNumber)?.int64Value
                            break
                        }
                    }
                    let item = LocalDebridCachedItem(name: firstName, size: totalSize)
                    fetched[hash] = .cached(item)
                    fetchedItems[hash] = item
                }
                await RealDebridAvailabilityCache.shared.store(items: fetchedItems, checkedHashes: Array(fetched.keys))
                merged.merge(fetched) { _, new in new }
            } catch is CancellationError {
                break
            } catch {
                continue
            }
        }
        for hash in hashes {
            if case nil = merged[hash] {
                merged[hash] = .unknown
            }
        }
        return merged
    }

    // MARK: - Premiumize

    private func checkPremiumizeCached(apiKey: String, hashes: [String]) async -> [String: LocalDebridCacheStatus]? {
        var components = URLComponents(string: "https://www.premiumize.me/api/cache/check")
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "apikey", value: apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
        ]
        for hash in hashes {
            queryItems.append(URLQueryItem(name: "items[]", value: "magnet:?xt=urn:btih:\(hash)"))
        }
        components?.queryItems = queryItems
        guard let url = components?.url else { return nil }
        let request = URLRequest(url: url)

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else { return nil }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let status = json["status"] as? String, status == "success",
                  let responses = json["response"] as? [Bool] else {
                return nil
            }
            let filenames = json["filename"] as? [String?]
            let filesizes = json["filesize"] as? [NSNumber?]

            var result = unknownStatuses(for: hashes)
            for (index, isCached) in responses.enumerated() where index < hashes.count {
                let hash = hashes[index].lowercased()
                guard isCached else {
                    result[hash] = .notCached
                    continue
                }
                let name = (filenames?.indices.contains(index) == true) ? filenames?[index] : nil
                let size = (filesizes?.indices.contains(index) == true) ? filesizes?[index]?.int64Value : nil
                result[hash] = .cached(LocalDebridCachedItem(name: name, size: size))
            }
            return result
        } catch {
            return nil
        }
    }
}
