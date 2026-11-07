import Foundation
import XCTest
@testable import NuvioTV

@MainActor
final class ReleaseUpdateServiceTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "ReleaseUpdateServiceTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        ReleaseUpdateURLProtocolStub.reset()
    }

    override func tearDown() {
        ReleaseUpdateURLProtocolStub.reset()
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testNumericVersionsRecognizeReleasePrefixesAndCompareComponents() throws {
        let beta = try XCTUnwrap(NumericReleaseVersion(tag: "tvos-beta-3.4.6"))
        let tvos = try XCTUnwrap(NumericReleaseVersion(tag: "tvos-3.4.6"))
        let version = try XCTUnwrap(NumericReleaseVersion(tag: "v3.4.6"))
        let newerPatch = try XCTUnwrap(NumericReleaseVersion(tag: "3.4.10"))
        let olderPatch = try XCTUnwrap(NumericReleaseVersion(tag: "3.4.9"))

        XCTAssertEqual(beta, tvos)
        XCTAssertEqual(tvos, version)
        XCTAssertGreaterThan(newerPatch, olderPatch)
        XCTAssertNil(NumericReleaseVersion(tag: "tvos-beta-3.x.6"))
        XCTAssertNil(NumericReleaseVersion(tag: "3.4"))
        XCTAssertNil(NumericReleaseVersion(tag: "3.4.6-rc.1"))
        XCTAssertNil(NumericReleaseVersion(tag: "release-3.4.6"))
    }

    func testFailedAttemptIsThrottledAcrossInstancesAndValidReleaseIsCached() async throws {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        ReleaseUpdateURLProtocolStub.handler = { request in
            XCTAssertEqual(request.url, ReleaseUpdateService.latestReleaseEndpoint)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2026-03-10")
            return Self.response(for: request, status: 403, json: #"{"message":"rate limited"}"#)
        }

        let first = makeService(now: { now })
        await first.checkIfNeeded()
        XCTAssertEqual(defaults.object(forKey: ReleaseUpdateService.lastAttemptKey) as? Date, now)
        XCTAssertNil(first.latestRelease)

        let sameWindow = makeService(now: { now })
        await sameWindow.checkIfNeeded()
        XCTAssertEqual(ReleaseUpdateURLProtocolStub.requestCount, 1)

        now.addTimeInterval(24 * 60 * 60 + 1)
        ReleaseUpdateURLProtocolStub.handler = { request in
            Self.response(for: request, status: 200, json: Self.releaseJSON(tag: "tvos-beta-3.4.10"))
        }
        let nextWindow = makeService(now: { now })
        await nextWindow.checkIfNeeded()

        XCTAssertEqual(nextWindow.latestRelease?.displayVersion, "3.4.10")
        XCTAssertEqual(nextWindow.latestStatus, "3.4.10 · Available")
        XCTAssertNotNil(defaults.data(forKey: ReleaseUpdateService.cachedReleaseKey))

        let restored = makeService(now: { now }, runningVersion: "3.4.10")
        XCTAssertEqual(restored.latestRelease, nextWindow.latestRelease)
        XCTAssertEqual(restored.latestStatus, "3.4.10 · Up to date")
        XCTAssertFalse(restored.shouldShowNotice)
    }

    func testDismissIsLaunchLocalSkipPersistsAndNewVersionRemainsEligible() async {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        ReleaseUpdateURLProtocolStub.handler = { request in
            Self.response(for: request, status: 200, json: Self.releaseJSON(tag: "tvos-3.4.7"))
        }
        let service = makeService(now: { now })
        await service.checkIfNeeded()
        XCTAssertTrue(service.shouldShowNotice)

        service.dismissNotice()
        XCTAssertFalse(service.shouldShowNotice)

        let relaunched = makeService(now: { now })
        XCTAssertTrue(relaunched.shouldShowNotice)
        relaunched.skipCurrentVersion()
        XCTAssertFalse(relaunched.shouldShowNotice)
        XCTAssertEqual(defaults.string(forKey: ReleaseUpdateService.skippedTagKey), "tvos-3.4.7")

        now.addTimeInterval(24 * 60 * 60 + 1)
        ReleaseUpdateURLProtocolStub.handler = { request in
            Self.response(for: request, status: 200, json: Self.releaseJSON(tag: "tvos-3.4.8"))
        }
        let laterRelease = makeService(now: { now })
        await laterRelease.checkIfNeeded()
        XCTAssertTrue(laterRelease.shouldShowNotice)
    }

    func testForegroundSessionRestoresCachedNoticeButPreservesSkipAndDisabled() async {
        ReleaseUpdateURLProtocolStub.handler = { request in
            Self.response(for: request, status: 200, json: Self.releaseJSON(tag: "tvos-3.4.7"))
        }
        let initialSession = makeService()
        await initialSession.checkIfNeeded()
        XCTAssertEqual(initialSession.latestRelease?.displayVersion, "3.4.7")
        XCTAssertEqual(ReleaseUpdateURLProtocolStub.requestCount, 1)

        let foregroundSession = makeService()
        XCTAssertEqual(foregroundSession.latestRelease, initialSession.latestRelease)
        foregroundSession.dismissNotice()
        XCTAssertFalse(foregroundSession.shouldShowNotice)

        foregroundSession.beginForegroundSession()
        XCTAssertTrue(foregroundSession.shouldShowNotice)
        await foregroundSession.checkIfNeeded()
        XCTAssertEqual(ReleaseUpdateURLProtocolStub.requestCount, 1, "Restoring a cached release should respect the daily throttle.")

        foregroundSession.skipCurrentVersion()
        XCTAssertFalse(foregroundSession.shouldShowNotice)
        foregroundSession.beginForegroundSession()
        XCTAssertFalse(foregroundSession.shouldShowNotice, "A foreground session must not clear the persisted skip.")

        foregroundSession.setEnabled(false)
        foregroundSession.beginForegroundSession()
        XCTAssertFalse(foregroundSession.shouldShowNotice, "A foreground session must not re-enable update checks.")
        await foregroundSession.checkIfNeeded()
        XCTAssertEqual(ReleaseUpdateURLProtocolStub.requestCount, 1)
    }

    func testConcurrentChecksShareRequestAndDisablingDiscardsInflightResult() async {
        let started = expectation(description: "release request started")
        let releaseRequest = DispatchSemaphore(value: 0)
        ReleaseUpdateURLProtocolStub.handler = { request in
            started.fulfill()
            releaseRequest.wait()
            return Self.response(for: request, status: 200, json: Self.releaseJSON(tag: "tvos-3.4.7"))
        }
        let service = makeService()
        let first = Task { await service.checkIfNeeded() }
        await fulfillment(of: [started], timeout: 2)

        let second = Task { await service.checkIfNeeded() }
        await Task.yield()
        XCTAssertEqual(ReleaseUpdateURLProtocolStub.requestCount, 1)

        service.setEnabled(false)
        releaseRequest.signal()
        await first.value
        await second.value

        XCTAssertFalse(service.isEnabled)
        XCTAssertNil(service.latestRelease)
        XCTAssertNil(defaults.data(forKey: ReleaseUpdateService.cachedReleaseKey))
        await service.checkIfNeeded()
        XCTAssertEqual(ReleaseUpdateURLProtocolStub.requestCount, 1)
    }

    func testInvalidPayloadAndReleaseURLAreIgnored() async {
        ReleaseUpdateURLProtocolStub.handler = { request in
            Self.response(for: request, status: 200, json: Self.releaseJSON(
                tag: "tvos-3.4.7",
                url: "https://example.com/releases/tvos-3.4.7"
            ))
        }
        let service = makeService()
        await service.checkIfNeeded()

        XCTAssertNil(service.latestRelease)
        XCTAssertNil(defaults.data(forKey: ReleaseUpdateService.cachedReleaseKey))
        XCTAssertFalse(service.shouldShowNotice)
    }

    private func makeService(
        now: @escaping () -> Date = Date.init,
        runningVersion: String = "3.4.6"
    ) -> ReleaseUpdateService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReleaseUpdateURLProtocolStub.self]
        return ReleaseUpdateService(
            defaults: defaults,
            session: URLSession(configuration: configuration),
            now: now,
            runningVersion: runningVersion
        )
    }

    private static func response(for request: URLRequest, status: Int, json: String) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(json.utf8))
    }

    private static func releaseJSON(
        tag: String,
        url: String? = nil
    ) -> String {
        let releaseURL = url ?? "https://github.com/\(AppRepository.slug)/releases/tag/\(tag)"
        return """
        {"tag_name":"\(tag)","html_url":"\(releaseURL)","prerelease":false,"draft":false}
        """
    }
}

private final class ReleaseUpdateURLProtocolStub: URLProtocol {
    private static let lock = NSLock()
    private static var storedHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    private static var storedRequestCount = 0

    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedHandler
        }
        set {
            lock.lock()
            storedHandler = newValue
            lock.unlock()
        }
    }

    static var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedRequestCount
    }

    static func reset() {
        lock.lock()
        storedHandler = nil
        storedRequestCount = 0
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "api.github.com"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        Self.storedRequestCount += 1
        let handler = Self.storedHandler
        Self.lock.unlock()

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
