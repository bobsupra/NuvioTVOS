import Foundation
import Combine

// MARK: - What a check finds

/// What checking a Usenet stream before playing it found: the NZB read for what it
/// lacks itself, and a sample of its articles asked about on the servers (`STAT`,
/// nothing downloaded), the way playback checks a release when it starts.
struct UsenetAvailabilityReport: Sendable, Equatable {
    enum Verdict: String, Sendable, Equatable {
        /// Every sampled article is on the servers.
        case available
        /// A hole or two: it plays, with a damaged frame where one is.
        case partial
        /// What playback wouldn't start, or a release with whole parts missing.
        case incomplete
    }

    /// Articles asked about, and the ones no server had.
    var checked: Int
    var missing: Int
    /// The release's last article is missing (from the NZB or the servers).
    var tailMissing: Bool
    /// Articles the NZB lists fewer of than its subjects announce.
    var nzbGaps: Int
    /// Volumes missing from a numbered RAR set.
    var missingVolumes: Int

    /// Damage this long a run stops playback (`UsenetStreamSession.damageConsecutiveMissing`).
    static let nzbGapsLimit = 3

    var verdict: Verdict {
        let health = UsenetHealthCheck.Result(checked: checked, missing: missing, tailMissing: tailMissing)
        if !UsenetHealthCheck.isPlayable(health) || missingVolumes > 0 || nzbGaps >= Self.nzbGapsLimit {
            return .incomplete
        }
        return missing > 0 || nzbGaps > 0 ? .partial : .available
    }
}

// MARK: - The check

/// Reads an NZB without downloading any of its articles: which ones to ask the
/// servers about, and what the NZB shows missing by itself.
enum UsenetAvailability {
    struct Plan: Sendable, Equatable {
        /// Message IDs to ask about, spread over the release, its last article last.
        var samples: [String]
        /// The NZB lacks the release's last article: nothing to ask, it's missing.
        var tailMissingInNZB: Bool
        var nzbGaps: Int
        var missingVolumes: Int
    }

    static func plan(for nzb: UsenetNZB, mustInclude: String? = nil,
                     sampleCount: Int = UsenetHealthCheck.sampleCount) -> Plan {
        let files = contentFiles(of: nzb, mustInclude: mustInclude)
        let ids = files.flatMap { $0.segments.map(\.messageID) }
        var samples: [String] = []
        let count = min(sampleCount, ids.count)
        for step in 0..<count {
            let position = count == 1 ? ids.count - 1 : step * (ids.count - 1) / (count - 1)
            samples.append(ids[position])
        }
        var tailMissing = false
        if let last = files.last, let declared = declaredSegments(inSubject: last.subject),
           let lastNumber = last.segments.last?.number, lastNumber < declared {
            tailMissing = true
        }
        return Plan(
            samples: samples,
            tailMissingInNZB: tailMissing,
            nzbGaps: files.reduce(0) { $0 + gaps(in: $1) },
            missingVolumes: missingVolumes(in: files.map(\.name))
        )
    }

    /// The files that make up what plays: the videos and archive volumes when the names
    /// show them (the episode's own video in a pack the stream names a file of), else
    /// everything but repair data and info files (an obfuscated release). Volumes in the
    /// order they play.
    static func contentFiles(of nzb: UsenetNZB, mustInclude: String?) -> [UsenetFile] {
        let candidates = nzb.files.filter { !$0.isSidecar }
        let named = candidates.filter { $0.isVideo || $0.isArchive }
        var files = named.isEmpty ? candidates : named
        if let mustInclude, !mustInclude.isEmpty,
           let regex = try? NSRegularExpression(pattern: mustInclude, options: [.caseInsensitive]) {
            let matching = files.filter {
                regex.firstMatch(in: $0.name, range: NSRange($0.name.startIndex..., in: $0.name)) != nil
            }
            if !matching.isEmpty, matching.allSatisfy(\.isVideo) { files = matching }
        }
        // A set keeps the place of its first file in the NZB; its volumes go by number.
        let volumes = files.map { volume(of: $0.name) }
        var setPosition: [String: Int] = [:]
        for (position, volume) in volumes.enumerated() {
            guard let volume, setPosition[volume.set] == nil else { continue }
            setPosition[volume.set] = position
        }
        let keyed = files.enumerated().map { position, file -> (group: Int, index: Int, position: Int, file: UsenetFile) in
            if let volume = volumes[position], let group = setPosition[volume.set] {
                return (group, volume.index, position, file)
            }
            return (position, 0, position, file)
        }
        return keyed.sorted {
            ($0.group, $0.index, $0.position) < ($1.group, $1.index, $1.position)
        }.map(\.file)
    }

    /// The article count a subject announces: the last "(n/total)" in it.
    static func declaredSegments(inSubject subject: String) -> Int? {
        let pattern = #"\((\d+)/(\d+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(subject.startIndex..., in: subject)
        guard let match = regex.matches(in: subject, range: range).last,
              let totalRange = Range(match.range(at: 2), in: subject),
              let total = Int(subject[totalRange]), total > 0 else { return nil }
        return total
    }

    /// Articles of a file the NZB doesn't list, when its subject says how many there are.
    static func gaps(in file: UsenetFile) -> Int {
        guard let declared = declaredSegments(inSubject: file.subject) else { return 0 }
        let listed = Set(file.segments.map(\.number)).filter { (1...declared).contains($0) }.count
        return max(0, declared - listed)
    }

    /// A RAR volume's set (the name without its volume part) and its place in the set:
    /// `name.part03.rar` → 3, `name.rar` → 0 and `name.r00` → 1 (the old naming).
    static func volume(of name: String) -> (set: String, index: Int, firstIndex: Int)? {
        let lower = name.lowercased()
        if let match = lower.range(of: #"\.part(\d+)\.rar$"#, options: .regularExpression) {
            let digits = lower[match].dropFirst(5).dropLast(4)
            guard let number = Int(digits) else { return nil }
            // `part00`/`part000` sets start at 0, the others at 1.
            let startsAtZero = digits.count > 1 && digits.allSatisfy { $0 == "0" }
            return (String(lower[..<match.lowerBound]), number, startsAtZero ? 0 : 1)
        }
        if lower.hasSuffix(".rar") {
            return (String(lower.dropLast(4)), 0, 0)
        }
        if let match = lower.range(of: #"\.r(\d{2,3})$"#, options: .regularExpression),
           let number = Int(lower[match].dropFirst(2)) {
            return (String(lower[..<match.lowerBound]), number + 1, 0)
        }
        return nil
    }

    /// Volumes missing between a numbered set's first and last, per set.
    static func missingVolumes(in names: [String]) -> Int {
        var sets: [String: (first: Int, indices: Set<Int>)] = [:]
        for name in names {
            guard let volume = volume(of: name) else { continue }
            var entry = sets[volume.set] ?? (first: volume.firstIndex, indices: Set<Int>())
            entry.first = min(entry.first, volume.firstIndex)
            entry.indices.insert(volume.index)
            sets[volume.set] = entry
        }
        return sets.values.reduce(0) { total, set in
            guard let last = set.indices.max(), set.indices.count > 1 || last > set.first else { return total }
            return total + max(0, last - set.first + 1 - set.indices.count)
        }
    }

    /// Asks the servers about the plan's articles, in order (any server that has one counts).
    static func ask(_ plan: Plan, pool: UsenetConnectionPool) async throws -> UsenetAvailabilityReport {
        let found = try await withThrowingTaskGroup(of: (String, Bool).self, returning: [String: Bool].self) { group in
            for id in Set(plan.samples) {
                group.addTask { (id, try await pool.exists(messageID: id)) }
            }
            var results: [String: Bool] = [:]
            for try await answer in group { results[answer.0] = answer.1 }
            return results
        }
        let missing = found.values.filter { !$0 }.count
        let tailMissing = plan.tailMissingInNZB || plan.samples.last.map { found[$0] == false } ?? false
        return UsenetAvailabilityReport(
            checked: found.count,
            missing: missing,
            tailMissing: tailMissing,
            nzbGaps: plan.nzbGaps,
            missingVolumes: plan.missingVolumes
        )
    }
}

// MARK: - Checking streams from the stream list

/// Checks Usenet streams before they're played: one from its card's menu, all the list
/// shows from the button beside the sort button, or the first ones by themselves
/// (Settings → Usenet → Check Streams Automatically).
///
/// Each check downloads the stream's NZB into the NZB cache, so playing it afterwards
/// doesn't download it again; the indexer still counts it as a download. Two checks run
/// at once, over connections of their own (two per server), closed once the checks are
/// done, so playback keeps its own.
@MainActor
final class UsenetAvailabilityChecker: ObservableObject {
    static let shared = UsenetAvailabilityChecker()

    enum State: Equatable {
        case queued
        case checking
        case checked(UsenetAvailabilityReport)
        case failed(String)

        var isPending: Bool { self == .queued || self == .checking }
    }

    /// By NZB URL.
    @Published private(set) var states: [URL: State] = [:]

    static let concurrentChecks = 2
    static let connectionsPerServer = 2
    /// An automatic check doesn't ask again about a stream checked this recently;
    /// articles can still go missing later (takedowns), so not for longer.
    static let resultLifetime: TimeInterval = 6 * 60 * 60

    private var checkedAt: [URL: Date] = [:]
    private var queue: [UsenetStreamSpec] = []
    private var running = 0
    private var pools: [[UsenetServerConfig]: UsenetConnectionPool] = [:]
    private var poolShutdown: Task<Void, Never>?

    private init() {}

    nonisolated static func spec(for stream: NuvioStream) -> UsenetStreamSpec? {
        stream.directURL.flatMap(URL.init(string:)).flatMap(UsenetStreamSpec.init(url:))
    }

    func state(for stream: NuvioStream) -> State? {
        Self.spec(for: stream).flatMap { states[$0.nzbURL] }
    }

    /// Checked and found incomplete: failover to another Usenet stream passes it by.
    func isIncomplete(_ stream: NuvioStream) -> Bool {
        guard case .checked(let report)? = state(for: stream) else { return false }
        return report.verdict == .incomplete
    }

    func isChecking(_ streams: [NuvioStream]) -> Bool {
        streams.contains { state(for: $0)?.isPending == true }
    }

    /// Checks the Usenet ones among `streams`, in order. Asked for (`force`), it asks the
    /// servers again (the NZB comes from the cache); by itself, it skips streams checked
    /// within `resultLifetime`.
    func check(_ streams: [NuvioStream], force: Bool) {
        var seen = Set<URL>()
        for stream in streams {
            guard let spec = Self.spec(for: stream), seen.insert(spec.nzbURL).inserted else { continue }
            let url = spec.nzbURL
            if states[url]?.isPending == true { continue }
            if !force, case .checked? = states[url], let at = checkedAt[url],
               Date().timeIntervalSince(at) < Self.resultLifetime { continue }
            states[url] = .queued
            queue.append(spec)
        }
        pump()
    }

    private func pump() {
        poolShutdown?.cancel()
        poolShutdown = nil
        while running < Self.concurrentChecks, !queue.isEmpty {
            let spec = queue.removeFirst()
            let servers = UsenetSettings.servers(for: spec)
            guard !servers.isEmpty else {
                states[spec.nzbURL] = .failed(UsenetError.noServers.localizedDescription)
                continue
            }
            running += 1
            states[spec.nzbURL] = .checking
            let pool = pool(for: servers)
            Task {
                let state: State
                do {
                    state = .checked(try await Self.run(spec, pool: pool))
                } catch let error as UsenetNNTPError {
                    state = .failed(UsenetConnectionPool.describe(error))
                } catch {
                    state = .failed(error.localizedDescription)
                }
                self.finish(spec.nzbURL, state)
            }
        }
        if running == 0, queue.isEmpty, !pools.isEmpty { schedulePoolShutdown() }
    }

    private func finish(_ url: URL, _ state: State) {
        states[url] = state
        if case .checked = state { checkedAt[url] = Date() }
        running -= 1
        pump()
    }

    private func pool(for servers: [UsenetServerConfig]) -> UsenetConnectionPool {
        if let pool = pools[servers] { return pool }
        let limited = servers.map { server -> UsenetServerConfig in
            var server = server
            server.maxConnections = min(server.maxConnections, Self.connectionsPerServer)
            return server
        }
        let pool = UsenetConnectionPool(servers: limited)
        pools[servers] = pool
        return pool
    }

    /// The connections close a little after the last check, so a second press reuses them.
    private func schedulePoolShutdown() {
        poolShutdown = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, let self else { return }
            let pools = Array(self.pools.values)
            self.pools = [:]
            self.poolShutdown = nil
            for pool in pools { await pool.shutdown() }
        }
    }

    nonisolated static func run(_ spec: UsenetStreamSpec, pool: UsenetConnectionPool) async throws -> UsenetAvailabilityReport {
        let clock = ContinuousClock()
        let started = clock.now
        let nzb = try await UsenetEngineManager.loadNZB(spec.nzbURL)
        let loaded = clock.now
        let plan = UsenetAvailability.plan(for: nzb, mustInclude: spec.fileMustInclude)
        guard !plan.samples.isEmpty else { throw UsenetError.noPlayableFile }
        let report = try await UsenetAvailability.ask(plan, pool: pool)
        let done = clock.now
        let name = nzb.title ?? UsenetAvailability.contentFiles(of: nzb, mustInclude: spec.fileMustInclude).first?.name ?? "release"
        usenetLog.notice("usenet: check \(name, privacy: .public) — \(report.verdict.rawValue, privacy: .public), \(report.missing)/\(report.checked) sampled articles missing, NZB gaps \(report.nzbGaps), missing volumes \(report.missingVolumes); NZB \(Self.milliseconds(loaded - started)) ms, servers \(Self.milliseconds(done - loaded)) ms")
        return report
    }

    private nonisolated static func milliseconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }
}
