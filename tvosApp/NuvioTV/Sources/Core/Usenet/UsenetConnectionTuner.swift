import Foundation

// MARK: - Tune connections

/// One measured setting: download speed with `connections` connections on `port`.
struct UsenetTuneReading: Equatable, Sendable {
    var port: Int
    var connections: Int
    var megabitsPerSecond: Double
}

/// What a tuning run is doing now, and the settings measured so far.
struct UsenetTuneProgress: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case testData
        /// Opening connections to find how many the account accepts.
        case limit
        case port
        case connections
    }

    var phase: Phase
    var connections = 0
    var port = 0
    var readings: [UsenetTuneReading] = []
}

struct UsenetTuneResult: Equatable, Sendable {
    /// Connections the provider accepted before it turned one away; nil when none was turned away.
    var limit: Int?
    /// Connections open at once without a refusal.
    var tried: Int
    var port: Int
    /// The connection count to use.
    var connections: Int
    /// The fewest connections within reach of the best speed measured.
    var fastestConnections: Int
    var megabitsPerSecond: Double
    var readings: [UsenetTuneReading]
    var downloadedBytes: Int64
}

enum UsenetTuneFailure: Error, Equatable {
    /// The server can't be reached or turned the login away.
    case connect(String)
    /// The test NZB couldn't be downloaded.
    case testData
    /// The server doesn't have the test articles.
    case missingArticles
    /// Too little arrived to measure a speed.
    case tooSlow
}

/// The decisions of a tuning run, apart from the network so they can be tested. After the
/// Android app's tuner: the limit check finds how many connections the account really accepts
/// (more get refusals the stream keeps retrying), then the ports and connection counts are
/// measured with real articles.
enum UsenetTunePlan {
    /// Connections opened to find the limit, unless more are set.
    static let probeCap = 100
    static let maxProbe = 200
    /// Connections opened together while looking for the limit.
    static let probeBatch = 8
    /// Connections used to compare ports: enough to fill most lines.
    static let portConnections = 8
    /// Readings within this share of the best are as fast.
    static let goodEnough = 0.95
    /// Another port must be this much faster than the current one to replace it.
    static let portWin = 1.10
    /// A step adding less than this over the best so far is no gain; two in a row end the round.
    static let gain = 1.03
    static let ladderSteps = [4, 8, 12, 16, 24, 32, 48, 64, 80, 100, 128, 160, 200]

    static func probeCap(allowance: Int) -> Int {
        min(maxProbe, max(probeCap, allowance))
    }

    /// Connections that may be used: the limit less a tenth (at least one), so a second device
    /// or a slot the server hasn't freed yet doesn't cause refusals. Without a limit, what was
    /// tried.
    static func usable(limit: Int?, tried: Int) -> Int {
        guard let limit else { return tried }
        return max(1, limit - max(1, limit / 10))
    }

    /// The counts measured, up to `usable`.
    static func ladder(usable: Int) -> [Int] {
        var steps = ladderSteps.filter { $0 < usable }
        if !steps.contains(usable) { steps.append(usable) }
        return steps
    }

    /// The ports to compare, the current one first. Encrypted stays encrypted: a plain port
    /// would send the login in the clear.
    static func ports(port: Int, useSSL: Bool) -> [Int] {
        var ports = [port]
        for candidate in useSSL ? [563, 443] : [119] where !ports.contains(candidate) { ports.append(candidate) }
        return ports
    }

    static func averages(_ readings: [UsenetTuneReading], by key: (UsenetTuneReading) -> Int) -> [Int: Double] {
        Dictionary(grouping: readings, by: key).mapValues { same in
            same.map(\.megabitsPerSecond).reduce(0, +) / Double(same.count)
        }
    }

    /// The port to keep: another one only when it is clearly faster.
    static func bestPort(current: Int, readings: [UsenetTuneReading]) -> Int {
        let speeds = averages(readings, by: \.port)
        guard let best = speeds.max(by: { $0.value < $1.value }) else { return current }
        guard let currentSpeed = speeds[current] else { return best.key }
        return best.value > currentSpeed * portWin ? best.key : current
    }

    /// Whether the connection round can stop: the last two steps added less than `gain` over
    /// the best before them.
    static func flattened(_ speeds: [Double]) -> Bool {
        guard speeds.count >= 3 else { return false }
        let before = speeds.dropLast(2).max() ?? 0
        return speeds.suffix(2).allSatisfy { $0 < before * gain }
    }

    /// The fewest connections within `goodEnough` of the best average; nil without a reading.
    static func fastestConnections(_ readings: [UsenetTuneReading]) -> Int? {
        let speeds = averages(readings, by: \.connections)
        guard let best = speeds.values.max(), best > 0 else { return nil }
        return speeds.filter { $0.value >= best * goodEnough }.keys.min()
    }

    /// The count to use. With a limit, never above its usable share. Otherwise not lowered:
    /// unused connections cost nothing and help seeks; raised when more measured clearly faster.
    static func recommend(current: Int, fastest: Int, limit: Int?, tried: Int, speeds: [Int: Double]) -> Int {
        var wanted = current
        if fastest > current, let candidate = speeds[fastest] {
            let baseline = speeds[current] ?? speeds.filter { $0.key <= current }.max(by: { $0.key < $1.key })?.value ?? 0
            if baseline < candidate * goodEnough { wanted = fastest }
        }
        guard let limit else { return wanted }
        return min(wanted, usable(limit: limit, tried: tried))
    }

    /// The articles of the test NZB, in order.
    static func messageIDs(_ nzb: Data) -> [String] {
        guard let parsed = try? UsenetNZB.parse(nzb) else { return [] }
        return parsed.files.flatMap { $0.segments.map(\.messageID) }
    }
}

/// Measures a Usenet server: how many connections the account accepts, which port and how
/// many connections download fastest. Downloads a public test NZB kept current by SABnzbd
/// (about 1 GB in articles posted for speed tests) and as much of it as the measurements take.
actor UsenetConnectionTuner {
    static let testNZBURL = URL(string: "https://sabnzbd.org/tests/test_download_1GB.nzb")!
    static let maxNZBBytes = 4 << 20
    /// How long one setting is measured, once its connections are open.
    static let measureSeconds: Double = 5

    private let server: UsenetServerConfig
    private var stopped = false
    private var downloaded: Int64 = 0
    private var nextArticle = 0
    private var articles: [String] = []

    init(server: UsenetServerConfig) {
        self.server = server
    }

    func stop() { stopped = true }

    func run(progress: @escaping @Sendable (UsenetTuneProgress) -> Void) async throws -> UsenetTuneResult {
        progress(UsenetTuneProgress(phase: .testData))
        articles = UsenetTunePlan.messageIDs(try await Self.testNZB())
        guard !articles.isEmpty else { throw UsenetTuneFailure.testData }

        // Does the server reach, accept the login and have the articles?
        let first = UsenetNNTPConnection(config: server)
        do {
            try await first.open()
        } catch let error as UsenetNNTPError {
            throw UsenetTuneFailure.connect(UsenetConnectionPool.describe(error))
        }
        do {
            let body = try await first.fetchBody(messageID: articles[0])
            downloaded += Int64(body.count)
        } catch UsenetNNTPError.articleUnavailable {
            await first.close()
            throw UsenetTuneFailure.missingArticles
        } catch {
            await first.close()
            throw UsenetTuneFailure.connect(error.localizedDescription)
        }
        await first.close()

        // 1. The limit.
        let probe = try await findLimit(progress: progress)
        let usable = UsenetTunePlan.usable(limit: probe.limit, tried: probe.tried)

        // 2. The port.
        var readings: [UsenetTuneReading] = []
        let portCount = min(UsenetTunePlan.portConnections, usable)
        for port in UsenetTunePlan.ports(port: server.port, useSSL: server.useSSL) {
            try checkStopped()
            progress(UsenetTuneProgress(phase: .port, connections: portCount, port: port, readings: readings))
            if let speed = try await measure(port: port, connections: portCount) {
                readings.append(UsenetTuneReading(port: port, connections: portCount, megabitsPerSecond: speed))
            }
        }
        guard !readings.isEmpty else { throw UsenetTuneFailure.tooSlow }
        let port = UsenetTunePlan.bestPort(current: server.port, readings: readings)

        // 3. The connection count, on that port.
        var steps: [Double] = []
        var counts = UsenetTunePlan.ladder(usable: usable)
        // The count set now is measured too, so a change is a comparison, not a guess.
        if server.maxConnections <= usable, !counts.contains(server.maxConnections) {
            counts.append(server.maxConnections)
            counts.sort()
        }
        for count in counts {
            try checkStopped()
            progress(UsenetTuneProgress(phase: .connections, connections: count, port: port, readings: readings))
            guard let speed = try await measure(port: port, connections: count) else { continue }
            readings.append(UsenetTuneReading(port: port, connections: count, megabitsPerSecond: speed))
            steps.append(speed)
            if UsenetTunePlan.flattened(steps), count >= server.maxConnections { break }
        }
        let onPort = readings.filter { $0.port == port }
        guard let fastest = UsenetTunePlan.fastestConnections(onPort) else { throw UsenetTuneFailure.tooSlow }
        let speeds = UsenetTunePlan.averages(onPort, by: \.connections)
        let connections = UsenetTunePlan.recommend(current: server.maxConnections, fastest: fastest,
                                                   limit: probe.limit, tried: probe.tried, speeds: speeds)
        return UsenetTuneResult(
            limit: probe.limit, tried: probe.tried, port: port, connections: connections,
            fastestConnections: fastest, megabitsPerSecond: speeds[fastest] ?? 0,
            readings: readings, downloadedBytes: downloaded
        )
    }

    private func checkStopped() throws {
        if stopped || Task.isCancelled { throw CancellationError() }
    }

    // MARK: The limit

    /// Opens connections a few at a time until the server turns one away or the cap is reached.
    private func findLimit(progress: @escaping @Sendable (UsenetTuneProgress) -> Void) async throws -> (limit: Int?, tried: Int) {
        let cap = UsenetTunePlan.probeCap(allowance: server.maxConnections)
        var open: [UsenetNNTPConnection] = []
        defer {
            let connections = open
            Task { for connection in connections { await connection.close() } }
        }
        var refused = false
        while open.count < cap, !refused {
            try checkStopped()
            progress(UsenetTuneProgress(phase: .limit, connections: open.count))
            let batch = min(UsenetTunePlan.probeBatch, cap - open.count)
            let config = server
            let results = await withTaskGroup(of: (UsenetNNTPConnection, Error?).self) { group in
                for _ in 0..<batch {
                    group.addTask {
                        let connection = UsenetNNTPConnection(config: config)
                        do {
                            try await connection.open()
                            return (connection, nil)
                        } catch {
                            return (connection, error)
                        }
                    }
                }
                var all: [(UsenetNNTPConnection, Error?)] = []
                for await result in group { all.append(result) }
                return all
            }
            let before = open.count
            for (connection, error) in results {
                if let error {
                    await connection.close()
                    // A login or greeting refused while others are open: the plan's limit.
                    if !open.isEmpty, UsenetConnectionPool.limitAfterRefusal(error, open: open.count, limit: cap) != nil {
                        refused = true
                    } else if open.isEmpty, let error = error as? UsenetNNTPError {
                        throw UsenetTuneFailure.connect(UsenetConnectionPool.describe(error))
                    }
                } else {
                    open.append(connection)
                }
            }
            // Connections failing for another reason (timeouts): no limit to find this way.
            if open.count == before, !refused { break }
        }
        // A refusal is checked once more, alone: a busy moment isn't a limit.
        if refused {
            let again = UsenetNNTPConnection(config: server)
            do {
                try await again.open()
                open.append(again)
                refused = false
            } catch {
                await again.close()
            }
        }
        return (refused ? open.count : nil, open.count)
    }

    // MARK: Measuring

    /// Download speed in Mbit/s with `connections` connections on `port`, nil when none opened.
    private func measure(port: Int, connections: Int) async throws -> Double? {
        var config = server
        config.port = port
        let opened = await withTaskGroup(of: UsenetNNTPConnection?.self) { group in
            for _ in 0..<connections {
                group.addTask {
                    let connection = UsenetNNTPConnection(config: config)
                    do {
                        try await connection.open()
                        return connection
                    } catch {
                        await connection.close()
                        return nil
                    }
                }
            }
            var all: [UsenetNNTPConnection] = []
            for await connection in group { if let connection { all.append(connection) } }
            return all
        }
        guard !opened.isEmpty else { return nil }
        let counter = ByteCounter()
        let deadline = ContinuousClock.now + .seconds(Self.measureSeconds)
        let start = ContinuousClock.now
        await withTaskGroup(of: Void.self) { group in
            for connection in opened {
                group.addTask {
                    while ContinuousClock.now < deadline, !Task.isCancelled {
                        let id = await self.takeArticle()
                        guard let body = try? await connection.fetchBody(messageID: id) else {
                            if await connection.isClosed { return }
                            continue
                        }
                        await counter.add(body.count)
                    }
                }
            }
            // A body still on its way when time is up is cut off: the connection closes.
            group.addTask {
                try? await Task.sleep(until: deadline, clock: .continuous)
                for connection in opened { await connection.close() }
            }
        }
        for connection in opened { await connection.close() }
        let elapsed = ContinuousClock.now - start
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let bytes = await counter.total
        downloaded += bytes
        guard bytes > 0, seconds > 0 else { return nil }
        return Double(bytes) * 8 / seconds / 1_000_000
    }

    private func takeArticle() -> String {
        defer { nextArticle += 1 }
        return articles[nextArticle % articles.count]
    }

    private actor ByteCounter {
        private(set) var total: Int64 = 0
        func add(_ bytes: Int) { total += Int64(bytes) }
    }

    // MARK: Test data

    private static func testNZB() async throws -> Data {
        var request = URLRequest(url: testNZBURL)
        request.timeoutInterval = 30
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty, data.count <= maxNZBBytes else {
                throw UsenetTuneFailure.testData
            }
            return data
        } catch let failure as UsenetTuneFailure {
            throw failure
        } catch {
            throw UsenetTuneFailure.testData
        }
    }
}
