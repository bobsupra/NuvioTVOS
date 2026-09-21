import XCTest
@testable import NuvioTV

final class PlaybackStreamCacheTests: XCTestCase {

    func testChunkIndexAndByteRangeCalculations() async {
        let fileLength: Int64 = 10 * 1024 * 1024 // 10 MiB
        let chunkSize: Int64 = 2 * 1024 * 1024 // 2 MiB
        let cache = PlaybackStreamDiskCache(
            sessionID: "test_session_math_\(UUID().uuidString)",
            fileLength: fileLength,
            chunkSize: chunkSize
        )

        let total = cache.totalChunks
        XCTAssertEqual(total, 5)

        let chunk0Index = cache.chunkIndex(forByteOffset: 0)
        let chunk0Range = cache.byteRange(forChunk: 0)
        XCTAssertEqual(chunk0Index, 0)
        XCTAssertEqual(chunk0Range, 0..<(2 * 1024 * 1024))

        let chunk2Index = cache.chunkIndex(forByteOffset: 4 * 1024 * 1024 + 500)
        let chunk2Range = cache.byteRange(forChunk: 2)
        XCTAssertEqual(chunk2Index, 2)
        XCTAssertEqual(chunk2Range, (4 * 1024 * 1024)..<(6 * 1024 * 1024))

        let lastChunkIndex = cache.chunkIndex(forByteOffset: fileLength - 1)
        let lastChunkRange = cache.byteRange(forChunk: 4)
        XCTAssertEqual(lastChunkIndex, 4)
        XCTAssertEqual(lastChunkRange, (8 * 1024 * 1024)..<(10 * 1024 * 1024))

        await cache.purge()
    }

    func testWriteAndReadChunkData() async {
        let fileLength: Int64 = 6 * 1024 * 1024
        let chunkSize: Int64 = 2 * 1024 * 1024
        let session = "test_write_read_\(UUID().uuidString)"
        let cache = PlaybackStreamDiskCache(
            sessionID: session,
            fileLength: fileLength,
            chunkSize: chunkSize
        )

        let sampleChunkData = Data(repeating: 0xAB, count: Int(chunkSize))
        await cache.writeChunk(0, data: sampleChunkData)

        let isCached = await cache.isChunkCached(0)
        XCTAssertTrue(isCached)

        let readBack = await cache.readChunk(0)
        XCTAssertEqual(readBack, sampleChunkData)

        // Read bytes across partial range
        let partial = await cache.readBytes(offset: 100, length: 50)
        XCTAssertNotNil(partial)
        XCTAssertEqual(partial?.count, 50)
        XCTAssertEqual(partial, Data(repeating: 0xAB, count: 50))

        await cache.purge()
    }

    func testSlidingWindowFIFOEviction() async {
        let fileLength: Int64 = 10 * 1024 * 1024 // 10 MiB (5 chunks of 2 MiB)
        let chunkSize: Int64 = 2 * 1024 * 1024
        let maxCacheSize: Int64 = 4 * 1024 * 1024 // Max 2 chunks (4 MiB)
        let session = "test_eviction_\(UUID().uuidString)"
        let cache = PlaybackStreamDiskCache(
            sessionID: session,
            fileLength: fileLength,
            chunkSize: chunkSize,
            maxCacheSizeBytes: maxCacheSize
        )

        let chunkData = Data(repeating: 0x01, count: Int(chunkSize))

        // Write chunk 0 and 1
        await cache.writeChunk(0, data: chunkData, playheadOffset: 0)
        await cache.writeChunk(1, data: chunkData, playheadOffset: 2 * 1024 * 1024)

        var cachedBytes = await cache.currentCachedBytes
        XCTAssertEqual(cachedBytes, 4 * 1024 * 1024)
        let chunk0Cached = await cache.isChunkCached(0)
        let chunk1Cached = await cache.isChunkCached(1)
        XCTAssertTrue(chunk0Cached)
        XCTAssertTrue(chunk1Cached)

        // Advance playhead to chunk 2 and write chunk 2 -> chunk 0 (oldest footage behind playhead) should be evicted
        await cache.writeChunk(2, data: chunkData, playheadOffset: 4 * 1024 * 1024)

        cachedBytes = await cache.currentCachedBytes
        XCTAssertEqual(cachedBytes, 4 * 1024 * 1024)
        let chunk0StillCached = await cache.isChunkCached(0)
        let chunk1StillCached = await cache.isChunkCached(1)
        let chunk2Cached = await cache.isChunkCached(2)
        XCTAssertFalse(chunk0StillCached) // Evicted
        XCTAssertTrue(chunk1StillCached)
        XCTAssertTrue(chunk2Cached)

        await cache.purge()
    }

    func testHeaderAndRewindMarginPreservationDuringEviction() async {
        let fileLength: Int64 = 20 * 1024 * 1024 // 20 MiB (10 chunks of 2 MiB)
        let chunkSize: Int64 = 2 * 1024 * 1024
        let maxCacheSize: Int64 = 8 * 1024 * 1024 // Max 4 chunks (8 MiB)
        let session = "test_header_rewind_\(UUID().uuidString)"
        let cache = PlaybackStreamDiskCache(
            sessionID: session,
            fileLength: fileLength,
            chunkSize: chunkSize,
            maxCacheSizeBytes: maxCacheSize,
            headerProtectBytes: 2 * 1024 * 1024, // 1 chunk (chunk 0 protected)
            rewindMarginBytes: 4 * 1024 * 1024   // 2 chunks (chunks 2 and 3 protected when playhead at 4)
        )

        let chunkData = Data(repeating: 0x02, count: Int(chunkSize))

        // Write chunks 0, 1, 2, 3 (fills 8 MiB budget)
        await cache.writeChunk(0, data: chunkData, playheadOffset: 0)
        await cache.writeChunk(1, data: chunkData, playheadOffset: 2 * 1024 * 1024)
        await cache.writeChunk(2, data: chunkData, playheadOffset: 4 * 1024 * 1024)
        await cache.writeChunk(3, data: chunkData, playheadOffset: 6 * 1024 * 1024)

        var cachedBytes = await cache.currentCachedBytes
        XCTAssertEqual(cachedBytes, 8 * 1024 * 1024)

        // Advance playhead to chunk 4 (offset 8 MiB) and write chunk 4 (exceeds 8 MiB budget)
        // Eviction should pick chunk 1 (old watched footage between header and rewind margin)
        // Chunk 0 (header) and chunks 2, 3 (rewind margin) must remain cached!
        await cache.writeChunk(4, data: chunkData, playheadOffset: 8 * 1024 * 1024)

        cachedBytes = await cache.currentCachedBytes
        XCTAssertEqual(cachedBytes, 8 * 1024 * 1024)
        let chunk0Cached = await cache.isChunkCached(0)
        let chunk1Cached = await cache.isChunkCached(1)
        let chunk2Cached = await cache.isChunkCached(2)
        let chunk3Cached = await cache.isChunkCached(3)
        let chunk4Cached = await cache.isChunkCached(4)

        XCTAssertTrue(chunk0Cached, "Container header chunk 0 must be preserved from eviction")
        XCTAssertFalse(chunk1Cached, "Old watched chunk 1 should be evicted first")
        XCTAssertTrue(chunk2Cached, "Rewind margin chunk 2 must be preserved")
        XCTAssertTrue(chunk3Cached, "Rewind margin chunk 3 must be preserved")
        XCTAssertTrue(chunk4Cached, "Active playhead chunk 4 must be cached")

        await cache.purge()
    }

    func testContiguousCachedRangesVisualization() async {
        let fileLength: Int64 = 10 * 1024 * 1024
        let chunkSize: Int64 = 2 * 1024 * 1024
        let session = "test_ranges_\(UUID().uuidString)"
        let cache = PlaybackStreamDiskCache(
            sessionID: session,
            fileLength: fileLength,
            chunkSize: chunkSize
        )

        let chunkData = Data(repeating: 0x00, count: Int(chunkSize))
        // Write chunk 0, 1 (contiguous 0..<4MB) and chunk 3 (gap at 2, chunk 3 is 6MB..<8MB)
        await cache.writeChunk(0, data: chunkData)
        await cache.writeChunk(1, data: chunkData)
        await cache.writeChunk(3, data: chunkData)

        let ranges = await cache.contiguousCachedByteRanges()
        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(ranges[0], 0..<(4 * 1024 * 1024))
        XCTAssertEqual(ranges[1], (6 * 1024 * 1024)..<(8 * 1024 * 1024))

        await cache.purge()
    }

    func testServerStartLifecycleAndContinuationSafety() async throws {
        let dummyURL = URL(string: "http://127.0.0.1:9999/video.mp4")!
        let server = PlaybackStreamCacheServer(
            remoteURL: dummyURL,
            fileLength: 50 * 1024 * 1024,
            sessionID: "test_server_lifecycle_\(UUID().uuidString)"
        )

        let localURL = try await server.start()
        XCTAssertTrue(localURL.absoluteString.starts(with: "http://127.0.0.1:"))

        // Verify calling start() again returns the same URL gracefully
        let localURL2 = try await server.start()
        XCTAssertEqual(localURL, localURL2)

        try await Task.sleep(nanoseconds: 200_000_000)
        await server.stop()
    }

    func testDemandPlaybackContinuesWhenDiskWriteFails() async throws {
        let chunkSize = Int(PlaybackStreamDiskCache.defaultChunkSize)
        let fileLength = Int64(chunkSize)
        let session = "test_write_failure_\(UUID().uuidString)"
        let remote = URL(string: "https://cache-test.invalid/video")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlaybackStreamCacheURLProtocol.self]
        PlaybackStreamCacheURLProtocol.handler = { request in
            let body = Data(repeating: 0x5A, count: chunkSize)
            return PlaybackStreamCacheURLProtocol.response(for: request, body: body, total: fileLength)
        }
        let server = PlaybackStreamCacheServer(
            remoteURL: remote, fileLength: fileLength, sessionID: session,
            sessionConfiguration: configuration
        )
        let cacheDirectory = serverDiskDirectory(for: session)
        try FileManager.default.removeItem(at: cacheDirectory)
        try Data([0x01]).write(to: cacheDirectory)
        defer {
            PlaybackStreamCacheURLProtocol.handler = nil
            try? FileManager.default.removeItem(at: cacheDirectory)
        }

        let localURL = try await server.start()
        var request = URLRequest(url: localURL)
        request.setValue("bytes=0-\(fileLength - 1)", forHTTPHeaderField: "Range")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            await server.stop()
            throw error
        }
        await server.stop()

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 206)
        XCTAssertEqual(data, Data(repeating: 0x5A, count: chunkSize))
    }

    func testLongResponseReturnsExactBytesPastCacheBudget() async throws {
        let chunkSize = Int(PlaybackStreamDiskCache.defaultChunkSize)
        let fileLength = Int64(chunkSize * 4 + 123)
        let expected = Data((0..<Int(fileLength)).map {
            UInt8(truncatingIfNeeded: ($0 / chunkSize) * 37 + ($0 % chunkSize))
        })
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlaybackStreamCacheURLProtocol.self]
        PlaybackStreamCacheURLProtocol.handler = { request in
            var response = PlaybackStreamCacheURLProtocol.response(for: request, body: expected, total: fileLength)
            response.contentRange = response.contentRange.replacingOccurrences(of: "/\(fileLength)", with: "/*")
            return response
        }
        let session = "test_long_response_\(UUID().uuidString)"
        defer {
            PlaybackStreamCacheURLProtocol.handler = nil
            try? FileManager.default.removeItem(at: serverDiskDirectory(for: session))
        }
        let server = PlaybackStreamCacheServer(
            remoteURL: URL(string: "https://cache-test.invalid/long")!, fileLength: fileLength,
            sessionID: session,
            maxDiskCacheSizeBytes: Int64(chunkSize * 2), sessionConfiguration: configuration
        )
        let localURL = try await server.start()
        var request = URLRequest(url: localURL)
        request.setValue("bytes=0-\(fileLength - 1)", forHTTPHeaderField: "Range")
        let data: Data
        do {
            data = try await URLSession.shared.data(for: request).0
        } catch {
            await server.stop()
            throw error
        }
        await server.stop()

        XCTAssertEqual(data, expected)
    }

    func testInvalidUpstreamRangeIsRejected() async throws {
        let chunkSize = Int(PlaybackStreamDiskCache.defaultChunkSize)
        let fileLength = Int64(chunkSize)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlaybackStreamCacheURLProtocol.self]
        PlaybackStreamCacheURLProtocol.handler = { request in
            var response = PlaybackStreamCacheURLProtocol.response(
                for: request, body: Data(repeating: 0x22, count: chunkSize), total: fileLength
            )
            response.contentRange = "bytes 1-\(chunkSize)/\(fileLength)"
            return response
        }
        let session = "test_invalid_range_\(UUID().uuidString)"
        let server = PlaybackStreamCacheServer(
            remoteURL: URL(string: "https://cache-test.invalid/invalid")!, fileLength: fileLength,
            sessionID: session, sessionConfiguration: configuration
        )
        let localURL = try await server.start()
        var request = URLRequest(url: localURL)
        request.setValue("bytes=0-\(fileLength - 1)", forHTTPHeaderField: "Range")
        let data: Data
        do {
            data = try await URLSession.shared.data(for: request).0
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost)
            data = Data()
        }
        await server.stop()
        PlaybackStreamCacheURLProtocol.handler = nil
        try? FileManager.default.removeItem(at: serverDiskDirectory(for: session))

        XCTAssertTrue(data.isEmpty)
        let cachedFraction = await server.cachedFraction()
        XCTAssertEqual(cachedFraction, 0)
    }

    func testUpstreamFetchesHonorConfiguredConcurrencyLimit() async throws {
        let chunkSize = Int(PlaybackStreamDiskCache.defaultChunkSize)
        let fileLength = Int64(chunkSize * 10)
        let expected = Data((0..<(chunkSize * 10)).map { UInt8(truncatingIfNeeded: $0) })
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlaybackStreamCacheURLProtocol.self]
        PlaybackStreamCacheURLProtocol.resetMetrics()
        PlaybackStreamCacheURLProtocol.delay = 0.05
        PlaybackStreamCacheURLProtocol.handler = { request in
            PlaybackStreamCacheURLProtocol.response(for: request, body: expected, total: fileLength)
        }
        let session = "test_fetch_limit_\(UUID().uuidString)"
        defer {
            PlaybackStreamCacheURLProtocol.handler = nil
            PlaybackStreamCacheURLProtocol.delay = 0
            try? FileManager.default.removeItem(at: serverDiskDirectory(for: session))
        }
        let server = PlaybackStreamCacheServer(
            remoteURL: URL(string: "https://cache-test.invalid/limit")!, fileLength: fileLength,
            sessionID: session, sessionConfiguration: configuration, maxConcurrentUpstream: 2
        )
        let localURL = try await server.start()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for chunk in [0, 4, 8] {
                group.addTask {
                    var request = URLRequest(url: localURL)
                    let start = chunk * chunkSize
                    request.setValue("bytes=\(start)-\(start + chunkSize - 1)", forHTTPHeaderField: "Range")
                    let data = try await URLSession.shared.data(for: request).0
                    XCTAssertEqual(data, expected.subdata(in: start..<(start + chunkSize)))
                }
            }
            try await group.waitForAll()
        }
        await server.stop()
        XCTAssertEqual(PlaybackStreamCacheURLProtocol.maximumActiveRequests, 2)
    }

    func testRateLimitCooldownRetriesDemandWithoutHammering() async throws {
        let chunkSize = Int(PlaybackStreamDiskCache.defaultChunkSize)
        let fileLength = Int64(chunkSize)
        let expected = Data(repeating: 0x3C, count: chunkSize)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlaybackStreamCacheURLProtocol.self]
        PlaybackStreamCacheURLProtocol.resetMetrics()
        PlaybackStreamCacheURLProtocol.handler = { request in
            if PlaybackStreamCacheURLProtocol.requestCount <= 2 {
                var response = PlaybackStreamCacheURLProtocol.response(for: request, body: Data(), total: fileLength)
                response.statusCode = 429
                response.retryAfter = PlaybackStreamCacheURLProtocol.requestCount == 1 ? "nan" : "0.1"
                return response
            }
            return PlaybackStreamCacheURLProtocol.response(for: request, body: expected, total: fileLength)
        }
        let session = "test_rate_limit_\(UUID().uuidString)"
        defer {
            PlaybackStreamCacheURLProtocol.handler = nil
            try? FileManager.default.removeItem(at: serverDiskDirectory(for: session))
        }
        let server = PlaybackStreamCacheServer(
            remoteURL: URL(string: "https://cache-test.invalid/rate")!, fileLength: fileLength,
            sessionID: session, sessionConfiguration: configuration, rateLimitCooldown: 0.1
        )
        let localURL = try await server.start()
        var request = URLRequest(url: localURL)
        request.setValue("bytes=0-\(chunkSize - 1)", forHTTPHeaderField: "Range")
        let data = try await URLSession.shared.data(for: request).0
        await server.stop()

        XCTAssertEqual(data, expected)
        let starts = PlaybackStreamCacheURLProtocol.requestStarts
        XCTAssertEqual(starts.count, 3)
        for (previous, next) in zip(starts, starts.dropFirst()) {
            XCTAssertGreaterThanOrEqual(next.timeIntervalSince(previous), 0.08)
        }
    }

    func testBackgroundDoesNotRefetchWhenCacheHasNoCapacity() async throws {
        let chunkSize = Int(PlaybackStreamDiskCache.defaultChunkSize)
        let fileLength = Int64(chunkSize * 3)
        let expected = Data(repeating: 0x44, count: chunkSize * 3)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlaybackStreamCacheURLProtocol.self]
        PlaybackStreamCacheURLProtocol.resetMetrics()
        PlaybackStreamCacheURLProtocol.handler = { request in
            PlaybackStreamCacheURLProtocol.response(for: request, body: expected, total: fileLength)
        }
        let session = "test_background_capacity_\(UUID().uuidString)"
        defer {
            PlaybackStreamCacheURLProtocol.handler = nil
            try? FileManager.default.removeItem(at: serverDiskDirectory(for: session))
        }
        let server = PlaybackStreamCacheServer(
            remoteURL: URL(string: "https://cache-test.invalid/full")!, fileLength: fileLength,
            sessionID: session, maxDiskCacheSizeBytes: Int64(chunkSize), sessionConfiguration: configuration
        )
        _ = try await server.start()
        try await Task.sleep(nanoseconds: 500_000_000)
        await server.stop()
        XCTAssertEqual(PlaybackStreamCacheURLProtocol.requestCount, 1)
    }

    func testStopCancelsFetchAdmissionPromptly() async throws {
        let chunkSize = Int(PlaybackStreamDiskCache.defaultChunkSize)
        let fileLength = Int64(chunkSize * 2)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlaybackStreamCacheURLProtocol.self]
        PlaybackStreamCacheURLProtocol.resetMetrics()
        PlaybackStreamCacheURLProtocol.delay = 2
        PlaybackStreamCacheURLProtocol.handler = { request in
            PlaybackStreamCacheURLProtocol.response(
                for: request, body: Data(repeating: 0x55, count: chunkSize * 2), total: fileLength
            )
        }
        let session = "test_stop_admission_\(UUID().uuidString)"
        defer {
            PlaybackStreamCacheURLProtocol.handler = nil
            PlaybackStreamCacheURLProtocol.delay = 0
            try? FileManager.default.removeItem(at: serverDiskDirectory(for: session))
        }
        let server = PlaybackStreamCacheServer(
            remoteURL: URL(string: "https://cache-test.invalid/stop")!, fileLength: fileLength,
            sessionID: session, sessionConfiguration: configuration, maxConcurrentUpstream: 1
        )
        let localURL = try await server.start()
        // Wait until background forward prefetch begins (request 1)
        for _ in 0..<100 where PlaybackStreamCacheURLProtocol.requestCount == 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(PlaybackStreamCacheURLProtocol.requestCount, 1)

        // Launch first demand task, which preempts the forward task and occupies the single upstream slot
        let activeDemand = Task {
            var request = URLRequest(url: localURL, timeoutInterval: 5)
            request.setValue("bytes=0-\(chunkSize - 1)", forHTTPHeaderField: "Range")
            return try? await URLSession.shared.data(for: request).0
        }
        for _ in 0..<100 where PlaybackStreamCacheURLProtocol.requestCount < 2 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let countBeforePending = PlaybackStreamCacheURLProtocol.requestCount

        // Launch second demand task. Since slot is occupied by active demand, second demand must queue in admission
        let pendingDemand = Task {
            var request = URLRequest(url: localURL, timeoutInterval: 2)
            request.setValue("bytes=\(chunkSize)-\(fileLength - 1)", forHTTPHeaderField: "Range")
            return try? await URLSession.shared.data(for: request).0
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        let started = Date()
        await server.stop()
        let data = await pendingDemand.value
        _ = await activeDemand.value
        XCTAssertNil(data)
        // Queued demand must not have been admitted or issued an upstream request after stop
        XCTAssertEqual(PlaybackStreamCacheURLProtocol.requestCount, countBeforePending)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
    }
}

private func serverDiskDirectory(for sessionID: String) -> URL {
    let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
    return caches.appendingPathComponent("PlaybackStreamCache", isDirectory: true)
        .appendingPathComponent(sessionID, isDirectory: true)
}

extension PlaybackStreamCacheTests {
    func testDemandDeliveryDoesNotWaitForDiskPersistence() async throws {
        let chunk = Int(PlaybackStreamDiskCache.defaultChunkSize)
        let body = Data(repeating: 0x4D, count: chunk * 8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlaybackStreamCacheURLProtocol.self]
        PlaybackStreamCacheURLProtocol.resetMetrics()
        PlaybackStreamCacheURLProtocol.handler = { request in
            PlaybackStreamCacheURLProtocol.response(for: request, body: body, total: Int64(body.count))
        }
        let writeStarted = expectation(description: "Disk persistence entered")
        let delivered = expectation(description: "Demand delivered despite blocked disk")
        let diskGate = CacheDiskWriteGate { writeStarted.fulfill() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            diskGate.release()
            PlaybackStreamCacheURLProtocol.handler = nil
            try? FileManager.default.removeItem(at: root)
        }
        let server = PlaybackStreamCacheServer(
            remoteURL: URL(string: "https://cache-test.invalid/slow_disk")!,
            fileLength: Int64(body.count), cacheRoot: root, sessionConfiguration: configuration,
            maxConcurrentUpstream: 1,
            freeSpaceProvider: { _ in diskGate.capacity() }
        )
        diskGate.arm()
        let demand = Task {
            let first = await server.fetchDemandChunk(0)
            // The next upstream batch must start even while the first batch's
            // disk write is blocked and only one network request is allowed.
            let nextBatch = await server.fetchDemandChunk(4)
            // Let batch 4 replace batch 0 in the bounded recent-chunk cache.
            // Chunk 0 must remain available from its still-blocked active write.
            try? await Task.sleep(nanoseconds: 100_000_000)
            let activeWriteBytes = await server.fetchDemandChunk(0)
            delivered.fulfill()
            return [first, nextBatch, activeWriteBytes]
        }
        await fulfillment(of: [writeStarted, delivered], timeout: 2)
        diskGate.release()
        let received = await demand.value
        XCTAssertEqual(received, Array(repeating: Data(body.prefix(chunk)), count: 3))
        XCTAssertEqual(PlaybackStreamCacheURLProtocol.requestCount, 2)
        await server.stop()
    }

    func testDemandJoinsBatchAndReceivesChunkBeforeBatchCompletes() async throws {
        let chunk = Int(PlaybackStreamDiskCache.defaultChunkSize)
        let body = Data(repeating: 0x6A, count: chunk * 4)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlaybackStreamCacheURLProtocol.self]
        PlaybackStreamCacheURLProtocol.resetMetrics()
        PlaybackStreamCacheURLProtocol.handler = { request in
            var response = PlaybackStreamCacheURLProtocol.response(for: request, body: body, total: Int64(body.count))
            response.bodyChunkBytes = chunk
            response.bodyChunkDelay = 0.5
            return response
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            PlaybackStreamCacheURLProtocol.handler = nil
            try? FileManager.default.removeItem(at: root)
        }
        let server = PlaybackStreamCacheServer(
            remoteURL: URL(string: "https://cache-test.invalid/incremental")!,
            fileLength: Int64(body.count), cacheRoot: root,
            sessionConfiguration: configuration, maxConcurrentUpstream: 1
        )
        _ = try await server.start()
        for _ in 0..<100 where PlaybackStreamCacheURLProtocol.requestCount == 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let started = Date()
        let first = await server.fetchDemandChunk(0)
        XCTAssertEqual(first, body.prefix(chunk))
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.8, "Demand must not wait for the 1.5-second batch tail")
        let second = await server.fetchDemandChunk(1)
        XCTAssertEqual(second, body.prefix(chunk))
        XCTAssertEqual(PlaybackStreamCacheURLProtocol.requestCount, 1, "Overlapping demand must share the original transfer")
        XCTAssertEqual(PlaybackStreamCacheURLProtocol.cancellationCount, 0)
        await server.stop()
    }

    func testJoinedPlaybackBatchIsProtectedFromUnrelatedDemand() async throws {
        let chunk = Int(PlaybackStreamDiskCache.defaultChunkSize)
        let body = Data(repeating: 0x62, count: chunk * 8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlaybackStreamCacheURLProtocol.self]
        PlaybackStreamCacheURLProtocol.resetMetrics()
        PlaybackStreamCacheURLProtocol.handler = { request in
            var response = PlaybackStreamCacheURLProtocol.response(for: request, body: body, total: Int64(body.count))
            response.bodyChunkBytes = chunk
            response.bodyChunkDelay = 0.2
            return response
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            PlaybackStreamCacheURLProtocol.handler = nil
            try? FileManager.default.removeItem(at: root)
        }
        let server = PlaybackStreamCacheServer(
            remoteURL: URL(string: "https://cache-test.invalid/protected_demand")!,
            fileLength: Int64(body.count), cacheRoot: root,
            sessionConfiguration: configuration, maxConcurrentUpstream: 1
        )
        _ = try await server.start()
        for _ in 0..<100 where PlaybackStreamCacheURLProtocol.requestCount == 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let playback = Task { await server.fetchDemandChunk(1) }
        try await Task.sleep(nanoseconds: 30_000_000)
        let other = Task { await server.fetchDemandChunk(4) }
        let playbackBytes = await playback.value
        let otherBytes = await other.value
        XCTAssertEqual(playbackBytes, body.prefix(chunk))
        XCTAssertEqual(otherBytes, body.prefix(chunk))
        XCTAssertEqual(PlaybackStreamCacheURLProtocol.cancellationCount, 0, "A batch serving playback is no longer disposable background work")
        await server.stop()
    }

    func testEstimatedTimelineAndHeadProbeDoNotSkipSequentialPrefetch() async throws {
        let chunk = Int(PlaybackStreamDiskCache.defaultChunkSize)
        let body = Data(repeating: 0x35, count: chunk * 16)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlaybackStreamCacheURLProtocol.self]
        PlaybackStreamCacheURLProtocol.resetMetrics()
        PlaybackStreamCacheURLProtocol.handler = { request in
            var response = PlaybackStreamCacheURLProtocol.response(for: request, body: body, total: Int64(body.count))
            response.bodyChunkBytes = chunk
            response.bodyChunkDelay = 0.3
            return response
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            PlaybackStreamCacheURLProtocol.handler = nil
            try? FileManager.default.removeItem(at: root)
        }
        let server = PlaybackStreamCacheServer(
            remoteURL: URL(string: "https://cache-test.invalid/vbr")!,
            fileLength: Int64(body.count), cacheRoot: root, sessionConfiguration: configuration
        )
        let local = try await server.start()
        var request = URLRequest(url: local, timeoutInterval: 5)
        request.setValue("bytes=0-\(chunk - 1)", forHTTPHeaderField: "Range")
        let first = try await URLSession.shared.data(for: request).0
        XCTAssertEqual(first, body.prefix(chunk))
        // A VBR timeline estimate runs well ahead of the actual sequential reader.
        await server.updateTimeline(playheadOffset: Int64(chunk * 12), durationSeconds: 30)
        var head = URLRequest(url: local, timeoutInterval: 5)
        head.httpMethod = "HEAD"
        head.setValue("bytes=\(body.count - 32)-", forHTTPHeaderField: "Range")
        _ = try await URLSession.shared.data(for: head)
        for _ in 0..<300 where PlaybackStreamCacheURLProtocol.requestCount < 2 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let ranges = PlaybackStreamCacheURLProtocol.requestRanges
        XCTAssertGreaterThanOrEqual(ranges.count, 2)
        if ranges.count >= 2 {
            XCTAssertEqual(ranges[0], "bytes=0-\(chunk * 4 - 1)")
            XCTAssertEqual(ranges[1], "bytes=\(chunk * 4)-\(chunk * 8 - 1)", "Fill must continue from real reads, leaving no VBR-induced gap")
        }
        await server.stop()
    }

    func testSustainedColdReadUsesSharedBatches() async throws {
        let chunk = Int(PlaybackStreamDiskCache.defaultChunkSize)
        var body = Data()
        for index in 0..<16 { body.append(Data(repeating: UInt8(index), count: chunk)) }
        let expected = body
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlaybackStreamCacheURLProtocol.self]
        PlaybackStreamCacheURLProtocol.resetMetrics()
        PlaybackStreamCacheURLProtocol.delay = 0.1
        PlaybackStreamCacheURLProtocol.handler = { request in
            var response = PlaybackStreamCacheURLProtocol.response(for: request, body: expected, total: Int64(expected.count))
            response.bodyChunkBytes = chunk / 4 + 17 // Deliveries cross cache-chunk boundaries.
            response.bodyChunkDelay = 0.01
            return response
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            PlaybackStreamCacheURLProtocol.handler = nil
            PlaybackStreamCacheURLProtocol.delay = 0
            try? FileManager.default.removeItem(at: root)
        }
        let server = PlaybackStreamCacheServer(
            remoteURL: URL(string: "https://cache-test.invalid/sustained")!,
            fileLength: Int64(body.count), cacheRoot: root,
            sessionConfiguration: configuration, maxConcurrentUpstream: 1
        )
        let local = try await server.start()
        var request = URLRequest(url: local, timeoutInterval: 10)
        request.setValue("bytes=0-\(body.count - 1)", forHTTPHeaderField: "Range")
        let started = Date()
        do {
            let received = try await URLSession.shared.data(for: request).0
            XCTAssertEqual(received, expected)
            XCTAssertLessThan(Date().timeIntervalSince(started), 3.2, "32 MiB must sustain at least the trace's ~79 Mbps average")
            XCTAssertEqual(PlaybackStreamCacheURLProtocol.requestCount, 4, "Sixteen sequential chunks should share four upstream batches")
            XCTAssertEqual(PlaybackStreamCacheURLProtocol.cancellationCount, 0)
        } catch {
            await server.stop()
            throw error
        }
        await server.stop()
    }

    func testTruncatedBatchDoesNotPublishPartialChunk() async throws {
        let chunk = Int(PlaybackStreamDiskCache.defaultChunkSize)
        let body = Data(repeating: 0x73, count: chunk * 4)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlaybackStreamCacheURLProtocol.self]
        PlaybackStreamCacheURLProtocol.resetMetrics()
        PlaybackStreamCacheURLProtocol.handler = { request in
            let valid = PlaybackStreamCacheURLProtocol.response(for: request, body: body, total: Int64(body.count))
            return PlaybackStreamCacheURLProtocol.Response(
                data: Data(valid.data.prefix(17)), statusCode: 206, contentRange: valid.contentRange,
                declaredContentLength: valid.data.count
            )
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            PlaybackStreamCacheURLProtocol.handler = nil
            try? FileManager.default.removeItem(at: root)
        }
        let server = PlaybackStreamCacheServer(
            remoteURL: URL(string: "https://cache-test.invalid/truncated")!,
            fileLength: Int64(body.count), cacheRoot: root, sessionConfiguration: configuration
        )
        let received = await server.fetchDemandChunk(0)
        XCTAssertNil(received)
        let fraction = await server.cachedFraction()
        XCTAssertEqual(fraction, 0)
        await server.stop()
    }

    func testSequentialDemandReusesCompletedBatchWhenDiskIsUnavailable() async throws {
        let chunk = Int(PlaybackStreamDiskCache.defaultChunkSize)
        let body = Data(repeating: 0x59, count: chunk * 8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlaybackStreamCacheURLProtocol.self]
        PlaybackStreamCacheURLProtocol.resetMetrics()
        PlaybackStreamCacheURLProtocol.handler = { request in
            PlaybackStreamCacheURLProtocol.response(for: request, body: body, total: Int64(body.count))
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            PlaybackStreamCacheURLProtocol.handler = nil
            try? FileManager.default.removeItem(at: root)
        }
        let server = PlaybackStreamCacheServer(
            remoteURL: URL(string: "https://cache-test.invalid/ram_batches")!,
            fileLength: Int64(body.count), cacheRoot: root,
            sessionConfiguration: configuration, freeSpaceProvider: { _ in 0 }
        )
        for index in 0..<8 {
            let received = await server.fetchDemandChunk(index)
            XCTAssertEqual(received, body.prefix(chunk))
            // Let the transfer finish and release its in-flight entry before
            // requesting its neighbors, as a paced playback consumer would.
            if index % 4 == 0 { try await Task.sleep(nanoseconds: 100_000_000) }
        }
        XCTAssertEqual(PlaybackStreamCacheURLProtocol.requestCount, 2)
        let persistedFraction = await server.cachedFraction()
        XCTAssertEqual(persistedFraction, 0)
        await server.stop()
    }
}

private final class CacheDiskWriteGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var armed = false
    private let didBlock: () -> Void

    init(didBlock: @escaping () -> Void) { self.didBlock = didBlock }
    func arm() { lock.withLock { armed = true } }
    func release() { semaphore.signal() }
    func capacity() -> Int64 {
        let shouldBlock = lock.withLock {
            let result = armed
            armed = false
            return result
        }
        if shouldBlock {
            didBlock()
            _ = semaphore.wait(timeout: .now() + 5)
        }
        return 1 << 40
    }
}

private final class PlaybackStreamCacheURLProtocol: URLProtocol {
    struct Response {
        let data: Data
        var statusCode: Int
        var contentRange: String
        var retryAfter: String?
        var etag: String?
        var lastModified: String?
        var bodyChunkBytes: Int? = nil
        var bodyChunkDelay: TimeInterval = 0
        var declaredContentLength: Int? = nil
    }

    private static let metricsLock = NSLock()
    private static var storedHandler: ((URLRequest) -> Response)?
    private static var storedDelay: TimeInterval = 0
    private static var activeRequests = 0
    private static var maximumActive = 0
    private static var starts = [Date]()
    private static var ranges = [String?]()
    private static var cancellations = 0
    static var handler: ((URLRequest) -> Response)? {
        get { metricsLock.withLock { storedHandler } }
        set { metricsLock.withLock { storedHandler = newValue } }
    }
    static var delay: TimeInterval {
        get { metricsLock.withLock { storedDelay } }
        set { metricsLock.withLock { storedDelay = newValue } }
    }
    static var maximumActiveRequests: Int { metricsLock.withLock { maximumActive } }
    static var requestCount: Int { metricsLock.withLock { starts.count } }
    static var requestStarts: [Date] { metricsLock.withLock { starts } }
    static var requestRanges: [String?] { metricsLock.withLock { ranges } }
    static var cancellationCount: Int { metricsLock.withLock { cancellations } }
    private let deliveryLock = NSRecursiveLock()
    private var finished = false
    private var delivery: DispatchWorkItem?

    static func resetMetrics() {
        metricsLock.withLock {
            activeRequests = 0
            maximumActive = 0
            starts = []
            ranges = []
            cancellations = 0
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "cache-test.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        deliveryLock.lock()
        defer { deliveryLock.unlock() }
        Self.metricsLock.withLock {
            Self.starts.append(Date())
            Self.ranges.append(request.value(forHTTPHeaderField: "Range"))
            Self.activeRequests += 1
            Self.maximumActive = max(Self.maximumActive, Self.activeRequests)
        }
        let response = Self.handler?(request)
        let work = DispatchWorkItem { [self] in
            deliveryLock.lock()
            defer { deliveryLock.unlock() }
            guard !finished else { return }
            guard let response, let url = request.url else {
                finished = true
                Self.metricsLock.withLock { Self.activeRequests -= 1 }
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            var headers = ["Content-Range": response.contentRange, "Content-Length": "\(response.declaredContentLength ?? response.data.count)", "Accept-Ranges": "bytes"]
            if request.httpMethod == "HEAD", let total = response.contentRange.split(separator: "/").last {
                headers["Content-Length"] = String(total)
            }
            if let retryAfter = response.retryAfter { headers["Retry-After"] = retryAfter }
            if let etag = response.etag { headers["ETag"] = etag }
            if let lm = response.lastModified { headers["Last-Modified"] = lm }
            let http = HTTPURLResponse(url: url, statusCode: response.statusCode, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            deliverBody(response, offset: 0)
        }
        delivery = work
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.delay, execute: work)
    }

    private func deliverBody(_ response: Response, offset: Int) {
        deliveryLock.lock()
        defer { deliveryLock.unlock() }
        guard !finished else { return }
        if request.httpMethod != "HEAD", offset < response.data.count {
            let end = min(response.data.count, offset + max(1, response.bodyChunkBytes ?? response.data.count))
            client?.urlProtocol(self, didLoad: response.data.subdata(in: offset..<end))
            if end < response.data.count {
                let work = DispatchWorkItem { [self] in deliverBody(response, offset: end) }
                delivery = work
                DispatchQueue.global().asyncAfter(deadline: .now() + response.bodyChunkDelay, execute: work)
                return
            }
        }
        finished = true
        Self.metricsLock.withLock { Self.activeRequests -= 1 }
        client?.urlProtocolDidFinishLoading(self)
        delivery = nil
    }

    override func stopLoading() {
        deliveryLock.lock()
        defer { deliveryLock.unlock() }
        delivery?.cancel()
        delivery = nil
        guard !finished else { return }
        finished = true
        Self.metricsLock.withLock {
            Self.activeRequests -= 1
            Self.cancellations += 1
        }
    }

    static func response(
        for request: URLRequest, body: Data, total: Int64, etag: String? = nil, lastModified: String? = nil
    ) -> Response {
        if request.httpMethod == "HEAD" {
            return Response(data: Data(), statusCode: 200, contentRange: "bytes */\(total)", retryAfter: nil, etag: etag, lastModified: lastModified)
        }
        guard let rangeHeader = request.value(forHTTPHeaderField: "Range") else {
            return Response(data: body, statusCode: 200, contentRange: "bytes 0-\(body.count - 1)/\(total)", retryAfter: nil, etag: etag, lastModified: lastModified)
        }
        let range = rangeHeader
            .replacingOccurrences(of: "bytes=", with: "").split(separator: "-")
        let start = Int64(range[0])!
        let end = Int64(range[1])!
        let data = body.isEmpty ? Data() : Data(body[Int(start)...Int(end)])
        return Response(data: data, statusCode: 206, contentRange: "bytes \(start)-\(end)/\(total)", retryAfter: nil, etag: etag, lastModified: lastModified)
    }
}


extension PlaybackStreamCacheTests {
    func testGlobalBudgetIsEnforcedAsActiveSessionGrows() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = PlaybackStreamDiskCache(sessionID: "old", fileLength: 16, chunkSize: 4, maxCacheSizeBytes: 12, cacheRoot: root)
        let active = PlaybackStreamDiskCache(sessionID: "active", fileLength: 16, chunkSize: 4, maxCacheSizeBytes: 12, cacheRoot: root)
        let chunk = Data(repeating: 0xAA, count: 4)
        await old.writeChunk(0, data: chunk)
        await old.writeChunk(1, data: chunk)
        await active.writeChunk(0, data: chunk)
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.cacheDirectory.path))
        await active.writeChunk(1, data: chunk)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.cacheDirectory.path))
        let oldChunkStillPresent = await old.isChunkCached(0)
        XCTAssertFalse(oldChunkStillPresent)
        let oldBytes = await old.currentCachedBytes
        XCTAssertEqual(oldBytes, 0)
        let retained = await active.readChunk(0)
        XCTAssertEqual(retained, chunk)
        await active.writeChunk(2, data: chunk)
        await active.writeChunk(3, data: chunk, playheadOffset: 12)
        let files = try FileManager.default.contentsOfDirectory(at: active.cacheDirectory, includingPropertiesForKeys: [.fileSizeKey])
        let total = try files.reduce(0) { try $0 + ($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        XCTAssertLessThanOrEqual(total, 12)
        // A pruned actor can resume writing without counting its deleted chunks.
        await old.writeChunk(2, data: chunk, playheadOffset: 8)
        let resumed = await old.currentCachedBytes
        XCTAssertEqual(resumed, 4)
    }

    func testPrefetchDoesNotDisplaceNeededChunks() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = PlaybackStreamDiskCache(sessionID: "prefetch", fileLength: 16, chunkSize: 4, maxCacheSizeBytes: 8, cacheRoot: root)
        let chunk = Data(repeating: 1, count: 4)
        await cache.writeChunk(0, data: chunk)
        await cache.writeChunk(1, data: chunk)
        let archiveFits = await cache.canPrefetchChunk(2, playheadOffset: 4, evictBehindPlayhead: false)
        let forwardFits = await cache.canPrefetchChunk(2, playheadOffset: 4, evictBehindPlayhead: true)
        let forwardTooEarly = await cache.canPrefetchChunk(2, playheadOffset: 0, evictBehindPlayhead: true)
        XCTAssertFalse(archiveFits)
        XCTAssertTrue(forwardFits)
        XCTAssertFalse(forwardTooEarly)
        await cache.writeChunk(2, data: chunk, playheadOffset: 4, prefetchEvictsBehind: false)
        let skippedArchive = await cache.isChunkCached(2)
        XCTAssertFalse(skippedArchive)
        await cache.writeChunk(2, data: chunk, playheadOffset: 4, prefetchEvictsBehind: true)
        let forwardStored = await cache.isChunkCached(2)
        XCTAssertTrue(forwardStored)
        let watchedChunkEligible = await cache.canPrefetchChunk(0, playheadOffset: 4, evictBehindPlayhead: false)
        XCTAssertFalse(watchedChunkEligible)
    }

    func testPartialLastChunkUsesExactBudget() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = PlaybackStreamDiskCache(sessionID: "partial", fileLength: 10, chunkSize: 4, maxCacheSizeBytes: 10, cacheRoot: root)
        await cache.writeChunk(0, data: Data(repeating: 1, count: 4))
        await cache.writeChunk(1, data: Data(repeating: 2, count: 4))
        await cache.writeChunk(2, data: Data(repeating: 3, count: 2))
        let bytes = await cache.currentCachedBytes
        let first = await cache.readChunk(0)
        XCTAssertEqual(bytes, 10)
        XCTAssertNotNil(first)
    }

    func testSessionSurvivesQuitAndReopeningSameURLReusesDiskChunks() async throws {
        let chunkSize = Int(PlaybackStreamDiskCache.defaultChunkSize)
        let fileLength = Int64(chunkSize * 2)
        let expected = Data((0..<Int(fileLength)).map { UInt8(truncatingIfNeeded: $0) })
        let remoteURL = URL(string: "https://cache-test.invalid/movie_stream.mp4")!
        let sessionID = "reopen_test_\(UUID().uuidString)"

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlaybackStreamCacheURLProtocol.self]
        PlaybackStreamCacheURLProtocol.resetMetrics()
        PlaybackStreamCacheURLProtocol.handler = { request in
            PlaybackStreamCacheURLProtocol.response(for: request, body: expected, total: fileLength)
        }
        defer {
            PlaybackStreamCacheURLProtocol.handler = nil
            try? FileManager.default.removeItem(at: serverDiskDirectory(for: sessionID))
        }

        // --- Session 1: First playback, fetches chunk 0 and persists to disk ---
        do {
            let server1 = PlaybackStreamCacheServer(
                remoteURL: remoteURL, fileLength: fileLength,
                sessionID: sessionID, sessionConfiguration: configuration
            )
            let localURL1 = try await server1.start()
            var request = URLRequest(url: localURL1)
            request.setValue("bytes=0-\(chunkSize - 1)", forHTTPHeaderField: "Range")
            let chunk0 = try await URLSession.shared.data(for: request).0
            XCTAssertEqual(chunk0, expected.subdata(in: 0..<chunkSize))

            // Wait briefly for chunk to be committed to disk
            let fraction = await server1.cachedFraction()
            XCTAssertGreaterThanOrEqual(fraction, 0.5)

            // User quits the player / session stops (RAM buffer discarded)
            await server1.stop()
        }

        let requestsAfterSession1 = PlaybackStreamCacheURLProtocol.requestCount
        XCTAssertGreaterThanOrEqual(requestsAfterSession1, 1)

        // --- Session 2: User reopens the same stream URL ---
        do {
            // New server instance created for the same stream URL and session ID (simulating app relaunch/reopen)
            let server2 = PlaybackStreamCacheServer(
                remoteURL: remoteURL, fileLength: fileLength,
                sessionID: sessionID, sessionConfiguration: configuration
            )
            let localURL2 = try await server2.start()

            // Verify chunk 0 was scanned from disk immediately on initialization
            let initialFraction = await server2.cachedFraction()
            XCTAssertGreaterThanOrEqual(initialFraction, 0.5)

            // Request chunk 0 again: must be served 100% from disk with 0 new upstream requests
            var request = URLRequest(url: localURL2)
            request.setValue("bytes=0-\(chunkSize - 1)", forHTTPHeaderField: "Range")
            let chunk0Reopened = try await URLSession.shared.data(for: request).0
            XCTAssertEqual(chunk0Reopened, expected.subdata(in: 0..<chunkSize))

            // Forward fill may fetch other chunks while the cached chunk is served.
            // Only a range overlapping chunk 0 would violate reuse.
            let reopenedRanges = PlaybackStreamCacheURLProtocol.requestRanges.dropFirst(requestsAfterSession1)
            for range in reopenedRanges {
                let start = range?.replacingOccurrences(of: "bytes=", with: "").split(separator: "-").first.flatMap { Int($0) }
                XCTAssertGreaterThanOrEqual(start ?? -1, chunkSize, "Cached chunk 0 must not be downloaded again")
            }

            await server2.stop()
        }
    }

    func testDifferentStreamURLProducesIsolatedSessionWithoutReusingChunks() async throws {
        let chunkSize = Int(PlaybackStreamDiskCache.defaultChunkSize)
        let fileLength = Int64(chunkSize * 2)
        let data1 = Data(repeating: 0x11, count: Int(fileLength))

        let session1ID = "session_A_\(UUID().uuidString)"
        let session2ID = "session_B_\(UUID().uuidString)"

        defer {
            try? FileManager.default.removeItem(at: serverDiskDirectory(for: session1ID))
            try? FileManager.default.removeItem(at: serverDiskDirectory(for: session2ID))
        }

        // Session 1 writes chunk 0
        let cache1 = PlaybackStreamDiskCache(sessionID: session1ID, fileLength: fileLength, chunkSize: Int64(chunkSize))
        await cache1.writeChunk(0, data: data1.subdata(in: 0..<chunkSize))
        let cache1HasChunk0 = await cache1.isChunkCached(0)
        XCTAssertTrue(cache1HasChunk0)

        // Session 2 (different URL / token) starts fresh
        let cache2 = PlaybackStreamDiskCache(sessionID: session2ID, fileLength: fileLength, chunkSize: Int64(chunkSize))
        let cache2HasChunk0 = await cache2.isChunkCached(0)
        let cache2Fraction = await cache2.cachedFraction

        XCTAssertFalse(cache2HasChunk0)
        XCTAssertEqual(cache2Fraction, 0)
    }

    func testTVOSClearingCacheStorageIsDetectedAndHandledGracefully() async throws {
        let chunkSize: Int64 = 2 * 1024 * 1024
        let fileLength: Int64 = 6 * 1024 * 1024
        let sessionID = "tvos_purge_test_\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let cache = PlaybackStreamDiskCache(
            sessionID: sessionID, fileLength: fileLength,
            chunkSize: chunkSize, cacheRoot: root
        )

        let chunkData = Data(repeating: 0x99, count: Int(chunkSize))
        await cache.writeChunk(0, data: chunkData)
        await cache.writeChunk(1, data: chunkData)

        var cachedBytes = await cache.currentCachedBytes
        XCTAssertEqual(cachedBytes, chunkSize * 2)

        // Simulate tvOS purging the Caches directory under storage pressure
        try FileManager.default.removeItem(at: cache.cacheDirectory)

        // The cache actor detects the missing directory and resets its cached state
        cachedBytes = await cache.currentCachedBytes
        XCTAssertEqual(cachedBytes, 0)
        let isChunk0Cached = await cache.isChunkCached(0)
        XCTAssertFalse(isChunk0Cached)

        // Writing new chunks recreates the directory seamlessly without failing
        await cache.writeChunk(2, data: chunkData)
        let isChunk2Cached = await cache.isChunkCached(2)
        XCTAssertTrue(isChunk2Cached)
        let bytesAfterRecreation = await cache.currentCachedBytes
        XCTAssertEqual(bytesAfterRecreation, chunkSize)
    }

    func testExactStreamURLReusesExistingSessionWhenValidatorsMatch() async throws {
        let chunkSize = Int(PlaybackStreamDiskCache.defaultChunkSize)
        let fileLength = Int64(chunkSize * 6) // 12 MiB (>10 MB)
        let expected = Data((0..<Int(fileLength)).map { UInt8(truncatingIfNeeded: $0) })
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let url1 = URL(string: "https://cache-test.invalid/d/TOKEN1/movie.mkv?token=alpha")!
        let url2 = url1 // Exact URL reuse remains supported.

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlaybackStreamCacheURLProtocol.self]
        PlaybackStreamCacheURLProtocol.resetMetrics()
        PlaybackStreamCacheURLProtocol.handler = { request in
            PlaybackStreamCacheURLProtocol.response(for: request, body: expected, total: fileLength, etag: "unique-movie-etag")
        }
        defer { PlaybackStreamCacheURLProtocol.handler = nil }

        // First session: URL1 opens, creates manifest and saves chunk 0
        guard let localURL1 = await PlaybackStreamCacheManager.shared.prepareCacheServer(
            for: url1,
            canonicalMediaKey: "canon_test_movie_1",
            filename: "movie.mkv",
            cacheRoot: root,
            sessionConfiguration: configuration
        ) else {
            XCTFail("Failed to prepare cache server 1")
            return
        }

        var req1 = URLRequest(url: localURL1)
        req1.setValue("bytes=0-\(chunkSize - 1)", forHTTPHeaderField: "Range")
        let chunk0Data = try await URLSession.shared.data(for: req1).0
        XCTAssertEqual(chunk0Data, expected.subdata(in: 0..<chunkSize))

        // Playback delivery precedes disk persistence; wait for the background write.
        for _ in 0..<100 {
            if await PlaybackStreamCacheManager.shared.currentCachedFraction() > 0 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let fraction1 = await PlaybackStreamCacheManager.shared.currentCachedFraction()
        XCTAssertGreaterThan(fraction1, 0)

        await PlaybackStreamCacheManager.shared.stopActiveSession()
        let networkRequestsAfterSession1 = PlaybackStreamCacheURLProtocol.requestCount
        XCTAssertGreaterThanOrEqual(networkRequestsAfterSession1, 1)

        // Second session: the exact URL opens with matching validators
        guard let localURL2 = await PlaybackStreamCacheManager.shared.prepareCacheServer(
            for: url2,
            canonicalMediaKey: "canon_test_movie_1",
            filename: "movie.mkv",
            cacheRoot: root,
            sessionConfiguration: configuration
        ) else {
            XCTFail("Failed to prepare cache server 2")
            return
        }

        // Must immediately have chunk 0 recognized on disk
        let initialFraction2 = await PlaybackStreamCacheManager.shared.currentCachedFraction()
        XCTAssertGreaterThan(initialFraction2, 0)

        // Read chunk 0: served 100% from disk!
        var req2 = URLRequest(url: localURL2)
        req2.setValue("bytes=0-\(chunkSize - 1)", forHTTPHeaderField: "Range")
        let chunk0Reused = try await URLSession.shared.data(for: req2).0
        XCTAssertEqual(chunk0Reused, expected.subdata(in: 0..<chunkSize))

        await PlaybackStreamCacheManager.shared.stopActiveSession()
    }

    func testRenewedStreamURLRejectsSessionWhenLengthOrValidatorsMismatch() async throws {
        let chunkSize = Int(PlaybackStreamDiskCache.defaultChunkSize)
        let fileLength1 = Int64(chunkSize * 6) // 12 MiB
        let fileLength2 = Int64(chunkSize * 8) // 16 MiB (different release)
        let expected1 = Data((0..<Int(fileLength1)).map { UInt8(truncatingIfNeeded: $0) })
        let expected2 = Data((0..<Int(fileLength2)).map { UInt8(truncatingIfNeeded: $0) })
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let url1 = URL(string: "https://cache-test.invalid/d/RELEASE1/movie.mkv?token=alpha")!
        let url2 = URL(string: "https://cache-test.invalid/d/RELEASE2/movie.mkv?token=beta")!

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlaybackStreamCacheURLProtocol.self]
        defer { PlaybackStreamCacheURLProtocol.handler = nil }

        // Session 1: length = 12 MiB
        PlaybackStreamCacheURLProtocol.resetMetrics()
        PlaybackStreamCacheURLProtocol.handler = { request in
            PlaybackStreamCacheURLProtocol.response(for: request, body: expected1, total: fileLength1, etag: "tag1")
        }

        guard let localURL1 = await PlaybackStreamCacheManager.shared.prepareCacheServer(
            for: url1, canonicalMediaKey: "canon_mismatch_test", filename: "movie.mkv", cacheRoot: root, sessionConfiguration: configuration
        ) else {
            XCTFail("Failed to prepare cache server 1")
            return
        }
        var req1 = URLRequest(url: localURL1)
        req1.setValue("bytes=0-\(chunkSize - 1)", forHTTPHeaderField: "Range")
        _ = try await URLSession.shared.data(for: req1)
        await PlaybackStreamCacheManager.shared.stopActiveSession()

        // Session 2: different release (length = 16 MiB)
        PlaybackStreamCacheURLProtocol.handler = { request in
            PlaybackStreamCacheURLProtocol.response(for: request, body: expected2, total: fileLength2, etag: "tag2")
        }

        guard let _ = await PlaybackStreamCacheManager.shared.prepareCacheServer(
            for: url2, canonicalMediaKey: "canon_mismatch_test", filename: "movie.mkv", cacheRoot: root, sessionConfiguration: configuration
        ) else {
            XCTFail("Failed to prepare cache server 2")
            return
        }

        // Session 2 should have rejected session 1's cache for reuse and created an isolated session directory.
        // Both session directories exist in root with their respective distinct file lengths.
        let subdirs = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        XCTAssertEqual(subdirs.count, 2)

        let manifests = subdirs.compactMap { PlaybackStreamDiskCache.readManifest(in: $0) }
        XCTAssertEqual(manifests.count, 2)
        XCTAssertTrue(manifests.contains { $0.fileLength == fileLength1 })
        XCTAssertTrue(manifests.contains { $0.fileLength == fileLength2 })

        await PlaybackStreamCacheManager.shared.stopActiveSession()
    }

    func testFreeSpaceReservePreventsPrefetchWhenStorageHeadroomIsExhausted() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let cache = PlaybackStreamDiskCache(
            sessionID: "headroom_test",
            fileLength: 10 * 1024 * 1024,
            chunkSize: 2 * 1024 * 1024,
            freeSpaceReserveBytes: 2 * 1024 * 1024 * 1024, // 2 GB reserve
            cacheRoot: root,
            freeSpaceProvider: { _ in 1 * 1024 * 1024 * 1024 } // Only 1 GB free (below reserve!)
        )

        // canPrefetchChunk must return false because free space (1 GB) < reserve (2 GB)
        let canPrefetch = await cache.canPrefetchChunk(0, playheadOffset: 0, evictBehindPlayhead: true)
        XCTAssertFalse(canPrefetch)

        // writeChunk must reject disk write to protect OS headroom
        let chunkData = Data(repeating: 0x55, count: 2 * 1024 * 1024)
        let written = await cache.writeChunk(0, data: chunkData)
        XCTAssertFalse(written)
        let isCached = await cache.isChunkCached(0)
        XCTAssertFalse(isCached)
    }

    func testFreeSpacePressurePrunesOldestSessionsFirst() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let session1Dir = root.appendingPathComponent("session_old", isDirectory: true)
        let session2Dir = root.appendingPathComponent("session_current", isDirectory: true)
        try FileManager.default.createDirectory(at: session1Dir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: session2Dir, withIntermediateDirectories: true)

        try Data(repeating: 1, count: 1024).write(to: session1Dir.appendingPathComponent("chunk_0.bin"))
        try Data(repeating: 2, count: 1024).write(to: session2Dir.appendingPathComponent("chunk_0.bin"))

        // Set modification date of session1 older
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-1000)], ofItemAtPath: session1Dir.path)

        // Simulate free space of 1 GB with a 2 GB reserve
        let available = PlaybackStreamDiskBudget.shared.availableBytes(
            in: root,
            limit: 100 * 1024 * 1024,
            preserving: session2Dir,
            freeSpaceReserve: 2_000_000_000,
            freeSpaceProvider: { _ in 1_000_000_000 }
        )

        // session1 should be pruned to relieve headroom pressure
        XCTAssertFalse(FileManager.default.fileExists(atPath: session1Dir.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: session2Dir.path))
        XCTAssertGreaterThanOrEqual(available, 0)
    }

    func testBatchSequentialFetchAndAdaptiveBuffering() async throws {
        let chunkSize = Int(PlaybackStreamDiskCache.defaultChunkSize)
        let fileLength = Int64(chunkSize * 4) // 8 MiB (4 chunks)
        let expected = Data((0..<Int(fileLength)).map { UInt8(truncatingIfNeeded: $0) })
        let remoteURL = URL(string: "https://cache-test.invalid/batch_test.mp4")!
        let sessionID = "batch_\(UUID().uuidString)"

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlaybackStreamCacheURLProtocol.self]
        PlaybackStreamCacheURLProtocol.resetMetrics()
        PlaybackStreamCacheURLProtocol.handler = { request in
            PlaybackStreamCacheURLProtocol.response(for: request, body: expected, total: fileLength)
        }
        defer {
            PlaybackStreamCacheURLProtocol.handler = nil
            try? FileManager.default.removeItem(at: serverDiskDirectory(for: sessionID))
        }

        let server = PlaybackStreamCacheServer(
            remoteURL: remoteURL, fileLength: fileLength,
            sessionID: sessionID, sessionConfiguration: configuration
        )
        // Configure duration = 60s -> bit rate ~1.06 Mbps, adaptive lead adapts
        await server.updateTimeline(playheadOffset: 0, durationSeconds: 60.0)
        let lead = await server.adaptiveForwardLeadBytes
        XCTAssertGreaterThanOrEqual(lead, 80 * 1024 * 1024)

        _ = try await server.start()

        // Wait briefly for background forward fill to burst batch fetch
        for _ in 0..<30 {
            let fraction = await server.cachedFraction()
            if fraction >= 1.0 { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        // All 4 chunks (8 MiB) should be cached in 1 upstream batch request
        let fraction = await server.cachedFraction()
        XCTAssertEqual(fraction, 1.0)
        XCTAssertEqual(PlaybackStreamCacheURLProtocol.requestCount, 1)

        await server.stop()
    }

    func testManifestDateEncodingRoundTrip() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let now = Date(timeIntervalSince1970: 1700000000)
        let manifest = PlaybackStreamManifest(
            sessionID: "test_session_123",
            fileLength: 50_000_000,
            etag: "strong-etag-123",
            lastModified: "Wed, 21 Oct 2015 07:28:00 GMT",
            canonicalMediaKey: "tmdb:12345",
            filename: "video.mp4",
            normalizedURLPath: "/path/video.mp4",
            createdAt: now,
            lastAccessedAt: now
        )

        PlaybackStreamDiskCache.writeManifest(manifest, to: tempDir)
        let readBack = PlaybackStreamDiskCache.readManifest(in: tempDir)

        XCTAssertNotNil(readBack)
        XCTAssertEqual(readBack?.canonicalMediaKey, "tmdb:12345")
        XCTAssertEqual(readBack?.fileLength, 50_000_000)
        XCTAssertEqual(readBack?.etag, "strong-etag-123")
        if let readDate = readBack?.createdAt {
            XCTAssertEqual(floor(readDate.timeIntervalSince1970), floor(now.timeIntervalSince1970))
        } else {
            XCTFail("Manifest createdAt date failed to decode")
        }
    }

    func testPromptDemandDoesNotBlockOnBatch() async throws {
        let chunkSize = Int(PlaybackStreamDiskCache.defaultChunkSize)
        let fileLength = Int64(chunkSize * 4) // 8 MiB (4 chunks)
        let expected = Data((0..<Int(fileLength)).map { UInt8(truncatingIfNeeded: $0) })
        let remoteURL = URL(string: "https://cache-test.invalid/prompt_demand.mp4")!
        let sessionID = "demand_\(UUID().uuidString)"

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlaybackStreamCacheURLProtocol.self]
        PlaybackStreamCacheURLProtocol.resetMetrics()
        PlaybackStreamCacheURLProtocol.handler = { request in
            let range = request.value(forHTTPHeaderField: "Range") ?? ""
            if range.contains("0-8388607") {
                Thread.sleep(forTimeInterval: 0.1)
            }
            return PlaybackStreamCacheURLProtocol.response(for: request, body: expected, total: fileLength)
        }
        defer {
            PlaybackStreamCacheURLProtocol.handler = nil
            try? FileManager.default.removeItem(at: serverDiskDirectory(for: sessionID))
        }

        let server = PlaybackStreamCacheServer(
            remoteURL: remoteURL, fileLength: fileLength,
            sessionID: sessionID, sessionConfiguration: configuration
        )
        _ = try await server.start()

        // Prompt demand fetch for chunk 2 (2 MiB)
        let chunk2Data = await server.fetchDemandChunk(2)
        XCTAssertNotNil(chunk2Data)
        XCTAssertEqual(chunk2Data?.count, chunkSize)

        let chunk2Range = (chunkSize * 2)..<(chunkSize * 3)
        XCTAssertEqual(chunk2Data, expected.subdata(in: chunk2Range))

        await server.stop()
    }

    func testDemandPlaybackContinuesInRAMWhenHeadroomExhausted() async throws {
        let chunkSize = Int(PlaybackStreamDiskCache.defaultChunkSize)
        let fileLength = Int64(chunkSize * 2)
        let expected = Data((0..<Int(fileLength)).map { UInt8(truncatingIfNeeded: $0) })
        let remoteURL = URL(string: "https://cache-test.invalid/headroom_degradation.mp4")!
        let sessionID = "headroom_deg_\(UUID().uuidString)"

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlaybackStreamCacheURLProtocol.self]
        PlaybackStreamCacheURLProtocol.resetMetrics()
        PlaybackStreamCacheURLProtocol.handler = { request in
            PlaybackStreamCacheURLProtocol.response(for: request, body: expected, total: fileLength)
        }
        defer {
            PlaybackStreamCacheURLProtocol.handler = nil
            try? FileManager.default.removeItem(at: serverDiskDirectory(for: sessionID))
        }

        // Simulate free space of 1 GB (below 2 GB reserve)
        let server = PlaybackStreamCacheServer(
            remoteURL: remoteURL, fileLength: fileLength,
            sessionID: sessionID,
            freeSpaceReserveBytes: 2 * 1024 * 1024 * 1024,
            sessionConfiguration: configuration,
            freeSpaceProvider: { _ in 1 * 1024 * 1024 * 1024 }
        )
        _ = try await server.start()

        // Demand fetch chunk 0
        let data = await server.fetchDemandChunk(0)
        // Data must be successfully delivered in RAM to player despite disk write failure
        XCTAssertNotNil(data)
        XCTAssertEqual(data?.count, chunkSize)
        XCTAssertEqual(data, expected.subdata(in: 0..<chunkSize))

        // But chunk should NOT be cached on disk
        let isCached = await server.contiguousCachedBytesAhead(of: 0)
        XCTAssertEqual(isCached, 0)

        await server.stop()
    }

    func testSeekCancelsObsoletePrefetch() async throws {
        let chunkSize = Int(PlaybackStreamDiskCache.defaultChunkSize)
        let fileLength = Int64(chunkSize * 10)
        let remoteURL = URL(string: "https://cache-test.invalid/seek_test.mp4")!
        let sessionID = "seek_\(UUID().uuidString)"

        let server = PlaybackStreamCacheServer(
            remoteURL: remoteURL, fileLength: fileLength,
            sessionID: sessionID
        )

        await server.updateTimeline(playheadOffset: 0, durationSeconds: 100.0)
        await server.updateTimeline(playheadOffset: 10 * 1024 * 1024, durationSeconds: 100.0)

        let lead = await server.adaptiveForwardLeadBytes
        XCTAssertGreaterThan(lead, 0)

        await server.stop()
    }

    func testUnavailableVolumeCapacityFallback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionDir = root.appendingPathComponent("session_cap_unavailable", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        let chunkSize: Int64 = 2 * 1024 * 1024
        let cache = PlaybackStreamDiskCache(
            sessionID: "cap_unavail_test",
            fileLength: 10 * 1024 * 1024,
            chunkSize: chunkSize,
            maxCacheSizeBytes: 20 * 1024 * 1024,
            cacheRoot: root,
            freeSpaceProvider: { _ in -1 }
        )

        let canPrefetch = await cache.canPrefetchChunk(0, playheadOffset: 0, evictBehindPlayhead: true)
        XCTAssertTrue(canPrefetch)

        let chunkData = Data(repeating: 0x42, count: Int(chunkSize))
        let written = await cache.writeChunk(0, data: chunkData)
        XCTAssertTrue(written)
        let isCached = await cache.isChunkCached(0)
        XCTAssertTrue(isCached)
    }

    func testDemandPreemptsForwardBatchWhenConcurrencyIsOne() async throws {
        let chunkSize = Int(PlaybackStreamDiskCache.defaultChunkSize)
        let fileLength = Int64(chunkSize * 8)
        let expected = Data(repeating: 0x77, count: Int(fileLength))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlaybackStreamCacheURLProtocol.self]
        PlaybackStreamCacheURLProtocol.resetMetrics()
        PlaybackStreamCacheURLProtocol.delay = 1.0 // 1.0s delay on upstream network
        PlaybackStreamCacheURLProtocol.handler = { request in
            PlaybackStreamCacheURLProtocol.response(
                for: request, body: expected, total: fileLength
            )
        }
        let session = "test_preempt_\(UUID().uuidString)"
        defer {
            PlaybackStreamCacheURLProtocol.handler = nil
            PlaybackStreamCacheURLProtocol.delay = 0
            try? FileManager.default.removeItem(at: serverDiskDirectory(for: session))
        }

        let server = PlaybackStreamCacheServer(
            remoteURL: URL(string: "https://cache-test.invalid/preempt.mp4")!,
            fileLength: fileLength,
            sessionID: session,
            sessionConfiguration: configuration,
            maxConcurrentUpstream: 1
        )
        _ = try await server.start()

        // Wait until forward prefetch starts and occupies the single upstream slot
        for _ in 0..<100 where PlaybackStreamCacheURLProtocol.requestCount == 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(PlaybackStreamCacheURLProtocol.requestCount, 1)

        let startDemand = Date()
        // Demand chunk 4 while forward batch is running.
        // Demand should preempt the forward batch immediately instead of stalling.
        let demandData = await server.fetchDemandChunk(4)
        let elapsed = Date().timeIntervalSince(startDemand)

        XCTAssertNotNil(demandData)
        XCTAssertEqual(demandData?.count, chunkSize)
        // If demand had stalled behind forward batch, total elapsed would be > 2.0s
        XCTAssertLessThan(elapsed, 1.8)

        await server.stop()
    }

    func testHeadroomAccountingDoesNotDoubleSubtractOtherBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let reserve: Int64 = 1 * 1024 * 1024 * 1024 // 1 GiB reserve
        let volumeFree: Int64 = 3 * 1024 * 1024 * 1024 // 3 GiB reported free volume capacity
        let limit: Int64 = 10 * 1024 * 1024 * 1024 // 10 GiB budget limit

        // Create an existing session directory with 2 GiB of data
        let otherSession = root.appendingPathComponent("other_session", isDirectory: true)
        try FileManager.default.createDirectory(at: otherSession, withIntermediateDirectories: true)
        let dummyChunk = otherSession.appendingPathComponent("chunk_0.dat")
        let dummyData = Data(repeating: 0x01, count: 1024)
        try dummyData.write(to: dummyChunk)

        let currentSessionDir = root.appendingPathComponent("current_session", isDirectory: true)
        try FileManager.default.createDirectory(at: currentSessionDir, withIntermediateDirectories: true)

        let available = PlaybackStreamDiskBudget.shared.availableBytes(
            in: root,
            limit: limit,
            preserving: currentSessionDir,
            freeSpaceReserve: reserve,
            freeSpaceProvider: { _ in volumeFree }
        )

        // volumeFree (3 GiB) already excludes all existing sessions on disk.
        // Headroom allowance = volumeFree + currentBytes (0) - reserve (1 GiB) = 2 GiB.
        // Budget allowance = limit (10 GiB) - otherBytes (1024) ~= 10 GiB.
        // Correct available bytes = min(budgetAllowance, headroomAllowance) = 2 GiB.
        // (The old buggy formula subtracted otherBytes from volumeFree again, resulting in undercounting).
        let expectedHeadroom = volumeFree - reserve
        XCTAssertEqual(available, expectedHeadroom)
    }

    func testNormalBufferingDoesNotTriggerFalseSeek() async throws {
        let chunkSize = Int(PlaybackStreamDiskCache.defaultChunkSize)
        let fileLength = Int64(chunkSize * 20) // 40 MiB
        let remoteURL = URL(string: "https://cache-test.invalid/false_seek.mp4")!
        let sessionID = "false_seek_\(UUID().uuidString)"

        let server = PlaybackStreamCacheServer(
            remoteURL: remoteURL, fileLength: fileLength,
            sessionID: sessionID
        )

        // Player starts at offset 0
        await server.updateTimeline(playheadOffset: 0, durationSeconds: 100.0)

        // Player progresses slightly to 1 MiB
        await server.updateTimeline(playheadOffset: 1 * 1024 * 1024, durationSeconds: 100.0)

        // Next poll arrives at 1.5 MiB (small forward increment of 0.5 MiB)
        // Decoupled playerPlayheadOffset ensures this is evaluated as diff = +0.5 MiB (not a backward seek)
        await server.updateTimeline(playheadOffset: Int64(1.5 * 1024 * 1024), durationSeconds: 100.0)

        let lead = await server.adaptiveForwardLeadBytes
        XCTAssertGreaterThan(lead, 0)

        await server.stop()
    }

    func testTimelineProgressDoesNotCancelActivePrefetchButExplicitSeekDoes() async throws {
        let chunkSize = Int(PlaybackStreamDiskCache.defaultChunkSize)
        let fileLength = Int64(chunkSize * 20)
        let body = Data(repeating: 0x61, count: Int(fileLength))
        let sessionID = "timeline_seek_\(UUID().uuidString)"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlaybackStreamCacheURLProtocol.self]
        PlaybackStreamCacheURLProtocol.resetMetrics()
        PlaybackStreamCacheURLProtocol.delay = 1
        PlaybackStreamCacheURLProtocol.handler = { request in
            PlaybackStreamCacheURLProtocol.response(for: request, body: body, total: fileLength)
        }
        defer {
            PlaybackStreamCacheURLProtocol.handler = nil
            PlaybackStreamCacheURLProtocol.delay = 0
            try? FileManager.default.removeItem(at: serverDiskDirectory(for: sessionID))
        }

        let server = PlaybackStreamCacheServer(
            remoteURL: URL(string: "https://cache-test.invalid/timeline_seek.mp4")!,
            fileLength: fileLength, sessionID: sessionID, sessionConfiguration: configuration
        )
        await server.updateTimeline(playheadOffset: 0, durationSeconds: 100)
        _ = try await server.start()
        for _ in 0..<100 where PlaybackStreamCacheURLProtocol.requestCount == 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertGreaterThan(PlaybackStreamCacheURLProtocol.requestCount, 0)

        // A large ordinary timeline advance is playback progress, not a seek.
        await server.updateTimeline(playheadOffset: 5 * 1024 * 1024, durationSeconds: 100, isSeek: false)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(PlaybackStreamCacheURLProtocol.cancellationCount, 0)

        await server.updateTimeline(playheadOffset: 30 * 1024 * 1024, durationSeconds: 100, isSeek: true)
        for _ in 0..<100 where PlaybackStreamCacheURLProtocol.cancellationCount == 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertGreaterThan(PlaybackStreamCacheURLProtocol.cancellationCount, 0)
        await server.stop()
    }
}


extension PlaybackStreamCacheTests {
    func testPlaybackCacheFileIdentityRequiresNormalizedHashAndExplicitIndex() {
        let valid = PlaybackCacheFileIdentity(infoHash: String(repeating: "A", count: 40), fileIndex: 0)
        XCTAssertEqual(valid?.infoHash, String(repeating: "a", count: 40))
        XCTAssertEqual(valid?.cacheKey, "torrent:\(String(repeating: "a", count: 40)):0")
        XCTAssertNil(PlaybackCacheFileIdentity(infoHash: String(repeating: "a", count: 40), fileIndex: nil))
        XCTAssertNil(PlaybackCacheFileIdentity(infoHash: "title", fileIndex: 0))
        XCTAssertNil(PlaybackCacheFileIdentity(infoHash: String(repeating: "g", count: 40), fileIndex: 0))
        XCTAssertNil(PlaybackCacheFileIdentity(infoHash: String(repeating: "a", count: 40), fileIndex: -1))
    }

    func testTrustedIdentityReusesChunksAcrossRenewedURLsAndIsolatesLength() async throws {
        let chunkSize = Int(PlaybackStreamDiskCache.defaultChunkSize)
        let length = Int64(chunkSize * 6)
        let body = Data(repeating: 0x19, count: Int(length))
        let identity = try XCTUnwrap(PlaybackCacheFileIdentity(infoHash: String(repeating: "b", count: 40), fileIndex: 2))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlaybackStreamCacheURLProtocol.self]
        PlaybackStreamCacheURLProtocol.resetMetrics()
        PlaybackStreamCacheURLProtocol.handler = { request in
            PlaybackStreamCacheURLProtocol.response(for: request, body: body, total: length)
        }
        defer { PlaybackStreamCacheURLProtocol.handler = nil }

        let firstURL = URL(string: "https://cache-test.invalid:8443/a/path?token=one")!
        let firstPrepared = await PlaybackStreamCacheManager.shared.prepareCacheServer(
            for: firstURL, cacheFileIdentity: identity, cacheRoot: root,
            sessionConfiguration: configuration, freeSpaceProvider: { _ in 100 * 1024 * 1024 * 1024 }
        )
        let firstLocal = try XCTUnwrap(firstPrepared)
        var request = URLRequest(url: firstLocal)
        request.setValue("bytes=0-\(chunkSize - 1)", forHTTPHeaderField: "Range")
        _ = try await URLSession.shared.data(for: request)
        await PlaybackStreamCacheManager.shared.stopActiveSession()

        let requestsBeforeRenewal = PlaybackStreamCacheURLProtocol.requestCount
        let renewedURL = URL(string: "https://cache-test.invalid:9443/renewed?token=two")!
        let renewedPrepared = await PlaybackStreamCacheManager.shared.prepareCacheServer(
            for: renewedURL, cacheFileIdentity: identity, cacheRoot: root,
            sessionConfiguration: configuration, freeSpaceProvider: { _ in 100 * 1024 * 1024 * 1024 }
        )
        let renewedLocal = try XCTUnwrap(renewedPrepared)
        request.url = renewedLocal
        let reused = try await URLSession.shared.data(for: request).0
        XCTAssertEqual(reused, body.prefix(chunkSize))
        let renewedRanges = PlaybackStreamCacheURLProtocol.requestRanges.dropFirst(requestsBeforeRenewal)
        XCTAssertFalse(renewedRanges.contains { $0 == "bytes=0-\(chunkSize - 1)" })
        await PlaybackStreamCacheManager.shared.stopActiveSession()

        let differentIdentity = try XCTUnwrap(PlaybackCacheFileIdentity(infoHash: String(repeating: "c", count: 40), fileIndex: 2))
        let isolatedPrepared = await PlaybackStreamCacheManager.shared.prepareCacheServer(
            for: renewedURL, cacheFileIdentity: differentIdentity, cacheRoot: root,
            sessionConfiguration: configuration, freeSpaceProvider: { _ in 100 * 1024 * 1024 * 1024 }
        )
        let isolatedURL = try XCTUnwrap(isolatedPrepared)
        XCTAssertNotEqual(renewedLocal.path, isolatedURL.path)
        await PlaybackStreamCacheManager.shared.stopActiveSession()
    }

    func testTypedIdentityCacheReopensByExactURLWhenMetadataIsMissing() async throws {
        let chunkSize = Int(PlaybackStreamDiskCache.defaultChunkSize)
        let length = Int64(chunkSize * 6)
        let body = Data(repeating: 0x27, count: Int(length))
        let identity = try XCTUnwrap(PlaybackCacheFileIdentity(infoHash: String(repeating: "d", count: 40), fileIndex: 1))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = URL(string: "https://cache-test.invalid/exact/movie?token=one")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlaybackStreamCacheURLProtocol.self]
        PlaybackStreamCacheURLProtocol.resetMetrics()
        PlaybackStreamCacheURLProtocol.handler = { request in
            PlaybackStreamCacheURLProtocol.response(for: request, body: body, total: length, etag: "exact")
        }
        defer { PlaybackStreamCacheURLProtocol.handler = nil }

        let typed = await PlaybackStreamCacheManager.shared.prepareCacheServer(
            for: url, cacheFileIdentity: identity, cacheRoot: root,
            sessionConfiguration: configuration, freeSpaceProvider: { _ in 100 * 1024 * 1024 * 1024 }
        )
        let typedLocal = try XCTUnwrap(typed)
        var request = URLRequest(url: typedLocal)
        request.setValue("bytes=0-\(chunkSize - 1)", forHTTPHeaderField: "Range")
        _ = try await URLSession.shared.data(for: request)
        await PlaybackStreamCacheManager.shared.stopActiveSession()
        let beforeReopen = PlaybackStreamCacheURLProtocol.requestCount

        let reopened = await PlaybackStreamCacheManager.shared.prepareCacheServer(
            for: url, cacheRoot: root, sessionConfiguration: configuration,
            freeSpaceProvider: { _ in 100 * 1024 * 1024 * 1024 }
        )
        let reopenedLocal = try XCTUnwrap(reopened)
        request.url = reopenedLocal
        let reused = try await URLSession.shared.data(for: request).0
        XCTAssertEqual(reused, body.prefix(chunkSize))
        let reopenedRanges = PlaybackStreamCacheURLProtocol.requestRanges.dropFirst(beforeReopen)
        XCTAssertFalse(reopenedRanges.contains { $0 == "bytes=0-\(chunkSize - 1)" })
        await PlaybackStreamCacheManager.shared.stopActiveSession()
    }

    func testDifferentResourcesNeverShareCachedChunksFromMatchingValidators() async throws {
        let chunkSize = Int(PlaybackStreamDiskCache.defaultChunkSize)
        let length = Int64(chunkSize * 2)
        let firstBody = Data(repeating: 0x11, count: Int(length))
        let secondBody = Data(repeating: 0x22, count: Int(length))
        let firstURL = URL(string: "https://cache-test.invalid/movie.mkv?token=one")!
        let lastModified = "Tue, 15 Sep 2026 10:00:00 GMT"
        let cases: [(String, String?, String?)] = [
            ("https://cache-test.invalid/movie.mkv?token=two", "\"same\"", nil),
            ("https://cache-test.invalid/another/movie.mkv", "\"same\"", nil),
            ("https://cache-test.invalid:8443/movie.mkv", "\"same\"", nil),
            ("https://cache-test.invalid/movie.mkv?token=two", nil, lastModified),
            ("https://cache-test.invalid/movie.mkv?token=two", "W/\"same\"", lastModified),
            ("https://cache-test.invalid/movie.mkv?token=two", nil, nil)
        ]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlaybackStreamCacheURLProtocol.self]
        for (secondURLString, etag, modified) in cases {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let secondURL = URL(string: secondURLString)!
            PlaybackStreamCacheURLProtocol.handler = { request in
                PlaybackStreamCacheURLProtocol.response(
                    for: request, body: request.url == firstURL ? firstBody : secondBody,
                    total: length, etag: etag, lastModified: modified
                )
            }
            defer { PlaybackStreamCacheURLProtocol.handler = nil }
            do {
                let firstPrepared = await PlaybackStreamCacheManager.shared.prepareCacheServer(
                    for: firstURL, canonicalMediaKey: "same-title", filename: "movie.mkv",
                    cacheRoot: root, sessionConfiguration: configuration,
                    freeSpaceProvider: { _ in 100 * 1024 * 1024 * 1024 }
                )
                let firstLocal = try XCTUnwrap(firstPrepared)
                var request = URLRequest(url: firstLocal)
                request.setValue("bytes=0-\(chunkSize - 1)", forHTTPHeaderField: "Range")
                let firstData = try await URLSession.shared.data(for: request).0
                XCTAssertEqual(firstData, firstBody.prefix(chunkSize))
                await PlaybackStreamCacheManager.shared.stopActiveSession()

                let secondPrepared = await PlaybackStreamCacheManager.shared.prepareCacheServer(
                    for: secondURL, canonicalMediaKey: "same-title", filename: "movie.mkv",
                    cacheRoot: root, sessionConfiguration: configuration,
                    freeSpaceProvider: { _ in 100 * 1024 * 1024 * 1024 }
                )
                let secondLocal = try XCTUnwrap(secondPrepared)
                XCTAssertNotEqual(firstLocal.path, secondLocal.path, secondURLString)
                request.url = secondLocal
                let secondData = try await URLSession.shared.data(for: request).0
                XCTAssertEqual(secondData, secondBody.prefix(chunkSize), secondURLString)
                await PlaybackStreamCacheManager.shared.stopActiveSession()
            } catch {
                await PlaybackStreamCacheManager.shared.stopActiveSession()
                throw error
            }
        }
    }

    func testUnifiedBufferPolicyAndSchedulerCoordination() async {
        // 1. Verify PlaybackCacheProfile buffer sizing and resolution
        XCTAssertEqual(PlaybackCacheProfile.conservative.hybridCacheTargetLeadSeconds, 45.0)
        XCTAssertEqual(PlaybackCacheProfile.medium.hybridCacheTargetLeadSeconds, 90.0)
        XCTAssertEqual(PlaybackCacheProfile.large.hybridCacheTargetLeadSeconds, 150.0)
        XCTAssertEqual(PlaybackCacheProfile.max.hybridCacheTargetLeadSeconds, 240.0)
        XCTAssertEqual(PlaybackCacheProfile.ultra.hybridCacheTargetLeadSeconds, 360.0)

        // 2. Verify Auto lead seconds scaling
        let autoHighRAM = PlaybackCacheProfile.resolveAutoLeadSeconds(
            physicalMemoryBytes: 4 * 1024 * 1024 * 1024, availableMemoryBytes: 1200 * 1024 * 1024
        )
        XCTAssertEqual(autoHighRAM, 240.0)

        let autoLowRAM = PlaybackCacheProfile.resolveAutoLeadSeconds(
            physicalMemoryBytes: 2 * 1024 * 1024 * 1024, availableMemoryBytes: 200 * 1024 * 1024
        )
        XCTAssertEqual(autoLowRAM, 60.0)

        // 3. Verify Aether segment coordination: 10 segments (or direct bounds) when backed by hybrid cache, direct profile otherwise
        XCTAssertEqual(PlaybackCacheProfile.max.aetherForwardBufferSegments(isBackedByHybridDiskCache: true), 10)
        XCTAssertEqual(PlaybackCacheProfile.max.aetherForwardBufferSegments(isBackedByHybridDiskCache: false), 25)
        XCTAssertEqual(PlaybackCacheProfile.conservative.aetherForwardBufferSegments(isBackedByHybridDiskCache: true), 4)
        XCTAssertEqual(PlaybackCacheProfile.conservative.aetherForwardBufferSegments(isBackedByHybridDiskCache: false), 4)
        XCTAssertEqual(PlaybackCacheProfile.medium.aetherForwardBufferSegments(isBackedByHybridDiskCache: true), 10)
        XCTAssertEqual(PlaybackCacheProfile.medium.aetherForwardBufferSegments(isBackedByHybridDiskCache: false), 10)
        XCTAssertEqual(PlaybackCacheProfile.large.aetherForwardBufferSegments(isBackedByHybridDiskCache: true), 10)
        XCTAssertEqual(PlaybackCacheProfile.large.aetherForwardBufferSegments(isBackedByHybridDiskCache: false), 18)

        // 4. Verify PlaybackStreamCacheServer adaptive forward lead calculation uses targetLeadSeconds
        let server = PlaybackStreamCacheServer(
            remoteURL: URL(string: "https://example.com/video.mkv")!,
            fileLength: 1_000_000_000, // 1 GB
            targetLeadSeconds: 60.0
        )
        await server.updateTimeline(playheadOffset: 0, durationSeconds: 1000) // 1 MB/s byte rate
        let forwardLead = await server.adaptiveForwardLeadBytes
        // Estimated rate = 1 MB/s * 60s target lead = 60 MB, clamped to min 80 MB
        XCTAssertEqual(forwardLead, 80 * 1024 * 1024)

        let serverLarge = PlaybackStreamCacheServer(
            remoteURL: URL(string: "https://example.com/video.mkv")!,
            fileLength: 5_000_000_000, // 5 GB
            targetLeadSeconds: 200.0
        )
        await serverLarge.updateTimeline(playheadOffset: 0, durationSeconds: 1000) // 5 MB/s byte rate
        let forwardLeadLarge = await serverLarge.adaptiveForwardLeadBytes
        // Estimated rate = 5 MB/s * 200s target lead = 1_000_000_000 bytes
        XCTAssertEqual(forwardLeadLarge, 1_000_000_000)
    }

    func testSuffixRangeAndOpenEndedRangeRequests() async throws {
        let chunkSize = Int(PlaybackStreamDiskCache.defaultChunkSize)
        let fileLength = Int64(chunkSize * 4) // 8 MiB
        var fullBody = Data()
        for i in 0..<4 {
            fullBody.append(Data(repeating: UInt8(i + 1), count: chunkSize))
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlaybackStreamCacheURLProtocol.self]
        PlaybackStreamCacheURLProtocol.resetMetrics()
        PlaybackStreamCacheURLProtocol.handler = { request in
            PlaybackStreamCacheURLProtocol.response(for: request, body: fullBody, total: fileLength)
        }
        let session = "test_suffix_\(UUID().uuidString)"
        defer {
            PlaybackStreamCacheURLProtocol.handler = nil
            try? FileManager.default.removeItem(at: serverDiskDirectory(for: session))
        }

        let server = PlaybackStreamCacheServer(
            remoteURL: URL(string: "https://cache-test.invalid/suffix_test.mkv")!,
            fileLength: fileLength,
            sessionID: session,
            sessionConfiguration: configuration
        )
        let localURL = try await server.start()

        // 1. Test Suffix Range: bytes=-65536 (last 64 KB of the file)
        var suffixReq = URLRequest(url: localURL)
        suffixReq.setValue("bytes=-65536", forHTTPHeaderField: "Range")
        let (suffixData, suffixResp) = try await URLSession.shared.data(for: suffixReq)
        let httpSuffix = suffixResp as! HTTPURLResponse
        XCTAssertEqual(httpSuffix.statusCode, 206)
        XCTAssertEqual(httpSuffix.value(forHTTPHeaderField: "Content-Range"), "bytes \(fileLength - 65536)-\(fileLength - 1)/\(fileLength)")
        XCTAssertEqual(suffixData.count, 65536)
        XCTAssertEqual(suffixData, fullBody.suffix(65536))

        // 2. Test Open-Ended Range: bytes=2097152- (from offset 2MB to end)
        var openEndedReq = URLRequest(url: localURL)
        openEndedReq.setValue("bytes=\(chunkSize)-", forHTTPHeaderField: "Range")
        let (openData, openResp) = try await URLSession.shared.data(for: openEndedReq)
        let httpOpen = openResp as! HTTPURLResponse
        XCTAssertEqual(httpOpen.statusCode, 206)
        XCTAssertEqual(httpOpen.value(forHTTPHeaderField: "Content-Range"), "bytes \(chunkSize)-\(fileLength - 1)/\(fileLength)")
        XCTAssertEqual(openData.count, Int(fileLength) - chunkSize)
        XCTAssertEqual(openData, fullBody.subdata(in: chunkSize..<Int(fileLength)))

        await server.stop()
    }
}


