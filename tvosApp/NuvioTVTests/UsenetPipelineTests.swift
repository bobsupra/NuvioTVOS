import Foundation
import Network
import XCTest
@testable import NuvioTV

/// A news server that answers commands one after another, a little later, the way a busy
/// provider does, so commands pile up on a connection that pipelines them. Bodies name their
/// article, so an answer read by the wrong request shows.
private final class PipelineServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "nuvio.tests.pipeline-nntp")
    private let lock = NSLock()
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var waiting: [ObjectIdentifier: Int] = [:]
    private var busyUntil: [ObjectIdentifier: DispatchTime] = [:]
    private var mostWaiting = 0
    private var opened = 0
    private var dropped: Set<String> = []
    /// Answered "430 No such article".
    private let missing: Set<String>
    /// The first time it is asked for, the connection closes instead of answering.
    private let dropping: Set<String>

    init(missing: Set<String> = [], dropping: Set<String> = []) {
        self.missing = missing
        self.dropping = dropping
    }

    /// The most commands one connection had waiting for an answer, and the connections opened.
    var counts: (mostWaiting: Int, opened: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (mostWaiting, opened)
    }

    func start() async throws -> Int {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        let gate = OnceGate<Bool>()
        let ready = await withCheckedContinuation { continuation in
            gate.arm(continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: gate.resume(true)
                case .failed, .cancelled: gate.resume(false)
                default: break
                }
            }
            listener.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 5) { gate.resume(false) }
        }
        guard ready, let port = listener.port?.rawValue else { throw UsenetNNTPError.notConnected }
        return Int(port)
    }

    func stop() {
        listener?.cancel()
        lock.lock()
        let open = connections
        connections = []
        lock.unlock()
        open.forEach { $0.cancel() }
    }

    private func accept(_ connection: NWConnection) {
        lock.lock()
        connections.append(connection)
        opened += 1
        lock.unlock()
        connection.start(queue: queue)
        send("200 Pipeline test server ready\r\n", on: connection)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            while let end = buffer.range(of: Data("\r\n".utf8)) {
                let line = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
                buffer = Data(buffer[end.upperBound...])
                self.answer(line, on: connection)
            }
            if error == nil, !isComplete { self.receive(on: connection, buffer: buffer) }
        }
    }

    private func answer(_ line: String, on connection: NWConnection) {
        guard line.hasPrefix("BODY <"), line.hasSuffix(">") else {
            send("500 What?\r\n", on: connection)
            return
        }
        let id = String(line.dropFirst("BODY <".count).dropLast())
        let key = ObjectIdentifier(connection)
        lock.lock()
        waiting[key, default: 0] += 1
        mostWaiting = max(mostWaiting, waiting[key, default: 0])
        // Answers go out one after another, each 30 ms after the one before.
        let at = max(busyUntil[key] ?? .now(), .now()) + 0.03
        busyUntil[key] = at
        let drop = dropping.contains(id) && dropped.insert(id).inserted
        lock.unlock()
        queue.asyncAfter(deadline: at) {
            self.lock.lock()
            self.waiting[key, default: 1] -= 1
            self.lock.unlock()
            if drop {
                connection.cancel()
            } else if self.missing.contains(id) {
                self.send("430 No such article\r\n", on: connection)
            } else {
                self.send("222 0 <\(id)> body follows\r\nbody of \(id)\r\n.\r\n", on: connection)
            }
        }
    }

    private func send(_ text: String, on connection: NWConnection) {
        connection.send(content: Data(text.utf8), completion: .contentProcessed { _ in })
    }
}

final class UsenetPipelineTests: XCTestCase {
    private enum Fetched: Equatable {
        case body(String)
        case missing
        case failed(String)
    }

    private actor Results {
        private(set) var all: [String: Fetched] = [:]
        func set(_ id: String, _ result: Fetched) { all[id] = result }
    }

    private func pool(port: Int, connections: Int, depth: Int) -> UsenetConnectionPool {
        UsenetConnectionPool(servers: [UsenetServerConfig(
            host: "127.0.0.1", port: port, useSSL: false, username: nil, password: nil, maxConnections: connections
        )], pipelineDepth: depth)
    }

    /// Fetches every ID at once and collects how each ended.
    private func fetchAll(_ ids: [String], from pool: UsenetConnectionPool,
                          priority: UsenetConnectionPool.FetchPriority = .readAhead) async -> [String: Fetched] {
        let results = Results()
        let done = expectation(description: "\(ids.count) fetches")
        done.expectedFulfillmentCount = ids.count
        for id in ids {
            Task {
                let result: Fetched
                do {
                    switch try await pool.fetch(messageID: id, priority: priority) {
                    case .body(let body): result = .body(String(decoding: body, as: UTF8.self))
                    case .missing: result = .missing
                    }
                } catch {
                    result = .failed(String(describing: error))
                }
                await results.set(id, result)
                done.fulfill()
            }
        }
        await fulfillment(of: [done], timeout: 30)
        return await results.all
    }

    private func assertBodies(_ results: [String: Fetched], _ ids: [String], file: StaticString = #filePath, line: UInt = #line) {
        for id in ids {
            guard case .body(let body)? = results[id] else {
                return XCTFail("\(id): \(String(describing: results[id]))", file: file, line: line)
            }
            // The body comes without its last line break.
            XCTAssertEqual(body, "body of \(id)", file: file, line: line)
        }
    }

    func testReadAheadPipelinesOnAConnection() async throws {
        let server = PipelineServer()
        let port = try await server.start()
        defer { server.stop() }
        let pool = pool(port: port, connections: 2, depth: 4)
        let ids = (0..<12).map { "part\($0)@test" }
        let results = await fetchAll(ids, from: pool)
        assertBodies(results, ids)
        XCTAssertGreaterThan(server.counts.mostWaiting, 1, "requests went out together")
        XCTAssertLessThanOrEqual(server.counts.mostWaiting, 4)
        XCTAssertEqual(server.counts.opened, 2)
        await pool.shutdown()
    }

    func testWithoutPipeliningOneRequestAtATime() async throws {
        let server = PipelineServer()
        let port = try await server.start()
        defer { server.stop() }
        let pool = pool(port: port, connections: 2, depth: 1)
        let ids = (0..<6).map { "part\($0)@test" }
        assertBodies(await fetchAll(ids, from: pool), ids)
        XCTAssertEqual(server.counts.mostWaiting, 1)
        await pool.shutdown()
    }

    func testWhatThePlayerWaitsForIsNeverPipelined() async throws {
        let server = PipelineServer()
        let port = try await server.start()
        defer { server.stop() }
        let pool = pool(port: port, connections: 2, depth: 4)
        let ids = (0..<6).map { "part\($0)@test" }
        assertBodies(await fetchAll(ids, from: pool, priority: .playback), ids)
        XCTAssertEqual(server.counts.mostWaiting, 1)
        await pool.shutdown()
    }

    func testAMissingArticleInThePipelineLeavesTheOthers() async throws {
        let server = PipelineServer(missing: ["part3@test"])
        let port = try await server.start()
        defer { server.stop() }
        let pool = pool(port: port, connections: 1, depth: 4)
        let ids = (0..<8).map { "part\($0)@test" }
        let results = await fetchAll(ids, from: pool)
        XCTAssertEqual(results["part3@test"], .missing)
        assertBodies(results, ids.filter { $0 != "part3@test" })
        XCTAssertEqual(server.counts.opened, 1, "a missing article keeps the connection")
        await pool.shutdown()
    }

    func testADroppedConnectionSendsItsRequestsAgain() async throws {
        let server = PipelineServer(dropping: ["part2@test"])
        let port = try await server.start()
        defer { server.stop() }
        let pool = pool(port: port, connections: 1, depth: 4)
        let ids = (0..<8).map { "part\($0)@test" }
        let results = await fetchAll(ids, from: pool)
        assertBodies(results, ids)
        XCTAssertGreaterThanOrEqual(server.counts.opened, 2)
        let stats = await pool.stats()
        XCTAssertLessThanOrEqual(stats.openConnections, 1, "the dropped connection counted once")
        await pool.shutdown()
    }

    func testTheWaitQueueLetsReadAheadJoinFirst() {
        var queue = UsenetWaitQueue<(String, Bool)>()
        queue.append(("player", false), urgent: true)
        queue.append(("stat", false), urgent: false)
        queue.append(("read-ahead", true), urgent: false)
        XCTAssertEqual(queue.popFirstNormal(where: { $0.1 })?.0, "read-ahead")
        XCTAssertNil(queue.popFirstNormal(where: { $0.1 }))
        XCTAssertEqual(queue.popFirst()?.0, "player")
        XCTAssertEqual(queue.popFirst()?.0, "stat")
    }

    func testThePipelineSettingKeepsToItsChoices() {
        let store = UserDefaults(suiteName: "usenet-pipeline-\(UUID().uuidString)")!
        XCTAssertEqual(UsenetSettings.pipelineDepth(store: store), 1)
        UsenetSettings.setPipelineDepth(4, store: store)
        XCTAssertEqual(UsenetSettings.pipelineDepth(store: store), 4)
        UsenetSettings.setPipelineDepth(3, store: store)
        XCTAssertEqual(UsenetSettings.pipelineDepth(store: store), 1)
    }
}
