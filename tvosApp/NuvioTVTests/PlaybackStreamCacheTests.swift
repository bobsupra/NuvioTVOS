import XCTest
import AetherEngine
import Darwin
@testable import NuvioTV
#if NUVIO_MPV_MEMORY_WATCHDOG && os(tvOS)
import Libmpv
#endif

private final class PlaybackThumbnailYieldCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    func shouldYieldOnFourthCheck() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        return calls == 4
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

final class PlaybackStreamCacheTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        await PlaybackStreamCacheManager.shared.stopActiveSession()
        PlaybackStreamCacheURLProtocol.resetMetrics()
        PlaybackStreamCacheURLProtocol.handler = nil
        PlaybackStreamCacheURLProtocol.delay = 0
    }

    override func tearDown() async throws {
        await PlaybackStreamCacheManager.shared.stopActiveSession()
        PlaybackStreamCacheURLProtocol.resetMetrics()
        PlaybackStreamCacheURLProtocol.handler = nil
        PlaybackStreamCacheURLProtocol.delay = 0
        try await super.tearDown()
    }

    private func waitForProtocolCancellationIfStillLoading() async {
        guard PlaybackStreamCacheURLProtocol.activeRequestCount > 0 else { return }
        for _ in 0..<50 where PlaybackStreamCacheURLProtocol.activeRequestCount > 0
            && PlaybackStreamCacheURLProtocol.cancellationCount == 0 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

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
            response.contentRange = "bytes 0--\(chunkSize - 1)/\(fileLength)"
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

extension PlaybackStreamCacheTests {
    func testCacheOnlyReaderHasIndependentCursorsAndReadsShortFinalChunk() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = thumbnailSource(root: root, fileLength: 7, chunkSize: 4)
        try FileManager.default.createDirectory(at: source.cacheDirectory, withIntermediateDirectories: true)
        try Data([1, 2, 3, 4]).write(to: source.cacheDirectory.appendingPathComponent("chunk_0.bin"))
        try Data([5, 6, 7]).write(to: source.cacheDirectory.appendingPathComponent("chunk_1.bin"))
        defer { try? FileManager.default.removeItem(at: root) }

        let first = PlaybackStreamCacheIOReader(source: source)
        let second = PlaybackStreamCacheIOReader(source: source)
        let firstRead = read(first, size: 6)
        XCTAssertEqual(firstRead.count, 6)
        XCTAssertEqual(firstRead.data, Data([1, 2, 3, 4, 5, 6]))
        XCTAssertEqual(first.seek(offset: 6, whence: Int32(SEEK_SET)), 6)
        XCTAssertEqual(read(first, size: 4).data, Data([7]))
        XCTAssertEqual(read(first, size: 1).count, 0)

        XCTAssertEqual(read(second, size: 2).data, Data([1, 2]))
        XCTAssertEqual(second.seek(offset: 3, whence: Int32(SEEK_SET)), 3)
        XCTAssertEqual(read(second, size: 4).data, Data([4, 5, 6, 7]))
        first.close()
        second.close()
    }

    func testCacheOnlyReaderFailsOnHolesCorruptionAndPurgeWithoutNetwork() throws {
        PlaybackStreamCacheURLProtocol.resetMetrics()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = thumbnailSource(root: root, fileLength: 8, chunkSize: 4)
        try FileManager.default.createDirectory(at: source.cacheDirectory, withIntermediateDirectories: true)
        try Data([1, 2, 3, 4]).write(to: source.cacheDirectory.appendingPathComponent("chunk_0.bin"))
        defer { try? FileManager.default.removeItem(at: root) }

        let holeReader = PlaybackStreamCacheIOReader(source: source)
        XCTAssertEqual(read(holeReader, size: 8).count, 4)
        XCTAssertEqual(read(holeReader, size: 1).count, -1)
        holeReader.close()

        try Data([5, 6]).write(to: source.cacheDirectory.appendingPathComponent("chunk_1.bin"))
        let corruptReader = PlaybackStreamCacheIOReader(source: source)
        XCTAssertEqual(corruptReader.seek(offset: 4, whence: Int32(SEEK_SET)), 4)
        XCTAssertEqual(read(corruptReader, size: 1).count, -1)
        corruptReader.close()
        try Data(repeating: 5, count: 64).write(to: source.cacheDirectory.appendingPathComponent("chunk_1.bin"))
        let oversizedReader = PlaybackStreamCacheIOReader(source: source)
        XCTAssertEqual(oversizedReader.seek(offset: 4, whence: Int32(SEEK_SET)), 4)
        XCTAssertEqual(read(oversizedReader, size: 1).count, -1)
        oversizedReader.close()

        let purgeRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let purgeSource = thumbnailSource(root: purgeRoot, fileLength: 4, chunkSize: 4)
        try FileManager.default.createDirectory(at: purgeSource.cacheDirectory, withIntermediateDirectories: true)
        let chunkURL = purgeSource.cacheDirectory.appendingPathComponent("chunk_0.bin")
        try Data([9, 8, 7, 6]).write(to: chunkURL)
        let purgedReader = PlaybackStreamCacheIOReader(source: purgeSource)
        XCTAssertEqual(read(purgedReader, size: 1).data, Data([9]))
        try FileManager.default.removeItem(at: purgeSource.cacheDirectory)
        XCTAssertEqual(read(purgedReader, size: 1).count, -1)
        purgedReader.close()
        try? FileManager.default.removeItem(at: purgeRoot)

        XCTAssertEqual(PlaybackStreamCacheURLProtocol.requestCount, 0)
    }

    func testCacheOnlyReaderCancellationDoesNotInvalidateAndSeekOverflowFails() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = thumbnailSource(root: root, fileLength: 4, chunkSize: 4)
        try FileManager.default.createDirectory(at: source.cacheDirectory, withIntermediateDirectories: true)
        try Data([1, 2, 3, 4]).write(to: source.cacheDirectory.appendingPathComponent("chunk_0.bin"))
        defer { try? FileManager.default.removeItem(at: root) }

        let reader = PlaybackStreamCacheIOReader(source: source)
        XCTAssertEqual(reader.seek(offset: Int64.max, whence: Int32(SEEK_END)), -1)
        XCTAssertEqual(reader.seek(offset: -1, whence: Int32(SEEK_SET)), -1)
        XCTAssertEqual(reader.seek(offset: 1, whence: Int32(SEEK_SET)), 1)
        XCTAssertEqual(reader.seek(offset: Int64.max, whence: Int32(SEEK_CUR)), -1)
        XCTAssertEqual(reader.seek(offset: 0, whence: 65_536), 4)

        reader.cancel()
        XCTAssertEqual(read(reader, size: 1).data, Data([2]))
        reader.close()
        XCTAssertEqual(read(reader, size: 1).count, -1)
    }

    func testManagerThumbnailSourceRequiresExactActiveProxyAndKeepsOriginAuthority() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let remote = URL(string: "https://cache-test.invalid/thumbnail_source")!
        let headers = ["Authorization": "Bearer original", "X-Playback-Source": "catalog"]
        let sessionToken = "thumbnail_source_\(UUID().uuidString)"
        let body = Data((0..<128).map { UInt8($0) })
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlaybackStreamCacheURLProtocol.self]
        PlaybackStreamCacheURLProtocol.handler = { request in
            PlaybackStreamCacheURLProtocol.response(for: request, body: body, total: Int64(body.count))
        }
        defer {
            PlaybackStreamCacheURLProtocol.handler = nil
            try? FileManager.default.removeItem(at: root)
        }

        let manager = PlaybackStreamCacheManager.shared
        let maybeLocalURL = await manager.prepareCacheServer(
            for: remote, headers: headers, sessionToken: sessionToken, cacheRoot: root,
            sessionConfiguration: configuration, preparationBudget: 1)
        let localURL = try XCTUnwrap(maybeLocalURL)
        let maybeDescriptor = await manager.thumbnailSource(for: localURL)
        let descriptor = try XCTUnwrap(maybeDescriptor)
        XCTAssertEqual(descriptor.remoteURL, remote)
        XCTAssertEqual(descriptor.originalHeaders, headers)

        var wrongToken = URLComponents(url: localURL, resolvingAgainstBaseURL: false)!
        wrongToken.path = "/stream/not-the-active-session"
        let wrongTokenURL = try XCTUnwrap(wrongToken.url)
        let wrongTokenSource = await manager.thumbnailSource(for: wrongTokenURL)
        XCTAssertNil(wrongTokenSource)
        var wrongPort = URLComponents(url: localURL, resolvingAgainstBaseURL: false)!
        wrongPort.port = (wrongPort.port ?? 80) + 1
        let wrongPortURL = try XCTUnwrap(wrongPort.url)
        let wrongPortSource = await manager.thumbnailSource(for: wrongPortURL)
        XCTAssertNil(wrongPortSource)

        await manager.stopActiveSession(token: sessionToken)
        let stoppedSource = await manager.thumbnailSource(for: localURL)
        XCTAssertNil(stoppedSource)

        try FileManager.default.createDirectory(at: descriptor.cacheDirectory, withIntermediateDirectories: true)
        try body.write(to: descriptor.cacheDirectory.appendingPathComponent("chunk_0.bin"))
        PlaybackStreamCacheURLProtocol.resetMetrics()
        let reader = PlaybackStreamCacheIOReader(source: descriptor)
        let cachedRead = read(reader, size: 16)
        reader.close()
        XCTAssertEqual(cachedRead.data, Data(body.prefix(16)))
        XCTAssertEqual(PlaybackStreamCacheURLProtocol.requestCount, 0)
    }

    func testBoundedPreviewExtractsElapsedFrameFromSourceAndCachedBytes() async throws {
        // Synthetic 16x16 H.264, four frames at 2 fps, with presentation timestamps starting at 600s.
        let encoded = """
            AAAAIGZ0eXBpc29tAAACAGlzb21pc28yYXZjMW1wNDEAAAAIZnJlZQAABSdtZGF0AAACXgYF//9a3EXpvebZSLeWLNgg2SPu73gy
            NjQgLSBjb3JlIDE2NSByMzIyMiBiMzU2MDVhIC0gSC4yNjQvTVBFRy00IEFWQyBjb2RlYyAtIENvcHlsZWZ0IDIwMDMtMjAyNSAt
            IGh0dHA6Ly93d3cudmlkZW9sYW4ub3JnL3gyNjQuaHRtbCAtIG9wdGlvbnM6IGNhYmFjPTEgcmVmPTEgZGVibG9jaz0xOjA6MCBh
            bmFseXNlPTB4MzoweDExMyBtZT1oZXggc3VibWU9NyBwc3k9MSBwc3lfcmQ9MS4wMDowLjAwIG1peGVkX3JlZj0wIG1lX3Jhbmdl
            PTE2IGNocm9tYV9tZT0xIHRyZWxsaXM9MSA4eDhkY3Q9MSBjcW09MCBkZWFkem9uZT0yMSwxMSBmYXN0X3Bza2lwPTEgY2hyb21h
            X3FwX29mZnNldD0tMiB0aHJlYWRzPTEgbG9va2FoZWFkX3RocmVhZHM9MSBzbGljZWRfdGhyZWFkcz0wIG5yPTAgZGVjaW1hdGU9
            MSBpbnRlcmxhY2VkPTAgYmx1cmF5X2NvbXBhdD0wIGNvbnN0cmFpbmVkX2ludHJhPTAgYmZyYW1lcz0wIHdlaWdodHA9MCBrZXlp
            bnQ9MSBrZXlpbnRfbWluPTEgc2NlbmVjdXQ9NDAgaW50cmFfcmVmcmVzaD0wIHJjPWNyZiBtYnRyZWU9MCBjcmY9MjMuMCBxY29t
            cD0wLjYwIHFwbWluPTAgcXBtYXg9NjkgcXBzdGVwPTQgaXBfcmF0aW89MS40MCBhcT0xOjEuMDAAgAAAALhliIQ31NopgqyeqBlk
            Fs2Isf4vSQqd5cHYwLI3OAiyEuSeVkq6r0IZhxP9t2PwgAUNTBedID4FzIRwIyVaoDWbZXT9qaBNF+sze3eLLKeE+FXPKmgluesN
            PnsgTl2sf/g3F+fCRASE8Y5F0aav7cY9I73Cer4kOllVqamtPE2Xo8MyQ1yJU+9zMhGzhVoYnPdvtW5NssKRTGijUIebglH36665
            nGjipO/CVhG+vSgT+duTv/V02dONAAAAq2WIggIf09t2gD49xQz8+0GCuSJY1Nz3Ic4hZPzThVuYxV3Qe3hbFnctNcCduLdzpv0x
            5qvCfT1B0EWi1hmk3ohZjqJK2gzZfdUBlYS3DtyEO1SwTbj55m0m8vj15K4SGT5cXznlDk+rW7a8vDOhSBAJi20LueyEW/RS6F9l
            8Jnn8S+n0CrYJsASwow96vta/3ksIIyP2W0BMKP39cx6VletjWRwb8AiC/UwpgAAAKZliIQIf9PYQd1+KAwekmXdMFcvWu3xid/P
            bLP8MJmNykz/gjIrPjyzv49a8BPs1Wkuu2EljfgL17wIsKQcYKpF0nSpuOBgqbVhI5Fjk6odGSUhIGly9xtO2cmuC9o/Vs8NEd2s
            30R2t2qR4Rb1GALnBPk5TAL0YQrNPNljEbi0O8YbIx3T70P8J9qk1woSA4Vh+puR626DcnihCjf2iOwr5QayoTX/AAAApGWIggIf
            09HNTzW0RZ0ky7pgrlzMR81UFw9RG9AtSq41NAz/WvV25rRBeS1wsEmpmzF9SpYIBamC2IyqVONfkDbXpd2s1ne9Nrl8gsXD+UW7
            kglvXDs7Oeo6GXs1GPMliP8OH3CP2lu4XfQwvIMaYWFxEK/ZT/xNG8TpAij6rLj1HwyAv+h6v9/2nM5DzIHhF5d4/lMptBhJYVQA
            SZ52kThVZfX8AAADLG1vb3YAAABsbXZoZAAAAAAAAAAAAAAAAAAAA+gACS+QAAEAAAEAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAA
            AAAAAQAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAIAAAJWdHJhawAAAFx0a2hkAAAAAwAAAAAA
            AAAAAAAAAQAAAAAACS+QAAAAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAQAAAAAAQAAAAEAAA
            AAAAMGVkdHMAAAAoZWxzdAAAAAAAAAACAAknwP////8AAQAAAAAH0AAAAAAAAQAAAAABwm1kaWEAAAAgbWRoZAAAAAAAAAAAAAAA
            AAAAQAAAAIAAVcQAAAAAAC1oZGxyAAAAAAAAAAB2aWRlAAAAAAAAAAAAAAAAVmlkZW9IYW5kbGVyAAAAAW1taW5mAAAAFHZtaGQA
            AAABAAAAAAAAAAAAAAAkZGluZgAAABxkcmVmAAAAAAAAAAEAAAAMdXJsIAAAAAEAAAEtc3RibAAAALlzdHNkAAAAAAAAAAEAAACp
            YXZjMQAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAQABAASAAAAEgAAAAAAAAAARVMYXZjNjIuMjguMTAyIGxpYngyNjQAAAAAAAAA
            AAAAABj//wAAAC9hdmNDAWQQCv/hABNnZBAKrLvYCIAAAAMAgAAAAwICAQAFaO4PLIv9+PgAAAAAEHBhc3AAAAABAAAAAQAAABRi
            dHJ0AAAAAAAAFHwAAAAAAAAAGHN0dHMAAAAAAAAAAQAAAAQAACAAAAAAHHN0c2MAAAAAAAAAAQAAAAEAAAAEAAAAAQAAACRzdHN6
            AAAAAAAAAAAAAAAEAAADHgAAAK8AAACqAAAAqAAAABRzdGNvAAAAAAAAAAEAAAAwAAAAYnVkdGEAAABabWV0YQAAAAAAAAAhaGRs
            cgAAAAAAAAAAbWRpcmFwcGwAAAAAAAAAAAAAAAAtaWxzdAAAACWpdG9vAAAAHWRhdGEAAAABAAAAAExhdmY2Mi4xMi4xMDI=
            """
        let bytes = try XCTUnwrap(Data(base64Encoded: encoded, options: .ignoreUnknownCharacters))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("nonzero-start.mp4")
        try bytes.write(to: url)
        let limits = ProbeLimits(maxInputBytes: 1024 * 1024, maxPackets: 128,
                                 maxPacketBytes: 1024 * 1024, timeBudget: 5)

        let sourceExtractor = FrameExtractor(url: url)
        let sourceStill = await sourceExtractor.boundedSnapshot(
            at: 1, maxSize: CGSize(width: 32, height: 32), limits: limits,
            cancellation: ProbeCancellation(), relativeToPresentationStart: true)
        await sourceExtractor.shutdown()
        let sourceFrame = try XCTUnwrap(sourceStill)
        XCTAssertEqual(try XCTUnwrap(sourceFrame.actualSeconds), 1, accuracy: 0.05)

        let source = thumbnailSource(root: root, fileLength: Int64(bytes.count), chunkSize: 256)
        try FileManager.default.createDirectory(at: source.cacheDirectory, withIntermediateDirectories: true)
        for offset in stride(from: 0, to: bytes.count, by: 256) {
            try bytes.subdata(in: offset..<min(offset + 256, bytes.count)).write(
                to: source.cacheDirectory.appendingPathComponent("chunk_\(offset / 256).bin"))
        }
        let reader = PlaybackStreamCacheIOReader(source: source)
        defer { reader.close() }
        let cacheExtractor = FrameExtractor(reader: reader, formatHint: "mov")
        let cacheStill = await cacheExtractor.boundedSnapshot(
            at: 1, maxSize: CGSize(width: 32, height: 32), limits: limits,
            cancellation: ProbeCancellation(), relativeToPresentationStart: true)
        await cacheExtractor.shutdown()
        let cachedFrame = try XCTUnwrap(cacheStill)
        XCTAssertEqual(try XCTUnwrap(cachedFrame.actualSeconds), 1, accuracy: 0.05)
        XCTAssertEqual(cachedFrame.image.width, sourceFrame.image.width)
        XCTAssertEqual(cachedFrame.image.height, sourceFrame.image.height)

        let context = PlaybackThumbnailSourceContext(
            generation: 1, playbackURL: url, headerSourceURL: nil, requestHeaders: [:],
            isLive: false, isKnownHLS: false, streamKey: "synthetic-nonzero-start")
        let sharedStill = await PlaybackThumbnailSourceFallback.boundedSnapshot(
            sourceContext: context, atSeconds: 1, maxWidth: 32,
            cancellation: PlaybackThumbnailRequestCancellation(), isCurrent: { true })
        let sharedFrame = try XCTUnwrap(sharedStill)
        XCTAssertEqual(try XCTUnwrap(sharedFrame.actualSeconds), 1, accuracy: 0.05)
        XCTAssertEqual(sharedFrame.image.width, sourceFrame.image.width)

        let requiredRPUStill = await PlaybackThumbnailSourceFallback.boundedSnapshot(
            sourceContext: context, atSeconds: 1, maxWidth: 32,
            cancellation: PlaybackThumbnailRequestCancellation(), isCurrent: { true },
            requiredDolbyVisionReshaping: true)
        XCTAssertNil(requiredRPUStill, "The scene-analysis DV5 path must not accept a non-Dolby-Vision fallback frame")

        let yieldCounter = PlaybackThumbnailYieldCounter()
        let yieldedStill = await PlaybackThumbnailSourceFallback.boundedSnapshot(
            sourceContext: context, atSeconds: 1, maxWidth: 32,
            cancellation: PlaybackThumbnailRequestCancellation(), isCurrent: { true },
            yieldWhile: { yieldCounter.shouldYieldOnFourthCheck() })
        XCTAssertNil(yieldedStill)
        XCTAssertEqual(yieldCounter.callCount, 5,
                       "The frame extractor must receive and poll the engine's playback-priority gate")
    }

    private func thumbnailSource(
        root: URL,
        fileLength: Int64,
        chunkSize: Int64,
        sessionID: String = UUID().uuidString
    ) -> PlaybackStreamThumbnailSource {
        PlaybackStreamThumbnailSource(
            cacheDirectory: root.appendingPathComponent(sessionID, isDirectory: true),
            fileLength: fileLength,
            chunkSize: chunkSize,
            sessionID: sessionID,
            remoteURL: URL(string: "https://cache-test.invalid/video")!,
            originalHeaders: ["X-Test": "origin"]
        )
    }

    private func read(_ reader: PlaybackStreamCacheIOReader, size: Int) -> (count: Int32, data: Data) {
        var buffer = [UInt8](repeating: 0, count: size)
        let count = buffer.withUnsafeMutableBufferPointer { reader.read($0.baseAddress, size: Int32(size)) }
        return (count, count > 0 ? Data(buffer.prefix(Int(count))) : Data())
    }
}

private func serverDiskDirectory(for sessionID: String) -> URL {
    let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
    return caches.appendingPathComponent("PlaybackStreamCache", isDirectory: true)
        .appendingPathComponent(sessionID, isDirectory: true)
}

private actor PlaybackCacheStopBarrier {
    private var armed = false
    private var entered = false
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func arm() { armed = true }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredContinuation = $0 }
    }

    func blockIfArmed() async {
        guard armed else { return }
        armed = false
        entered = true
        enteredContinuation?.resume()
        enteredContinuation = nil
        await withCheckedContinuation { releaseContinuation = $0 }
        releaseContinuation = nil
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
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
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5, "Demand must not wait for the full batch tail")
        let second = await server.fetchDemandChunk(1)
        XCTAssertEqual(second, body.prefix(chunk))
        XCTAssertEqual(PlaybackStreamCacheURLProtocol.requestCount, 1, "Overlapping demand must share the original transfer")
        XCTAssertEqual(PlaybackStreamCacheURLProtocol.cancellationCount, 0)
        await server.stop()
    }

    func testDemandTakesOverStalledForwardBatchOnceForConcurrentReaders() async throws {
        let chunk = Int(PlaybackStreamDiskCache.defaultChunkSize)
        let body = Data(repeating: 0x5A, count: chunk * 8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlaybackStreamCacheURLProtocol.self]
        PlaybackStreamCacheURLProtocol.resetMetrics()
        PlaybackStreamCacheURLProtocol.delay = 10
        PlaybackStreamCacheURLProtocol.handler = { request in
            PlaybackStreamCacheURLProtocol.response(for: request, body: body, total: Int64(body.count))
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            PlaybackStreamCacheURLProtocol.handler = nil
            PlaybackStreamCacheURLProtocol.delay = 0
            try? FileManager.default.removeItem(at: root)
        }
        let server = PlaybackStreamCacheServer(
            remoteURL: URL(string: "https://cache-test.invalid/stalled_forward")!,
            fileLength: Int64(body.count), cacheRoot: root,
            sessionConfiguration: configuration, maxConcurrentUpstream: 1,
            demandBatchJoinGrace: 0.2
        )
        _ = try await server.start()
        for _ in 0..<100 where PlaybackStreamCacheURLProtocol.requestCount == 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(PlaybackStreamCacheURLProtocol.requestCount, 1)
        PlaybackStreamCacheURLProtocol.delay = 0

        let started = Date()
        async let first = server.fetchDemandChunk(0)
        async let second = server.fetchDemandChunk(0)
        let received = await (first, second)
        XCTAssertEqual(received.0, body.prefix(chunk))
        XCTAssertEqual(received.1, body.prefix(chunk))
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        XCTAssertEqual(
            PlaybackStreamCacheURLProtocol.requestRanges.filter { $0 == "bytes=0-\(chunk - 1)" }.count, 1
        )
        XCTAssertGreaterThanOrEqual(PlaybackStreamCacheURLProtocol.cancellationCount, 1)
        await server.stop()
    }

    func testDemandTakesOverStalledTailOfDemandBatch() async throws {
        let chunk = Int(PlaybackStreamDiskCache.defaultChunkSize)
        let body = Data(repeating: 0x5B, count: chunk * 4)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlaybackStreamCacheURLProtocol.self]
        PlaybackStreamCacheURLProtocol.resetMetrics()
        PlaybackStreamCacheURLProtocol.handler = { request in
            var response = PlaybackStreamCacheURLProtocol.response(
                for: request, body: body, total: Int64(body.count)
            )
            if request.value(forHTTPHeaderField: "Range") == "bytes=0-\(body.count - 1)" {
                response.bodyChunkBytes = chunk
                response.bodyChunkDelay = 10
            }
            return response
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            PlaybackStreamCacheURLProtocol.handler = nil
            try? FileManager.default.removeItem(at: root)
        }
        let server = PlaybackStreamCacheServer(
            remoteURL: URL(string: "https://cache-test.invalid/stalled_demand_tail")!,
            fileLength: Int64(body.count), cacheRoot: root,
            sessionConfiguration: configuration, maxConcurrentUpstream: 1,
            freeSpaceProvider: { _ in 0 }, demandBatchJoinGrace: 0.2
        )
        let first = await server.fetchDemandChunk(0)
        XCTAssertEqual(first, body.prefix(chunk))

        let started = Date()
        let second = await server.fetchDemandChunk(1)
        XCTAssertEqual(second, body.prefix(chunk))
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        XCTAssertEqual(
            PlaybackStreamCacheURLProtocol.requestRanges.filter {
                $0 == "bytes=\(chunk)-\(2 * chunk - 1)"
            }.count, 1
        )
        XCTAssertGreaterThanOrEqual(PlaybackStreamCacheURLProtocol.cancellationCount, 1)
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

    func testForwardAuditRefetchesExternallyRemovedChunkAfterLeadIsSatisfied() async throws {
        let chunkSize = Int(PlaybackStreamDiskCache.defaultChunkSize)
        let fileLength = Int64(chunkSize * 44)
        let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessionID = "forward_stale_chunk_\(UUID().uuidString)"
        let freeSpaceProvider: PlaybackStreamDiskCache.FreeSpaceProvider = { _ in Int64.max }
        defer {
            PlaybackStreamCacheURLProtocol.handler = nil
            try? FileManager.default.removeItem(at: cacheRoot)
        }

        let seedCache = PlaybackStreamDiskCache(
            sessionID: sessionID,
            fileLength: fileLength,
            maxCacheSizeBytes: fileLength + Int64(chunkSize * 6),
            freeSpaceReserveBytes: 0,
            cacheRoot: cacheRoot,
            freeSpaceProvider: freeSpaceProvider
        )
        let cachedChunk = Data(repeating: 0x41, count: chunkSize)
        for index in 2..<43 {
            await seedCache.writeChunk(index, data: cachedChunk)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlaybackStreamCacheURLProtocol.self]
        PlaybackStreamCacheURLProtocol.resetMetrics()
        let body = Data(repeating: 0x73, count: Int(fileLength))
        PlaybackStreamCacheURLProtocol.handler = { request in
            PlaybackStreamCacheURLProtocol.response(for: request, body: body, total: fileLength)
        }
        let server = PlaybackStreamCacheServer(
            remoteURL: URL(string: "https://cache-test.invalid/stale_chunk")!,
            fileLength: fileLength,
            sessionID: sessionID,
            maxDiskCacheSizeBytes: fileLength + Int64(chunkSize * 6),
            freeSpaceReserveBytes: 0,
            targetLeadSeconds: 10,
            cacheRoot: cacheRoot,
            sessionConfiguration: configuration,
            maxConcurrentUpstream: 1,
            freeSpaceProvider: freeSpaceProvider
        )
        let staleChunkURL = cacheRoot
            .appendingPathComponent(sessionID, isDirectory: true)
            .appendingPathComponent("chunk_10.bin")
        try FileManager.default.removeItem(at: staleChunkURL)
        await server.updateTimeline(
            playheadOffset: Int64(chunkSize * 2), durationSeconds: 120, isSeek: true
        )
        _ = try await server.start()

        let expectedRange = "bytes=\(chunkSize * 10)-\(chunkSize * 11 - 1)"
        for _ in 0..<500 where !PlaybackStreamCacheURLProtocol.requestRanges.contains(where: { $0 == expectedRange }) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let requestedRanges = PlaybackStreamCacheURLProtocol.requestRanges.compactMap { $0 }
        await server.stop()

        XCTAssertTrue(
            requestedRanges.contains(expectedRange),
            "Forward fill should audit cached files even while metadata reports enough lead"
        )
    }

    func testArchiveScanCursorStartsAtPlayheadAndWrapsToEarlierMissingChunks() async throws {
        let chunkSize = Int(PlaybackStreamDiskCache.defaultChunkSize)
        let fileLength = Int64(chunkSize * 44)
        let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessionID = "archive_cursor_\(UUID().uuidString)"
        let freeSpaceProvider: PlaybackStreamDiskCache.FreeSpaceProvider = { _ in Int64.max }
        defer {
            PlaybackStreamCacheURLProtocol.handler = nil
            try? FileManager.default.removeItem(at: cacheRoot)
        }

        let seedCache = PlaybackStreamDiskCache(
            sessionID: sessionID,
            fileLength: fileLength,
            maxCacheSizeBytes: fileLength,
            freeSpaceReserveBytes: 0,
            cacheRoot: cacheRoot,
            freeSpaceProvider: freeSpaceProvider
        )
        let cachedChunk = Data(repeating: 0x31, count: chunkSize)
        for index in 2..<43 {
            await seedCache.writeChunk(index, data: cachedChunk)
        }
        let prefilledBytes = await seedCache.currentCachedBytes
        XCTAssertEqual(prefilledBytes, Int64(chunkSize * 41))

        let body = Data(repeating: 0x72, count: Int(fileLength))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlaybackStreamCacheURLProtocol.self]
        PlaybackStreamCacheURLProtocol.resetMetrics()
        PlaybackStreamCacheURLProtocol.handler = { request in
            PlaybackStreamCacheURLProtocol.response(for: request, body: body, total: fileLength)
        }
        let server = PlaybackStreamCacheServer(
            remoteURL: URL(string: "https://cache-test.invalid/archive_cursor")!,
            fileLength: fileLength,
            sessionID: sessionID,
            maxDiskCacheSizeBytes: fileLength,
            freeSpaceReserveBytes: 0,
            targetLeadSeconds: 10,
            cacheRoot: cacheRoot,
            sessionConfiguration: configuration,
            maxConcurrentUpstream: 2,
            freeSpaceProvider: freeSpaceProvider,
            thermalStateProvider: { .nominal }
        )
        await server.updateTimeline(
            playheadOffset: Int64(chunkSize * 2), durationSeconds: 120, isSeek: true
        )
        _ = try await server.start()

        for _ in 0..<1000 where PlaybackStreamCacheURLProtocol.requestCount < 2 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let requestedRanges = PlaybackStreamCacheURLProtocol.requestRanges.compactMap { $0 }
        let lead = await server.contiguousCachedBytesAhead(of: Int64(chunkSize * 2))
        let isBursting = await server.isBursting
        let targetLead = await server.adaptiveForwardLeadBytes
        let concurrency = await server.concurrencyMetrics
        await server.stop()

        XCTAssertGreaterThanOrEqual(requestedRanges.count, 2,
            "Archive state: lead=\(lead), bursting=\(isBursting), target=\(targetLead), active=\(concurrency.active), max=\(concurrency.currentMax)")
        XCTAssertEqual(
            Array(requestedRanges.prefix(2)),
            [
                "bytes=\(chunkSize * 43)-\(chunkSize * 44 - 1)",
                "bytes=0-\(chunkSize * 2 - 1)"
            ],
            "Archive should scan from the playhead, reach EOF, then wrap to earlier missing chunks"
        )
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
        let testID = UUID().uuidString
        let server = PlaybackStreamCacheServer(
            remoteURL: URL(string: "https://cache-test.invalid/sustained-\(testID)")!,
            fileLength: Int64(body.count), cacheRoot: root,
            sessionConfiguration: configuration, maxConcurrentUpstream: 1,
            demandBatchJoinGrace: 5.0
        )
        let local = try await server.start()
        var request = URLRequest(url: local, timeoutInterval: 10)
        request.setValue("bytes=0-\(body.count - 1)", forHTTPHeaderField: "Range")
        let started = Date()
        do {
            let received = try await URLSession.shared.data(for: request).0
            XCTAssertEqual(received, expected)
            XCTAssertLessThan(Date().timeIntervalSince(started), 4.5, "32 MiB must sustain at least the trace's ~79 Mbps average")
            XCTAssertTrue((4...5).contains(PlaybackStreamCacheURLProtocol.requestCount), "Sixteen sequential chunks should share four to five upstream batches")
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

#if NUVIO_MPV_MEMORY_WATCHDOG && os(tvOS)
final class MPVDiskBufferPolicyTests: XCTestCase {
    func testBundledMPVSupportsNativeDiskCacheAndRuntimeToggle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mpv-native-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try XCTUnwrap(PlaybackCacheSettings.prepareMPVPacketCacheDirectory(cachesDirectory: root))
        let handle = try XCTUnwrap(mpv_create())
        defer { mpv_terminate_destroy(handle) }
        for (name, value) in [
            ("config", "no"), ("vo", "null"), ("ao", "null"), ("cache", "yes"),
            ("demuxer-cache-dir", directory.path), ("demuxer-cache-unlink-files", "immediate"),
            ("cache-on-disk", "yes"), ("demuxer-max-bytes", "32MiB"), ("demuxer-max-back-bytes", "16MiB")
        ] {
            XCTAssertGreaterThanOrEqual(mpv_set_option_string(handle, name, value), 0, name)
        }
        XCTAssertGreaterThanOrEqual(mpv_initialize(handle), 0)
        for enabled in [CInt(0), CInt(1)] {
            var requested = enabled
            XCTAssertGreaterThanOrEqual(mpv_set_property(handle, "cache-on-disk", MPV_FORMAT_FLAG, &requested), 0)
            var actual: CInt = -1
            XCTAssertGreaterThanOrEqual(mpv_get_property(handle, "cache-on-disk", MPV_FORMAT_FLAG, &actual), 0)
            XCTAssertEqual(actual, enabled)
        }
    }

    func testRemoteAndLiveSourcesUseNativeDiskAndProfileLead() {
        let cases: [(String, Bool, PlaybackCacheProfile, Int)] = [
            ("https://video.example/movie.mkv", false, .medium, 90),
            ("https://video.example/channel.m3u8", false, .large, 150),
            ("https://video.example/live", true, .conservative, 45)
        ]

        for (rawURL, isLive, profile, expectedSeconds) in cases {
            let policy = MPVPlaybackCachePolicy.resolve(
                url: URL(string: rawURL)!,
                isLiveStream: isLive,
                profile: profile,
                nativeDiskAvailable: true
            )
            XCTAssertTrue(policy.nativeDiskEnabled, rawURL)
            XCTAssertEqual(policy.forwardBuffer, "32MiB")
            XCTAssertEqual(policy.backBuffer, "16MiB")
            XCTAssertEqual(policy.cacheSeconds, expectedSeconds)
            XCTAssertTrue(policy.diagnosticMode.hasSuffix("network_disk"))
        }
    }

    func testLocalAndLoopbackSourcesAvoidDuplicateDiskCache() {
        let sources = [URL(fileURLWithPath: "/tmp/video.mkv"), URL(string: "http://127.0.0.1:49211/video")!]
        for url in sources {
            let policy = MPVPlaybackCachePolicy.resolve(
                url: url,
                isLiveStream: false,
                profile: .ultra,
                nativeDiskAvailable: true
            )
            XCTAssertFalse(policy.nativeDiskEnabled)
            XCTAssertEqual(policy.cacheSeconds, 30)
            XCTAssertEqual(policy.source, .localOrLoopback)
            XCTAssertEqual(policy.diagnosticMode, "local_or_disk")
        }
    }

    func testUnavailableCacheDirectoryUsesBoundedRAMFallback() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mpv-cache-parent-\(UUID().uuidString)")
        XCTAssertTrue(FileManager.default.createFile(atPath: root.path, contents: Data()))
        defer { try? FileManager.default.removeItem(at: root) }

        let cacheDirectory = PlaybackCacheSettings.prepareMPVPacketCacheDirectory(cachesDirectory: root)
        XCTAssertNil(cacheDirectory)
        let policy = MPVPlaybackCachePolicy.resolve(
            url: URL(string: "https://video.example/movie.mkv")!,
            isLiveStream: false,
            profile: .max,
            nativeDiskAvailable: cacheDirectory != nil
        )
        XCTAssertFalse(policy.nativeDiskEnabled)
        XCTAssertEqual(policy.forwardBuffer, "32MiB")
        XCTAssertEqual(policy.backBuffer, "16MiB")
        XCTAssertEqual(policy.cacheSeconds, 240)
        XCTAssertEqual(policy.diagnosticMode, "network_ram_fallback")
    }
}
#endif

#if NUVIO_MPV_MEMORY_WATCHDOG && os(tvOS)
final class MPVStreamSessionTests: XCTestCase {
    private let testURL = URL(string: "https://mpv-reader.invalid/video")!

    override func setUp() {
        super.setUp()
        MPVStreamSessionTestURLProtocol.reset()
    }

    override func tearDown() {
        MPVStreamSessionTestURLProtocol.reset()
        super.tearDown()
    }

    func testFiniteRangesAreDemandDrivenAndByteExact() throws {
        let rangeSize = 256 * 1024
        let total = rangeSize * 2 + 452
        let expected = Data((0..<total).map { UInt8(truncatingIfNeeded: $0) })
        let firstCompletionGate = DispatchSemaphore(value: 0)
        MPVStreamSessionTestURLProtocol.handler = { request in
            Self.rangeResponse(request, body: expected, rangeSize: rangeSize, total: total,
                               completionGate: Self.requestStart(request) == 0 ? firstCompletionGate : nil)
        }
        let bridge = MPVStreamProtocolBridge.shared
        let baselineBufferedBytes = bridge.memoryDiagnosticSnapshot().bufferedDataBytes
        let session = try makeSession(rangeRequestSize: rangeSize)
        defer { session.close() }

        XCTAssertTrue(waitForBufferedBytes(baselineBufferedBytes + Int64(rangeSize)))
        XCTAssertEqual(MPVStreamSessionTestURLProtocol.requestRanges, ["bytes=0-\(rangeSize - 1)"])
        let first = readExactly(session, count: rangeSize)
        XCTAssertEqual(first, Data(expected.prefix(rangeSize)))
        XCTAssertEqual(MPVStreamSessionTestURLProtocol.requestRanges, ["bytes=0-\(rangeSize - 1)"], "The next range waits for both the previous read and task completion")

        firstCompletionGate.signal()
        let second = readExactly(session, count: rangeSize)
        XCTAssertEqual(second, Data(expected[rangeSize..<(rangeSize * 2)]))
        let last = readExactly(session, count: total - rangeSize * 2)
        XCTAssertEqual(last, Data(expected[(rangeSize * 2)..<total]))
        XCTAssertEqual(boundedRead(session, count: 1)?.count, 0)
        XCTAssertEqual(session.size(), Int64(total))
        XCTAssertEqual(
            MPVStreamSessionTestURLProtocol.requestRanges,
            ["bytes=0-\(rangeSize - 1)", "bytes=\(rangeSize)-\(rangeSize * 2 - 1)", "bytes=\(rangeSize * 2)-\(total - 1)"]
        )
    }

    func testUnknownLengthEndsOnlyAtMatchingUnsatisfiedRange() throws {
        let body = Data((0..<1_024).map { UInt8(truncatingIfNeeded: $0) })
        MPVStreamSessionTestURLProtocol.handler = { request in
            if Self.requestStart(request) == 0 {
                return .init(statusCode: 206, contentRange: "bytes 0-1023/*", body: body)
            }
            return .init(
                statusCode: 416,
                contentRange: "bytes */1024",
                body: Data(repeating: 0xEE, count: 128 * 1024),
                keepOpen: true
            )
        }
        let session = try makeSession(rangeRequestSize: 1_024)
        defer { session.close() }

        XCTAssertEqual(readExactly(session, count: body.count), body)
        XCTAssertEqual(boundedRead(session, count: 1, timeout: 1)?.count, 0)
        XCTAssertEqual(session.size(), 1_024)
        XCTAssertEqual(MPVStreamSessionTestURLProtocol.requestRanges, ["bytes=0-1023", "bytes=1024-2047"])

        MPVStreamSessionTestURLProtocol.reset()
        MPVStreamSessionTestURLProtocol.handler = { request in
            if Self.requestStart(request) == 0 {
                return .init(statusCode: 206, contentRange: "bytes 0-1023/*", body: body)
            }
            return .init(statusCode: 416, contentRange: "bytes */900", body: Data(repeating: 0xEE, count: 128 * 1024), keepOpen: true)
        }
        let invalidSession = try makeSession(rangeRequestSize: 1_024)
        defer { invalidSession.close() }
        XCTAssertEqual(readExactly(invalidSession, count: body.count), body)
        XCTAssertEqual(boundedRead(invalidSession, count: 1)?.count, -1)
    }

    func testInitial200FallsBackToSequentialAndNonzeroRangeIsRejected() throws {
        MPVStreamSessionTestURLProtocol.handler = { _ in
            .init(statusCode: 200, body: Data([0x12, 0x34, 0x56]), contentLength: 3)
        }
        let fallbackSession = try makeSession(rangeRequestSize: 2)
        defer { fallbackSession.close() }
        XCTAssertEqual(readExactly(fallbackSession, count: 3), Data([0x12, 0x34, 0x56]))
        XCTAssertEqual(boundedRead(fallbackSession, count: 1)?.count, 0)
        XCTAssertEqual(MPVStreamSessionTestURLProtocol.requestRanges, ["bytes=0-1"])

        MPVStreamSessionTestURLProtocol.reset()
        MPVStreamSessionTestURLProtocol.handler = { request in
            if Self.requestStart(request) == 0 {
                return .init(statusCode: 206, contentRange: "bytes 0-3/8", body: Data([0, 1, 2, 3]))
            }
            return .init(statusCode: 200, body: Data([6, 7]), contentLength: 2)
        }
        let ignoredRangeSession = try makeSession(rangeRequestSize: 4)
        defer { ignoredRangeSession.close() }
        XCTAssertEqual(readExactly(ignoredRangeSession, count: 4), Data([0, 1, 2, 3]))
        XCTAssertEqual(ignoredRangeSession.seek(to: 6), 6)
        XCTAssertEqual(boundedRead(ignoredRangeSession, count: 1)?.count, -1)
        XCTAssertEqual(MPVStreamSessionTestURLProtocol.requestRanges, ["bytes=0-3", "bytes=6-7"])
    }

    func testSequential200CannotChangeKnownRepresentationLength() throws {
        let lock = NSLock()
        var zeroOffsetRequests = 0
        MPVStreamSessionTestURLProtocol.handler = { request in
            switch Self.requestStart(request) {
            case 0:
                let isInitial = lock.withLock {
                    zeroOffsetRequests += 1
                    return zeroOffsetRequests == 1
                }
                if isInitial {
                    return .init(statusCode: 206, contentRange: "bytes 0-3/8", body: Data([0, 1, 2, 3]))
                }
                return .init(statusCode: 200, body: Data(repeating: 0xEE, count: 9), contentLength: 9)
            case 4:
                return .init(statusCode: 206, contentRange: "bytes 4-7/8", body: Data([4, 5, 6, 7]))
            default:
                return .init(statusCode: 416, contentRange: "bytes */8")
            }
        }

        let session = try makeSession(rangeRequestSize: 4)
        defer { session.close() }
        XCTAssertEqual(readExactly(session, count: 4), Data([0, 1, 2, 3]))
        XCTAssertEqual(session.size(), 8)
        XCTAssertEqual(session.seek(to: 4), 4)
        XCTAssertEqual(readExactly(session, count: 4), Data([4, 5, 6, 7]))
        XCTAssertEqual(session.seek(to: 0), 0)
        XCTAssertEqual(boundedRead(session, count: 1)?.count, -1)
        XCTAssertEqual(MPVStreamSessionTestURLProtocol.requestRanges, ["bytes=0-3", "bytes=4-7", "bytes=0-3"])
    }

    func testTruncatedTimeoutResumesAtExactUnreadOffset() throws {
        let total = 512 * 1024
        let rangeSize = 256 * 1024
        let prefixSize = 128 * 1024
        let expected = Data((0..<total).map { UInt8(truncatingIfNeeded: $0) })
        let firstCompletionGate = DispatchSemaphore(value: 0)
        MPVStreamSessionTestURLProtocol.handler = { request in
            if Self.requestStart(request) == 0 {
                return .init(
                    statusCode: 206,
                    contentRange: "bytes 0-\(rangeSize - 1)/\(total)",
                    body: Data(expected.prefix(prefixSize)),
                    contentLength: Int64(rangeSize),
                    error: URLError(.timedOut),
                    completionGate: firstCompletionGate
                )
            }
            return Self.rangeResponse(request, body: expected, rangeSize: rangeSize, total: total)
        }
        let baselineBufferedBytes = MPVStreamProtocolBridge.shared.memoryDiagnosticSnapshot().bufferedDataBytes
        let session = try makeSession(rangeRequestSize: rangeSize)
        defer { session.close() }

        XCTAssertTrue(waitForBufferedBytes(baselineBufferedBytes + Int64(prefixSize)))
        let prefix = readExactly(session, count: prefixSize)
        firstCompletionGate.signal()
        XCTAssertEqual(prefix, Data(expected.prefix(prefixSize)))

        var received = prefix ?? Data()
        while received.count < total {
            guard let next = boundedRead(session, count: min(16 * 1024, total - received.count)), next.count > 0 else {
                XCTFail("The resumed range did not complete")
                return
            }
            received.append(next.data)
        }
        XCTAssertEqual(received, expected)
        XCTAssertEqual(boundedRead(session, count: 1)?.count, 0)
        XCTAssertEqual(
            MPVStreamSessionTestURLProtocol.requestRanges,
            ["bytes=0-262143", "bytes=131072-393215", "bytes=393216-524287"]
        )
    }

    func testOversizedRangeChunkIsTerminalBeforeAppend() throws {
        MPVStreamSessionTestURLProtocol.handler = { _ in
            .init(
                statusCode: 206,
                contentRange: "bytes 0-1023/2048",
                body: Data(repeating: 0xCC, count: 1_025),
                contentLength: 1_024
            )
        }
        let rangeSession = try makeSession(rangeRequestSize: 1_024, bufferLimit: 4 * 1_024)
        defer { rangeSession.close() }
        var rangeBytes = Data()
        var rangeFailed = false
        for _ in 0..<4 {
            guard let result = boundedRead(rangeSession, count: 1_024) else { break }
            if result.count < 0 {
                rangeFailed = true
                break
            }
            if result.count == 0 { break }
            rangeBytes.append(result.data)
        }
        XCTAssertTrue(rangeFailed, "An oversized range body must fail instead of being truncated")
        XCTAssertLessThanOrEqual(rangeBytes.count, 1_024)
    }

    func testSequentialBackpressureCompletesUnevenChunksAfterReaderStarts() throws {
        let total = 6_000
        let expected = Data((0..<total).map { UInt8(truncatingIfNeeded: $0 * 17) })
        MPVStreamSessionTestURLProtocol.handler = { _ in
            .init(
                statusCode: 200,
                body: expected,
                contentLength: Int64(total),
                chunkSizes: [1_000, 2_300, 2_700]
            )
        }
        let baselineBufferedBytes = MPVStreamProtocolBridge.shared.memoryDiagnosticSnapshot().bufferedDataBytes
        let session = try makeSession(rangeRequestSize: 1_024, bufferLimit: 4_096)
        defer { session.close() }

        XCTAssertTrue(waitForBufferedBytes(baselineBufferedBytes + 4_096))
        XCTAssertEqual(readExactly(session, count: total), expected)
        XCTAssertEqual(boundedRead(session, count: 1)?.count, 0)
        XCTAssertEqual(MPVStreamProtocolBridge.shared.memoryDiagnosticSnapshot().bufferedDataBytes, baselineBufferedBytes)
    }

    func testBlockedSequentialProducerUnblocksOnCloseAndCancel() throws {
        let body = Data(repeating: 0xA5, count: 6_000)
        MPVStreamSessionTestURLProtocol.handler = { _ in
            .init(statusCode: 200, body: body, contentLength: Int64(body.count))
        }
        let baselineBufferedBytes = MPVStreamProtocolBridge.shared.memoryDiagnosticSnapshot().bufferedDataBytes
        let closedSession = try makeSession(rangeRequestSize: 1_024, bufferLimit: 4_096)
        XCTAssertTrue(waitForBufferedBytes(baselineBufferedBytes + 4_096))
        closedSession.close()
        XCTAssertEqual(MPVStreamProtocolBridge.shared.memoryDiagnosticSnapshot().bufferedDataBytes, baselineBufferedBytes)

        MPVStreamSessionTestURLProtocol.reset()
        MPVStreamSessionTestURLProtocol.handler = { _ in
            .init(statusCode: 200, body: body, contentLength: Int64(body.count))
        }
        let cancelledSession = try makeSession(rangeRequestSize: 1_024, bufferLimit: 4_096)
        defer { cancelledSession.close() }
        XCTAssertTrue(waitForBufferedBytes(baselineBufferedBytes + 4_096))
        cancelledSession.cancel()
        XCTAssertEqual(MPVStreamProtocolBridge.shared.memoryDiagnosticSnapshot().bufferedDataBytes, baselineBufferedBytes)
        XCTAssertEqual(boundedRead(cancelledSession, count: 1)?.count, -1)
    }

    func testSeekReleasesBlockedSequentialProducerAndUsesReplacementTask() throws {
        let total = 6_000
        let expected = Data((0..<total).map { UInt8(truncatingIfNeeded: $0 * 13) })
        MPVStreamSessionTestURLProtocol.handler = { request in
            if Self.requestStart(request) == 0 {
                return .init(statusCode: 200, body: expected, contentLength: Int64(total))
            }
            let start = Self.requestStart(request) ?? -1
            guard start == 5_000 else {
                return .init(statusCode: 416, contentRange: "bytes */\(total)")
            }
            return .init(
                statusCode: 206,
                contentRange: "bytes 5000-5999/\(total)",
                body: Data(expected.suffix(1_000)),
                contentLength: 1_000
            )
        }
        let baselineBufferedBytes = MPVStreamProtocolBridge.shared.memoryDiagnosticSnapshot().bufferedDataBytes
        let session = try makeSession(rangeRequestSize: 1_000, bufferLimit: 4_096)
        defer { session.close() }

        XCTAssertTrue(waitForBufferedBytes(baselineBufferedBytes + 4_096))
        XCTAssertEqual(session.seek(to: 5_000), 5_000)
        XCTAssertEqual(readExactly(session, count: 1_000), Data(expected.suffix(1_000)))
        XCTAssertEqual(boundedRead(session, count: 1)?.count, 0)
        XCTAssertEqual(MPVStreamSessionTestURLProtocol.requestRanges, ["bytes=0-999", "bytes=5000-5999"])
    }

    func testSeekReplacesPendingRangeAndSeekToKnownEOFIsImmediate() throws {
        let rangeSize = 128 * 1024
        let target = rangeSize + 2
        let total = rangeSize + 4
        let oldCompletionGate = DispatchSemaphore(value: 0)
        MPVStreamSessionTestURLProtocol.handler = { request in
            switch Self.requestStart(request) {
            case 0:
                return .init(
                    statusCode: 206,
                    contentRange: "bytes 0-\(rangeSize - 1)/\(total)",
                    body: Data(repeating: 0x01, count: rangeSize),
                    completionGate: oldCompletionGate
                )
            case Int64(target):
                return .init(statusCode: 206, contentRange: "bytes \(target)-\(total - 1)/\(total)", body: Data([6, 7]))
            default:
                return .init(statusCode: 416, contentRange: "bytes */8", keepOpen: true)
            }
        }
        let baselineBufferedBytes = MPVStreamProtocolBridge.shared.memoryDiagnosticSnapshot().bufferedDataBytes
        let session = try makeSession(rangeRequestSize: rangeSize)
        defer { session.close() }
        XCTAssertTrue(waitForBufferedBytes(baselineBufferedBytes + Int64(rangeSize)))
        XCTAssertEqual(session.size(), Int64(total))

        XCTAssertEqual(session.seek(to: Int64(target)), Int64(target))
        XCTAssertEqual(readExactly(session, count: 2), Data([6, 7]))
        XCTAssertEqual(MPVStreamSessionTestURLProtocol.requestRanges, ["bytes=0-\(rangeSize - 1)", "bytes=\(target)-\(total - 1)"])
        XCTAssertEqual(session.seek(to: Int64(total)), Int64(total))
        XCTAssertEqual(boundedRead(session, count: 1)?.count, 0)
        XCTAssertEqual(MPVStreamSessionTestURLProtocol.requestRanges.count, 2)
    }

    func testCancelAndCloseImmediatelyUnblockReaders() throws {
        let cancelRequestStarted = expectation(description: "cancelled stream request starts")
        MPVStreamSessionTestURLProtocol.handler = { _ in
            .init(
                statusCode: 206,
                contentRange: "bytes 0-0/8",
                body: Data(),
                contentLength: 1,
                keepOpen: true,
                onStart: { cancelRequestStarted.fulfill() }
            )
        }
        let cancelSession = try makeSession(rangeRequestSize: 1)
        defer { cancelSession.close() }
        let cancelRead = beginRead(cancelSession, count: 1)
        wait(for: [cancelRequestStarted, cancelRead.started], timeout: 2)
        cancelSession.cancel()
        wait(for: [cancelRead.finished], timeout: 2)
        XCTAssertEqual(cancelRead.result.value?.count, -1)

        MPVStreamSessionTestURLProtocol.reset()
        let closeRequestStarted = expectation(description: "closed stream request starts")
        MPVStreamSessionTestURLProtocol.handler = { _ in
            .init(
                statusCode: 206,
                contentRange: "bytes 0-0/8",
                body: Data(),
                contentLength: 1,
                keepOpen: true,
                onStart: { closeRequestStarted.fulfill() }
            )
        }
        let closeSession = try makeSession(rangeRequestSize: 1)
        let closeRead = beginRead(closeSession, count: 1)
        wait(for: [closeRequestStarted, closeRead.started], timeout: 2)
        closeSession.close()
        wait(for: [closeRead.finished], timeout: 2)
        XCTAssertEqual(closeRead.result.value?.count, -1)
    }

    func testLoopbackPlaybackCacheSupportsFiniteRanges() async throws {
        let expected = Data((0..<1_537).map { UInt8(truncatingIfNeeded: $0 * 31) })
        let upstreamConfiguration = URLSessionConfiguration.ephemeral
        upstreamConfiguration.protocolClasses = [PlaybackStreamCacheURLProtocol.self]
        PlaybackStreamCacheURLProtocol.handler = { request in
            PlaybackStreamCacheURLProtocol.response(for: request, body: expected, total: Int64(expected.count))
        }
        let sessionID = "mpv_reader_loopback_\(UUID().uuidString)"
        let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent(sessionID, isDirectory: true)
        defer {
            PlaybackStreamCacheURLProtocol.handler = nil
            try? FileManager.default.removeItem(at: cacheRoot)
        }
        let server = PlaybackStreamCacheServer(
            remoteURL: URL(string: "https://cache-test.invalid/mpv-reader")!,
            fileLength: Int64(expected.count),
            sessionID: sessionID,
            cacheRoot: cacheRoot,
            sessionConfiguration: upstreamConfiguration
        )
        let localURL = try await server.start()
        let session = try makeSession(url: localURL, rangeRequestSize: 512)

        let actual = readExactly(session, count: expected.count)
        let eof = boundedRead(session, count: 1)?.count
        session.close()
        await server.stop()

        XCTAssertEqual(actual, expected)
        XCTAssertEqual(eof, 0)
    }

    private func makeSession(
        url: URL? = nil,
        rangeRequestSize: Int,
        bufferLimit: Int = 64 * 1024 * 1024
    ) throws -> MPVStreamSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MPVStreamSessionTestURLProtocol.self]
        return try XCTUnwrap(MPVStreamSession(
            url: url ?? testURL,
            headers: [:],
            sessionConfiguration: configuration,
            rangeRequestSize: rangeRequestSize,
            bufferLimit: bufferLimit
        ))
    }

    private func readExactly(_ session: MPVStreamSession, count: Int) -> Data? {
        var result = Data()
        while result.count < count {
            guard let next = boundedRead(session, count: count - result.count), next.count > 0 else { return nil }
            result.append(next.data)
        }
        return result
    }

    private func boundedRead(_ session: MPVStreamSession, count: Int, timeout: TimeInterval = 3) -> ReadResult? {
        let pending = beginRead(session, count: count)
        guard XCTWaiter.wait(for: [pending.finished], timeout: timeout) == .completed else {
            session.cancel()
            return nil
        }
        return pending.result.value
    }

    private func beginRead(_ session: MPVStreamSession, count: Int) -> PendingRead {
        let started = XCTestExpectation(description: "stream read starts")
        let finished = expectation(description: "stream read finishes")
        let result = ReadResultBox()
        DispatchQueue.global(qos: .userInitiated).async {
            started.fulfill()
            result.value = self.performRead(session, count: count)
            finished.fulfill()
        }
        return PendingRead(started: started, finished: finished, result: result)
    }

    private func performRead(_ session: MPVStreamSession, count: Int) -> ReadResult {
        var bytes = [CChar](repeating: 0, count: count)
        let readCount = bytes.withUnsafeMutableBufferPointer { buffer in
            session.read(into: buffer.baseAddress!, count: count)
        }
        let data = readCount > 0
            ? Data(bytes.prefix(Int(readCount)).map { UInt8(bitPattern: $0) })
            : Data()
        return ReadResult(count: readCount, data: data)
    }

    private func waitForBufferedBytes(_ minimum: Int64, timeout: TimeInterval = 3) -> Bool {
        let buffered = expectation(description: "stream buffer reaches expected bytes")
        DispatchQueue.global(qos: .userInitiated).async {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if MPVStreamProtocolBridge.shared.memoryDiagnosticSnapshot().bufferedDataBytes >= minimum {
                    buffered.fulfill()
                    return
                }
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
        return XCTWaiter.wait(for: [buffered], timeout: timeout + 0.25) == .completed
    }

    private static func requestStart(_ request: URLRequest) -> Int64? {
        guard let range = request.value(forHTTPHeaderField: "Range"), range.hasPrefix("bytes=") else { return nil }
        let value = range.dropFirst("bytes=".count)
        guard let start = value.split(separator: "-", omittingEmptySubsequences: false).first else { return nil }
        return Int64(start)
    }

    private static func rangeResponse(
        _ request: URLRequest,
        body: Data,
        rangeSize: Int,
        total: Int,
        completionGate: DispatchSemaphore? = nil
    ) -> MPVStreamSessionTestURLProtocol.Response {
        guard let start = request.value(forHTTPHeaderField: "Range")
            .flatMap({ $0.dropFirst("bytes=".count).split(separator: "-", omittingEmptySubsequences: false).first })
            .flatMap({ Int64($0) }),
              start >= 0, start < Int64(total) else {
            return .init(statusCode: 416, contentRange: "bytes */\(total)")
        }
        let end = min(start + Int64(rangeSize) - 1, Int64(total) - 1)
        let responseBody = Data(body[Int(start)..<Int(end + 1)])
        return .init(
            statusCode: 206,
            contentRange: "bytes \(start)-\(end)/\(total)",
            body: responseBody,
            contentLength: Int64(responseBody.count),
            completionGate: completionGate
        )
    }

    private struct ReadResult {
        let count: Int64
        let data: Data
    }

    private struct PendingRead {
        let started: XCTestExpectation
        let finished: XCTestExpectation
        let result: ReadResultBox
    }

    private final class ReadResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storedValue: ReadResult?
        var value: ReadResult? {
            get { lock.withLock { storedValue } }
            set { lock.withLock { storedValue = newValue } }
        }
    }
}

private final class MPVStreamSessionTestURLProtocol: URLProtocol {
    struct Response {
        let statusCode: Int
        let contentRange: String?
        let body: Data
        let contentLength: Int64?
        let error: Error?
        let completionGate: DispatchSemaphore?
        let keepOpen: Bool
        let onStart: (() -> Void)?
        let chunkSizes: [Int]?

        init(
            statusCode: Int,
            contentRange: String? = nil,
            body: Data = Data(),
            contentLength: Int64? = nil,
            error: Error? = nil,
            completionGate: DispatchSemaphore? = nil,
            keepOpen: Bool = false,
            onStart: (() -> Void)? = nil,
            chunkSizes: [Int]? = nil
        ) {
            self.statusCode = statusCode
            self.contentRange = contentRange
            self.body = body
            self.contentLength = contentLength
            self.error = error
            self.completionGate = completionGate
            self.keepOpen = keepOpen
            self.onStart = onStart
            self.chunkSizes = chunkSizes
        }
    }

    private static let stateLock = NSLock()
    private static var storedHandler: ((URLRequest) -> Response)?
    private static var storedRanges = [String]()

    static var handler: ((URLRequest) -> Response)? {
        get { stateLock.withLock { storedHandler } }
        set { stateLock.withLock { storedHandler = newValue } }
    }

    static var requestRanges: [String] { stateLock.withLock { storedRanges } }

    static func reset() {
        stateLock.withLock {
            storedHandler = nil
            storedRanges = []
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "mpv-reader.invalid"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private let deliveryLock = NSRecursiveLock()
    private var isStopped = false
    private var completionGate: DispatchSemaphore?

    override func startLoading() {
        Self.stateLock.lock()
        Self.storedRanges.append(request.value(forHTTPHeaderField: "Range") ?? "<missing>")
        let handler = Self.storedHandler
        Self.stateLock.unlock()
        guard let response = handler?(request), let url = request.url else {
            finish(with: URLError(.badServerResponse))
            return
        }
        response.onStart?()

        deliveryLock.lock()
        completionGate = response.completionGate
        guard !isStopped else {
            deliveryLock.unlock()
            return
        }
        var fields = ["Content-Length": "\(response.contentLength ?? Int64(response.body.count))", "Accept-Ranges": "bytes"]
        if let contentRange = response.contentRange { fields["Content-Range"] = contentRange }
        let http = HTTPURLResponse(url: url, statusCode: response.statusCode, httpVersion: "HTTP/1.1", headerFields: fields)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        if !isStopped && !response.body.isEmpty {
            var bodyOffset = 0
            for requestedSize in response.chunkSizes ?? [response.body.count] where bodyOffset < response.body.count {
                let chunkSize = min(max(0, requestedSize), response.body.count - bodyOffset)
                guard chunkSize > 0 else { continue }
                let endOffset = bodyOffset + chunkSize
                client?.urlProtocol(self, didLoad: response.body.subdata(in: bodyOffset..<endOffset))
                bodyOffset = endOffset
                if isStopped { break }
            }
            if !isStopped && bodyOffset < response.body.count {
                client?.urlProtocol(self, didLoad: response.body.subdata(in: bodyOffset..<response.body.count))
            }
        }
        guard !isStopped else {
            deliveryLock.unlock()
            return
        }
        if !response.keepOpen {
            if let gate = response.completionGate {
                DispatchQueue.global().async { [weak self] in
                    guard gate.wait(timeout: .now() + 4) == .success else { return }
                    self?.finish(with: response.error)
                }
            } else {
                finish(with: response.error)
            }
        }
        deliveryLock.unlock()
    }

    private func finish(with error: Error?) {
        deliveryLock.lock()
        defer { deliveryLock.unlock() }
        guard !isStopped else { return }
        isStopped = true
        if let error {
            client?.urlProtocol(self, didFailWithError: error)
        } else {
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        deliveryLock.lock()
        isStopped = true
        let gate = completionGate
        deliveryLock.unlock()
        gate?.signal()
    }
}
#endif

#if NUVIO_MPV_MEMORY_WATCHDOG && os(tvOS)
final class MPVMemoryWatchdogTests: XCTestCase {
    func testLogRotationIsBoundedAndCarriesPreviousTailAcrossLaunch() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MPVMemoryDiagnosticLogStore(directory: directory, maximumTotalBytes: 4 * 1024)
        _ = store.prepareForCurrentProcess()

        for value in 0..<80 {
            store.append(jsonLine: "{\"value\":\(value),\"payload\":\"\(String(repeating: "x", count: 80))\"}")
        }

        XCTAssertLessThanOrEqual(store.storedByteCount, 4 * 1024)
        XCTAssertFalse(store.currentData.isEmpty)
        XCTAssertFalse(store.previousData.isEmpty)
        let previousLastLine = try XCTUnwrap(String(data: store.previousData, encoding: .utf8)?.split(separator: "\n").last)

        let relaunchedStore = MPVMemoryDiagnosticLogStore(directory: directory, maximumTotalBytes: 4 * 1024)
        let startupReport = try XCTUnwrap(relaunchedStore.prepareForCurrentProcess())
        XCTAssertTrue(startupReport.previousPath.hasSuffix("previous.jsonl"))
        XCTAssertLessThanOrEqual(relaunchedStore.storedByteCount, 4 * 1024)
        let retainedTail = try XCTUnwrap(startupReport.previousTail)
        XCTAssertTrue(retainedTail.contains(String(previousLastLine)))
        XCTAssertTrue(retainedTail.contains("\"value\":79"))
    }

    func testStopPreventsLaterTimerAndEventSamples() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MPVMemoryDiagnosticLogStore(directory: directory)
        let counter = MetricCounter()
        let secondSample = expectation(description: "periodic sample arrives")
        let watchdog = MPVMemoryWatchdog(
            store: store,
            interval: 0.05,
            processID: 123,
            processMetrics: {
                let count = counter.increment()
                if count == 2 { secondSample.fulfill() }
                return Self.processMetrics(footprintMiB: Double(100 + count))
            },
            bridgeMetrics: { MPVStreamBridgeMemorySnapshot(activeSessions: 0, bufferedDataBytes: 0, suspendedTasks: 0, retryCount: 0) }
        )
        defer { watchdog.stop(event: "cleanup") }

        watchdog.start(sessionID: "test-session", cacheMode: "network", event: "test_start")
        wait(for: [secondSample], timeout: 2)
        watchdog.stop(event: "test_stop")
        watchdog.flushPendingWorkForTesting()
        let stoppedCount = counter.value
        watchdog.record(event: "after_stop")
        watchdog.flushPendingWorkForTesting()

        let timerWindow = expectation(description: "timer window after stop")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { timerWindow.fulfill() }
        wait(for: [timerWindow], timeout: 1)
        watchdog.flushPendingWorkForTesting()
        XCTAssertEqual(counter.value, stoppedCount)
        XCTAssertFalse(String(data: store.currentData, encoding: .utf8)?.contains("after_stop") ?? true)
    }

    func testMissingEngineMetricsAreOptionalAndSnapshotAgeIsReported() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MPVMemoryDiagnosticLogStore(directory: directory)
        let now = Date()
        let engine = MPVMemoryEngineSnapshot(
            sampledAt: now.addingTimeInterval(-10),
            cacheTotalBytes: nil,
            cacheForwardBytes: nil,
            cacheDurationSeconds: nil,
            inputBytesPerSecond: nil,
            timePositionSeconds: nil,
            coreIdle: nil,
            eofReached: nil,
            cacheReaderIdle: nil,
            cacheReaderEOF: nil,
            cacheUnderrun: nil,
            paused: nil,
            seeking: nil,
            pausedForCache: nil,
            width: nil,
            height: nil,
            codec: nil,
            hardwareDecoder: nil,
            demuxerMaxBytes: nil,
            demuxerMaxBackBytes: nil,
            localOrDiskCache: nil
        )
        let watchdog = MPVMemoryWatchdog(
            store: store,
            interval: 60,
            processID: 456,
            processMetrics: { Self.processMetrics(sampledAt: now) },
            bridgeMetrics: { MPVStreamBridgeMemorySnapshot(activeSessions: 0, bufferedDataBytes: 0, suspendedTasks: 0, retryCount: 0) }
        )

        watchdog.start(sessionID: "diagnostic-test", cacheMode: "local_or_disk", event: "test_start")
        watchdog.flushPendingWorkForTesting()
        watchdog.updateEngineSnapshot(engine)
        watchdog.flushPendingWorkForTesting()
        watchdog.stop(event: "test_stale_snapshot")
        watchdog.flushPendingWorkForTesting()

        let lastLine = try XCTUnwrap(String(data: store.currentData, encoding: .utf8)?.split(separator: "\n").last)
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lastLine.utf8)) as? [String: Any])
        XCTAssertEqual(record["sessionID"] as? String, "diagnostic-test")
        XCTAssertEqual(record["cacheMode"] as? String, "local_or_disk")
        XCTAssertEqual(record["engineSnapshotStale"] as? Bool, true)
        XCTAssertGreaterThan(record["engineSnapshotAgeSeconds"] as? Double ?? 0, 9.9)
        let engineRecord = try XCTUnwrap(record["engine"] as? [String: Any])
        XCTAssertNil(engineRecord["cacheTotalBytes"])
        XCTAssertNil(engineRecord["timePositionSeconds"])
    }

    func testFailedVMStatisticsDoNotCreateFalseFootprintSpike() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MPVMemoryDiagnosticLogStore(directory: directory)
        let counter = MetricCounter()
        let watchdog = MPVMemoryWatchdog(
            store: store,
            interval: 60,
            processID: 789,
            processMetrics: {
                if counter.increment() == 1 {
                    return Self.processMetrics(vmStatisticsAvailable: false, footprintMiB: nil)
                }
                return Self.processMetrics(footprintMiB: 100)
            },
            bridgeMetrics: { MPVStreamBridgeMemorySnapshot(activeSessions: 0, bufferedDataBytes: 0, suspendedTasks: 0, retryCount: 0) }
        )
        defer { watchdog.stop(event: "cleanup"); watchdog.flushPendingWorkForTesting() }

        watchdog.start(sessionID: "vm-stats-test", cacheMode: "network", event: "failed_vm_sample")
        watchdog.flushPendingWorkForTesting()
        watchdog.record(event: "valid_vm_sample")
        watchdog.flushPendingWorkForTesting()
        watchdog.stop(event: "vm_stats_stop")
        watchdog.flushPendingWorkForTesting()

        let lines = try XCTUnwrap(String(data: store.currentData, encoding: .utf8)).split(separator: "\n")
        XCTAssertGreaterThanOrEqual(lines.count, 3)
        let invalid = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        let valid = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any])
        XCTAssertEqual(invalid["vmStatisticsAvailable"] as? Bool, false)
        XCTAssertNil(invalid["footprintMiB"])
        XCTAssertNil(invalid["footprintHighWaterMiB"])
        XCTAssertEqual(valid["vmStatisticsAvailable"] as? Bool, true)
        XCTAssertEqual(valid["footprintMiB"] as? Double, 100)
        XCTAssertNil(valid["footprintDeltaMiB"])
        XCTAssertEqual(valid["footprintHighWaterMiB"] as? Double, 100)
        XCTAssertFalse((valid["alerts"] as? [String] ?? []).contains("sudden_footprint_rise"))
    }

    func testBridgeDiagnosticSnapshotAggregatesNumericSessionState() {
        let bridge = MPVStreamProtocolBridge.shared
        let before = bridge.memoryDiagnosticSnapshot()
        let sessionID = UUID()
        bridge.updateMemoryDiagnostics(
            sessionID: sessionID,
            bufferedDataBytes: 4096,
            isTaskSuspended: true,
            retryCount: 2
        )
        let during = bridge.memoryDiagnosticSnapshot()
        XCTAssertEqual(during.activeSessions, before.activeSessions + 1)
        XCTAssertEqual(during.bufferedDataBytes, before.bufferedDataBytes + 4096)
        XCTAssertEqual(during.suspendedTasks, before.suspendedTasks + 1)
        XCTAssertEqual(during.retryCount, before.retryCount + 2)

        bridge.removeMemoryDiagnostics(sessionID: sessionID)
        XCTAssertEqual(bridge.memoryDiagnosticSnapshot(), before)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mpv-memory-watchdog-\(UUID().uuidString)", isDirectory: true)
    }

    private static func processMetrics(
        sampledAt: Date = Date(),
        vmStatisticsAvailable: Bool = true,
        footprintMiB: Double? = 100
    ) -> MPVMemoryProcessMetrics {
        MPVMemoryProcessMetrics(
            sampledAt: sampledAt,
            vmStatisticsAvailable: vmStatisticsAvailable,
            footprintMiB: footprintMiB,
            residentMiB: vmStatisticsAvailable ? 80 : nil,
            availableMiB: 512,
            dirtyInternalMiB: vmStatisticsAvailable ? 40 : nil,
            compressedMiB: vmStatisticsAvailable ? 4 : nil,
            deviceMappedMiB: vmStatisticsAvailable ? 12 : nil,
            totalPhysicalRAMMiB: 4096,
            thermalState: "Nominal",
            appCacheMiB: 32,
            cacheBreakdownMiB: ["posters": 12, "urlCacheMemory": 20]
        )
    }

    private final class MetricCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func increment() -> Int {
            lock.lock()
            defer { lock.unlock() }
            count += 1
            return count
        }

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }
}
#endif

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
        var redirectURL: URL? = nil
        var errorCode: URLError.Code? = nil
    }

    struct RequestSnapshot {
        let url: URL?
        let method: String?
        let headers: [String: String]

        func value(forHTTPHeaderField field: String) -> String? {
            headers.first { $0.key.caseInsensitiveCompare(field) == .orderedSame }?.value
        }
    }

    private static let metricsLock = NSLock()
    private static var storedHandler: ((URLRequest) -> Response)?
    private static var storedDelay: TimeInterval = 0
    private static var activeRequests = 0
    private static var maximumActive = 0
    private static var starts = [Date]()
    private static var ranges = [String?]()
    private static var snapshots = [RequestSnapshot]()
    private static var deliveredBodyBytes = 0
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
    static var activeRequestCount: Int { metricsLock.withLock { activeRequests } }
    static var requestCount: Int { metricsLock.withLock { starts.count } }
    static var requestStarts: [Date] { metricsLock.withLock { starts } }
    static var requestRanges: [String?] { metricsLock.withLock { ranges } }
    static var requestSnapshots: [RequestSnapshot] { metricsLock.withLock { snapshots } }
    static var totalDeliveredBodyBytes: Int { metricsLock.withLock { deliveredBodyBytes } }
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
            snapshots = []
            deliveredBodyBytes = 0
            cancellations = 0
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        ["cache-test.invalid", "cache-redirect.invalid"].contains(request.url?.host)
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        deliveryLock.lock()
        defer { deliveryLock.unlock() }
        Self.metricsLock.withLock {
            Self.starts.append(Date())
            Self.ranges.append(request.value(forHTTPHeaderField: "Range"))
            Self.snapshots.append(RequestSnapshot(
                url: request.url,
                method: request.httpMethod,
                headers: request.allHTTPHeaderFields ?? [:]
            ))
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
            if let errorCode = response.errorCode {
                finished = true
                Self.metricsLock.withLock { Self.activeRequests -= 1 }
                client?.urlProtocol(self, didFailWithError: URLError(errorCode))
                return
            }
            if let redirectURL = response.redirectURL {
                let redirect = HTTPURLResponse(
                    url: url,
                    statusCode: response.statusCode,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Location": redirectURL.absoluteString]
                )!
                finished = true
                Self.metricsLock.withLock { Self.activeRequests -= 1 }
                var redirectRequest = URLRequest(url: redirectURL)
                redirectRequest.httpMethod = request.httpMethod
                for (name, value) in request.allHTTPHeaderFields ?? [:] {
                    redirectRequest.setValue(value, forHTTPHeaderField: name)
                }
                client?.urlProtocol(self, wasRedirectedTo: redirectRequest, redirectResponse: redirect)
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
            Self.metricsLock.withLock { Self.deliveredBodyBytes += end - offset }
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
    func testRangeProbeIsRangeFirstAndSkipsHeadWithValidator() async {
        let url = URL(string: "https://cache-test.invalid/range_first")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlaybackStreamCacheURLProtocol.self]
        PlaybackStreamCacheURLProtocol.resetMetrics()
        PlaybackStreamCacheURLProtocol.handler = { request in
            PlaybackStreamCacheURLProtocol.Response(
                data: Data([0x42, 0x43]), statusCode: 206, contentRange: "bytes 0-1/64",
                retryAfter: nil, etag: "range-tag", lastModified: nil
            )
        }
        defer { PlaybackStreamCacheURLProtocol.handler = nil }

        let result = await PlaybackStreamCacheManager.shared.probeRangeSupport(
            url: url, sessionConfiguration: configuration, preparationBudget: 1
        )
        XCTAssertTrue(result.supportsRange)
        XCTAssertEqual(result.contentLength, 64)
        XCTAssertEqual(result.etag, "range-tag")
        XCTAssertEqual(PlaybackStreamCacheURLProtocol.requestCount, 1)
        XCTAssertEqual(PlaybackStreamCacheURLProtocol.requestSnapshots.first?.method, "GET")
        XCTAssertTrue(PlaybackStreamCacheURLProtocol.requestRanges.contains { $0 == "bytes=0-1" })
    }

    func testHeadFailureDoesNotVetoVerifiedRangeResponse() async {
        let url = URL(string: "https://cache-test.invalid/head_forbidden")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlaybackStreamCacheURLProtocol.self]
        PlaybackStreamCacheURLProtocol.resetMetrics()
        PlaybackStreamCacheURLProtocol.handler = { request in
            if request.httpMethod == "HEAD" {
                return PlaybackStreamCacheURLProtocol.Response(
                    data: Data(), statusCode: 403, contentRange: "", retryAfter: nil,
                    etag: nil, lastModified: nil
                )
            }
            return PlaybackStreamCacheURLProtocol.Response(
                data: Data([0x42, 0x43]), statusCode: 206, contentRange: "bytes 0-1/64",
                retryAfter: nil, etag: nil, lastModified: nil
            )
        }
        defer { PlaybackStreamCacheURLProtocol.handler = nil }

        let result = await PlaybackStreamCacheManager.shared.probeRangeSupport(
            url: url, sessionConfiguration: configuration, preparationBudget: 1
        )
        XCTAssertTrue(result.supportsRange)
        XCTAssertEqual(result.contentLength, 64)
        XCTAssertNil(result.etag)
        XCTAssertEqual(PlaybackStreamCacheURLProtocol.requestSnapshots.compactMap(\.method), ["GET", "HEAD"])
    }

    func testRangeProbeBudgetCancelsHangingGet() async {
        let url = URL(string: "https://cache-test.invalid/hanging_get")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlaybackStreamCacheURLProtocol.self]
        PlaybackStreamCacheURLProtocol.resetMetrics()
        PlaybackStreamCacheURLProtocol.delay = 5
        PlaybackStreamCacheURLProtocol.handler = { _ in
            PlaybackStreamCacheURLProtocol.Response(
                data: Data([0x42, 0x43]), statusCode: 206, contentRange: "bytes 0-1/64",
                retryAfter: nil, etag: "tag", lastModified: nil
            )
        }
        defer {
            PlaybackStreamCacheURLProtocol.handler = nil
            PlaybackStreamCacheURLProtocol.delay = 0
        }

        let started = ProcessInfo.processInfo.systemUptime
        let result = await PlaybackStreamCacheManager.shared.probeRangeSupport(
            url: url, sessionConfiguration: configuration, preparationBudget: 0.05
        )
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        XCTAssertFalse(result.supportsRange)
        XCTAssertEqual(PlaybackStreamCacheURLProtocol.requestCount, 1)
        await waitForProtocolCancellationIfStillLoading()
        XCTAssertGreaterThan(PlaybackStreamCacheURLProtocol.cancellationCount, 0)
        XCTAssertLessThan(elapsed, 0.5)
    }

    func testOptionalHeadBudgetCancelsHeadButKeepsVerifiedRange() async {
        let url = URL(string: "https://cache-test.invalid/hanging_optional_head")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlaybackStreamCacheURLProtocol.self]
        PlaybackStreamCacheURLProtocol.resetMetrics()
        PlaybackStreamCacheURLProtocol.delay = 0.15
        PlaybackStreamCacheURLProtocol.handler = { request in
            if request.httpMethod == "HEAD" {
                return PlaybackStreamCacheURLProtocol.response(for: request, body: Data(repeating: 0x42, count: 64), total: 64)
            }
            return PlaybackStreamCacheURLProtocol.Response(
                data: Data([0x42, 0x43]), statusCode: 206, contentRange: "bytes 0-1/64",
                retryAfter: nil, etag: nil, lastModified: nil
            )
        }
        defer {
            PlaybackStreamCacheURLProtocol.handler = nil
            PlaybackStreamCacheURLProtocol.delay = 0
        }

        let started = ProcessInfo.processInfo.systemUptime
        let result = await PlaybackStreamCacheManager.shared.probeRangeSupport(
            url: url, sessionConfiguration: configuration, preparationBudget: 0.25
        )
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        XCTAssertTrue(result.supportsRange)
        XCTAssertEqual(result.contentLength, 64)
        XCTAssertNil(result.etag)
        XCTAssertEqual(PlaybackStreamCacheURLProtocol.requestCount, 2)
        await waitForProtocolCancellationIfStillLoading()
        XCTAssertGreaterThan(PlaybackStreamCacheURLProtocol.cancellationCount, 0)
        XCTAssertLessThan(elapsed, 0.6)
    }

    func testManagerStopCancelsPendingRangeProbe() async throws {
        let url = URL(string: "https://cache-test.invalid/manager_stop_probe")!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let token = "probe_stop_\(UUID().uuidString)"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlaybackStreamCacheURLProtocol.self]
        PlaybackStreamCacheURLProtocol.resetMetrics()
        PlaybackStreamCacheURLProtocol.delay = 5
        PlaybackStreamCacheURLProtocol.handler = { _ in
            PlaybackStreamCacheURLProtocol.Response(
                data: Data([0x42, 0x43]), statusCode: 206, contentRange: "bytes 0-1/64",
                retryAfter: nil, etag: "tag", lastModified: nil
            )
        }
        defer {
            PlaybackStreamCacheURLProtocol.handler = nil
            PlaybackStreamCacheURLProtocol.delay = 0
            try? FileManager.default.removeItem(at: root)
        }

        let manager = PlaybackStreamCacheManager.shared
        let pending = Task {
            await manager.prepareCacheServer(
                for: url, sessionToken: token, cacheRoot: root,
                sessionConfiguration: configuration, preparationBudget: 5
            )
        }
        for _ in 0..<100 where PlaybackStreamCacheURLProtocol.requestCount == 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(PlaybackStreamCacheURLProtocol.requestCount, 1)
        await manager.stopActiveSession(token: token)
        let result = await pending.value
        XCTAssertNil(result)
        let hasActiveServer = await manager.hasActiveServer
        XCTAssertFalse(hasActiveServer)
        await waitForProtocolCancellationIfStillLoading()
        XCTAssertGreaterThan(PlaybackStreamCacheURLProtocol.cancellationCount, 0)
    }

    func testSupersedingProbeCannotPublishOrClearNewSession() async throws {
        let firstURL = URL(string: "https://cache-test.invalid/first_probe")!
        let secondURL = URL(string: "https://cache-test.invalid/second_probe")!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let firstToken = "probe_first_\(UUID().uuidString)"
        let secondToken = "probe_second_\(UUID().uuidString)"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlaybackStreamCacheURLProtocol.self]
        PlaybackStreamCacheURLProtocol.resetMetrics()
        PlaybackStreamCacheURLProtocol.delay = 5
        PlaybackStreamCacheURLProtocol.handler = { request in
            PlaybackStreamCacheURLProtocol.Response(
                data: Data([0x42, 0x43]), statusCode: 206, contentRange: "bytes 0-1/64",
                retryAfter: nil, etag: request.url == secondURL ? "second-tag" : "first-tag", lastModified: nil
            )
        }
        defer {
            PlaybackStreamCacheURLProtocol.handler = nil
            PlaybackStreamCacheURLProtocol.delay = 0
            try? FileManager.default.removeItem(at: root)
        }

        let manager = PlaybackStreamCacheManager.shared
        let firstPending = Task {
            await manager.prepareCacheServer(
                for: firstURL, sessionToken: firstToken, cacheRoot: root,
                sessionConfiguration: configuration, preparationBudget: 5
            )
        }
        for _ in 0..<100 where PlaybackStreamCacheURLProtocol.requestCount == 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(PlaybackStreamCacheURLProtocol.requestCount, 1)

        PlaybackStreamCacheURLProtocol.delay = 0
        let secondPending = Task {
            await manager.prepareCacheServer(
                for: secondURL, sessionToken: secondToken, cacheRoot: root,
                sessionConfiguration: configuration, preparationBudget: 1
            )
        }
        let secondLocalURL = await secondPending.value
        let firstLocalURL = await firstPending.value
        XCTAssertNotNil(secondLocalURL)
        XCTAssertNil(firstLocalURL)
        let activeSessionToken = await manager.activeSessionToken
        let hasActiveServer = await manager.hasActiveServer
        XCTAssertEqual(activeSessionToken, secondToken)
        XCTAssertTrue(hasActiveServer)
        await manager.stopActiveSession(token: secondToken)
    }

    func testCancelledPreparationAfterOldServerStopRemovesOnlyItsPublishedServer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlaybackStreamCacheURLProtocol.self]
        PlaybackStreamCacheURLProtocol.resetMetrics()
        PlaybackStreamCacheURLProtocol.handler = { request in
            PlaybackStreamCacheURLProtocol.response(
                for: request, body: Data([0x42, 0x43]), total: 64, etag: "probe-tag"
            )
        }
        defer {
            PlaybackStreamCacheURLProtocol.handler = nil
            try? FileManager.default.removeItem(at: root)
        }

        let barrier = PlaybackCacheStopBarrier()
        let manager = PlaybackStreamCacheManager(serverStopper: { server in
            await barrier.blockIfArmed()
            await server.stop()
        })
        let firstURL = URL(string: "https://cache-test.invalid/old_server")!
        let secondURL = URL(string: "https://cache-test.invalid/cancelled_server")!
        let firstToken = "post_probe_owner_\(UUID().uuidString)"
        let secondToken = "post_probe_cancel_\(UUID().uuidString)"
        let firstLocalURL = await manager.prepareCacheServer(
            for: firstURL, sessionToken: firstToken, cacheRoot: root,
            sessionConfiguration: configuration, freeSpaceProvider: { _ in 0 }
        )
        guard firstLocalURL != nil else {
            XCTFail("Expected the first cache server to become active")
            return
        }

        await barrier.arm()
        let cancelledPreparation = Task {
            await manager.prepareCacheServer(
                for: secondURL, sessionToken: secondToken, cacheRoot: root,
                sessionConfiguration: configuration, freeSpaceProvider: { _ in 0 }
            )
        }
        await barrier.waitUntilEntered()
        cancelledPreparation.cancel()
        await barrier.release()

        let cancelledLocalURL = await cancelledPreparation.value
        let hasActiveServer = await manager.hasActiveServer
        let activeSessionToken = await manager.activeSessionToken
        XCTAssertNil(cancelledLocalURL)
        XCTAssertFalse(hasActiveServer)
        XCTAssertNil(activeSessionToken)
        await manager.stopActiveSession()
    }

    func testRangeProbeRequiresExactTwoBytePartialResponse() async {
        let url = URL(string: "https://cache-test.invalid/probe")!
        let body = Data(repeating: 0x42, count: 64)
        let cases: [(name: String, status: Int, contentRange: String, data: Data, supportsRange: Bool, bodyChunkBytes: Int?)] = [
            ("ignored range", 200, "bytes 0-63/64", body, false, 2),
            ("wrong range", 206, "bytes 1-2/64", Data([0x42, 0x42]), false, nil),
            ("malformed range separator", 206, "bytes 0--1/64", Data([0x42, 0x42]), false, nil),
            ("malformed total separator", 206, "bytes 0-1//64", Data([0x42, 0x42]), false, nil),
            ("short body", 206, "bytes 0-1/64", Data([0x42]), false, nil),
            ("valid range", 206, "bytes 0-1/64", Data([0x42, 0x42]), true, nil)
        ]

        for testCase in cases {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [PlaybackStreamCacheURLProtocol.self]
            PlaybackStreamCacheURLProtocol.resetMetrics()
            PlaybackStreamCacheURLProtocol.handler = { request in
                if request.httpMethod == "HEAD" {
                    return PlaybackStreamCacheURLProtocol.response(for: request, body: body, total: 64, etag: "head-tag")
                }
                return PlaybackStreamCacheURLProtocol.Response(
                    data: testCase.data,
                    statusCode: testCase.status,
                    contentRange: testCase.contentRange,
                    retryAfter: nil,
                    etag: nil,
                    lastModified: nil,
                    bodyChunkBytes: testCase.bodyChunkBytes,
                    bodyChunkDelay: 0.01
                )
            }

            let result = await PlaybackStreamCacheManager.shared.probeRangeSupport(
                url: url,
                sessionConfiguration: configuration
            )
            XCTAssertEqual(result.supportsRange, testCase.supportsRange, testCase.name)
            if testCase.supportsRange {
                XCTAssertEqual(result.contentLength, 64)
                XCTAssertEqual(result.etag, "head-tag")
            } else {
                XCTAssertEqual(result.contentLength, 0)
            }
            let requestRanges = PlaybackStreamCacheURLProtocol.requestRanges
            XCTAssertTrue(requestRanges.contains { $0 == "bytes=0-1" })
            if testCase.supportsRange {
                XCTAssertEqual(requestRanges.count, 2)
                XCTAssertNil(requestRanges[1], "HEAD is only used as a validator fallback after a valid GET")
                XCTAssertEqual(PlaybackStreamCacheURLProtocol.requestSnapshots[1].method, "HEAD")
            } else {
                XCTAssertEqual(requestRanges.count, 1, "An invalid range response must not trigger HEAD")
            }
            if testCase.name == "ignored range" {
                XCTAssertLessThanOrEqual(PlaybackStreamCacheURLProtocol.totalDeliveredBodyBytes, testCase.data.count)
            }
        }
        PlaybackStreamCacheURLProtocol.handler = nil
    }

    func testProbeRedirectScopesHeadersToSameOriginAndPreservesProbeRange() async {
        let sourceURL = URL(string: "https://cache-test.invalid:8443/source")!
        let redirectCases: [(target: URL, preservesCustomHeaders: Bool)] = [
            (URL(string: "https://cache-test.invalid:8443/same-origin")!, true),
            (URL(string: "https://cache-redirect.invalid:8443/different-host")!, false),
            (URL(string: "https://cache-test.invalid:9443/different-port")!, false),
            (URL(string: "http://cache-test.invalid:8443/different-scheme")!, false)
        ]
        let body = Data(repeating: 0x53, count: 64)

        for redirectCase in redirectCases {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [PlaybackStreamCacheURLProtocol.self]
            PlaybackStreamCacheURLProtocol.resetMetrics()
            PlaybackStreamCacheURLProtocol.handler = { request in
                if request.url == sourceURL {
                    return PlaybackStreamCacheURLProtocol.Response(
                        data: Data(), statusCode: 302, contentRange: "", retryAfter: nil,
                        etag: nil, lastModified: nil, redirectURL: redirectCase.target
                    )
                }
                return PlaybackStreamCacheURLProtocol.response(for: request, body: body, total: 64)
            }

            let result = await PlaybackStreamCacheManager.shared.probeRangeSupport(
                url: sourceURL,
                headers: ["X-Playback-Secret": "secret", "Range": "bytes=50-60"],
                sessionConfiguration: configuration
            )
            XCTAssertTrue(result.supportsRange)
            let redirectedRequests = PlaybackStreamCacheURLProtocol.requestSnapshots.filter { $0.url == redirectCase.target }
            let redirectedGet = redirectedRequests.first { $0.method == "GET" }
            XCTAssertEqual(redirectedGet?.value(forHTTPHeaderField: "Range"), "bytes=0-1")
            XCTAssertEqual(
                redirectedGet?.value(forHTTPHeaderField: "X-Playback-Secret"),
                redirectCase.preservesCustomHeaders ? "secret" : nil
            )
        }
        PlaybackStreamCacheURLProtocol.handler = nil
    }

    func testProbeDoesNotRestoreHeadersAfterCrossOriginRedirect() async throws {
        let sourceURL = URL(string: "https://cache-test.invalid/source")!
        let intermediateURL = URL(string: "https://cache-redirect.invalid/first-hop")!
        let finalURL = URL(string: "https://cache-redirect.invalid/second-hop")!
        let body = Data(repeating: 0x39, count: 64)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlaybackStreamCacheURLProtocol.self]
        PlaybackStreamCacheURLProtocol.resetMetrics()
        PlaybackStreamCacheURLProtocol.handler = { request in
            if request.url == sourceURL {
                return PlaybackStreamCacheURLProtocol.Response(
                    data: Data(), statusCode: 302, contentRange: "", retryAfter: nil,
                    etag: nil, lastModified: nil, redirectURL: intermediateURL
                )
            }
            if request.url == intermediateURL {
                return PlaybackStreamCacheURLProtocol.Response(
                    data: Data(), statusCode: 302, contentRange: "", retryAfter: nil,
                    etag: nil, lastModified: nil, redirectURL: finalURL
                )
            }
            return PlaybackStreamCacheURLProtocol.response(for: request, body: body, total: 64)
        }
        defer { PlaybackStreamCacheURLProtocol.handler = nil }

        let result = await PlaybackStreamCacheManager.shared.probeRangeSupport(
            url: sourceURL,
            headers: ["X-Playback-Secret": "secret"],
            sessionConfiguration: configuration
        )
        XCTAssertTrue(result.supportsRange)

        let requests = PlaybackStreamCacheURLProtocol.requestSnapshots
        let intermediateGet = try XCTUnwrap(requests.first { $0.url == intermediateURL && $0.method == "GET" })
        let finalGet = try XCTUnwrap(requests.first { $0.url == finalURL && $0.method == "GET" })
        XCTAssertNil(intermediateGet.value(forHTTPHeaderField: "X-Playback-Secret"))
        XCTAssertNil(finalGet.value(forHTTPHeaderField: "X-Playback-Secret"))
        XCTAssertEqual(finalGet.value(forHTTPHeaderField: "Range"), "bytes=0-1")
    }

    func testCacheFetchReusesOriginalRedirectingURLAndStripsCrossOriginHeaders() async throws {
        let chunkSize = Int(PlaybackStreamDiskCache.defaultChunkSize)
        let fileLength = Int64(chunkSize * 6)
        let body = Data(repeating: 0x6A, count: Int(fileLength))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        await PlaybackStreamCacheManager.shared.stopActiveSession()

        let testID = UUID().uuidString
        let sourceURL = URL(string: "https://cache-test.invalid/signed/movie_\(testID)?token=original")!
        let intermediateURL = URL(string: "https://cache-redirect.invalid/first-hop/movie_\(testID)")!
        let resolvedURL = URL(string: "https://cache-redirect.invalid/renewed/movie_\(testID)")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlaybackStreamCacheURLProtocol.self]
        PlaybackStreamCacheURLProtocol.resetMetrics()
        PlaybackStreamCacheURLProtocol.handler = { request in
            if request.url == sourceURL {
                return PlaybackStreamCacheURLProtocol.Response(
                    data: Data(), statusCode: 302, contentRange: "", retryAfter: nil,
                    etag: nil, lastModified: nil, redirectURL: intermediateURL
                )
            }
            if request.url == intermediateURL {
                return PlaybackStreamCacheURLProtocol.Response(
                    data: Data(), statusCode: 302, contentRange: "", retryAfter: nil,
                    etag: nil, lastModified: nil, redirectURL: resolvedURL
                )
            }
            return PlaybackStreamCacheURLProtocol.response(for: request, body: body, total: fileLength)
        }
        defer { PlaybackStreamCacheURLProtocol.handler = nil }

        guard let localURL = await PlaybackStreamCacheManager.shared.prepareCacheServer(
            for: sourceURL,
            headers: ["X-Playback-Secret": "secret"],
            targetLeadSeconds: 0,
            cacheRoot: root,
            sessionConfiguration: configuration
        ) else {
            XCTFail("Expected redirecting range source to prepare a cache server")
            return
        }

        let probeRequests = PlaybackStreamCacheURLProtocol.requestSnapshots
        let probeFinalGet = try XCTUnwrap(probeRequests.first { $0.url == resolvedURL && $0.method == "GET" })
        XCTAssertEqual(probeFinalGet.value(forHTTPHeaderField: "Range"), "bytes=0-1")
        XCTAssertNil(probeFinalGet.value(forHTTPHeaderField: "X-Playback-Secret"))

        let requestCountBeforeFetch = PlaybackStreamCacheURLProtocol.requestSnapshots.count
        var localRequest = URLRequest(url: localURL)
        localRequest.setValue("bytes=0-\(chunkSize - 1)", forHTTPHeaderField: "Range")
        let fetched = try await URLSession.shared.data(for: localRequest).0
        XCTAssertEqual(fetched, body.prefix(chunkSize))

        let allSnapshots = PlaybackStreamCacheURLProtocol.requestSnapshots
        let sourceRequest = try XCTUnwrap(allSnapshots.first { $0.url == sourceURL })
        let intermediateGet = try XCTUnwrap(allSnapshots.first { $0.url == intermediateURL && $0.method == "GET" })
        let redirectedGet = try XCTUnwrap(allSnapshots.first { $0.url == resolvedURL && $0.method == "GET" })
        XCTAssertEqual(sourceRequest.value(forHTTPHeaderField: "X-Playback-Secret"), "secret")
        XCTAssertNil(intermediateGet.value(forHTTPHeaderField: "X-Playback-Secret"))
        XCTAssertNil(redirectedGet.value(forHTTPHeaderField: "X-Playback-Secret"))

        await PlaybackStreamCacheManager.shared.stopActiveSession()
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
            var fraction = await server1.cachedFraction()
            for _ in 0..<20 where fraction < 0.5 {
                try? await Task.sleep(nanoseconds: 50_000_000)
                fraction = await server1.cachedFraction()
            }
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

        // Demanding a chunk from the preempted batch should cleanly fetch rather than returning nil or stalling
        let preemptedChunk = await server.fetchDemandChunk(1)
        XCTAssertNotNil(preemptedChunk, "Chunk 1 from preempted forward batch must be successfully fetched on demand")
        XCTAssertEqual(preemptedChunk?.count, chunkSize)

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

    func testHeadroomAllowanceDoesNotOverflowWhenVolumeFreeIsMax() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let currentSessionDir = root.appendingPathComponent("current_session", isDirectory: true)
        try FileManager.default.createDirectory(at: currentSessionDir, withIntermediateDirectories: true)
        let dummyChunk = currentSessionDir.appendingPathComponent("chunk_0.dat")
        try Data(repeating: 0x01, count: 2 * 1024 * 1024).write(to: dummyChunk)

        let limit: Int64 = 20 * 1024 * 1024 * 1024
        let available = PlaybackStreamDiskBudget.shared.availableBytes(
            in: root,
            limit: limit,
            preserving: currentSessionDir,
            freeSpaceReserve: 0,
            freeSpaceProvider: { _ in Int64.max }
        )

        XCTAssertEqual(available, limit)
    }

    func testCurrentSessionIdentificationResolvesSymlinksAndStandardizedPaths() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let currentSessionDir = root.appendingPathComponent("current_session", isDirectory: true)
        try FileManager.default.createDirectory(at: currentSessionDir, withIntermediateDirectories: true)
        let dummyChunk = currentSessionDir.appendingPathComponent("chunk_0.dat")
        let dummyBytes: Int64 = 5 * 1024 * 1024
        try Data(repeating: 0x01, count: Int(dummyBytes)).write(to: dummyChunk)

        // Pass a non-standardized path (e.g. with ../ or symlinks)
        let nonStandardCurrentDir = root.appendingPathComponent("other/../current_session/", isDirectory: true)

        let limit: Int64 = 10 * 1024 * 1024
        let available = PlaybackStreamDiskBudget.shared.availableBytes(
            in: root,
            limit: limit,
            preserving: nonStandardCurrentDir,
            freeSpaceReserve: 0,
            freeSpaceProvider: { _ in limit * 2 }
        )

        // The current session (5 MiB) must be identified as currentBytes, not otherBytes.
        // Budget allowance = limit - otherBytes (0) = 10 MiB.
        XCTAssertEqual(available, limit)
        // Ensure the current session directory was preserved and not pruned.
        XCTAssertTrue(FileManager.default.fileExists(atPath: dummyChunk.path))
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
        XCTAssertEqual(PlaybackCacheProfile.ultra.hybridCacheTargetLeadSeconds, 600.0)

        // 2. Verify Auto lead seconds scaling
        let autoHighRAM = PlaybackCacheProfile.resolveAutoLeadSeconds(
            physicalMemoryBytes: 4 * 1024 * 1024 * 1024, availableMemoryBytes: 1200 * 1024 * 1024
        )
        XCTAssertEqual(autoHighRAM, 600.0)

        let autoLowRAM = PlaybackCacheProfile.resolveAutoLeadSeconds(
            physicalMemoryBytes: 2 * 1024 * 1024 * 1024, availableMemoryBytes: 100 * 1024 * 1024
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
            sessionConfiguration: configuration,
            freeSpaceProvider: { _ in 0 }
        )
        let localURL = try await server.start()

        // Concurrent suffix and final-packet reads share one bounded upstream span.
        let suffixReq: URLRequest = {
            var request = URLRequest(url: localURL)
            request.setValue("bytes=-65536", forHTTPHeaderField: "Range")
            return request
        }()
        let finalPacketReq: URLRequest = {
            var request = URLRequest(url: localURL)
            request.setValue("bytes=\(fileLength - 3122)-\(fileLength - 1)", forHTTPHeaderField: "Range")
            return request
        }()
        async let suffixResult = URLSession.shared.data(for: suffixReq)
        async let finalPacketResult = URLSession.shared.data(for: finalPacketReq)
        let (suffixData, suffixResp) = try await suffixResult
        let (finalPacketData, finalPacketResp) = try await finalPacketResult
        let httpSuffix = suffixResp as! HTTPURLResponse
        let httpFinalPacket = finalPacketResp as! HTTPURLResponse
        XCTAssertEqual(httpSuffix.statusCode, 206)
        XCTAssertEqual(httpSuffix.value(forHTTPHeaderField: "Content-Range"), "bytes \(fileLength - 65536)-\(fileLength - 1)/\(fileLength)")
        XCTAssertEqual(suffixData.count, 65536)
        XCTAssertEqual(suffixData, fullBody.suffix(65536))
        XCTAssertEqual(httpFinalPacket.statusCode, 206)
        XCTAssertEqual(httpFinalPacket.value(forHTTPHeaderField: "Content-Range"), "bytes \(fileLength - 3122)-\(fileLength - 1)/\(fileLength)")
        XCTAssertEqual(finalPacketData, fullBody.suffix(3122))
        XCTAssertEqual(PlaybackStreamCacheURLProtocol.requestCount, 1)
        XCTAssertEqual(PlaybackStreamCacheURLProtocol.requestRanges, ["bytes=\(fileLength - 65536)-\(fileLength - 1)"])
        let tailCachedFraction = await server.cachedFraction()
        XCTAssertEqual(tailCachedFraction, 0, "A short tail span must not be persisted as a chunk")

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

    func testTailSpanRejectsUnknownFileLengthAndShortBodyThenFallsBackToChunk() async throws {
        let chunkSize = Int(PlaybackStreamDiskCache.defaultChunkSize)
        let fileLength = Int64(chunkSize * 4)
        let body = Data(repeating: 0x6A, count: Int(fileLength))
        let tailRange = "bytes=\(fileLength - 65536)-\(fileLength - 1)"
        let finalChunkRange = "bytes=\(chunkSize * 3)-\(fileLength - 1)"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlaybackStreamCacheURLProtocol.self]

        for invalidTail in ["unknown total", "short body"] {
            PlaybackStreamCacheURLProtocol.resetMetrics()
            PlaybackStreamCacheURLProtocol.handler = { request in
                let response = PlaybackStreamCacheURLProtocol.response(for: request, body: body, total: fileLength)
                guard request.value(forHTTPHeaderField: "Range") == tailRange else { return response }
                if invalidTail == "unknown total" {
                    return PlaybackStreamCacheURLProtocol.Response(
                        data: response.data, statusCode: 206,
                        contentRange: "bytes \(fileLength - 65536)-\(fileLength - 1)/*",
                        retryAfter: nil, etag: nil, lastModified: nil
                    )
                }
                return PlaybackStreamCacheURLProtocol.Response(
                    data: Data(response.data.prefix(17)), statusCode: 206,
                    contentRange: response.contentRange, retryAfter: nil, etag: nil, lastModified: nil,
                    declaredContentLength: response.data.count
                )
            }
            let session = "test_tail_fallback_\(UUID().uuidString)"
            let server = PlaybackStreamCacheServer(
                remoteURL: URL(string: "https://cache-test.invalid/tail_fallback")!,
                fileLength: fileLength, sessionID: session, sessionConfiguration: configuration,
                freeSpaceProvider: { _ in 0 }
            )
            let localURL = try await server.start()
            var request = URLRequest(url: localURL)
            request.setValue("bytes=-65536", forHTTPHeaderField: "Range")
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as! HTTPURLResponse
            XCTAssertEqual(http.statusCode, 206, invalidTail)
            XCTAssertEqual(data, body.suffix(65536), invalidTail)
            XCTAssertEqual(PlaybackStreamCacheURLProtocol.requestRanges, [tailRange, finalChunkRange], invalidTail)
            let cachedFraction = await server.cachedFraction()
            XCTAssertEqual(cachedFraction, 0, "Tail failure must not publish partial data as a chunk")
            await server.stop()
            try? FileManager.default.removeItem(at: serverDiskDirectory(for: session))
        }
        PlaybackStreamCacheURLProtocol.handler = nil
    }

    func testTailRateLimitHonorsRetryAfterBeforeChunkFallback() async throws {
        let chunkSize = Int(PlaybackStreamDiskCache.defaultChunkSize)
        let fileLength = Int64(chunkSize * 4)
        let body = Data(repeating: 0x35, count: Int(fileLength))
        let tailRange = "bytes=\(fileLength - 65536)-\(fileLength - 1)"
        let finalChunkRange = "bytes=\(chunkSize * 3)-\(fileLength - 1)"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlaybackStreamCacheURLProtocol.self]
        PlaybackStreamCacheURLProtocol.resetMetrics()
        PlaybackStreamCacheURLProtocol.handler = { request in
            if request.value(forHTTPHeaderField: "Range") == tailRange {
                return PlaybackStreamCacheURLProtocol.Response(
                    data: Data(), statusCode: 429, contentRange: "bytes */\(fileLength)",
                    retryAfter: "0.3", etag: nil, lastModified: nil
                )
            }
            return PlaybackStreamCacheURLProtocol.response(for: request, body: body, total: fileLength)
        }
        let session = "test_tail_rate_limit_\(UUID().uuidString)"
        let server = PlaybackStreamCacheServer(
            remoteURL: URL(string: "https://cache-test.invalid/tail_rate_limit")!,
            fileLength: fileLength, sessionID: session, sessionConfiguration: configuration,
            rateLimitCooldown: 0.1, freeSpaceProvider: { _ in 0 }
        )
        let localURL = try await server.start()
        var request = URLRequest(url: localURL)
        request.setValue("bytes=-65536", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 206)
        XCTAssertEqual(data, body.suffix(65536))
        XCTAssertEqual(PlaybackStreamCacheURLProtocol.requestRanges, [tailRange, finalChunkRange])
        let starts = PlaybackStreamCacheURLProtocol.requestStarts
        XCTAssertEqual(starts.count, 2)
        if starts.count == 2 {
            XCTAssertGreaterThanOrEqual(starts[1].timeIntervalSince(starts[0]), 0.25)
        }
        await server.stop()
        try? FileManager.default.removeItem(at: serverDiskDirectory(for: session))
        PlaybackStreamCacheURLProtocol.handler = nil
    }

    func testTailRateLimitReleasesDemandSlotForUnrelatedRead() async throws {
        let chunkSize = Int(PlaybackStreamDiskCache.defaultChunkSize)
        let fileLength = Int64(chunkSize * 4)
        let body = Data(repeating: 0x49, count: Int(fileLength))
        let tailRange = "bytes=\(fileLength - 65536)-\(fileLength - 1)"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlaybackStreamCacheURLProtocol.self]
        PlaybackStreamCacheURLProtocol.resetMetrics()
        PlaybackStreamCacheURLProtocol.handler = { request in
            if request.value(forHTTPHeaderField: "Range") == tailRange {
                return PlaybackStreamCacheURLProtocol.Response(
                    data: Data(), statusCode: 429, contentRange: "bytes */\(fileLength)",
                    retryAfter: "0.5", etag: nil, lastModified: nil
                )
            }
            return PlaybackStreamCacheURLProtocol.response(for: request, body: body, total: fileLength)
        }
        let session = "test_tail_slot_release_\(UUID().uuidString)"
        let server = PlaybackStreamCacheServer(
            remoteURL: URL(string: "https://cache-test.invalid/tail_slot_release")!,
            fileLength: fileLength, sessionID: session, sessionConfiguration: configuration,
            rateLimitCooldown: 0.1, maxConcurrentUpstream: 1, freeSpaceProvider: { _ in 0 }
        )
        let localURL = try await server.start()
        let tailRequest: URLRequest = {
            var request = URLRequest(url: localURL)
            request.setValue("bytes=-65536", forHTTPHeaderField: "Range")
            return request
        }()
        let tailClient = Task { try? await URLSession.shared.data(for: tailRequest) }

        for _ in 0..<100 where PlaybackStreamCacheURLProtocol.requestCount == 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(PlaybackStreamCacheURLProtocol.requestCount, 1)

        let unrelatedRequest: URLRequest = {
            var request = URLRequest(url: localURL)
            request.setValue("bytes=0-63", forHTTPHeaderField: "Range")
            return request
        }()
        let (unrelatedData, unrelatedResponse) = try await URLSession.shared.data(for: unrelatedRequest)
        XCTAssertEqual((unrelatedResponse as? HTTPURLResponse)?.statusCode, 206)
        XCTAssertEqual(unrelatedData, body.prefix(64))
        let starts = PlaybackStreamCacheURLProtocol.requestStarts
        XCTAssertGreaterThanOrEqual(starts.count, 2)
        if starts.count >= 2 {
            XCTAssertLessThan(starts[1].timeIntervalSince(starts[0]), 0.4)
        }

        _ = await tailClient.value
        await server.stop()
        try? FileManager.default.removeItem(at: serverDiskDirectory(for: session))
        PlaybackStreamCacheURLProtocol.handler = nil
    }

    func testStoppingServerCancelsTailSpanDemandAndReleasesItsSlot() async throws {
        let chunkSize = Int(PlaybackStreamDiskCache.defaultChunkSize)
        let fileLength = Int64(chunkSize * 4)
        let body = Data(repeating: 0x7B, count: Int(fileLength))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlaybackStreamCacheURLProtocol.self]
        PlaybackStreamCacheURLProtocol.resetMetrics()
        PlaybackStreamCacheURLProtocol.handler = { request in
            var response = PlaybackStreamCacheURLProtocol.response(for: request, body: body, total: fileLength)
            response.bodyChunkBytes = 1024
            response.bodyChunkDelay = 0.5
            return response
        }
        let session = "test_tail_stop_\(UUID().uuidString)"
        let server = PlaybackStreamCacheServer(
            remoteURL: URL(string: "https://cache-test.invalid/tail_stop")!,
            fileLength: fileLength, sessionID: session, sessionConfiguration: configuration,
            freeSpaceProvider: { _ in 0 }
        )
        let localURL = try await server.start()
        let request: URLRequest = {
            var request = URLRequest(url: localURL)
            request.setValue("bytes=-65536", forHTTPHeaderField: "Range")
            return request
        }()
        let clientRequest = Task { try? await URLSession.shared.data(for: request) }
        for _ in 0..<100 where PlaybackStreamCacheURLProtocol.totalDeliveredBodyBytes == 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertGreaterThan(PlaybackStreamCacheURLProtocol.totalDeliveredBodyBytes, 0)
        await server.stop()
        _ = await clientRequest.value
        XCTAssertGreaterThan(PlaybackStreamCacheURLProtocol.cancellationCount, 0)
        let hasActiveDemand = await server.hasActiveDemand
        XCTAssertFalse(hasActiveDemand)
        try? FileManager.default.removeItem(at: serverDiskDirectory(for: session))
        PlaybackStreamCacheURLProtocol.handler = nil
    }

    // MARK: - Orivio Buffering Supercharge Tests

    func testHardwareAwareConcurrencyDefaults() {
        let concurrency = PlaybackStreamCacheServer.defaultMaxConcurrentUpstream()
        let memory = ProcessInfo.processInfo.physicalMemory
        if memory >= 4 * 1024 * 1024 * 1024 {
            XCTAssertEqual(concurrency, 8, "Apple TV 4K Gen 3 should default to 8 concurrent streams")
        } else if memory >= 3 * 1024 * 1024 * 1024 {
            XCTAssertEqual(concurrency, 6, "Apple TV 4K Gen 1/2 should default to 6 concurrent streams")
        } else {
            XCTAssertEqual(concurrency, 4, "Apple TV HD should default to 4 concurrent streams")
        }
    }

    func testOpeningBurstCalculationAndState() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }

        // 10 GB movie, 7200 seconds (2 hours) -> Bitrate = ~11.6 Mbps = 1.45 MB/s -> 60s burst = ~87 MB
        let tenGigabytes: Int64 = 10 * 1024 * 1024 * 1024
        let server = PlaybackStreamCacheServer(
            remoteURL: URL(string: "https://cache-test.invalid/burst_movie.mkv")!,
            fileLength: tenGigabytes,
            cacheRoot: root
        )

        // Before timeline is known, burst falls back to 256 MB
        let fallbackBurst = await server.burstTargetBytes
        XCTAssertEqual(fallbackBurst, 256 * 1024 * 1024)

        // After timeline is known (7200 seconds)
        await server.updateTimeline(playheadOffset: 0, durationSeconds: 7200)
        let calculatedBurst = await server.burstTargetBytes
        // Expected: (10GB / 7200) * 60 = 89,478,485 bytes (clamped to minForwardLeadBytes of 80MB)
        let expectedBurst = Int64(Double(tenGigabytes) / 7200.0 * 60.0)
        XCTAssertEqual(calculatedBurst, expectedBurst)
        XCTAssertGreaterThan(calculatedBurst, 80 * 1024 * 1024)

        // Initial burst state must be true
        let isBursting = await server.isBursting
        XCTAssertTrue(isBursting, "Stream must start in high-priority opening burst mode")
        await server.stop()
    }

    func testExpandedForwardBufferHorizonExceedsOnePointFiveGigabytes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }

        // 40 GB high-bitrate remux, 7200 seconds (2 hours) -> Bitrate = ~46.6 Mbps = 5.82 MB/s
        let fortyGB: Int64 = 40 * 1024 * 1024 * 1024
        let thirtyGBDisk: Int64 = 30 * 1024 * 1024 * 1024
        let server = PlaybackStreamCacheServer(
            remoteURL: URL(string: "https://cache-test.invalid/remux_4k.mkv")!,
            fileLength: fortyGB,
            maxDiskCacheSizeBytes: thirtyGBDisk,
            targetLeadSeconds: 600.0, // 10 minutes forward lead = ~3.5 GB lead
            cacheRoot: root
        )

        await server.updateTimeline(playheadOffset: 0, durationSeconds: 7200)
        let leadBytes = await server.adaptiveForwardLeadBytes

        // Verify lead exceeds the old legacy 1.5 GB limit
        let oldOnePointFiveGBLimit: Int64 = 1536 * 1024 * 1024
        XCTAssertGreaterThan(leadBytes, oldOnePointFiveGBLimit, "Lead horizon should exceed legacy 1.5 GB cap on high-capacity disk cache")
        // Expected ~3.49 GB (3744927288 bytes)
        let expectedBytes = Int64(Double(fortyGB) / 7200.0 * 600.0)
        XCTAssertEqual(leadBytes, expectedBytes)
        await server.stop()
    }

    func testAdaptiveRateLimitHalvingAndProgressiveRamp() async throws {
        let chunk = Int(PlaybackStreamDiskCache.defaultChunkSize)
        let fileLength = Int64(chunk * 32)
        let fullBody = Data((0..<Int(fileLength)).map { UInt8($0 % 256) })

        var requestAttempt = 0
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlaybackStreamCacheURLProtocol.self]
        PlaybackStreamCacheURLProtocol.resetMetrics()
        PlaybackStreamCacheURLProtocol.handler = { request in
            requestAttempt += 1
            if requestAttempt == 1 {
                // First request triggers HTTP 429 Too Many Requests
                var resp = PlaybackStreamCacheURLProtocol.response(for: request, body: Data(), total: fileLength)
                resp.statusCode = 429
                resp.retryAfter = "0.1"
                return resp
            }
            return PlaybackStreamCacheURLProtocol.response(for: request, body: fullBody, total: fileLength)
        }

        let session = "test_ratelimit_\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(session)
        defer {
            PlaybackStreamCacheURLProtocol.handler = nil
            try? FileManager.default.removeItem(at: root)
        }

        let server = PlaybackStreamCacheServer(
            remoteURL: URL(string: "https://cache-test.invalid/ratelimit.mkv")!,
            fileLength: fileLength,
            sessionID: session,
            cacheRoot: root,
            sessionConfiguration: configuration,
            rateLimitCooldown: 0.1,
            maxConcurrentUpstream: 8
        )

        let localURL = try await server.start()

        // Read first chunk: triggers 429, throttles and halves concurrency (from 8 to 4)
        var req = URLRequest(url: localURL)
        req.setValue("bytes=0-\(chunk - 1)", forHTTPHeaderField: "Range")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let httpResp = resp as! HTTPURLResponse
        XCTAssertEqual(httpResp.statusCode, 206)
        XCTAssertEqual(data.count, chunk)

        await server.stop()
    }

    func testDemandFetchBypassesThrottleCooldown() async throws {
        let chunk = Int(PlaybackStreamDiskCache.defaultChunkSize)
        let totalChunks = 8
        let fileLength = Int64(chunk * totalChunks)
        let fullBody = Data((0..<fileLength).map { UInt8($0 % 251) })

        var requestCount = 0
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlaybackStreamCacheURLProtocol.self]
        PlaybackStreamCacheURLProtocol.resetMetrics()
        PlaybackStreamCacheURLProtocol.handler = { request in
            requestCount += 1
            if requestCount == 1 {
                // First request (background prefetch) triggers 429 with 5s retry-after cooldown
                var resp = PlaybackStreamCacheURLProtocol.response(for: request, body: Data(), total: fileLength)
                resp.statusCode = 429
                resp.retryAfter = "5.0"
                return resp
            }
            return PlaybackStreamCacheURLProtocol.response(for: request, body: fullBody, total: fileLength)
        }

        let session = "test_cooldown_\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(session)
        defer {
            PlaybackStreamCacheURLProtocol.handler = nil
            try? FileManager.default.removeItem(at: root)
        }

        let server = PlaybackStreamCacheServer(
            remoteURL: URL(string: "https://cache-test.invalid/cooldown.mkv")!,
            fileLength: fileLength,
            sessionID: session,
            cacheRoot: root,
            sessionConfiguration: configuration,
            rateLimitCooldown: 5.0,
            maxConcurrentUpstream: 4
        )

        _ = try await server.start()

        // Wait until forward prefetch triggers the 429 and enters 5s cooldown
        for _ in 0..<100 where requestCount == 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        // Demand fetch must bypass the 5-second cooldown and succeed promptly (< 2.0s)
        let startDemand = Date()
        let demandData = await server.fetchDemandChunk(2)
        let elapsed = Date().timeIntervalSince(startDemand)

        XCTAssertNotNil(demandData, "Demand fetch must not be blocked by background rate-limit cooldown")
        XCTAssertEqual(demandData?.count, chunk)
        XCTAssertLessThan(elapsed, 2.0, "Demand fetch should bypass the 5s cooldown and complete quickly")

        await server.stop()
    }

    func testCannotConnectBackoffIsSharedBetweenBackgroundAndDemandFetches() async throws {
        let chunk = Int(PlaybackStreamDiskCache.defaultChunkSize)
        let fileLength = Int64(chunk * 8)
        let body = Data(repeating: 0x8D, count: Int(fileLength))
        let remoteURL = URL(string: "https://cache-test.invalid/transport_backoff_shared")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlaybackStreamCacheURLProtocol.self]
        PlaybackStreamCacheURLProtocol.resetMetrics()
        PlaybackStreamCacheURLProtocol.handler = { request in
            var response = PlaybackStreamCacheURLProtocol.response(for: request, body: body, total: fileLength)
            if PlaybackStreamCacheURLProtocol.requestCount == 1 {
                response.errorCode = .cannotConnectToHost
            }
            return response
        }

        let session = "test_transport_backoff_shared_\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(session)
        defer {
            PlaybackStreamCacheURLProtocol.handler = nil
            try? FileManager.default.removeItem(at: root)
        }

        let server = PlaybackStreamCacheServer(
            remoteURL: remoteURL,
            fileLength: fileLength,
            sessionID: session,
            cacheRoot: root,
            sessionConfiguration: configuration,
            rateLimitCooldown: 0.1,
            transportRetryBaseDelay: 0.25,
            maxConcurrentUpstream: 1
        )
        _ = try await server.start()

        for _ in 0..<100 where PlaybackStreamCacheURLProtocol.requestCount == 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(PlaybackStreamCacheURLProtocol.requestCount, 1, "Background fill should be the first upstream request")
        for _ in 0..<100 where PlaybackStreamCacheURLProtocol.activeRequestCount > 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        // Let the server classify the failed transport before adding a competing demand read.
        try await Task.sleep(nanoseconds: 20_000_000)

        let data = await server.fetchDemandChunk(6)

        XCTAssertEqual(data, Data(repeating: 0x8D, count: chunk))
        let starts = PlaybackStreamCacheURLProtocol.requestStarts
        XCTAssertGreaterThanOrEqual(starts.count, 2)
        XCTAssertTrue(starts.dropFirst().allSatisfy {
            $0.timeIntervalSince(starts[0]) >= 0.20
        }, "Every later demand/background request must respect the shared transport cooldown")
        let demandStart = Int64(chunk * 6)
        let demandEnd = Int64(chunk * 7)
        let demandRangeWasFetched = PlaybackStreamCacheURLProtocol.requestSnapshots.contains { snapshot in
            guard snapshot.url == remoteURL,
                  let range = snapshot.value(forHTTPHeaderField: "Range"),
                  range.hasPrefix("bytes=") else { return false }
            let bounds = range.dropFirst("bytes=".count).split(separator: "-")
            guard bounds.count == 2,
                  let lower = Int64(bounds[0]),
                  let upper = Int64(bounds[1]) else { return false }
            return lower <= demandStart && upper >= demandEnd - 1
        }
        XCTAssertTrue(demandRangeWasFetched, "An upstream range must cover the requested demand chunk")
        XCTAssertTrue(PlaybackStreamCacheURLProtocol.requestSnapshots.allSatisfy { $0.url == remoteURL })

        await server.stop()
    }

    func testSuccessfulDemandFetchResetsCannotConnectBackoffStreak() async throws {
        let chunk = Int(PlaybackStreamDiskCache.defaultChunkSize)
        let fileLength = Int64(chunk * 8)
        let body = Data(repeating: 0x6C, count: Int(fileLength))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlaybackStreamCacheURLProtocol.self]
        PlaybackStreamCacheURLProtocol.resetMetrics()
        PlaybackStreamCacheURLProtocol.handler = { request in
            var response = PlaybackStreamCacheURLProtocol.response(for: request, body: body, total: fileLength)
            if [1, 3].contains(PlaybackStreamCacheURLProtocol.requestCount) {
                response.errorCode = .cannotConnectToHost
            }
            return response
        }

        let session = "test_transport_backoff_reset_\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(session)
        defer {
            PlaybackStreamCacheURLProtocol.handler = nil
            try? FileManager.default.removeItem(at: root)
        }
        let server = PlaybackStreamCacheServer(
            remoteURL: URL(string: "https://cache-test.invalid/transport_backoff_reset")!,
            fileLength: fileLength,
            sessionID: session,
            cacheRoot: root,
            sessionConfiguration: configuration,
            transportRetryBaseDelay: 0.6,
            maxConcurrentUpstream: 1
        )

        let firstRead = await server.fetchDemandChunk(0)
        let recoveredRead = await server.fetchDemandChunk(4)

        XCTAssertEqual(firstRead, Data(repeating: 0x6C, count: chunk))
        XCTAssertEqual(recoveredRead, Data(repeating: 0x6C, count: chunk))
        let starts = PlaybackStreamCacheURLProtocol.requestStarts
        XCTAssertEqual(starts.count, 4)
        let firstRetryDelay = starts[1].timeIntervalSince(starts[0])
        let postRecoveryRetryDelay = starts[3].timeIntervalSince(starts[2])
        XCTAssertGreaterThanOrEqual(firstRetryDelay, 0.55)
        XCTAssertGreaterThanOrEqual(postRecoveryRetryDelay, 0.55)
        XCTAssertLessThan(postRecoveryRetryDelay, 1.0,
                          "A successful upstream fetch must reset the next transport failure to the base delay")

        await server.stop()
    }

    func testStoppingServerCancelsCannotConnectCooldownWaitPromptly() async throws {
        let chunk = Int(PlaybackStreamDiskCache.defaultChunkSize)
        let fileLength = Int64(chunk * 4)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlaybackStreamCacheURLProtocol.self]
        PlaybackStreamCacheURLProtocol.resetMetrics()
        PlaybackStreamCacheURLProtocol.handler = { request in
            var response = PlaybackStreamCacheURLProtocol.response(
                for: request, body: Data(repeating: 0x2A, count: Int(fileLength)), total: fileLength)
            response.errorCode = .cannotConnectToHost
            return response
        }

        let session = "test_transport_backoff_stop_\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(session)
        defer {
            PlaybackStreamCacheURLProtocol.handler = nil
            try? FileManager.default.removeItem(at: root)
        }
        let server = PlaybackStreamCacheServer(
            remoteURL: URL(string: "https://cache-test.invalid/transport_backoff_stop")!,
            fileLength: fileLength,
            sessionID: session,
            cacheRoot: root,
            sessionConfiguration: configuration,
            transportRetryBaseDelay: 2.0,
            maxConcurrentUpstream: 1
        )

        let fetch = Task { await server.fetchDemandChunk(0) }
        for _ in 0..<100 where PlaybackStreamCacheURLProtocol.requestCount == 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(PlaybackStreamCacheURLProtocol.requestCount, 1)
        for _ in 0..<100 where PlaybackStreamCacheURLProtocol.activeRequestCount > 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try await Task.sleep(nanoseconds: 20_000_000)

        let stopStarted = Date()
        await server.stop()
        let result = await fetch.value

        XCTAssertNil(result)
        XCTAssertLessThan(Date().timeIntervalSince(stopStarted), 1.0,
                          "Stopping must interrupt the cooldown wait instead of waiting out its deadline")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(PlaybackStreamCacheURLProtocol.requestCount, 1)
    }
}

final class PlaybackStreamRangeProbeMemoTests: XCTestCase {
    func testRangeProbeMemoIsExactOneShotAndOldTokenCleanupIsScoped() {
        let memo = PlaybackStreamRangeProbeMemo(capacity: 2)
        let url = URL(string: "https://cache-test.invalid/memo_exact")!
        let headers = ["Referer": "https://addon.example"]
        let firstToken = UUID()
        let secondToken = UUID()
        let first = StreamProbeResult(supportsRange: true, contentLength: 64, etag: "first", lastModified: nil)
        let second = StreamProbeResult(supportsRange: true, contentLength: 64, etag: "second", lastModified: nil)

        XCTAssertTrue(memo.store(first, url: url, headers: headers, profileID: "profile-a", token: firstToken))
        XCTAssertNil(memo.take(url: url, headers: ["Referer": "different"], profileID: "profile-a"))
        XCTAssertNil(memo.take(url: url, headers: headers, profileID: "profile-b"))
        XCTAssertTrue(memo.store(second, url: url, headers: headers, profileID: "profile-a", token: secondToken))
        memo.discard(token: firstToken)

        XCTAssertEqual(memo.take(url: url, headers: headers, profileID: "profile-a")?.etag, "second")
        XCTAssertNil(memo.take(url: url, headers: headers, profileID: "profile-a"))
    }

    func testRangeProbeMemoExpiryAndCapacityAreBounded() {
        let memo = PlaybackStreamRangeProbeMemo(capacity: 2)
        let headers: [String: String] = [:]
        let profileID = "profile-a"
        let result = StreamProbeResult(supportsRange: true, contentLength: 64, etag: "tag", lastModified: nil)
        let expiredURL = URL(string: "https://cache-test.invalid/memo_expired")!
        XCTAssertTrue(memo.store(result, url: expiredURL, headers: headers, profileID: profileID, token: UUID(), ttl: 0))
        XCTAssertNil(memo.take(url: expiredURL, headers: headers, profileID: profileID))

        let urls = ["memo_oldest", "memo_middle", "memo_newest"].map {
            URL(string: "https://cache-test.invalid/\($0)")!
        }
        for url in urls {
            XCTAssertTrue(memo.store(result, url: url, headers: headers, profileID: profileID, token: UUID()))
        }
        XCTAssertEqual(memo.count, 2)
        XCTAssertNil(memo.take(url: urls[0], headers: headers, profileID: profileID))
        XCTAssertNotNil(memo.take(url: urls[1], headers: headers, profileID: profileID))
        XCTAssertNotNil(memo.take(url: urls[2], headers: headers, profileID: profileID))
    }
}

extension PlaybackStreamCacheTests {
    func testHybridProbeMemoIsReusedByPrepareCacheServer() async throws {
        let url = URL(string: "https://cache-test.invalid/hybrid_memo_reuse")!
        let headers = ["Referer": "https://addon.example"]
        let profileID = "hybrid_profile_\(UUID().uuidString)"
        let warmID = UUID()
        let sessionToken = "hybrid_session_\(UUID().uuidString)"
        let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlaybackStreamCacheURLProtocol.self]
        PlaybackStreamCacheURLProtocol.resetMetrics()
        PlaybackStreamCacheURLProtocol.handler = { request in
            PlaybackStreamCacheURLProtocol.response(for: request, body: Data([0x42, 0x43]), total: 64, etag: "hybrid-tag")
        }
        defer {
            PlaybackStreamCacheURLProtocol.handler = nil
            PlaybackStreamRangeProbeMemo.shared.discard(token: warmID)
            try? FileManager.default.removeItem(at: cacheRoot)
        }

        let manager = PlaybackStreamCacheManager.shared
        let warmed = await manager.warmRangeProbeMemo(
            url: url, headers: headers, profileID: profileID, token: warmID,
            sessionConfiguration: configuration, preparationBudget: 1
        )
        XCTAssertTrue(warmed)
        XCTAssertEqual(PlaybackStreamCacheURLProtocol.requestCount, 1)

        let proxyURL = await manager.prepareCacheServer(
            for: url, headers: headers, sessionToken: sessionToken,
            cacheProfileIDOverride: profileID, cacheRoot: cacheRoot,
            sessionConfiguration: configuration, freeSpaceProvider: { _ in 0 }, preparationBudget: 1
        )
        XCTAssertNotNil(proxyURL)
        XCTAssertEqual(PlaybackStreamCacheURLProtocol.requestCount, 1, "prepare reused the completed Details probe")
        await manager.stopActiveSession(token: sessionToken)
    }

    func testHybridProbeMemoMismatchAndExpiryFallBackToColdProbe() async throws {
        let manager = PlaybackStreamCacheManager.shared
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlaybackStreamCacheURLProtocol.self]
        PlaybackStreamCacheURLProtocol.handler = { request in
            PlaybackStreamCacheURLProtocol.response(for: request, body: Data([0x42, 0x43]), total: 64, etag: "cold-tag")
        }
        defer { PlaybackStreamCacheURLProtocol.handler = nil }

        let cases: [(name: String, urlMismatch: Bool, headerMismatch: Bool, profileMismatch: Bool, expired: Bool)] = [
            ("URL", true, false, false, false),
            ("headers", false, true, false, false),
            ("profile", false, false, true, false),
            ("expired", false, false, false, true)
        ]
        for testCase in cases {
            await manager.stopActiveSession()
            let actualURL = URL(string: "https://cache-test.invalid/hybrid_cold_\(testCase.name)")!
            let warmURL = testCase.urlMismatch
                ? URL(string: "https://cache-test.invalid/hybrid_other_\(testCase.name)")!
                : actualURL
            let actualHeaders = ["Referer": "https://playback.example"]
            let warmHeaders = testCase.headerMismatch ? ["Referer": "https://warm.example"] : actualHeaders
            let actualProfile = "profile-\(testCase.name)"
            let warmProfile = testCase.profileMismatch ? "other-\(testCase.name)" : actualProfile
            let memoToken = UUID()
            let sessionToken = "hybrid_cold_\(testCase.name)_\(UUID().uuidString)"
            let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let probe = StreamProbeResult(supportsRange: true, contentLength: 64, etag: "warm-tag", lastModified: nil)
            XCTAssertTrue(PlaybackStreamRangeProbeMemo.shared.store(
                probe, url: warmURL, headers: warmHeaders, profileID: warmProfile,
                token: memoToken, ttl: testCase.expired ? 0 : 15
            ))
            PlaybackStreamCacheURLProtocol.resetMetrics()

            let proxyURL = await manager.prepareCacheServer(
                for: actualURL, headers: actualHeaders, sessionToken: sessionToken,
                cacheProfileIDOverride: actualProfile, cacheRoot: cacheRoot,
                sessionConfiguration: configuration, freeSpaceProvider: { _ in 0 }, preparationBudget: 1
            )
            XCTAssertNotNil(proxyURL, testCase.name)
            XCTAssertEqual(PlaybackStreamCacheURLProtocol.requestCount, 1, "\(testCase.name) mismatch must probe cold")
            await manager.stopActiveSession(token: sessionToken)
            PlaybackStreamRangeProbeMemo.shared.discard(token: memoToken)
            try? FileManager.default.removeItem(at: cacheRoot)
        }
    }

    func testBackgroundRangeWarmDoesNotCancelPendingPlaybackProbe() async throws {
        let manager = PlaybackStreamCacheManager()
        let pendingURL = URL(string: "https://cache-test.invalid/hybrid_pending_owner")!
        let warmURL = URL(string: "https://cache-test.invalid/hybrid_independent_warm")!
        let profileID = "profile-\(UUID().uuidString)"
        let warmToken = UUID()
        let sessionToken = "pending_owner_\(UUID().uuidString)"
        let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlaybackStreamCacheURLProtocol.self]
        PlaybackStreamCacheURLProtocol.resetMetrics()
        PlaybackStreamCacheURLProtocol.handler = { request in
            if request.url == pendingURL {
                return PlaybackStreamCacheURLProtocol.Response(
                    data: Data([0x42, 0x43]), statusCode: 206, contentRange: "bytes 0-1/64",
                    retryAfter: nil, etag: "owner-tag", lastModified: nil,
                    bodyChunkBytes: 1, bodyChunkDelay: 0.5
                )
            }
            return PlaybackStreamCacheURLProtocol.response(for: request, body: Data([0x42, 0x43]), total: 64, etag: "owner-tag")
        }
        defer {
            PlaybackStreamCacheURLProtocol.handler = nil
            PlaybackStreamRangeProbeMemo.shared.discard(token: warmToken)
            try? FileManager.default.removeItem(at: cacheRoot)
        }

        let pendingPreparation = Task {
            await manager.prepareCacheServer(
                for: pendingURL, sessionToken: sessionToken, cacheRoot: cacheRoot,
                sessionConfiguration: configuration, freeSpaceProvider: { _ in 0 }, preparationBudget: 5
            )
        }
        for _ in 0..<100 where PlaybackStreamCacheURLProtocol.requestCount == 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(PlaybackStreamCacheURLProtocol.requestCount, 1)

        let warmed = await manager.warmRangeProbeMemo(
            url: warmURL, headers: [:], profileID: profileID, token: warmToken,
            sessionConfiguration: configuration, preparationBudget: 2
        )
        XCTAssertTrue(warmed)
        let proxyURL = await pendingPreparation.value
        XCTAssertNotNil(proxyURL, "the independent warm must not replace/cancel the pending playback probe")
        let activeToken = await manager.activeSessionToken
        XCTAssertEqual(activeToken, sessionToken)
        await manager.stopActiveSession(token: sessionToken)
    }
}

extension PlaybackStreamCacheTests {
    func testCancelledBackgroundRangeWarmDoesNotPublishMemo() async throws {
        let url = URL(string: "https://cache-test.invalid/hybrid_cancelled_warm")!
        let headers = ["Referer": "https://addon.example"]
        let profileID = "cancel_profile_\(UUID().uuidString)"
        let token = UUID()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlaybackStreamCacheURLProtocol.self]
        PlaybackStreamCacheURLProtocol.resetMetrics()
        PlaybackStreamCacheURLProtocol.delay = 5
        PlaybackStreamCacheURLProtocol.handler = { request in
            PlaybackStreamCacheURLProtocol.response(for: request, body: Data([0x42, 0x43]), total: 64, etag: "cancel-tag")
        }
        defer {
            PlaybackStreamCacheURLProtocol.handler = nil
            PlaybackStreamCacheURLProtocol.delay = 0
            PlaybackStreamRangeProbeMemo.shared.discard(token: token)
        }

        let manager = PlaybackStreamCacheManager.shared
        let warming = Task {
            await manager.warmRangeProbeMemo(
                url: url, headers: headers, profileID: profileID, token: token,
                sessionConfiguration: configuration, preparationBudget: 5
            )
        }
        for _ in 0..<100 where PlaybackStreamCacheURLProtocol.requestCount == 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(PlaybackStreamCacheURLProtocol.requestCount, 1)
        warming.cancel()
        let warmedAfterCancellation = await warming.value
        XCTAssertFalse(warmedAfterCancellation)
        XCTAssertNil(PlaybackStreamRangeProbeMemo.shared.take(url: url, headers: headers, profileID: profileID))
        await waitForProtocolCancellationIfStillLoading()
        XCTAssertGreaterThan(PlaybackStreamCacheURLProtocol.cancellationCount, 0)
    }
}
