import XCTest
import CoreGraphics
import AetherEngine
@testable import NuvioTV

/// Serves byte ranges of an in-memory file, records every request, and can answer with a status
/// or a redirect instead.
private final class SeekPreviewStubProtocol: URLProtocol {
    enum Reply {
        case ranges(Data)
        case status(Int)
        case wholeFile(Data)
        case redirect(to: URL)
    }

    private static let lock = NSLock()
    private static var replies: [String: Reply] = [:]
    private static var recorded: [URLRequest] = []

    static func install(_ reply: Reply, forHost host: String) {
        lock.lock()
        replies[host] = reply
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        replies.removeAll()
        recorded.removeAll()
        lock.unlock()
    }

    static var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.recorded.append(request)
        let reply = request.url?.host.flatMap { Self.replies[$0] }
        Self.lock.unlock()
        guard let url = request.url, let reply else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        switch reply {
        case .ranges(let file):
            guard let range = Self.parseRange(request.value(forHTTPHeaderField: "Range")),
                  range.lowerBound < file.count else {
                send(url: url, status: 416, headers: [:], body: Data())
                return
            }
            let upper = min(range.upperBound, file.count - 1)
            let body = file.subdata(in: range.lowerBound..<(upper + 1))
            send(url: url, status: 206,
                 headers: ["Content-Range": "bytes \(range.lowerBound)-\(upper)/\(file.count)"],
                 body: body)
        case .status(let code):
            send(url: url, status: code, headers: [:], body: Data())
        case .wholeFile(let file):
            send(url: url, status: 200, headers: [:], body: file)
        case .redirect(let target):
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                                           headerFields: ["Location": target.absoluteString])!
            var next = request
            next.url = target
            // The client cancels this load and starts a new one for `next`.
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
        }
    }

    override func stopLoading() {}

    private func send(url: URL, status: Int, headers: [String: String], body: Data) {
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    static func parseRange(_ header: String?) -> ClosedRange<Int>? {
        guard let header, header.hasPrefix("bytes=") else { return nil }
        let parts = header.dropFirst("bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, let start = Int(parts[0]), let end = Int(parts[1]), end >= start else { return nil }
        return start...end
    }
}

final class SeekPreviewLaneTests: XCTestCase {
    override func setUp() {
        super.setUp()
        SeekPreviewStubProtocol.reset()
    }

    override func tearDown() {
        SeekPreviewStubProtocol.reset()
        super.tearDown()
    }

    private func makeTransport(origin: URL) -> SeekPreviewRangeTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SeekPreviewStubProtocol.self]
        return SeekPreviewRangeTransport(originURL: origin, headers: ["User-Agent": "NuvioTests"],
                                         configuration: configuration)
    }

    private func makeFile(bytes: Int) -> Data {
        Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
    }

    /// The transport blocks its caller; keep that off the test's own thread.
    private func offMain<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await Task.detached { body() }.value
    }

    // MARK: Policy

    func testOptionOffWaitsForAetherToReleaseItsPausedConnection() {
        func decide(paused: Bool, pausedFor: TimeInterval?, playing: Bool) -> SeekPreviewNetworkPolicy.Decision {
            SeekPreviewNetworkPolicy.aether(
                beyondBuffer: false, isPaused: paused, pausedFor: pausedFor, isPlaying: playing,
                forwardBufferSeconds: 60, throughputMbps: 200, bitrateMbps: 20)
        }
        XCTAssertEqual(decide(paused: true, pausedFor: 1, playing: false), .pauseTooRecent)
        XCTAssertEqual(decide(paused: true, pausedFor: nil, playing: false), .pauseTooRecent)
        XCTAssertEqual(decide(paused: true, pausedFor: 6, playing: false), .allowed)
        XCTAssertEqual(decide(paused: false, pausedFor: nil, playing: true), .playing)
        XCTAssertEqual(decide(paused: false, pausedFor: nil, playing: false), .busy)
    }

    func testOptionOnAdmitsPlaybackOnlyWithAHealthyBuffer() {
        func decide(buffer: Double?, throughput: Double?, bitrate: Double?) -> SeekPreviewNetworkPolicy.Decision {
            SeekPreviewNetworkPolicy.aether(
                beyondBuffer: true, isPaused: false, pausedFor: nil, isPlaying: true,
                forwardBufferSeconds: buffer, throughputMbps: throughput, bitrateMbps: bitrate)
        }
        XCTAssertEqual(decide(buffer: 30, throughput: 100, bitrate: 20), .allowed)
        XCTAssertEqual(decide(buffer: 30, throughput: nil, bitrate: 20), .allowed)
        XCTAssertEqual(decide(buffer: 8, throughput: 100, bitrate: 20), .bufferLow)
        XCTAssertEqual(decide(buffer: nil, throughput: 100, bitrate: 20), .bufferLow)
        XCTAssertEqual(decide(buffer: 30, throughput: 25, bitrate: 20), .throughputLow)
        XCTAssertEqual(
            SeekPreviewNetworkPolicy.aether(
                beyondBuffer: true, isPaused: true, pausedFor: 0.2, isPlaying: false,
                forwardBufferSeconds: nil, throughputMbps: nil, bitrateMbps: nil),
            .allowed)
    }

    func testChapterStillsLoadWhateverTheBufferOrOption() {
        XCTAssertEqual(SeekPreviewNetworkPolicy.chapterThumbnails(), .allowed)
    }

    func testUsenetPreviewsDoNotWaitForThePausedConnection() {
        XCTAssertEqual(
            SeekPreviewNetworkPolicy.aether(
                beyondBuffer: false, isPaused: true, pausedFor: 0.5, isPlaying: false,
                forwardBufferSeconds: nil, throughputMbps: nil, bitrateMbps: nil,
                playbackHoldsConnection: false),
            .allowed)
        XCTAssertEqual(
            SeekPreviewNetworkPolicy.aether(
                beyondBuffer: false, isPaused: false, pausedFor: nil, isPlaying: true,
                forwardBufferSeconds: 60, throughputMbps: nil, bitrateMbps: nil,
                playbackHoldsConnection: false),
            .playing, "during playback the option still decides")
    }

    func testUsenetPreviewPathMapsOnlyStreamURLs() {
        XCTAssertEqual(
            UsenetStreamServer.previewURL(for: URL(string: "http://127.0.0.1:5000/usenet/ABC/video.mkv")!),
            URL(string: "http://127.0.0.1:5000/usenet/ABC/preview/video.mkv")!)
        XCTAssertNil(UsenetStreamServer.previewURL(for: URL(string: "http://127.0.0.1:5000/usenet/ABC/preview/video.mkv")!))
        XCTAssertNil(UsenetStreamServer.previewURL(for: URL(string: "https://example.com/usenet/ABC/video.mkv")!))
        XCTAssertNil(UsenetStreamServer.previewURL(for: URL(string: "http://127.0.0.1:5000/stream/ABC/video.mkv")!))
    }

    func testMPVPauseAdmitsAtOnceAndPlaybackFollowsTheOption() {
        XCTAssertEqual(SeekPreviewNetworkPolicy.mpv(beyondBuffer: false, isPaused: true, isPlaying: false, cacheSeconds: nil), .allowed)
        XCTAssertEqual(SeekPreviewNetworkPolicy.mpv(beyondBuffer: false, isPaused: false, isPlaying: true, cacheSeconds: 60), .playing)
        XCTAssertEqual(SeekPreviewNetworkPolicy.mpv(beyondBuffer: true, isPaused: false, isPlaying: true, cacheSeconds: 60), .allowed)
        XCTAssertEqual(SeekPreviewNetworkPolicy.mpv(beyondBuffer: true, isPaused: false, isPlaying: true, cacheSeconds: 4), .bufferLow)
    }

    func testPreviewOriginServesOnlyRemoteProgressiveSources() {
        let remote = URL(string: "https://store-1.torbox.example/dl/file.mkv?token=a")!
        XCTAssertEqual(origin(playback: remote), remote)
        XCTAssertNil(origin(playback: remote, isLive: true))
        XCTAssertNil(origin(playback: remote, isKnownHLS: true))
        XCTAssertNil(origin(playback: URL(string: "https://cdn.example/master.m3u8")!))
        XCTAssertNil(origin(playback: URL(string: "https://cdn.example/disc.iso")!))
        XCTAssertNil(origin(playback: URL(string: "http://127.0.0.1:8090/play/abc")!))
        XCTAssertEqual(origin(playback: URL(string: "http://127.0.0.1:9000/usenet/token/video.mkv")!),
                       URL(string: "http://127.0.0.1:9000/usenet/token/preview/video.mkv")!,
                       "a Usenet stream is read through its preview path")
        XCTAssertNil(origin(playback: URL(string: "http://127.0.0.1:9000/usenet/token/video.mkv")!, isLive: true))
        XCTAssertNil(origin(playback: URL(fileURLWithPath: "/tmp/movie.mkv")))

        let proxy = URL(string: "http://127.0.0.1:7000/stream/session/file.mkv")!
        XCTAssertNil(origin(playback: proxy), "a cache proxy needs its descriptor or header source")
        XCTAssertEqual(origin(playback: proxy, descriptor: remote), remote)
        XCTAssertEqual(origin(playback: proxy, headerSource: remote), remote)
    }

    private func origin(playback: URL, headerSource: URL? = nil, descriptor: URL? = nil,
                        isLive: Bool = false, isKnownHLS: Bool = false) -> URL? {
        SeekPreviewNetworkPolicy.previewOrigin(
            playbackURL: playback, headerSourceURL: headerSource, descriptorRemoteURL: descriptor,
            isLive: isLive, isKnownHLS: isKnownHLS)
    }

    // MARK: Grid

    func testGridCellsAreFiveSecondsAndDecodeAtTheirMiddle() {
        XCTAssertEqual(SeekPreviewGrid.cell(for: 0, duration: 600), 0)
        XCTAssertEqual(SeekPreviewGrid.cell(for: 4.9, duration: 600), 0)
        XCTAssertEqual(SeekPreviewGrid.cell(for: 5, duration: 600), 1)
        XCTAssertEqual(SeekPreviewGrid.cell(for: 600, duration: 600), 119, "the end clamps into the last cell")
        XCTAssertNil(SeekPreviewGrid.cell(for: -1, duration: 600))
        XCTAssertNil(SeekPreviewGrid.cell(for: .nan, duration: 600))
        XCTAssertEqual(SeekPreviewGrid.center(of: 3), 17.5)
        XCTAssertEqual(SeekPreviewGrid.storageSeconds(of: 3), 15)
    }

    func testStoryboardSpreadsSixteenDistinctCellsOverTheTitle() {
        let cells = SeekPreviewGrid.storyboardCells(duration: 2_700, count: 16)
        XCTAssertEqual(cells.count, 16)
        XCTAssertEqual(Set(cells).count, 16)
        XCTAssertEqual(cells.first, SeekPreviewGrid.cell(for: 2_700 / 32, duration: 2_700))
        XCTAssertTrue(cells.allSatisfy { $0 >= 0 && $0 <= 539 })
        XCTAssertEqual(SeekPreviewGrid.storyboardCells(duration: 20, count: 16).count, 4, "short titles dedupe")
    }

    func testNeighborsFollowTheScrubDirectionInsideTheTitle() {
        XCTAssertEqual(SeekPreviewGrid.neighbors(of: 10, direction: 1, count: 2, lastCell: 100), [11, 12])
        XCTAssertEqual(SeekPreviewGrid.neighbors(of: 10, direction: -1, count: 2, lastCell: 100), [9, 8])
        XCTAssertEqual(SeekPreviewGrid.neighbors(of: 99, direction: 1, count: 2, lastCell: 100), [100])
        XCTAssertEqual(SeekPreviewGrid.neighbors(of: 0, direction: -1, count: 2, lastCell: 100), [])
    }

    // MARK: Keyframe-first fast previews

    func testFastPreviewAcceptsTheKeyframeBeforeTheTarget() {
        XCTAssertTrue(HybridSeekThumbnailPolicy.acceptsPreview(actualSeconds: 40, requestedSeconds: 46, precise: false))
        XCTAssertFalse(HybridSeekThumbnailPolicy.acceptsPreview(actualSeconds: 40, requestedSeconds: 46, precise: true))
        XCTAssertFalse(HybridSeekThumbnailPolicy.acceptsPreview(actualSeconds: 50, requestedSeconds: 46, precise: false),
                       "a frame after the target is never the keyframe before it")
        XCTAssertFalse(HybridSeekThumbnailPolicy.acceptsPreview(actualSeconds: 20, requestedSeconds: 46, precise: false))
        XCTAssertTrue(HybridSeekThumbnailPolicy.acceptsPreview(actualSeconds: 45.8, requestedSeconds: 46, precise: true))
    }

    // MARK: Cache identity

    func testCanonicalKeySeparatesReleasesOfTheSameEpisode() {
        let base = TrickplayDiskCache.canonicalKey(contentId: "tt1", season: 1, episode: 2, duration: 2_600)
        let releaseA = TrickplayDiskCache.canonicalKey(
            contentId: "tt1", season: 1, episode: 2, duration: 2_600, fileIdentity: "torrent:abc:0")
        let releaseB = TrickplayDiskCache.canonicalKey(
            contentId: "tt1", season: 1, episode: 2, duration: 2_600, fileIdentity: "torrent:def:0")
        let sameAsA = TrickplayDiskCache.canonicalKey(
            contentId: "tt1", season: 1, episode: 2, duration: 2_604, fileIdentity: " TORRENT:abc:0 ")
        XCTAssertNotEqual(releaseA, releaseB)
        XCTAssertNotEqual(releaseA, base)
        XCTAssertEqual(releaseA, sameAsA)
        XCTAssertEqual(base, TrickplayDiskCache.canonicalKey(contentId: "tt1", season: 1, episode: 2, duration: 2_600, fileIdentity: ""))
        XCTAssertTrue(SeekPreviewLane.diskKey(for: releaseA).hasPrefix(releaseA))
        XCTAssertNotEqual(SeekPreviewLane.diskKey(for: releaseA), releaseA)
    }

    func testNearestStillComesFromEitherKindWithinTheDistance() async {
        let index = HybridSeekThumbnailIndex()
        await index.reset(generation: 3)
        let fine = makeImage()
        let coarse = makeImage()
        await index.store(fine, seconds: 100, kind: .fine, generation: 3, persistToDisk: false)
        await index.store(coarse, seconds: 130, kind: .coarse, generation: 3, persistToDisk: false)
        let nearFine = await index.nearest(seconds: 108, maxDistance: 30, generation: 3)
        let nearCoarse = await index.nearest(seconds: 125, maxDistance: 30, generation: 3)
        let none = await index.nearest(seconds: 200, maxDistance: 30, generation: 3)
        let otherGeneration = await index.nearest(seconds: 100, maxDistance: 30, generation: 4)
        XCTAssertTrue(nearFine === fine)
        XCTAssertTrue(nearCoarse === coarse)
        XCTAssertNil(none)
        XCTAssertNil(otherGeneration)
    }

    func testKeyframeStillNeverAnswersTheExactLookupOfItsTarget() async {
        let index = HybridSeekThumbnailIndex()
        await index.reset(generation: 5)
        let keyframe = makeImage()
        await index.store(keyframe, seconds: 1_365, kind: .approximate, generation: 5, persistToDisk: false)
        let exact = await index.lookup(seconds: 1_365, duration: 7_200, generation: 5, exactOnly: true)
        let nearby = await index.nearest(seconds: 1_370, maxDistance: 30, generation: 5)
        let sampled = await index.hasCoarse(at: 1_365, generation: 5)
        XCTAssertNil(exact, "a keyframe decoded for 1365 s is not the still at 1365 s")
        XCTAssertTrue(nearby === keyframe, "it still stands in for a nearby target")
        XCTAssertFalse(sampled)
    }

    // MARK: Transport

    func testContentRangeTotalParses() {
        XCTAssertEqual(SeekPreviewRangeTransport.totalSize(fromContentRange: "bytes 0-524287/1234567890"), 1_234_567_890)
        XCTAssertNil(SeekPreviewRangeTransport.totalSize(fromContentRange: "bytes 0-1/*"))
        XCTAssertNil(SeekPreviewRangeTransport.totalSize(fromContentRange: nil))
    }

    func testThrottleStatusStopsTheTransportForTheSession() async {
        let origin = URL(string: "https://throttle.test/file.mkv")!
        SeekPreviewStubProtocol.install(.status(429), forHost: "throttle.test")
        let transport = makeTransport(origin: origin)
        defer { transport.invalidate() }

        let first = await offMain { transport.fetch(offset: 0, length: 1_024, isAborted: { false }) }
        let second = await offMain { transport.fetch(offset: 0, length: 1_024, isAborted: { false }) }
        XCTAssertEqual(first.failureValue, .tripped("HTTP 429"))
        XCTAssertEqual(second.failureValue, .tripped("HTTP 429"))
        XCTAssertEqual(SeekPreviewStubProtocol.requests.count, 1, "a tripped transport sends nothing more")
        XCTAssertEqual(transport.stats.trippedReason, "HTTP 429")
    }

    func testOriginThatIgnoresRangeStopsPreviews() async {
        let origin = URL(string: "https://norange.test/file.mkv")!
        SeekPreviewStubProtocol.install(.wholeFile(makeFile(bytes: 64 * 1024)), forHost: "norange.test")
        let transport = makeTransport(origin: origin)
        defer { transport.invalidate() }

        let result = await offMain { transport.fetch(offset: 0, length: 1_024, isAborted: { false }) }
        XCTAssertEqual(result.failureValue, .rangeUnsupported)
        XCTAssertNotNil(transport.trippedReason)
    }

    func testRedirectTargetIsReusedForLaterRanges() async {
        let file = makeFile(bytes: 256 * 1024)
        let origin = URL(string: "https://resolve.test/play/42")!
        SeekPreviewStubProtocol.install(.redirect(to: URL(string: "https://cdn.test/file.mkv")!), forHost: "resolve.test")
        SeekPreviewStubProtocol.install(.ranges(file), forHost: "cdn.test")
        let transport = makeTransport(origin: origin)
        defer { transport.invalidate() }

        let first = await offMain { transport.fetch(offset: 0, length: 1_000, isAborted: { false }) }
        let second = await offMain { transport.fetch(offset: 4_000, length: 1_000, isAborted: { false }) }
        XCTAssertEqual(first.successValue?.data, file.subdata(in: 0..<1_000))
        XCTAssertEqual(second.successValue?.data, file.subdata(in: 4_000..<5_000))
        XCTAssertEqual(second.successValue?.totalSize, Int64(file.count))
        let hosts = SeekPreviewStubProtocol.requests.compactMap { $0.url?.host }
        XCTAssertEqual(hosts.filter { $0 == "resolve.test" }.count, 1, "the resolve URL is asked once")
        XCTAssertTrue(transport.stats.usesResolvedURL)
    }

    // MARK: Reader

    func testReaderServesRepeatReadsFromItsRangesAndGrowsRunningReads() async {
        let file = makeFile(bytes: 3 * 1024 * 1024)
        let origin = URL(string: "https://media.test/file.mkv")!
        SeekPreviewStubProtocol.install(.ranges(file), forHost: "media.test")
        let transport = makeTransport(origin: origin)
        let reader = SeekPreviewRangeReader(transport: transport)
        defer {
            reader.close()
            transport.invalidate()
        }
        reader.setNetworkPermitted(true)

        let outcome = await offMain { () -> [Int] in
            let chunk = 256 * 1024
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
            defer { buffer.deallocate() }
            var results: [Int] = []
            _ = reader.seek(offset: 0, whence: SEEK_SET)
            results.append(Int(reader.read(buffer, size: Int32(chunk))))           // fetches 512 KiB
            results.append(Int(reader.read(buffer, size: Int32(chunk))))           // from memory
            results.append(Int(reader.seek(offset: 0, whence: 0x10000)))          // AVSEEK_SIZE
            results.append(Int(reader.read(buffer, size: Int32(chunk))))           // runs on: 1 MiB fetch
            let matches = Data(bytes: buffer, count: chunk) == file.subdata(in: (512 * 1024)..<(768 * 1024))
            results.append(matches ? 1 : 0)
            _ = reader.seek(offset: 0, whence: SEEK_SET)
            results.append(Int(reader.read(buffer, size: Int32(chunk))))           // head again, from memory
            return results
        }
        XCTAssertEqual(outcome, [256 * 1024, 256 * 1024, file.count, 256 * 1024, 1, 256 * 1024])
        let ranges = SeekPreviewStubProtocol.requests.compactMap { $0.value(forHTTPHeaderField: "Range") }
        XCTAssertEqual(ranges, ["bytes=0-524287", "bytes=524288-1572863"])
        XCTAssertEqual(reader.cachedBytes, 512 * 1024 + 1024 * 1024)
    }

    func testReaderWithoutNetworkPermissionFailsMissesWithoutRequests() async {
        let file = makeFile(bytes: 1024 * 1024)
        SeekPreviewStubProtocol.install(.ranges(file), forHost: "denied.test")
        let transport = makeTransport(origin: URL(string: "https://denied.test/file.mkv")!)
        let reader = SeekPreviewRangeReader(transport: transport)
        defer {
            reader.close()
            transport.invalidate()
        }

        let read = await offMain { () -> Int32 in
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4_096)
            defer { buffer.deallocate() }
            return reader.read(buffer, size: 4_096)
        }
        XCTAssertEqual(read, -1)
        XCTAssertTrue(SeekPreviewStubProtocol.requests.isEmpty)
        XCTAssertFalse(reader.discImageProbeEnabled)
    }

    // MARK: Helpers

    private func makeImage() -> CGImage {
        let bytes = Data([0, 0, 0, 255])
        let provider = CGDataProvider(data: bytes as CFData)!
        return CGImage(
            width: 1, height: 1,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
    }
}

private extension Result {
    var successValue: Success? {
        if case .success(let value) = self { return value }
        return nil
    }

    var failureValue: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}

@MainActor
private final class NearestOnlyScrubThumbnailProvider: ScrubThumbnailProviding {
    var supportsScrubThumbnails = true
    let nearestImage: CGImage
    private(set) var nearestRequests: [Double] = []

    init(nearestImage: CGImage) { self.nearestImage = nearestImage }

    func cachedScrubThumbnail(atSeconds seconds: Double, duration: Double) async -> CGImage? { nil }
    private(set) var decodeRequests = 0
    func scrubThumbnail(atSeconds seconds: Double, maxWidth: Int, precise: Bool) async -> CGImage? {
        decodeRequests += 1
        return nil
    }
    func nearestScrubThumbnail(atSeconds seconds: Double, maxDistance: Double) async -> CGImage? {
        nearestRequests.append(seconds)
        return nearestImage
    }
}

extension SeekPreviewLaneTests {
    @MainActor
    func testNearestStillStandsInOnlyAfterTheTargetsOwnRequestsFail() async {
        let defaults = ProfileSettings.current
        let previous = defaults.object(forKey: SettingsKey.seekPreviewEnabled)
        defaults.set(true, forKey: SettingsKey.seekPreviewEnabled)
        defer { defaults.set(previous, forKey: SettingsKey.seekPreviewEnabled) }

        let image = makeImage()
        let provider = NearestOnlyScrubThumbnailProvider(nearestImage: image)
        let coordinator = PlaybackSessionCoordinator(
            aetherControllerFactory: { nil },
            engineSettingProvider: { "MPVKit" },
            loadDispatcher: { _, _, _ in }
        )
        let model = PlayerViewModel(sessionCoordinator: coordinator, scrubThumbnailProvider: provider)
        defer { model.pendingSeekDelta = 0; coordinator.stopAll() }
        coordinator.load(PlaybackLoadRequest(videoURL: URL(fileURLWithPath: "/tmp/nearest-preview.mkv")))
        coordinator.onHandoffToast?("Compatibility player enabled")
        XCTAssertEqual(model.activeEngineKind, .mpv)

        let published = expectation(description: "the nearest still reaches the preview")
        let subscription = model.$scrubThumbnail.sink { candidate in
            if candidate === image { published.fulfill() }
        }
        defer { subscription.cancel() }
        model.pendingSeekDelta = 1
        model.requestScrubThumbnail(at: 900)
        // Only after the fast, the exact and both retries came back empty.
        await fulfillment(of: [published], timeout: 8)
        XCTAssertEqual(provider.nearestRequests, [900], "asked once, after the target's own requests")
        XCTAssertGreaterThanOrEqual(provider.decodeRequests, 4)
    }
}
